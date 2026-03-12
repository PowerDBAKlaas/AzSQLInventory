#Requires -Modules Az.Accounts, Az.ResourceGraph, Az.Monitor

<#
.SYNOPSIS
    Identifies underused Azure SQL Databases across all subscriptions.

.DESCRIPTION
    Enumerates all SQL Databases via Azure Resource Graph, pulls 30 days of
    hourly metrics from Azure Monitor (free tier, no Log Analytics required),
    calculates per-database underuse scores, and exports to CSV and HTML.

    Metrics evaluated:
        - CPU %                 : % of hours below 10%
        - DTU %                 : % of hours below 10% (DTU-tier only)
        - Sessions %            : % of hours below 5%
        - Successful Connections: % of hours with zero connections (idle)
        - Storage Used %        : current max — low % on large allocation = waste

.PARAMETER OutputPath
    Folder to write CSV and HTML output. Defaults to current directory.

.PARAMETER DaysBack
    Number of days to analyse. Default: 30. Max 30 (hourly granularity limit).

.PARAMETER CpuThresholdPct
    CPU % below which an hour is considered idle. Default: 10.

.PARAMETER DtuThresholdPct
    DTU % below which an hour is considered idle. Default: 10.

.PARAMETER SessionsThresholdPct
    Sessions % below which an hour is considered idle. Default: 5.

.PARAMETER UnderuseScoreThreshold
    Minimum composite score (0–100) to include in output. Default: 70.
    Higher = more confident the DB is underused.

.PARAMETER SubscriptionIds
    Optional array of subscription IDs to limit scope.
    Defaults to all accessible subscriptions.

.EXAMPLE
    .\Find-AzSqlUnderusedDatabases.ps1

.EXAMPLE
    .\Find-AzSqlUnderusedDatabases.ps1 -DaysBack 14 -UnderuseScoreThreshold 80 -OutputPath C:\Reports
#>

[CmdletBinding()]
param (
    [string]   $OutputPath              = '.',
    [int]      $DaysBack                = 30,
    [double]   $CpuThresholdPct         = 10,
    [double]   $DtuThresholdPct         = 10,
    [double]   $SessionsThresholdPct    = 5,
    [int]      $UnderuseScoreThreshold  = 70,
    [string[]] $SubscriptionIds         = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helpers ──────────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "`n[$([datetime]::Now.ToString('HH:mm:ss'))] $Message" -ForegroundColor $Color
}

function Write-Done  { Write-Host '  ✓ Done' -ForegroundColor Green }
function Write-Skip  { param([string]$Msg) Write-Host "  – $Msg" -ForegroundColor DarkGray }

# Invoke ARG with automatic paging (1000-record limit per request)
function Invoke-ArgQuery {
    param([string]$Query, [string[]]$Subscriptions)

    $results   = [System.Collections.Generic.List[PSObject]]::new()
    $skipToken = $null

    do {
        $params = @{ Query = $Query }
        if ($Subscriptions.Count -gt 0) { $params['Subscription'] = $Subscriptions }
        if ($skipToken)                  { $params['SkipToken']    = $skipToken }

        $page      = Search-AzGraph @params -First 1000
        $skipToken = $page.SkipToken

        foreach ($row in $page) { $results.Add($row) }

    } while ($skipToken)

    return $results
}

