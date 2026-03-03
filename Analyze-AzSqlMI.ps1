#Requires -Version 5.1

<#
.SYNOPSIS
    Analyzes Azure SQL Managed Instance metrics and generates optimization recommendations.

.DESCRIPTION
    Processes instance-level metric CSVs to calculate statistics, classify workload patterns,
    and generate vCore sizing and scheduling recommendations for each managed instance.

.PARAMETER MetricsPath
    Path to directory containing metric CSV files

.EXAMPLE
    $results = .\Analyze-AzSqlManagedInstances.ps1 -MetricsPath "C:\Metrics"
    $results | Export-Csv "mi-recommendations.csv" -NoTypeInformation
    
.EXAMPLE
    $results = .\Analyze-AzSqlManagedInstances.ps1 -MetricsPath "C:\Metrics" | 
        Where-Object { $_.Status -eq 'OPTIMIZE' }
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MetricsPath
)

#region Configuration

# Azure Pricing (West Europe, EUR, monthly, LicenseIncluded, Feb 2025 estimates)
# Prices are per vCore per month
$Pricing = @{
    # General Purpose
    'GP_Gen5_vCore' = 365.0
    'GP_Gen8_vCore' = 380.0  # Gen8 typically 4% more expensive
    
    # Business Critical
    'BC_Gen5_vCore' = 730.0
    'BC_Gen8_vCore' = 760.0
    
    # Storage pricing (per GB per month)
    'Storage_GB_Monthly' = 0.115
}

# Scheduled pause automation cost (EUR per month)
$AutomationCostMonthly = 10

# vCore limits per instance
$vCoreSessionsPerCore = 30000
$vCoreWorkersPerCore = 512

#endregion

#region Helper Functions

function Get-Percentile {
    param([double[]]$Data, [int]$Percentile)
    if ($Data.Count -eq 0) { return 0 }
    $sorted = $Data | Sort-Object
    $index = [Math]::Ceiling($Percentile / 100 * $sorted.Count) - 1
    if ($index -lt 0) { $index = 0 }
    return $sorted[$index]
}

function Get-CoefficientOfVariation {
    param([double[]]$Data)
    if ($Data.Count -eq 0) { return 0 }
    $stats = $Data | Measure-Object -Average -StandardDeviation
    if ($stats.Average -eq 0) { return 0 }
    return ($stats.StandardDeviation / $stats.Average) * 100
}

function Get-LinearTrend {
    param([object[]]$TimeSeries, [string]$ValueProperty)
    if ($TimeSeries.Count -lt 10) { return 0 }
    
    $n = $TimeSeries.Count
    $x = 1..$n
    $y = $TimeSeries.$ValueProperty
    
    $sumX = ($x | Measure-Object -Sum).Sum
    $sumY = ($y | Measure-Object -Sum).Sum
    $sumXY = 0
    $sumXX = 0
    
    for ($i = 0; $i -lt $n; $i++) {
        $sumXY += $x[$i] * $y[$i]
        $sumXX += $x[$i] * $x[$i]
    }
    
    $slope = ($n * $sumXY - $sumX * $sumY) / ($n * $sumXX - $sumX * $sumX)
    $avgY = $sumY / $n
    
    if ($avgY -eq 0) { return 0 }
    
    $monthlyChange = ($slope * 30 * 288) / $avgY * 100
    return $monthlyChange
}

function Get-Autocorrelation {
    param([double[]]$Data, [int]$Lag = 288)  # 24 hours in 5-min intervals
    
    if ($Data.Count -lt ($Lag + 100)) { return 0 }
    
    $n = $Data.Count - $Lag
    $mean = ($Data | Measure-Object -Average).Average
    
    $numerator = 0
    $denominator = 0
    
    for ($i = 0; $i -lt $n; $i++) {
        $numerator += ($Data[$i] - $mean) * ($Data[$i + $Lag] - $mean)
    }
    
    for ($i = 0; $i -lt $Data.Count; $i++) {
        $denominator += [Math]::Pow(($Data[$i] - $mean), 2)
    }
    
    if ($denominator -eq 0) { return 0 }
    return $numerator / $denominator
}

