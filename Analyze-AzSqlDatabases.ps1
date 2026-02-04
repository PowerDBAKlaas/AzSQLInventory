#Requires -Version 5.1

<#
.SYNOPSIS
    Analyzes Azure SQL Database metrics and generates optimization recommendations.

.DESCRIPTION
    Processes metric CSVs to calculate statistics, classify workload patterns,
    and run through a comprehensive decision tree (Tier 1-5) to generate
    specific recommendations for each database.

.PARAMETER MetricsPath
    Path to directory containing metric CSV files

.PARAMETER OutputPath
    Optional path to export results CSV

.EXAMPLE
    $results = .\Analyze-AzSqlDatabases.ps1 -MetricsPath "C:\Metrics"
    $results | Export-Csv "recommendations.csv" -NoTypeInformation

.EXAMPLE
    $results = .\Analyze-AzSqlDatabases.ps1 -MetricsPath "C:\Metrics" |
        Where-Object { $_.Status -eq 'OPTIMIZE' }
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MetricsPath
)

#region Configuration

# DTU Tier Limits
$DTULimits = @{
    'Basic' = @{ Sessions = 30; Workers = 30; DTU = 5 }
    'S0'    = @{ Sessions = 60; Workers = 200; DTU = 10 }
    'S1'    = @{ Sessions = 90; Workers = 200; DTU = 20 }
    'S2'    = @{ Sessions = 120; Workers = 400; DTU = 50 }
    'S3'    = @{ Sessions = 200; Workers = 400; DTU = 100 }
    'S4'    = @{ Sessions = 400; Workers = 1600; DTU = 200 }
    'S6'    = @{ Sessions = 800; Workers = 1600; DTU = 400 }
    'S7'    = @{ Sessions = 1600; Workers = 3200; DTU = 800 }
    'S9'    = @{ Sessions = 3200; Workers = 6400; DTU = 1600 }
    'S12'   = @{ Sessions = 6400; Workers = 12800; DTU = 3000 }
    'P1'    = @{ Sessions = 200; Workers = 400; DTU = 125 }
    'P2'    = @{ Sessions = 400; Workers = 800; DTU = 250 }
    'P4'    = @{ Sessions = 800; Workers = 1600; DTU = 500 }
    'P6'    = @{ Sessions = 1600; Workers = 3200; DTU = 1000 }
    'P11'   = @{ Sessions = 3200; Workers = 6400; DTU = 1750 }
    'P15'   = @{ Sessions = 6400; Workers = 12800; DTU = 4000 }
}

# vCore per-core limits
$vCoreSessionsPerCore = 30000
$vCoreWorkersPerCore = 512

# Azure Pricing (West Europe, EUR, monthly, Feb 2025 estimates)
$Pricing = @{
    # DTU tiers
    'Basic'              = 4.45
    'S0'                 = 13.39
    'S1'                 = 26.77
    'S2'                 = 66.93
    'S3'                 = 133.86
    'S4'                 = 267.72
    'S6'                 = 535.44
    'S7'                 = 1070.88
    'S9'                 = 2141.76
    'S12'                = 4283.52
    'P1'                 = 401.04
    'P2'                 = 802.08
    'P4'                 = 1604.16
    'P6'                 = 2406.24
    'P11'                = 4011.12
    'P15'                = 6416.64

    # vCore GP (per vCore per month)
    'GP_Gen5_vCore'      = 267.0
    'GP_S_Gen5_vCore'    = 66.75  # Serverless avg (50% discount when paused)

    # vCore BC (per vCore per month)
    'BC_Gen5_vCore'      = 534.0

    # Elastic Pool per eDTU
    'Pool_Standard_eDTU' = 1.34
    'Pool_Premium_eDTU'  = 3.21
}

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
    $mean = ($Data | Measure-Object -Average).Average
    if ($mean -eq 0) { return 0 }
    $variance = ($Data | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average
    $stdDev = [Math]::Sqrt($variance)
    return ($stdDev / $mean) * 100
}

function Get-LinearTrend {
    param([object[]]$TimeSeries, [string]$ValueProperty)
    if ($TimeSeries.Count -lt 2) { return 0 }

    $n = $TimeSeries.Count
    $x = 0..($n - 1)
    $y = $TimeSeries | ForEach-Object { $_.$ValueProperty }

    $sumX = ($x | Measure-Object -Sum).Sum
    $sumY = ($y | Measure-Object -Sum).Sum
    $sumXY = 0..($n - 1) | ForEach-Object { $x[$_] * $y[$_] } | Measure-Object -Sum | Select-Object -ExpandProperty Sum
    $sumX2 = ($x | ForEach-Object { $_ * $_ } | Measure-Object -Sum).Sum

    $slope = ($n * $sumXY - $sumX * $sumY) / ($n * $sumX2 - $sumX * $sumX)
    $meanY = $sumY / $n

    if ($meanY -eq 0) { return 0 }

    # Return trend as % change per month (assuming 30 days of data)
    return ($slope * 30 / $meanY) * 100
}