# Get a single metric time-series for one resource via Get-AzMetric
# Returns array of (TimeStamp, Value) or empty if metric not available
function Get-MetricSeries {
    param(
        [string]   $ResourceId,
        [string]   $MetricName,
        [datetime] $StartTime,
        [datetime] $EndTime,
        [string]   $Aggregation = 'Average',  # Average | Total | Maximum
        [string]   $SubscriptionId
    )

    try {
        # Set context to correct subscription for this resource
        $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop

        $metric = Get-AzMetric `
            -ResourceId   $ResourceId `
            -MetricName   $MetricName `
            -StartTime    $StartTime `
            -EndTime      $EndTime `
            -TimeGrain    '01:00:00' `
            -AggregationType $Aggregation `
            -ErrorAction  Stop

        $series = $metric.Data |
            Where-Object { $null -ne $_.$Aggregation } |
            Select-Object TimeStamp, @{ N = 'Value'; E = { $_.$Aggregation } }

        return @($series)
    }
    catch {
        return @()
    }
}

# Calculate % of data points below a threshold
function Get-PctBelow {
    param([object[]]$Series, [double]$Threshold)
    if ($Series.Count -eq 0) { return $null }
    $below = ($Series | Where-Object { $_.Value -lt $Threshold }).Count
    return [math]::Round(($below / $Series.Count) * 100, 1)
}

# Calculate % of data points equal to zero
function Get-PctZero {
    param([object[]]$Series)
    if ($Series.Count -eq 0) { return $null }
    $zero = ($Series | Where-Object { $_.Value -eq 0 }).Count
    return [math]::Round(($zero / $Series.Count) * 100, 1)
}

#endregion

#region ── Initialise ───────────────────────────────────────────────────────────

Write-Step 'Verifying Azure connection...'
try   { $null = Get-AzContext -ErrorAction Stop }
catch { throw 'Not connected to Azure. Run Connect-AzAccount first.' }
Write-Done

$EndTime   = Get-Date
$StartTime = $EndTime.AddDays(-$DaysBack)
$OutputPath = Resolve-Path $OutputPath

Write-Host "  Time range : $($StartTime.ToString('yyyy-MM-dd HH:mm')) → $($EndTime.ToString('yyyy-MM-dd HH:mm'))"
Write-Host "  Output     : $OutputPath"

#endregion

#region ── Enumerate databases ──────────────────────────────────────────────────

Write-Step 'Enumerating SQL Databases via Resource Graph...'

$argQuery = @'
Resources
| where type =~ 'microsoft.sql/servers/databases'
| where name != 'master'
| extend
    ServerName  = tostring(split(id, '/')[8]),
    Tier        = tostring(sku.tier),
    Edition     = tostring(sku.name),
    Capacity    = toint(sku.capacity),
    AllocatedGB = round(todouble(properties.maxSizeBytes) / 1073741824, 1),
    Status      = tostring(properties.status),
    IsDtuTier   = sku.tier in~ ('Basic','Standard','Premium')
| project
    id, name, subscriptionId, resourceGroup, location,
    ServerName, Tier, Edition, Capacity, AllocatedGB, Status, IsDtuTier
'@

$databases = Invoke-ArgQuery -Query $argQuery -Subscriptions $SubscriptionIds

if ($databases.Count -eq 0) {
    Write-Warning 'No SQL Databases found. Check subscription scope and permissions.'
    exit 0
}

Write-Host "  Found $($databases.Count) databases across $($databases | Select-Object -ExpandProperty subscriptionId -Unique | Measure-Object | Select-Object -ExpandProperty Count) subscriptions"

# Resolve subscription names for display
$subQuery = @'
ResourceContainers
| where type == 'microsoft.resources/subscriptions'
| project subscriptionId, SubscriptionName = name
'@
$subNames = Invoke-ArgQuery -Query $subQuery -Subscriptions $SubscriptionIds |
    Group-Object subscriptionId |
    ForEach-Object { [PSCustomObject]@{ SubscriptionId = $_.Name; SubscriptionName = $_.Group[0].SubscriptionName } }
$subLookup = @{}
foreach ($s in $subNames) { $subLookup[$s.SubscriptionId] = $s.SubscriptionName }

#endregion

#region ── Collect metrics ──────────────────────────────────────────────────────

Write-Step "Collecting metrics for $($databases.Count) databases (this takes a while)..."

$results = [System.Collections.Generic.List[PSObject]]::new()
$i       = 0

foreach ($db in $databases) {
    $i++
    $pct  = [math]::Round(($i / $databases.Count) * 100)
    Write-Progress -Activity 'Collecting Azure Monitor metrics' `
                   -Status   "$i / $($databases.Count) — $($db.name)" `
                   -PercentComplete $pct

    $subId = $db.subscriptionId
    $rid   = $db.id

    # ── CPU (always available)
    $cpuSeries = @(Get-MetricSeries -ResourceId $rid -MetricName 'cpu_percent' `
                     -StartTime $StartTime -EndTime $EndTime `
                     -Aggregation 'Average' -SubscriptionId $subId
    $cpuPctBelow = Get-PctBelow -Series $cpuSeries -Threshold $CpuThresholdPct

    # ── DTU (DTU-tier only; null = vCore tier)
    $dtuPctBelow = $null
    if ($db.IsDtuTier) {
        $dtuSeries = @(Get-MetricSeries -ResourceId $rid -MetricName 'dtu_consumption_percent' `
                         -StartTime $StartTime -EndTime $EndTime `
                         -Aggregation 'Average' -SubscriptionId $subId
        $dtuPctBelow = Get-PctBelow -Series $dtuSeries -Threshold $DtuThresholdPct
    }

    # ── Sessions %
    $sessSeries = @(Get-MetricSeries -ResourceId $rid -MetricName 'sessions_percent' `
                      -StartTime $StartTime -EndTime $EndTime `
                      -Aggregation 'Average' -SubscriptionId $subId
    $sessPctBelow = Get-PctBelow -Series $sessSeries -Threshold $SessionsThresholdPct

    # ── Successful connections (Total per hour; zero = idle that hour)
    $connSeries = @(Get-MetricSeries -ResourceId $rid -MetricName 'connection_successful' `
                      -StartTime $StartTime -EndTime $EndTime `
                      -Aggregation 'Total' -SubscriptionId $subId
    $connPctZero = Get-PctZero -Series $connSeries

    # ── Storage % (Maximum over period — single value for allocation waste)
    $storSeries = @(Get-MetricSeries -ResourceId $rid -MetricName 'storage_percent' `
                      -StartTime $StartTime -EndTime $EndTime `
                      -Aggregation 'Maximum' -SubscriptionId $subId
    $storMax    = if ($storSeries.Count -gt 0) {
                      [math]::Round(($storSeries | Measure-Object Value -Maximum).Maximum, 1)
                  } else { $null }
    # Storage underuse: low % on large DB. Score = inverse (100 - storMax) weighted by size
    $storScore  = if ($null -ne $storMax -and $db.AllocatedGB -ge 10) {
                      [math]::Round([math]::Max(0, 100 - $storMax), 1)
                  } else { $null }

    # ── Composite underuse score (0–100, higher = more underused)
    # Weights: CPU 30%, Sessions 25%, Connections 25%, DTU/Storage 10% each
    # If DTU not available, redistribute weight to CPU
    $scores  = [System.Collections.Generic.List[double]]::new()
    $weights = [System.Collections.Generic.List[double]]::new()

    if ($null -ne $cpuPctBelow)  { $scores.Add($cpuPctBelow);  $weights.Add(30) }
    if ($null -ne $sessPctBelow) { $scores.Add($sessPctBelow); $weights.Add(25) }
    if ($null -ne $connPctZero)  { $scores.Add($connPctZero);  $weights.Add(25) }
    if ($null -ne $dtuPctBelow)  { $scores.Add($dtuPctBelow);  $weights.Add(10) }
    if ($null -ne $storScore)    { $scores.Add($storScore);    $weights.Add(10) }

    $compositeScore = $null
    if ($scores.Count -gt 0) {
        $totalWeight    = ($weights | Measure-Object -Sum).Sum
        $weightedSum    = 0
        for ($j = 0; $j -lt $scores.Count; $j++) {
            $weightedSum += $scores[$j] * $weights[$j]
        }
        $compositeScore = [math]::Round($weightedSum / $totalWeight, 1)
    }

    $results.Add([PSCustomObject]@{
        SubscriptionName    = $subLookup[$subId] ?? $subId
        SubscriptionId      = $subId
        ResourceGroup       = $db.resourceGroup
        ServerName          = $db.ServerName
        DatabaseName        = $db.name
        Location            = $db.location
        Tier                = $db.Tier
        Edition             = $db.Edition
        'vCores/DTU'        = $db.Capacity
        'AllocatedGB'       = $db.AllocatedGB
        Status              = $db.Status
        'CPU_PctHoursBelow10'      = $cpuPctBelow
        'DTU_PctHoursBelow10'      = $dtuPctBelow
        'Sessions_PctHoursBelow5'  = $sessPctBelow
        'Connections_PctHoursIdle' = $connPctZero
        'StorageUsed_MaxPct'       = $storMax
        'StorageWasteScore'        = $storScore
        'DataPoints_CPU'           = $cpuSeries.Count
        'UnderuseScore'            = $compositeScore
        ResourceId                 = $rid
    })

    # Throttle to avoid Azure Monitor rate limits (600 requests/min per subscription)
    Start-Sleep -Milliseconds 200
}

Write-Progress -Activity 'Collecting Azure Monitor metrics' -Completed

#endregion

#region ── Filter and sort ──────────────────────────────────────────────────────

Write-Step 'Calculating results...'

$candidates = $results |
    Where-Object { $null -ne $_.UnderuseScore -and $_.UnderuseScore -ge $UnderuseScoreThreshold } |
    Sort-Object UnderuseScore -Descending

Write-Host "  $($candidates.Count) databases scored ≥ $UnderuseScoreThreshold (underuse threshold)"
Write-Host "  $($results.Count - $candidates.Count) databases excluded (score below threshold or no data)"

#endregion

#region ── CSV export ───────────────────────────────────────────────────────────

Write-Step 'Writing CSV...'

$timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$csvPath    = Join-Path $OutputPath "AzSql_Underuse_$timestamp.csv"
$htmlPath   = Join-Path $OutputPath "AzSql_Underuse_$timestamp.html"

$candidates | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "  $csvPath"

#endregion

#region ── HTML export ──────────────────────────────────────────────────────────

Write-Step 'Writing HTML report...'

function Format-Score {
    param([object]$Value, [string]$Suffix = '%')
    if ($null -eq $Value) { return '<span style="color:#999">n/a</span>' }
    $v    = [double]$Value
    $color = switch ($true) {
        ($v -ge 90) { '#c0392b' }  # red
        ($v -ge 70) { '#e67e22' }  # orange
        ($v -ge 50) { '#f39c12' }  # yellow
        default     { '#27ae60' }  # green
    }
    return "<span style='color:$color;font-weight:bold'>$Value$Suffix</span>"
}

function Format-StorPct {
    param([object]$Value)
    if ($null -eq $Value) { return '<span style="color:#999">n/a</span>' }
    $v     = [double]$Value
    $color = switch ($true) {
        ($v -ge 90) { '#c0392b' }
        ($v -ge 80) { '#e67e22' }
        ($v -ge 60) { '#f39c12' }
        default     { '#27ae60' }
    }
    return "<span style='color:$color'>$Value%</span>"
}

$rows = foreach ($r in $candidates) {
    $scoreColor = switch ($true) {
        ($r.UnderuseScore -ge 90) { '#c0392b' }
        ($r.UnderuseScore -ge 80) { '#e67e22' }
        ($r.UnderuseScore -ge 70) { '#f39c12' }
        default                   { '#27ae60' }
    }
    $portalUrl = "https://portal.azure.com/#resource$($r.ResourceId)/overview"
    $dtuCell   = if ($null -ne $r.DTU_PctHoursBelow10) {
                     Format-Score $r.DTU_PctHoursBelow10
                 } else { '<span style="color:#999">vCore</span>' }
    @"
    <tr>
        <td><span style='color:$scoreColor;font-size:1.1em;font-weight:bold'>$($r.UnderuseScore)</span></td>
        <td>$($r.SubscriptionName)</td>
        <td>$($r.ResourceGroup)</td>
        <td><a href='$portalUrl' target='_blank'>$($r.DatabaseName)</a></td>
        <td>$($r.ServerName)</td>
        <td>$($r.Tier) / $($r.Edition)</td>
        <td>$($r.'vCores/DTU')</td>
        <td>$($r.AllocatedGB) GB</td>
        <td>$($r.Status)</td>
        <td>$(Format-Score $r.CPU_PctHoursBelow10)</td>
        <td>$dtuCell</td>
        <td>$(Format-Score $r.Sessions_PctHoursBelow5)</td>
        <td>$(Format-Score $r.Connections_PctHoursIdle)</td>
        <td>$(Format-StorPct $r.StorageUsed_MaxPct)</td>
    </tr>
"@
}

$generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm'

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Azure SQL Underuse Report — $generatedAt</title>
<style>
  body        { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; background: #f5f5f5; color: #222; margin: 0; padding: 20px; }
  h1          { color: #1a1a2e; }
  h2          { color: #16213e; border-bottom: 2px solid #0f3460; padding-bottom: 4px; }
  .meta       { background:#fff; border-radius:6px; padding:12px 18px; margin-bottom:18px; box-shadow:0 1px 4px rgba(0,0,0,.1); }
  .meta span  { margin-right: 24px; }
  table       { width:100%; border-collapse:collapse; background:#fff; border-radius:6px; overflow:hidden; box-shadow:0 1px 4px rgba(0,0,0,.1); }
  th          { background:#16213e; color:#fff; padding:8px 10px; text-align:left; font-size:12px; white-space:nowrap; }
  td          { padding:7px 10px; border-bottom:1px solid #eee; vertical-align:middle; }
  tr:hover td { background:#f0f4ff; }
  tr:last-child td { border-bottom:none; }
  a           { color: #0f3460; }
  .note       { background:#fff8e1; border-left:4px solid #f39c12; padding:10px 14px; border-radius:4px; margin:16px 0; }
  .legend     { display:flex; gap:16px; flex-wrap:wrap; margin: 8px 0 16px; font-size:12px; }
  .legend span{ padding:3px 10px; border-radius:12px; }
  .footer     { color:#999; font-size:11px; margin-top:20px; }
</style>
</head>
<body>
<h1>💤 Azure SQL — Underused Database Report</h1>
<div class="meta">
  <span>📅 Generated: <strong>$generatedAt</strong></span>
  <span>📆 Period: <strong>$DaysBack days</strong></span>
  <span>🗄️ Candidates: <strong>$($candidates.Count)</strong></span>
  <span>🔍 Total analysed: <strong>$($results.Count)</strong></span>
  <span>🎯 Score threshold: <strong>≥ $UnderuseScoreThreshold</strong></span>
</div>

<div class="note">
  <strong>Underuse Score (0–100):</strong>
  Weighted composite: CPU 30% · Sessions 25% · Idle connections 25% · DTU 10% · Storage waste 10%.
  Higher = more likely underused. Scores reflect % of hourly intervals below the threshold over the analysis period.
  <br><strong>Thresholds:</strong> CPU &lt; $CpuThresholdPct% · DTU &lt; $DtuThresholdPct% · Sessions &lt; $SessionsThresholdPct% · Connections = 0.
</div>

<div class="legend">
  <span style="background:#fdecea;color:#c0392b">● Score ≥ 90 — strong candidate</span>
  <span style="background:#fef3e2;color:#e67e22">● Score ≥ 80</span>
  <span style="background:#fefce8;color:#856404">● Score ≥ 70</span>
  <span style="background:#eafaf1;color:#27ae60">● Score &lt; 70 — borderline</span>
</div>

<h2>📋 Underuse Candidates — sorted by score</h2>
<table>
  <thead>
    <tr>
      <th>Score</th>
      <th>Subscription</th>
      <th>Resource Group</th>
      <th>Database</th>
      <th>Server</th>
      <th>Tier / Edition</th>
      <th>vCores/DTU</th>
      <th>Allocated</th>
      <th>Status</th>
      <th>CPU<br>% hrs &lt;$CpuThresholdPct%</th>
      <th>DTU<br>% hrs &lt;$DtuThresholdPct%</th>
      <th>Sessions<br>% hrs &lt;$SessionsThresholdPct%</th>
      <th>Connections<br>% hrs idle</th>
      <th>Storage<br>Max used %</th>
    </tr>
  </thead>
  <tbody>
$($rows -join "`n")
  </tbody>
</table>

<div class="note" style="margin-top:20px">
  <strong>Next steps for each candidate:</strong>
  Click the database name → portal Metrics blade → extend to 90 days for confirmation.
  Run <code>SELECT * FROM sys.dm_exec_sessions WHERE is_user_process = 1</code> directly on the server for live connection check.
  Check Query Performance Insight for actual query activity before decommissioning.
</div>

<p class="footer">
  Generated by Find-AzSqlUnderusedDatabases.ps1 &nbsp;·&nbsp;
  Free tier only — Azure Monitor Platform Metrics + Azure Resource Graph &nbsp;·&nbsp;
  No Log Analytics required.
</p>
</body>
</html>
"@

$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Host "  $htmlPath"

#endregion

#region ── Summary ──────────────────────────────────────────────────────────────

Write-Step 'Complete.' 'Green'
Write-Host ''
Write-Host '  Top 10 underuse candidates:' -ForegroundColor Yellow
$candidates | Select-Object -First 10 |
    Format-Table -AutoSize `
        DatabaseName, SubscriptionName, Tier, AllocatedGB,
        UnderuseScore, CPU_PctHoursBelow10, Connections_PctHoursIdle

Write-Host "  CSV  : $csvPath"
Write-Host "  HTML : $htmlPath"

#endregion