function Get-WeeklyVariance {
    param([object[]]$TimeSeries, [string]$ValueProperty)
    
    if ($TimeSeries.Count -lt 2016) { return 0 }  # Need at least 1 week (7 days × 24 hours × 12 intervals)
    
    $weekdays = $TimeSeries | Where-Object { 
        $dow = ([DateTime]$_.Timestamp).DayOfWeek
        $dow -ne 'Saturday' -and $dow -ne 'Sunday'
    } | ForEach-Object { $_.$ValueProperty }
    
    $weekends = $TimeSeries | Where-Object { 
        $dow = ([DateTime]$_.Timestamp).DayOfWeek
        $dow -eq 'Saturday' -or $dow -eq 'Sunday'
    } | ForEach-Object { $_.$ValueProperty }
    
    if ($weekdays.Count -eq 0 -or $weekends.Count -eq 0) { return 0 }
    
    $weekdayAvg = ($weekdays | Measure-Object -Average).Average
    $weekendAvg = ($weekends | Measure-Object -Average).Average
    
    if ($weekdayAvg -eq 0 -and $weekendAvg -eq 0) { return 0 }
    
    $maxAvg = [Math]::Max($weekdayAvg, $weekendAvg)
    $minAvg = [Math]::Min($weekdayAvg, $weekendAvg)
    
    return [Math]::Abs(($maxAvg - $minAvg) / $maxAvg * 100)
}

function Get-InstanceCost {
    param(
        [string]$ServiceTier,
        [string]$HardwareGeneration,
        [int]$vCores,
        [int]$StorageGB
    )
    
    # Determine pricing key
    $tierPrefix = if ($ServiceTier -eq 'GeneralPurpose') { 'GP' } else { 'BC' }
    $genSuffix = if ($HardwareGeneration -match 'Gen8') { 'Gen8' } else { 'Gen5' }
    $pricingKey = "${tierPrefix}_${genSuffix}_vCore"
    
    if (-not $Pricing.ContainsKey($pricingKey)) {
        Write-Warning "Unknown pricing for $ServiceTier $HardwareGeneration"
        return 0
    }
    
    $vCoreCost = $vCores * $Pricing[$pricingKey]
    $storageCost = $StorageGB * $Pricing['Storage_GB_Monthly']
    
    return $vCoreCost + $storageCost
}