function Get-Autocorrelation {
    param([double[]]$Data, [int]$Lag = 24)
    if ($Data.Count -lt ($Lag * 2)) { return 0 }

    $mean = ($Data | Measure-Object -Average).Average
    $variance = ($Data | ForEach-Object { [Math]::Pow($_ - $mean, 2) } | Measure-Object -Average).Average

    if ($variance -eq 0) { return 0 }

    $autocovariance = 0
    for ($i = 0; $i -lt ($Data.Count - $Lag); $i++) {
        $autocovariance += ($Data[$i] - $mean) * ($Data[$i + $Lag] - $mean)
    }
    $autocovariance /= ($Data.Count - $Lag)

    return $autocovariance / $variance
}

function Test-BimodalDistribution {
    param([double[]]$Data)
    if ($Data.Count -lt 20) { return $false }

    # Simple bimodal test: check if there are two distinct clusters
    $sorted = $Data | Sort-Object
    $q1 = Get-Percentile -Data $sorted -Percentile 25
    $q3 = Get-Percentile -Data $sorted -Percentile 75
    $median = Get-Percentile -Data $sorted -Percentile 50

    $iqr = $q3 - $q1
    if ($iqr -eq 0) { return $false }

    # Check for gap around median (Hartigan's dip test approximation)
    $midRange = $Data | Where-Object { $_ -gt ($median - $iqr * 0.5) -and $_ -lt ($median + $iqr * 0.5) }
    $midCount = $midRange.Count
    $totalCount = $Data.Count

    # If middle range is sparse (<20% of data), likely bimodal
    return ($midCount / $totalCount) -lt 0.2
}