function Get-WeeklyBusyWindows {
    param(
        [object[]]$TimeSeries,
        [string]$ValueProperty,
        [double]$BusyThreshold
    )
    
    if ($TimeSeries.Count -eq 0) { return @() }
    
    # Group by day-of-week + time slot
    $weeklySlots = $TimeSeries | Group-Object {
        $dt = [DateTime]$_.Timestamp
        "$($dt.DayOfWeek) $($dt.ToString('HH:mm'))"
    }
    
    # Calculate average for each weekly slot
    $slotAverages = $weeklySlots | ForEach-Object {
        $parts = $_.Name -split ' '
        [PSCustomObject]@{
            DayOfWeek = $parts[0]
            Time = $parts[1]
            Avg = ($_.Group.$ValueProperty | Measure-Object -Average).Average
        }
    } | Where-Object { $_.Avg -gt $BusyThreshold }
    
    if ($slotAverages.Count -eq 0) { return @() }
    
    # Sort by day order then time
    $dayOrder = @{Monday=1; Tuesday=2; Wednesday=3; Thursday=4; Friday=5; Saturday=6; Sunday=7}
    $slotAverages = $slotAverages | Sort-Object { 
        $dayOrder[$_.DayOfWeek] * 10000 + [int]$_.Time.Replace(':','')
    }
    
    # Group contiguous slots into windows
    $windows = @()
    $currentWindow = $null
    
    foreach ($slot in $slotAverages) {
        if (-not $currentWindow) {
            # Start new window
            $currentWindow = @{
                Day = $slot.DayOfWeek
                Start = $slot.Time
                End = $slot.Time
                AvgUsage = @($slot.Avg)
            }
        }
        elseif ($currentWindow.Day -eq $slot.DayOfWeek) {
            # Same day - check if contiguous (5 minutes apart)
            $currentEndTime = [DateTime]::ParseExact($currentWindow.End, 'HH:mm', $null)
            $slotTime = [DateTime]::ParseExact($slot.Time, 'HH:mm', $null)
            $diffMinutes = ($slotTime - $currentEndTime).TotalMinutes
            
            if ($diffMinutes -eq 5) {
                # Extend current window
                $currentWindow.End = $slot.Time
                $currentWindow.AvgUsage += $slot.Avg
            }
            else {
                # Gap detected - save current window and start new one
                $startTime = [DateTime]::ParseExact($currentWindow.Start, 'HH:mm', $null)
                $endTime = [DateTime]::ParseExact($currentWindow.End, 'HH:mm', $null)
                $durationHours = ($endTime - $startTime).TotalHours + (5.0/60)
                
                $windows += [PSCustomObject]@{
                    Period = "$($currentWindow.Day) $($currentWindow.Start)-$($currentWindow.End)"
                    AvgUsage = [Math]::Round(($currentWindow.AvgUsage | Measure-Object -Average).Average, 2)
                    DurationHours = [Math]::Round($durationHours, 2)
                }
                
                $currentWindow = @{
                    Day = $slot.DayOfWeek
                    Start = $slot.Time
                    End = $slot.Time
                    AvgUsage = @($slot.Avg)
                }
            }
        }
        else {
            # Different day - save current window and start new one
            $startTime = [DateTime]::ParseExact($currentWindow.Start, 'HH:mm', $null)
            $endTime = [DateTime]::ParseExact($currentWindow.End, 'HH:mm', $null)
            $durationHours = ($endTime - $startTime).TotalHours + (5.0/60)
            
            $windows += [PSCustomObject]@{
                Period = "$($currentWindow.Day) $($currentWindow.Start)-$($currentWindow.End)"
                AvgUsage = [Math]::Round(($currentWindow.AvgUsage | Measure-Object -Average).Average, 2)
                DurationHours = [Math]::Round($durationHours, 2)
            }
            
            $currentWindow = @{
                Day = $slot.DayOfWeek
                Start = $slot.Time
                End = $slot.Time
                AvgUsage = @($slot.Avg)
            }
        }
    }
    
    # Add last window
    if ($currentWindow) {
        $startTime = [DateTime]::ParseExact($currentWindow.Start, 'HH:mm', $null)
        $endTime = [DateTime]::ParseExact($currentWindow.End, 'HH:mm', $null)
        $durationHours = ($endTime - $startTime).TotalHours + (5.0/60)
        
        $windows += [PSCustomObject]@{
            Period = "$($currentWindow.Day) $($currentWindow.Start)-$($currentWindow.End)"
            AvgUsage = [Math]::Round(($currentWindow.AvgUsage | Measure-Object -Average).Average, 2)
            DurationHours = [Math]::Round($durationHours, 2)
        }
    }
    
    return $windows
}

function Get-PredictabilityScore {
    param(
        [object[]]$TimeSeries,
        [string]$ValueProperty,
        [double]$BusyThreshold
    )
    
    if ($TimeSeries.Count -lt 288) { return 0 }
    
    # Calculate busy hours per day
    $dailyBusyHours = $TimeSeries | 
        Group-Object { ([DateTime]$_.Timestamp).Date } | 
        ForEach-Object {
            $busySlots = $_.Group | Where-Object { $_.$ValueProperty -gt $BusyThreshold }
            $busySlots.Count / 12
        }
    
    if ($dailyBusyHours.Count -eq 0) { return 0 }
    
    # Calculate coefficient of variation
    $stats = $dailyBusyHours | Measure-Object -Average -StandardDeviation
    
    if ($stats.Average -eq 0) { return 0 }
    
    $cv = ($stats.StandardDeviation / $stats.Average) * 100
    
    # Score: 100 = perfectly predictable, 0 = chaotic
    $score = [Math]::Max(0, [Math]::Min(100, 100 - $cv))
    
    return [Math]::Round($score, 0)
}

function Get-ScheduledPauseCost {
    param(
        [double]$CurrentCost,
        [object[]]$BusyWindows,
        [double]$BufferHours = 0.5
    )
    
    if ($BusyWindows.Count -eq 0) {
        return [PSCustomObject]@{
            RuntimeCost = 0
            AutomationCost = 0
            TotalCost = 0
            ActiveHoursWeekly = 0
            ActiveFraction = 0
        }
    }
    
    # Total busy hours per week
    $busyHoursPerWeek = ($BusyWindows.DurationHours | Measure-Object -Sum).Sum
    
    # Add buffer for startup/shutdown
    $totalActiveHoursPerWeek = $busyHoursPerWeek + ($BusyWindows.Count * $BufferHours * 2)
    
    # Calculate runtime cost
    $activeFraction = $totalActiveHoursPerWeek / 168
    $runtimeCost = $CurrentCost * $activeFraction
    
    return [PSCustomObject]@{
        RuntimeCost = [Math]::Round($runtimeCost, 2)
        AutomationCost = $AutomationCostMonthly
        TotalCost = [Math]::Round($runtimeCost + $AutomationCostMonthly, 2)
        ActiveHoursWeekly = [Math]::Round($totalActiveHoursPerWeek, 1)
        ActiveFraction = [Math]::Round($activeFraction * 100, 1)
    }
}

#endregion

#region Data Import

Write-Verbose "Importing metric files from $MetricsPath"

# Import SKU data
$skuFile = Join-Path $MetricsPath "azsqlmiSKU.csv"
if (-not (Test-Path $skuFile)) {
    throw "SKU file not found: $skuFile"
}
$instances = Import-Csv $skuFile -Delimiter "`t"

# Import metrics
$metricFiles = @{
    CPU     = "azsqlmi_metric_cpu.csv"
    Storage = "azsqlmi_metric_storage.csv"
}

$metrics = @{}
foreach ($metricName in $metricFiles.Keys) {
    $file = Join-Path $MetricsPath $metricFiles[$metricName]
    if (Test-Path $file) {
        Write-Verbose "Importing $metricName metrics"
        $metrics[$metricName] = Import-Csv $file -Delimiter "`t"
    } else {
        Write-Warning "Metric file not found: $file"
        $metrics[$metricName] = @()
    }
}

#endregion

#region Analysis