function Get-WeeklyVariance {
    param([object[]]$TimeSeries, [string]$ValueProperty)
    if ($TimeSeries.Count -lt 168) { return 0 }  # Need at least 1 week

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

function Get-DatabaseCost {
    param(
        [string]$Edition,
        [string]$SkuName,
        [int]$Capacity
    )

    if ($Pricing.ContainsKey($SkuName)) {
        return $Pricing[$SkuName]
    }

    # vCore pricing
    if ($Edition -eq 'GeneralPurpose') {
        if ($SkuName -match 'Serverless') {
            return $Capacity * $Pricing['GP_S_Gen5_vCore']
        }
        return $Capacity * $Pricing['GP_Gen5_vCore']
    }

    if ($Edition -eq 'BusinessCritical') {
        return $Capacity * $Pricing['BC_Gen5_vCore']
    }

    return 0
}

#endregion

#region Data Import

Write-Verbose "Importing metric files from $MetricsPath"

# Import SKU data
$skuFile = Join-Path $MetricsPath 'AzSQLDb_SKU.csv'
if (-not (Test-Path $skuFile)) {
    throw "SKU file not found: $skuFile"
}
$databases = Import-Csv $skuFile

# Import metrics
$metricFiles = @{
    DTU         = 'azsqldb_metric_dtu_consumption_percent.csv'
    CPU         = 'azsqldb_metric_cpu_percent.csv'
    Workers     = 'azsqldb_metric_workers_percent.csv'
    Sessions    = 'azsqldb_metric_sessions_percent.csv'
    Storage     = 'azsqldb_metric_storage_percent.csv'
    Connections = 'azsqldb_metric_connection_successful.csv'
    LogWrite    = 'azsqldb_metric_log_write_percent.csv'
}

$metrics = @{}
foreach ($metricName in $metricFiles.Keys) {
    $file = Join-Path $MetricsPath $metricFiles[$metricName]
    if (Test-Path $file) {
        Write-Verbose "Importing $metricName metrics"
        $metrics[$metricName] = Import-Csv $file
    } else {
        Write-Warning "Metric file not found: $file"
        $metrics[$metricName] = @()
    }
}

#endregion

#region Main Analysis Loop

$results = foreach ($db in $databases) {
    Write-Verbose "Analyzing $($db.ServerName)/$($db.DatabaseName)"

    # Detect database type early
    $isDTU = $db.SkuName -match '^(Basic|Standard|Premium|S\d+|P\d+)$'
    $isInPool = -not [string]::IsNullOrEmpty($db.ElasticPoolName)
    $isServerless = $db.SkuName -match '_S_' -or $db.Edition -match 'Serverless'
    $isHyperscale = $db.Edition -eq 'Hyperscale'

    # Initialize result object
    $result = [PSCustomObject]@{
        # Identity
        ServerName                   = $db.ServerName
        DatabaseName                 = $db.DatabaseName

        # Current State
        CurrentEdition               = $db.Edition
        CurrentSkuName               = $db.SkuName
        CurrentCapacity              = $db.Capacity
        CurrentModel                 = if ($isDTU) { 'DTU' } else { 'vCore' }
        CurrentMaxSizeGB             = if ($db.MaxSizeBytes) { [Math]::Round($db.MaxSizeBytes / 1GB, 2) } else { $db.MaxSizeGB }
        ElasticPoolName              = $db.ElasticPoolName
        IsInPool                     = $isInPool
        IsServerless                 = $isServerless
        IsHyperscale                 = $isHyperscale

        # Recommendation
        Status                       = 'ANALYZING'
        Classification               = 'UNKNOWN'
        Recommendation               = 'Analyzing...'
        RecommendedTier              = ''
        RecommendedCapacity          = 0
        Confidence                   = 'Medium'
        Priority                     = 'Medium'
        NextAction                   = ''
        Flags                        = ''

        # Statistics - Usage
        DTU_Avg                      = 0
        DTU_P95                      = 0
        DTU_Max                      = 0
        CPU_Avg                      = 0
        CPU_P95                      = 0
        CPU_Max                      = 0
        CV_DTU                       = 0
        CV_CPU                       = 0
        Idle_Percent                 = 0

        # Statistics - Resources
        Sessions_Peak_Actual         = 0
        Sessions_Peak_Percent        = 0
        Workers_Peak_Actual          = 0
        Workers_Peak_Percent         = 0
        Storage_Used_GB              = 0
        Storage_Percent              = 0
        LogWrite_P95                 = 0

        # Statistics - Patterns
        Connections_Per_Hour_Avg     = 0
        Pattern_Autocorrelation      = 0
        Weekly_Variance_Percent      = 0
        Growth_DTU_Trend             = 0
        Growth_CPU_Trend             = 0
        Growth_Storage_MB_Per_Month  = 0
        Days_Of_Data                 = 0

        # Decisions
        Serverless_Viable            = $false
        ElasticPool_Candidate        = $false

        # Costs
        Current_Cost_EUR_Monthly     = 0
        Recommended_Cost_EUR_Monthly = 0
        Savings_EUR_Monthly          = 0
        Savings_Percent              = 0
    }

    # Get metrics for this database
    $dbKey = "$($db.ServerName)|$($db.DatabaseName)"

    # Special handling for databases in elastic pools
    if ($isInPool) {
        # Pooled databases don't have individual DTU limits
        # They share the pool's eDTU and should be analyzed differently

        # We can still get CPU, sessions, workers, storage metrics
        $computeData = $metrics.CPU | Where-Object {
            "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
        }

        $sessionsData = $metrics.Sessions | Where-Object {
            "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
        }

        $workersData = $metrics.Workers | Where-Object {
            "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
        }

        $storageData = $metrics.Storage | Where-Object {
            "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
        }

        $connectionsData = $metrics.Connections | Where-Object {
            "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
        }

        $logWriteData = $metrics.LogWrite | Where-Object {
            "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
        }

        # Check data sufficiency
        if ($computeData.Count -lt 168) {
            $result.Status = 'OK'
            $result.Classification = 'IN_POOL'
            $result.Recommendation = "OK (in elastic pool '$($db.ElasticPoolName)', insufficient data)"
            $result.NextAction = 'Monitor pool performance'
            $result.Confidence = 'Low'
            $result.Priority = 'Low'
            $result.Days_Of_Data = [Math]::Round($computeData.Count / 24, 1)
            $result.Flags = 'Part of elastic pool - individual optimization not applicable'
            $result
            continue
        }

        $result.Days_Of_Data = [Math]::Round($computeData.Count / 24, 1)

        # Calculate basic statistics for pooled database
        $cpuValues = $computeData.Nominal_Value
        $result.CPU_Avg = [Math]::Round(($cpuValues | Measure-Object -Average).Average, 2)
        $result.CPU_P95 = [Math]::Round((Get-Percentile -Data $cpuValues -Percentile 95), 2)
        $result.CPU_Max = [Math]::Round(($cpuValues | Measure-Object -Maximum).Maximum, 2)

        if ($sessionsData.Count -gt 0) {
            $result.Sessions_Peak_Percent = [Math]::Round(($sessionsData.Metric_Value | Measure-Object -Maximum).Maximum, 2)
            $result.Sessions_Peak_Actual = [Math]::Round(($sessionsData.Nominal_Value | Measure-Object -Maximum).Maximum, 0)
        }

        if ($workersData.Count -gt 0) {
            $result.Workers_Peak_Percent = [Math]::Round(($workersData.Metric_Value | Measure-Object -Maximum).Maximum, 2)
            $result.Workers_Peak_Actual = [Math]::Round(($workersData.Nominal_Value | Measure-Object -Maximum).Maximum, 0)
        }

        if ($storageData.Count -gt 0) {
            $result.Storage_Percent = [Math]::Round(($storageData.Metric_Value | Measure-Object -Average).Average, 2)
            $result.Storage_Used_GB = [Math]::Round(($result.Storage_Percent / 100) * $result.CurrentMaxSizeGB, 2)
        }

        # Check if hitting pool-level constraints
        if ($result.Sessions_Peak_Percent -gt 80 -or $result.Workers_Peak_Percent -gt 80) {
            $result.Status = 'REVIEW'
            $result.Classification = 'IN_POOL_CONSTRAINED'
            $result.Recommendation = 'Review pool capacity (database hitting pool limits)'
            $result.Priority = 'High'
            $result.NextAction = "Check elastic pool '$($db.ElasticPoolName)' sizing"
            $result.Flags = if ($result.Sessions_Peak_Percent -gt 80) { 'Sessions constrained' } else { 'Workers constrained' }
        } else {
            $result.Status = 'OK'
            $result.Classification = 'IN_POOL'
            $result.Recommendation = "OK (in elastic pool '$($db.ElasticPoolName)')"
            $result.NextAction = 'Monitor pool performance'
            $result.Flags = 'Part of elastic pool - individual optimization not applicable'
        }

        $result
        continue
    }

    # For non-pooled databases, determine if DTU or vCore

    # Get time-series data
    if ($isDTU) {
        $computeData = $metrics.DTU | Where-Object {
            "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
        }

        # Fallback to CPU if DTU metrics missing
        if ($computeData.Count -eq 0) {
            Write-Warning "DTU metrics missing for $dbKey, using CPU metrics as fallback"
            $computeData = $metrics.CPU | Where-Object {
                "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
            }
            $isDTU = $false  # Treat as vCore for analysis
        }
    } else {
        $computeData = $metrics.CPU | Where-Object {
            "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
        }
    }

    $sessionsData = $metrics.Sessions | Where-Object {
        "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
    }

    $workersData = $metrics.Workers | Where-Object {
        "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
    }

    $storageData = $metrics.Storage | Where-Object {
        "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
    }

    $connectionsData = $metrics.Connections | Where-Object {
        "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
    }

    $logWriteData = $metrics.LogWrite | Where-Object {
        "$($_.ServerName)|$($_.DatabaseName)" -eq $dbKey
    }

    # Check data sufficiency (Tier 2)
    if ($computeData.Count -lt 168) {
        # Less than 7 days of hourly data
        $result.Status = 'REVIEW'
        $result.Classification = 'INSUFFICIENT_DATA'
        $result.Recommendation = 'OK (insufficient data for analysis)'
        $result.NextAction = 'Re-analyze after day 30'
        $result.Confidence = 'Low'
        $result.Priority = 'Low'
        $result.Days_Of_Data = [Math]::Round($computeData.Count / 24, 1)
        $result.Current_Cost_EUR_Monthly = Get-DatabaseCost -Edition $db.Edition -SkuName $db.SkuName -Capacity $db.Capacity
        $result
        continue
    }

    $result.Days_Of_Data = [Math]::Round($computeData.Count / 24, 1)

    # Calculate statistics
    if ($isDTU) {
        $dtuValues = $computeData.Nominal_Value
        $result.DTU_Avg = [Math]::Round(($dtuValues | Measure-Object -Average).Average, 2)
        $result.DTU_P95 = [Math]::Round((Get-Percentile -Data $dtuValues -Percentile 95), 2)
        $result.DTU_Max = [Math]::Round(($dtuValues | Measure-Object -Maximum).Maximum, 2)
        $result.CV_DTU = [Math]::Round((Get-CoefficientOfVariation -Data $dtuValues), 2)

        $idleCount = ($computeData | Where-Object { $_.Metric_Value -lt 5 }).Count
        $result.Idle_Percent = [Math]::Round(($idleCount / $computeData.Count * 100), 2)

        $result.Growth_DTU_Trend = [Math]::Round((Get-LinearTrend -TimeSeries $computeData -ValueProperty 'Nominal_Value'), 2)
        $result.Pattern_Autocorrelation = [Math]::Round((Get-Autocorrelation -Data $dtuValues -Lag 24), 2)
        $result.Weekly_Variance_Percent = [Math]::Round((Get-WeeklyVariance -TimeSeries $computeData -ValueProperty 'Nominal_Value'), 2)

        $computeMetricName = 'DTU'
        $computeP95 = $result.DTU_P95
    } else {
        $cpuValues = $computeData.Nominal_Value
        $result.CPU_Avg = [Math]::Round(($cpuValues | Measure-Object -Average).Average, 2)
        $result.CPU_P95 = [Math]::Round((Get-Percentile -Data $cpuValues -Percentile 95), 2)
        $result.CPU_Max = [Math]::Round(($cpuValues | Measure-Object -Maximum).Maximum, 2)
        $result.CV_CPU = [Math]::Round((Get-CoefficientOfVariation -Data $cpuValues), 2)

        $idleCount = ($computeData | Where-Object { $_.Metric_Value -lt 5 }).Count
        $result.Idle_Percent = [Math]::Round(($idleCount / $computeData.Count * 100), 2)

        $result.Growth_CPU_Trend = [Math]::Round((Get-LinearTrend -TimeSeries $computeData -ValueProperty 'Nominal_Value'), 2)
        $result.Pattern_Autocorrelation = [Math]::Round((Get-Autocorrelation -Data $cpuValues -Lag 24), 2)
        $result.Weekly_Variance_Percent = [Math]::Round((Get-WeeklyVariance -TimeSeries $computeData -ValueProperty 'Nominal_Value'), 2)

        $computeMetricName = 'CPU'
        $computeP95 = $result.CPU_P95
    }

    # Sessions/Workers statistics
    if ($sessionsData.Count -gt 0) {
        $result.Sessions_Peak_Percent = [Math]::Round(($sessionsData.Metric_Value | Measure-Object -Maximum).Maximum, 2)
        $result.Sessions_Peak_Actual = [Math]::Round(($sessionsData.Nominal_Value | Measure-Object -Maximum).Maximum, 0)
    }

    if ($workersData.Count -gt 0) {
        $result.Workers_Peak_Percent = [Math]::Round(($workersData.Metric_Value | Measure-Object -Maximum).Maximum, 2)
        $result.Workers_Peak_Actual = [Math]::Round(($workersData.Nominal_Value | Measure-Object -Maximum).Maximum, 0)
    }

    # Storage statistics
    if ($storageData.Count -gt 0) {
        $result.Storage_Percent = [Math]::Round(($storageData.Metric_Value | Measure-Object -Average).Average, 2)
        $result.Storage_Used_GB = [Math]::Round(($result.Storage_Percent / 100) * $result.CurrentMaxSizeGB, 2)

        # Storage growth
        $storageGrowth = Get-LinearTrend -TimeSeries $storageData -ValueProperty 'Metric_Value'
        $result.Growth_Storage_MB_Per_Month = [Math]::Round(($storageGrowth / 100 * $result.CurrentMaxSizeGB * 1024), 0)
    }

    # Connections statistics
    if ($connectionsData.Count -gt 0) {
        $totalConnections = ($connectionsData.Metric_Value | Measure-Object -Sum).Sum
        $totalHours = $connectionsData.Count
        $result.Connections_Per_Hour_Avg = [Math]::Round(($totalConnections / $totalHours), 2)
    }

    # Log write statistics
    if ($logWriteData.Count -gt 0) {
        $result.LogWrite_P95 = [Math]::Round((Get-Percentile -Data $logWriteData.Metric_Value -Percentile 95), 2)
    }

    # Current cost
    $result.Current_Cost_EUR_Monthly = Get-DatabaseCost -Edition $db.Edition -SkuName $db.SkuName -Capacity $db.Capacity

    #region Decision Tree

    # TIER 1: Constraint Triage
    $constraintViolation = $false
    $constraintReason = ''

    if ($result.Sessions_Peak_Percent -gt 80) {
        $constraintViolation = $true
        $constraintReason = 'Sessions constraint'
    }

    if ($result.Workers_Peak_Percent -gt 80) {
        $constraintViolation = $true
        $constraintReason = if ($constraintReason) { "$constraintReason + Workers constraint" } else { 'Workers constraint' }
    }

    if ($result.Storage_Percent -gt 90) {
        $constraintViolation = $true
        $constraintReason = if ($constraintReason) { "$constraintReason + Storage constraint" } else { 'Storage constraint' }
    }

    if ($constraintViolation) {
        $result.Status = 'UPGRADE'
        $result.Classification = 'CONSTRAINED'
        $result.Recommendation = "Upgrade required: $constraintReason"
        $result.Priority = 'High'
        $result.Confidence = 'High'
        $result.Flags = $constraintReason

        # Suggest next tier
        if ($isDTU) {
            $tiers = @('S0', 'S1', 'S2', 'S3', 'S4', 'S6', 'S7', 'S9', 'S12', 'P1', 'P2', 'P4', 'P6', 'P11', 'P15')
            $currentIndex = $tiers.IndexOf($db.SkuName)
            if ($currentIndex -ge 0 -and $currentIndex -lt ($tiers.Count - 1)) {
                $result.RecommendedTier = $tiers[$currentIndex + 1]
                $result.NextAction = "Upgrade to $($result.RecommendedTier)"
            } else {
                $result.NextAction = 'Review tier upgrade options'
            }
        } else {
            $result.RecommendedTier = 'Add vCores or switch to BusinessCritical'
            $result.NextAction = 'Review vCore scaling options'
        }

        $result
        continue
    }

    # TIER 2: Growth/Decline Detection
    $growthTrend = if ($isDTU) { $result.Growth_DTU_Trend } else { $result.Growth_CPU_Trend }

    # Check storage growth (skip for Hyperscale - it auto-scales)
    if (-not $isHyperscale -and $result.Growth_Storage_MB_Per_Month -gt 0) {
        $monthsUntilFull = ($result.CurrentMaxSizeGB * 1024 - $result.Storage_Used_GB * 1024) / $result.Growth_Storage_MB_Per_Month
        if ($monthsUntilFull -lt 6 -and $monthsUntilFull -gt 0) {
            $result.Status = 'UPGRADE'
            $result.Classification = 'GROWING'
            $result.Recommendation = "Storage will max out in $([Math]::Round($monthsUntilFull, 1)) months"
            $result.Priority = if ($monthsUntilFull -lt 1) { 'Immediate' } else { 'High' }
            $result.RecommendedTier = if ($result.CurrentMaxSizeGB -gt 1000) { 'Hyperscale' } else { 'Increase max size or upgrade tier' }
            $result.NextAction = 'Plan storage expansion'
            $result.Confidence = 'High'
            $result
            continue
        }
    }

    # Check compute growth
    if ($growthTrend -gt 20) {
        $result.Status = 'UPGRADE'
        $result.Classification = 'GROWING'
        $result.Recommendation = "$computeMetricName growing at $([Math]::Round($growthTrend, 1))% per month"
        $result.Priority = 'High'
        $result.NextAction = 'Monitor and plan capacity increase'
        $result.Confidence = 'Medium'
        $result
        continue
    }

    # Check decline
    if ($growthTrend -lt -20) {
        $result.Status = 'REVIEW'
        $result.Classification = 'DECLINING'
        $result.Flags = "Usage declining at $([Math]::Round([Math]::Abs($growthTrend), 1))% per month"

        if ($growthTrend -lt -50) {
            $result.Recommendation = 'URGENT: Decommission candidate'
            $result.Priority = 'Immediate'
            $result.NextAction = 'Business review for decommissioning'
        } else {
            $result.Recommendation = 'FLAG: Decommission candidate or aggressive downgrade'
            $result.Priority = 'Medium'
            $result.NextAction = 'Business review or downgrade with monthly monitoring'
        }

        $result.Confidence = 'High'
        $result
        continue
    }

    # TIER 3: Workload Classification
    $cv = if ($isDTU) { $result.CV_DTU } else { $result.CV_CPU }
    $idle = $result.Idle_Percent
    $autocorr = $result.Pattern_Autocorrelation
    $weeklyVar = $result.Weekly_Variance_Percent

    # Check bimodal (batch-heavy)
    $computeValues = if ($isDTU) { $computeData.Nominal_Value } else { $computeData.Nominal_Value }
    $isBimodal = Test-BimodalDistribution -Data $computeValues

    if ($isBimodal) {
        $result.Classification = 'BATCH_HEAVY'
    } elseif ($weeklyVar -gt 50) {
        $result.Classification = 'WEEKEND_WEEKDAY'
    } elseif ($cv -lt 50 -and $idle -gt 70) {
        $result.Classification = 'SPARSE'
    } elseif ($cv -lt 50 -and $idle -lt 70) {
        $result.Classification = 'STEADY'
    } elseif ($cv -ge 50 -and $cv -lt 100 -and $autocorr -gt 0.7) {
        $result.Classification = 'PERIODIC'
    } elseif ($cv -ge 100 -and $idle -gt 50) {
        $result.Classification = 'BURSTY'
    } elseif ($cv -ge 50 -and $idle -lt 30) {
        $result.Classification = 'CHAOTIC'
    } elseif ($cv -ge 50 -and $idle -ge 30 -and $idle -le 50) {
        if ($autocorr -gt 0.4) {
            $result.Classification = 'PERIODIC'
        } else {
            $result.Classification = 'CHAOTIC'
        }
    } else {
        $result.Classification = 'UNCLASSIFIED'
    }

    # TIER 4: Optimization Paths

    switch ($result.Classification) {
        'BURSTY' {
            # Tier 4A: Serverless viability

            # If already serverless, optimize min/max vCore
            if ($isServerless) {
                $result.Serverless_Viable = $true
                $result.Status = 'OPTIMIZE'

                # Calculate optimal vCore range
                $optimalMinVCore = [Math]::Max(0.5, [Math]::Ceiling($result.CPU_P95 / 100 * 0.8))
                $optimalMaxVCore = [Math]::Max($optimalMinVCore, [Math]::Ceiling($result.CPU_Max / 100 * 1.2))

                # Parse current min/max from SKU name (e.g., GP_S_Gen5_2)
                # Actual min/max would need to come from database properties
                $currentVCores = $db.Capacity

                if ($optimalMaxVCore -lt $currentVCores) {
                    $result.Recommendation = 'Optimize serverless vCore range'
                    $result.RecommendedTier = "GP_S_Gen5_$optimalMinVCore-$optimalMaxVCore"
                    $result.RecommendedCapacity = $optimalMinVCore
                    $result.Recommended_Cost_EUR_Monthly = $optimalMinVCore * $Pricing['GP_S_Gen5_vCore']
                    $result.Priority = 'Medium'
                    $result.NextAction = 'Adjust serverless min/max vCore settings'
                } else {
                    $result.Status = 'OK'
                    $result.Recommendation = 'OK (serverless settings appropriate)'
                    $result.Priority = 'Low'
                }
            } else {
                # Not serverless yet - check if viable
                $serverlessDisqualifiers = @()

                if ($result.Connections_Per_Hour_Avg -gt 12) {
                    # >1 per 5 min
                    $serverlessDisqualifiers += 'High connection frequency'
                }

                if ($result.LogWrite_P95 -gt 40) {
                    $serverlessDisqualifiers += 'Write-heavy workload'
                }

                if ($serverlessDisqualifiers.Count -eq 0) {
                    $result.Serverless_Viable = $true
                    $result.Status = 'OPTIMIZE'

                    # Calculate vCore size
                    $minVCore = [Math]::Max(0.5, [Math]::Ceiling($result.CPU_P95 / 100))
                    $maxVCore = [Math]::Max($minVCore, [Math]::Ceiling($result.CPU_Max / 100 * 1.2))

                    $result.Recommendation = 'Migrate to Serverless'
                    $result.RecommendedTier = "GP_S_Gen5_$minVCore-$maxVCore"
                    $result.RecommendedCapacity = $minVCore
                    $result.Recommended_Cost_EUR_Monthly = $minVCore * $Pricing['GP_S_Gen5_vCore']
                    $result.Priority = 'High'
                    $result.NextAction = 'Test serverless migration'
                } else {
                    $result.Serverless_Viable = $false
                    $result.Flags = "Serverless blocked: $($serverlessDisqualifiers -join ', ')"
                    # Fallback to Tier 4C
                    $result.Classification = 'BURSTY_PROVISIONED'
                }
            }
        }

        'SPARSE' {
            # Similar to BURSTY for serverless
            if ($isServerless) {
                # Already serverless - optimize
                $optimalMinVCore = 0.5
                $optimalMaxVCore = [Math]::Max(0.5, [Math]::Ceiling($result.CPU_Max / 100 * 1.2))

                $result.Serverless_Viable = $true
                $result.Status = 'OK'
                $result.Recommendation = 'OK (serverless appropriate for sparse usage)'
                $result.Priority = 'Low'

                if ($optimalMaxVCore -lt $db.Capacity) {
                    $result.Status = 'OPTIMIZE'
                    $result.Recommendation = 'Reduce serverless max vCore'
                    $result.RecommendedTier = "GP_S_Gen5_$optimalMinVCore-$optimalMaxVCore"
                    $result.RecommendedCapacity = $optimalMinVCore
                    $result.Recommended_Cost_EUR_Monthly = $optimalMinVCore * $Pricing['GP_S_Gen5_vCore']
                    $result.Priority = 'Medium'
                }
            } elseif ($result.Connections_Per_Hour_Avg -lt 2) {
                $result.Serverless_Viable = $true
                $result.Status = 'OPTIMIZE'
                $result.Recommendation = 'Migrate to Serverless (sparse usage)'
                $result.RecommendedTier = 'GP_S_Gen5_0.5-1'
                $result.RecommendedCapacity = 0.5
                $result.Recommended_Cost_EUR_Monthly = 0.5 * $Pricing['GP_S_Gen5_vCore']
                $result.Priority = 'High'
            } else {
                $result.Status = 'REVIEW'
                $result.Recommendation = 'FLAG: Decommission review (sparse usage but connections prevent serverless)'
                $result.Priority = 'Medium'
            }
        }

        'PERIODIC' {
            # Tier 4B: Elastic pool candidate
            $result.ElasticPool_Candidate = $true
            $result.Status = 'OPTIMIZE'
            $result.Recommendation = 'Elastic pool candidate (predictable pattern)'
            $result.Flags = 'Requires multi-DB analysis for pool sizing'
            $result.Priority = 'Medium'
        }

        'WEEKEND_WEEKDAY' {
            # Tier 4B: Scheduled scaling or pool
            $result.ElasticPool_Candidate = $true
            $result.Status = 'OPTIMIZE'
            $result.Recommendation = 'Scheduled scaling OR elastic pool'
            $result.Flags = "Weekly pattern: weekday/weekend variance $([Math]::Round($weeklyVar, 0))%"
            $result.Priority = 'Medium'
        }

        'BATCH_HEAVY' {
            # Tier 4D: Workload split analysis
            $result.Status = 'OPTIMIZE'
            $result.Recommendation = 'Consider workload split (OLTP + batch)'
            $result.Flags = 'Bimodal usage detected'
            $result.Priority = 'Medium'
            $result.NextAction = 'Assess if batch can be separated'
        }

        'CHAOTIC' {
            # Tier 4F: Conservative provisioning
            $result.Status = 'OK'
            $targetCapacity = $computeP95 * 1.5  # 1.5x safety margin
            $currentCapacity = if ($isDTU) { $DTULimits[$db.SkuName].DTU } else { $db.Capacity * 100 }

            # Hyperscale cannot downgrade
            if ($isHyperscale) {
                $result.Recommendation = 'OK (Hyperscale - high variance, query optimization advised)'
                $result.Flags = 'Chaotic pattern - Hyperscale tier cannot downgrade'
            } elseif ($targetCapacity -lt $currentCapacity * 0.7) {
                $result.Recommendation = 'Conservative downgrade possible (high variance workload)'
                $result.Status = 'OPTIMIZE'
                $result.Priority = 'Low'
            } else {
                $result.Recommendation = 'OK (high variance, query optimization advised)'
            }

            if (-not $result.Flags) {
                $result.Flags = 'Chaotic pattern - unpredictable peaks'
            }
            $result.Confidence = 'Low'
        }

        'UNCLASSIFIED' {
            # Tier 4F: Conservative
            $result.Status = 'OK'
            $result.Recommendation = 'OK (workload pattern unclear)'
            $result.Flags = 'Unclassified pattern'
            $result.Confidence = 'Low'
        }

        default {
            # STEADY, BURSTY_PROVISIONED, or fallback
            # Tier 4C: Steady state optimization

            # Calculate optimal tier (60-75% utilization target)
            $targetUtilization = 70
            $optimalCapacity = $computeP95 * 1.2  # 20% headroom

            if ($isDTU) {
                # Find optimal DTU tier
                $tiers = @('S0', 'S1', 'S2', 'S3', 'S4', 'S6', 'S7', 'S9', 'S12')
                $optimalTier = $null

                foreach ($tier in $tiers) {
                    $tierCapacity = $DTULimits[$tier].DTU
                    if ($optimalCapacity -le ($tierCapacity * 0.75)) {
                        $optimalTier = $tier
                        break
                    }
                }

                if (-not $optimalTier) {
                    # Check Premium
                    $premiumTiers = @('P1', 'P2', 'P4', 'P6', 'P11', 'P15')
                    foreach ($tier in $premiumTiers) {
                        $tierCapacity = $DTULimits[$tier].DTU
                        if ($optimalCapacity -le ($tierCapacity * 0.75)) {
                            $optimalTier = $tier
                            break
                        }
                    }
                }

                if ($optimalTier) {
                    $currentCapacityValue = $DTULimits[$db.SkuName].DTU
                    $optimalCapacityValue = $DTULimits[$optimalTier].DTU

                    if ($computeP95 -ge ($currentCapacityValue * 0.6) -and $computeP95 -le ($currentCapacityValue * 0.8)) {
                        # Current tier is optimal
                        $result.Status = 'OK'
                        $result.Recommendation = 'OK (optimal utilization)'
                        $result.Confidence = 'High'
                    } elseif ($optimalCapacityValue -lt $currentCapacityValue) {
                        # Can downgrade
                        $result.Status = 'OPTIMIZE'
                        $result.Recommendation = "Downgrade to $optimalTier"
                        $result.RecommendedTier = $optimalTier
                        $result.Recommended_Cost_EUR_Monthly = Get-DatabaseCost -Edition 'Standard' -SkuName $optimalTier -Capacity 0
                        $result.Priority = 'Medium'
                        $result.Confidence = 'High'
                    } else {
                        $result.Status = 'OK'
                        $result.Recommendation = 'OK (tier appropriate)'
                    }
                } else {
                    # Very high usage, consider vCore
                    $result.Status = 'OPTIMIZE'
                    $result.Recommendation = 'Consider migration to vCore (high DTU usage)'
                    $result.Priority = 'Medium'
                }
            } else {
                # vCore optimization

                # Hyperscale special handling
                if ($isHyperscale) {
                    # Hyperscale cannot easily downgrade, only optimize vCores
                    $optimalVCores = [Math]::Ceiling($result.CPU_P95 / 100 * 1.2)

                    if ($result.CPU_P95 -ge 60 -and $result.CPU_P95 -le 80) {
                        $result.Status = 'OK'
                        $result.Recommendation = 'OK (Hyperscale utilization optimal)'
                        $result.Flags = 'Hyperscale tier - storage auto-scales'
                    } elseif ($optimalVCores -lt $db.Capacity) {
                        $result.Status = 'OPTIMIZE'
                        $result.Recommendation = "Reduce Hyperscale vCores to $optimalVCores"
                        $result.RecommendedCapacity = $optimalVCores
                        $result.Recommended_Cost_EUR_Monthly = $optimalVCores * $Pricing['GP_Gen5_vCore']
                        $result.Priority = 'Medium'
                        $result.Flags = 'Hyperscale tier - cannot downgrade to non-Hyperscale'
                    } else {
                        $result.Status = 'OK'
                        $result.Recommendation = 'OK (Hyperscale vCores appropriate)'
                        $result.Flags = 'Hyperscale tier - storage auto-scales'
                    }
                } else {
                    # Regular vCore optimization
                    $optimalVCores = [Math]::Ceiling($result.CPU_P95 / 100 * 1.2)

                    if ($result.CPU_P95 -ge 60 -and $result.CPU_P95 -le 80) {
                        $result.Status = 'OK'
                        $result.Recommendation = 'OK (optimal utilization)'
                    } elseif ($optimalVCores -lt $db.Capacity) {
                        $result.Status = 'OPTIMIZE'
                        $result.Recommendation = "Reduce vCores to $optimalVCores"
                        $result.RecommendedCapacity = $optimalVCores
                        $result.Recommended_Cost_EUR_Monthly = $optimalVCores * $Pricing['GP_Gen5_vCore']
                        $result.Priority = 'Medium'
                    } else {
                        $result.Status = 'OK'
                        $result.Recommendation = 'OK (vCore appropriate)'
                    }
                }
            }
        }
    }

    # TIER 5: Cost validation
    if ($result.Status -eq 'OPTIMIZE' -and $result.Recommended_Cost_EUR_Monthly -gt 0) {
        $result.Savings_EUR_Monthly = [Math]::Round($result.Current_Cost_EUR_Monthly - $result.Recommended_Cost_EUR_Monthly, 2)

        if ($result.Current_Cost_EUR_Monthly -gt 0) {
            $result.Savings_Percent = [Math]::Round(($result.Savings_EUR_Monthly / $result.Current_Cost_EUR_Monthly * 100), 2)
        }

        # Cost threshold validation
        if ($result.Savings_EUR_Monthly -lt 50 -and $result.Savings_Percent -lt 30) {
            $result.Status = 'OK'
            $result.Recommendation = 'OK (savings too small to justify migration)'
            $result.Flags = "Potential savings: €$($result.Savings_EUR_Monthly)/mo ($($result.Savings_Percent)%)"
            $result.Priority = 'Low'
        }
    }

    #endregion

    $result
}

#endregion

# Output results
$results