$results = foreach ($instance in $instances) {
    Write-Verbose "Analyzing instance: $($instance.InstanceName)"
    
    # Initialize result object
    $result = [PSCustomObject]@{
        # Identity
        InstanceName            = $instance.InstanceName
        
        # Current State
        CurrentServiceTier      = $instance.ServiceTier
        CurrentHardwareGen      = $instance.HardwareGeneration
        CurrentvCores           = $instance.vCores
        CurrentStorageGB        = $instance.StorageSizeGB
        LicenseType             = $instance.LicenseType
        
        # Recommendation
        Status                  = 'ANALYZING'
        Classification          = 'UNKNOWN'
        Recommendation          = 'Analyzing...'
        RecommendedvCores       = 0
        Confidence              = 'Medium'
        Priority                = 'Medium'
        Impact                  = 'Medium'
        NextAction              = ''
        Flags                   = ''
        
        # Statistics - Usage
        CPU_Avg                 = $null
        CPU_P95                 = $null
        CPU_Max                 = $null
        CV_CPU                  = $null
        Idle_Percent            = $null
        
        # Statistics - Storage
        Storage_Used_GB         = $null
        Storage_Percent         = $null
        
        # Statistics - Patterns
        Pattern_Autocorrelation = $null
        Weekly_Variance_Percent = $null
        Growth_CPU_Trend        = $null
        Growth_Storage_GB_Per_Month = $null
        Days_Of_Data            = 0
        
        # Busy Period Detection
        Busy_Windows            = $null
        Busy_Hours_Per_Week     = $null
        Active_Hours_Per_Day_Avg = $null
        Pattern_Predictability_Score = $null
        Scheduled_Pause_Feasibility = $null
        
        # Costs
        Current_Cost_EUR_Monthly = 0
        Recommended_Cost_EUR_Monthly = 0
        Savings_EUR_Monthly     = 0
        Savings_Percent         = 0
        Alternative_Recommendation = $null
        Alternative_Cost_EUR_Monthly = $null
        
        # Scheduled Pause Cost Breakdown
        Scheduled_Pause_Runtime_Cost = $null
        Scheduled_Pause_Automation_Cost = $null
        Scheduled_Pause_Active_Hours_Weekly = $null
        Scheduled_Pause_Total_Cost = $null
    }
    
    # Get metrics for this instance
    $cpuData = $metrics.CPU | Where-Object { $_.InstanceName -eq $instance.InstanceName }
    $storageData = $metrics.Storage | Where-Object { $_.InstanceName -eq $instance.InstanceName }
    
    # Check data sufficiency
    if ($cpuData.Count -eq 0) {
        # No data at all - likely permission issue
        $result.Status = 'REVIEW'
        $result.Classification = 'NO_DATA'
        $result.Recommendation = 'No metric data available (check permissions)'
        $result.NextAction = 'Verify metric collection permissions'
        $result.Confidence = 'Low'
        $result.Priority = 'Low'
        $result.Days_Of_Data = 0
        $result.Flags = 'No metric data collected - permission issue or collection failure'
        $result.Current_Cost_EUR_Monthly = Get-InstanceCost -ServiceTier $instance.ServiceTier -HardwareGeneration $instance.HardwareGeneration -vCores $instance.vCores -StorageGB $instance.StorageSizeGB
        $result
        continue
    }
    
    if ($cpuData.Count -lt 2016) {  # Less than 7 days (5-min intervals: 7×24×12)
        $result.Status = 'REVIEW'
        $result.Classification = 'INSUFFICIENT_DATA'
        $result.Recommendation = 'OK (insufficient data for analysis)'
        $result.NextAction = 'Re-analyze after day 30'
        $result.Confidence = 'Low'
        $result.Priority = 'Low'
        $result.Days_Of_Data = [Math]::Round($cpuData.Count / 288, 1)
        $result.Current_Cost_EUR_Monthly = Get-InstanceCost -ServiceTier $instance.ServiceTier -HardwareGeneration $instance.HardwareGeneration -vCores $instance.vCores -StorageGB $instance.StorageSizeGB
        $result
        continue
    }
    
    $result.Days_Of_Data = [Math]::Round($cpuData.Count / 288, 1)
    
    # Calculate CPU statistics
    $cpuValues = $cpuData.Metric_Value
    $result.CPU_Avg = [Math]::Round(($cpuValues | Measure-Object -Average).Average, 2)
    $result.CPU_P95 = [Math]::Round((Get-Percentile -Data $cpuValues -Percentile 95), 2)
    $result.CPU_Max = [Math]::Round(($cpuValues | Measure-Object -Maximum).Maximum, 2)
    $result.CV_CPU = [Math]::Round((Get-CoefficientOfVariation -Data $cpuValues), 2)
    
    $idleCount = ($cpuData | Where-Object { $_.Metric_Value -lt 5 }).Count
    $result.Idle_Percent = [Math]::Round(($idleCount / $cpuData.Count * 100), 2)
    
    $result.Growth_CPU_Trend = [Math]::Round((Get-LinearTrend -TimeSeries $cpuData -ValueProperty 'Metric_Value'), 2)
    $result.Pattern_Autocorrelation = [Math]::Round((Get-Autocorrelation -Data $cpuValues -Lag 288), 2)
    $result.Weekly_Variance_Percent = [Math]::Round((Get-WeeklyVariance -TimeSeries $cpuData -ValueProperty 'Metric_Value'), 2)
    
    # Storage statistics
    if ($storageData.Count -gt 0) {
        $result.Storage_Used_GB = [Math]::Round((($storageData.Metric_Value | Measure-Object -Average).Average / 1024), 2)
        $result.Storage_Percent = [Math]::Round(($result.Storage_Used_GB / $instance.StorageSizeGB * 100), 2)
        
        # Storage growth
        $storageGrowth = Get-LinearTrend -TimeSeries $storageData -ValueProperty 'Metric_Value'
        $result.Growth_Storage_GB_Per_Month = [Math]::Round(($storageGrowth / 100 * $result.Storage_Used_GB), 2)
    }
    
    # Current cost
    $result.Current_Cost_EUR_Monthly = Get-InstanceCost -ServiceTier $instance.ServiceTier -HardwareGeneration $instance.HardwareGeneration -vCores $instance.vCores -StorageGB $instance.StorageSizeGB
    
    # Detect busy windows and calculate predictability
    $busyThreshold = $result.CPU_P95 * 0.10
    $busyWindows = Get-WeeklyBusyWindows -TimeSeries $cpuData -ValueProperty 'Metric_Value' -BusyThreshold $busyThreshold
    
    if ($busyWindows.Count -gt 0) {
        $result.Busy_Windows = ($busyWindows.Period -join ', ')
        $result.Busy_Hours_Per_Week = [Math]::Round(($busyWindows.DurationHours | Measure-Object -Sum).Sum, 1)
        $result.Active_Hours_Per_Day_Avg = [Math]::Round($result.Busy_Hours_Per_Week / 7, 1)
        
        $result.Pattern_Predictability_Score = Get-PredictabilityScore -TimeSeries $cpuData -ValueProperty 'Metric_Value' -BusyThreshold $busyThreshold
        $result.Scheduled_Pause_Feasibility = $result.Pattern_Predictability_Score
    }
    
    #region Decision Tree
    
    # TIER 1: Constraint Triage (simplified for MI - mainly CPU)
    if ($result.CPU_P95 -gt 85) {
        $result.Status = 'UPGRADE'
        $result.Classification = 'CONSTRAINED'
        $result.Recommendation = "Upgrade required: CPU constraint (P95: $($result.CPU_P95)%)"
        $result.Priority = 'High'
        $result.Confidence = 'High'
        $result.RecommendedvCores = $instance.vCores + 2
        $result.NextAction = "Increase vCores from $($instance.vCores) to $($result.RecommendedvCores)"
        $result
        continue
    }
    
    # TIER 2: Growth Trajectory
    $growthTrend = $result.Growth_CPU_Trend
    
    if ($growthTrend -gt 10) {
        $result.Status = 'REVIEW'
        $result.Classification = 'GROWING'
        $result.Recommendation = "CPU growing at $([Math]::Round($growthTrend, 1))% per month - monitor closely"
        $result.Priority = 'Medium'
        $result.NextAction = 'Review in 30 days'
        $result
        continue
    }
    
    if ($growthTrend -lt -20) {
        $result.Status = 'REVIEW'
        $result.Classification = 'DECLINING'
        $result.Recommendation = "Usage declining $([Math]::Abs([Math]::Round($growthTrend, 1)))% per month"
        $result.Priority = 'Medium'
        $result.NextAction = 'Consider decommission or vCore reduction'
        $result
        continue
    }
    
    # TIER 3: Workload Classification
    $cv = $result.CV_CPU
    $idlePct = $result.Idle_Percent
    $autocorr = $result.Pattern_Autocorrelation
    $weeklyVar = $result.Weekly_Variance_Percent
    
    if ($cv -gt 100 -and $idlePct -gt 50) {
        $result.Classification = 'BURSTY'
    }
    elseif ($cv -lt 50 -and $idlePct -gt 70) {
        $result.Classification = 'SPARSE'
    }
    elseif ($autocorr -gt 0.7) {
        $result.Classification = 'PERIODIC'
    }
    elseif ($cv -lt 50 -and $idlePct -lt 70) {
        $result.Classification = 'STEADY'
    }
    elseif ($weeklyVar -gt 50) {
        $result.Classification = 'WEEKEND_WEEKDAY'
    }
    elseif ($cv -gt 100 -and $idlePct -lt 30) {
        $result.Classification = 'CHAOTIC'
    }
    else {
        $result.Classification = 'UNCLASSIFIED'
    }
    
    # TIER 4: Optimization Paths
    
    switch ($result.Classification) {
        'BURSTY' {
            # High variability, significant idle time
            # Calculate scheduled pause cost
            if ($busyWindows.Count -gt 0) {
                $scheduledCostCalc = Get-ScheduledPauseCost -CurrentCost $result.Current_Cost_EUR_Monthly -BusyWindows $busyWindows
                $result.Scheduled_Pause_Runtime_Cost = $scheduledCostCalc.RuntimeCost
                $result.Scheduled_Pause_Automation_Cost = $scheduledCostCalc.AutomationCost
                $result.Scheduled_Pause_Active_Hours_Weekly = $scheduledCostCalc.ActiveHoursWeekly
                $result.Scheduled_Pause_Total_Cost = $scheduledCostCalc.TotalCost
                
                # Also check if vCore reduction is viable
                $optimalvCores = [Math]::Max(4, [Math]::Ceiling($result.CPU_P95 / 100 * $instance.vCores * 1.2))
                
                if ($optimalvCores -lt $instance.vCores) {
                    $reducedCost = Get-InstanceCost -ServiceTier $instance.ServiceTier -HardwareGeneration $instance.HardwareGeneration -vCores $optimalvCores -StorageGB $instance.StorageSizeGB
                    
                    # Compare: current, reduced vCore, scheduled pause
                    $options = @(
                        [PSCustomObject]@{ Name = "Reduce to $optimalvCores vCores"; Cost = $reducedCost }
                    )
                    
                    if ($result.Pattern_Predictability_Score -ge 40) {
                        $options += [PSCustomObject]@{ Name = "Scheduled pause"; Cost = $result.Scheduled_Pause_Total_Cost }
                    }
                    
                    $best = $options | Sort-Object Cost | Select-Object -First 1
                    $alternative = $options | Where-Object { $_.Name -ne $best.Name } | Sort-Object Cost | Select-Object -First 1
                    
                    $result.Status = 'OPTIMIZE'
                    $result.Recommendation = $best.Name
                    $result.RecommendedvCores = if ($best.Name -match 'vCores') { $optimalvCores } else { $instance.vCores }
                    $result.Recommended_Cost_EUR_Monthly = $best.Cost
                    
                    if ($alternative) {
                        $result.Alternative_Recommendation = "$($alternative.Name) (€$($alternative.Cost))"
                        $result.Alternative_Cost_EUR_Monthly = $alternative.Cost
                    }
                    
                    $result.Priority = 'High'
                } else {
                    # Can't reduce vCores, but scheduled pause viable
                    if ($result.Pattern_Predictability_Score -ge 40 -and $result.Scheduled_Pause_Total_Cost -lt $result.Current_Cost_EUR_Monthly * 0.7) {
                        $result.Status = 'OPTIMIZE'
                        $result.Recommendation = "Scheduled pause"
                        $result.Recommended_Cost_EUR_Monthly = $result.Scheduled_Pause_Total_Cost
                        $result.Priority = 'Medium'
                    } else {
                        $result.Status = 'OK'
                        $result.Recommendation = "OK (bursty but vCore count appropriate)"
                        $result.Priority = 'Low'
                    }
                }
                
                if ($result.Scheduled_Pause_Feasibility) {
                    $result.Flags = "Scheduled pause feasibility: $($result.Scheduled_Pause_Feasibility)"
                }
            }
        }
        
        'SPARSE' {
            # Very low usage
            if ($busyWindows.Count -gt 0 -and $result.Pattern_Predictability_Score -ge 60) {
                $scheduledCostCalc = Get-ScheduledPauseCost -CurrentCost $result.Current_Cost_EUR_Monthly -BusyWindows $busyWindows
                $result.Scheduled_Pause_Runtime_Cost = $scheduledCostCalc.RuntimeCost
                $result.Scheduled_Pause_Automation_Cost = $scheduledCostCalc.AutomationCost
                $result.Scheduled_Pause_Active_Hours_Weekly = $scheduledCostCalc.ActiveHoursWeekly
                $result.Scheduled_Pause_Total_Cost = $scheduledCostCalc.TotalCost
                
                $result.Status = 'OPTIMIZE'
                $result.Recommendation = "Scheduled pause (sparse usage)"
                $result.Recommended_Cost_EUR_Monthly = $result.Scheduled_Pause_Total_Cost
                $result.Priority = 'High'
                $result.Flags = "Scheduled pause feasibility: $($result.Scheduled_Pause_Feasibility)"
            } else {
                $result.Status = 'REVIEW'
                $result.Recommendation = "FLAG: Decommission review (sparse usage)"
                $result.Priority = 'Medium'
            }
        }
        
        'STEADY' {
            # Steady workload - optimize vCore count
            $optimalvCores = [Math]::Max(4, [Math]::Ceiling($result.CPU_P95 / 100 * $instance.vCores * 1.2))
            
            if ($result.CPU_P95 -ge 60 -and $result.CPU_P95 -le 80) {
                $result.Status = 'OK'
                $result.Recommendation = "OK (optimal utilization)"
            }
            elseif ($optimalvCores -lt $instance.vCores) {
                $result.Status = 'OPTIMIZE'
                $result.Recommendation = "Reduce vCores to $optimalvCores"
                $result.RecommendedvCores = $optimalvCores
                $result.Recommended_Cost_EUR_Monthly = Get-InstanceCost -ServiceTier $instance.ServiceTier -HardwareGeneration $instance.HardwareGeneration -vCores $optimalvCores -StorageGB $instance.StorageSizeGB
                $result.Priority = 'Medium'
            }
            else {
                $result.Status = 'OK'
                $result.Recommendation = "OK (vCore count appropriate)"
            }
        }
        
        default {
            # PERIODIC, WEEKEND_WEEKDAY, CHAOTIC, UNCLASSIFIED
            $result.Status = 'OK'
            $result.Recommendation = "OK (pattern detected: $($result.Classification))"
            $result.Priority = 'Low'
            
            if ($result.Scheduled_Pause_Feasibility -ge 60) {
                $result.Flags = "Scheduled pause feasibility: $($result.Scheduled_Pause_Feasibility) - consider automation"
            }
        }
    }
    
    #endregion
    
    # TIER 5: Cost validation and Impact assessment
    if ($result.Status -eq 'OPTIMIZE' -and $result.Recommended_Cost_EUR_Monthly -gt 0) {
        $result.Savings_EUR_Monthly = [Math]::Round($result.Current_Cost_EUR_Monthly - $result.Recommended_Cost_EUR_Monthly, 2)
        
        if ($result.Current_Cost_EUR_Monthly -gt 0) {
            $result.Savings_Percent = [Math]::Round(($result.Savings_EUR_Monthly / $result.Current_Cost_EUR_Monthly * 100), 2)
        }
        
        # Set Impact level
        if ($result.Savings_EUR_Monthly -gt 500 -or $result.Savings_Percent -gt 50) {
            $result.Impact = 'High'
        } elseif ($result.Savings_EUR_Monthly -gt 200 -or $result.Savings_Percent -gt 30) {
            $result.Impact = 'Medium'
        } elseif ($result.Savings_EUR_Monthly -gt 0) {
            $result.Impact = 'Low'
        } else {
            $result.Impact = 'None'
        }
        
        # Keep recommendation but adjust priority for low-impact
        if ($result.Savings_EUR_Monthly -lt 100 -and $result.Savings_Percent -lt 15) {
            $result.Impact = 'Low'
            $result.Priority = 'Low'
            if ($result.Flags) {
                $result.Flags += " | Low cost impact: €$($result.Savings_EUR_Monthly)/mo ($($result.Savings_Percent)%)"
            } else {
                $result.Flags = "Low cost impact: €$($result.Savings_EUR_Monthly)/mo ($($result.Savings_Percent)%)"
            }
        }
    }
    
    # Set Impact for non-optimization recommendations
    if ($result.Status -ne 'OPTIMIZE' -and $result.Impact -eq 'Medium') {
        if ($result.Status -eq 'UPGRADE') {
            $result.Impact = 'High'
        } elseif ($result.Status -eq 'REVIEW') {
            $result.Impact = 'Medium'
        } else {
            $result.Impact = 'None'
        }
    }
    
    $result
}

#endregion

# Output results
$results
