<#
.SYNOPSIS
    Reports wasted space in Azure SQL Databases and Managed Instance databases with shrink recommendations and cost estimates.

.DESCRIPTION
    Enumerates all Azure SQL Databases and Managed Instance databases via Resource Graph, connects to each server using
    an Entra ID access token (reuses existing Connect-AzAccount session — no stored credentials),
    queries sys.database_files and sys.dm_db_file_space_usage for exact file-level allocation
    vs actual used space, calculates monthly cost of wasted space, and recommends the
    appropriate shrink operation per file.

    Pricing: West Europe, as of 2025-Q1. Verify at https://azure.microsoft.com/pricing/details/azure-sql-database/
    vCore tiers  : storage billed per GB/month (waste = direct cost)
    DTU tiers    : storage included in tier price (waste = over-provisioning risk)

.PARAMETER OutputPath
    Folder to write CSV and HTML output. Defaults to current directory.

.PARAMETER MinWastedGB
    Only report files with at least this many GB wasted. Default: 1.

.PARAMETER MinWastePct
    Only report files with at least this % free space. Default: 20.

.PARAMETER QueryTimeoutSeconds
    Timeout for each Invoke-Sqlcmd call. Default: 30.

.PARAMETER SubscriptionIds
    Optional array of subscription IDs to limit scope. Defaults to all accessible.

.EXAMPLE
    .\Find-AzSqlSpaceWaste.ps1

.EXAMPLE
    .\Find-AzSqlSpaceWaste.ps1 -MinWastedGB 5 -OutputPath C:\Reports
#>

[CmdletBinding()]
param (
    [string]   $OutputPath           = '.',
    [double]   $MinWastedGB          = 1,
    [double]   $MinWastePct          = 20,
    [int]      $QueryTimeoutSeconds  = 30,
    [string[]] $SubscriptionIds      = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "Find-AzSqlSpaceWaste.ps1 starting..." -ForegroundColor Cyan

#region ── Pricing table — West Europe, 2025-Q1 ──────────────────────────────
# Source: https://azure.microsoft.com/en-us/pricing/details/azure-sql-database/
# vCore tiers: per GB/month beyond included storage
# DTU tiers: included in tier — cost shown is indicative over-provisioning impact
$StoragePricePerGBMonth = @{
    'GeneralPurpose'   = 0.115   # €/GB/month — charged per GB
    'BusinessCritical' = 0.230   # €/GB/month — charged per GB
    'Hyperscale'       = 0.115   # €/GB/month — charged per GB
    'Premium'          = 0.0     # included in DTU tier price
    'Standard'         = 0.0     # included in DTU tier price
    'Basic'            = 0.0     # included in DTU tier price
}
#endregion

#region ── Helpers ───────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host "`n[$([datetime]::Now.ToString('HH:mm:ss'))] $Message" -ForegroundColor $Color
}

function Write-Info  { param([string]$Msg) Write-Host "  $Msg" -ForegroundColor DarkGray }
function Write-Ok    { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }

# Safely convert a possibly-null/DBNull/empty value to double
function ConvertTo-SafeDouble {
    param($Value, [double]$Default = 0)
    if ($null -eq $Value -or $Value -is [System.DBNull] -or "$Value" -eq '') { return $Default }
    try   { return [double]$Value }
    catch { return $Default }
}

# Safely get .Sum from Measure-Object, returning 0 if null or empty collection
function Get-SafeSum {
    param([object[]]$Collection, [string]$Property)
    $measured = @($Collection | Where-Object { $null -ne $_.$Property }) |
        Measure-Object -Property $Property -Sum -ErrorAction SilentlyContinue
    if ($null -eq $measured -or $null -eq $measured.Sum) { return 0 }
    return $measured.Sum
}

function Invoke-ArgQuery {
    param([string]$Query, [string[]]$Subscriptions)
    $results   = [System.Collections.Generic.List[PSObject]]::new()
    $skipToken = $null
    do {
        $params = @{ Query = $Query }
        if ($Subscriptions.Count -gt 0) { $params['Subscription'] = $Subscriptions }
        if ($skipToken)                  { $params['SkipToken']    = $skipToken }
        Write-Host "    [ARG] Querying page..." -ForegroundColor DarkGray
        $page      = Search-AzGraph @params -First 1000
        $skipToken = $page.SkipToken
        foreach ($row in $page) { $results.Add($row) }
    } while ($skipToken)
    return $results
}

# Build shrink recommendation for a single file row
function Get-ShrinkRecommendation {
    param(
        [string] $DatabaseName,
        [string] $LogicalName,
        [string] $FileType,        # ROWS | LOG
        [double] $AllocatedMB,
        [double] $UsedMB,
        [double] $FreeMB,
        [double] $WastePct
    )

    $targetMB   = [math]::Ceiling($UsedMB * 1.15)   # leave 15% headroom
    $dbQuoted   = $DatabaseName -replace "'", "''"

    if ($WastePct -lt 15) {
        return [PSCustomObject]@{
            Action      = 'None'
            Risk        = 'Low'
            Description = 'Less than 15% free — no shrink justified.'
            TSQL        = '-- No action required.'
        }
    }

    if ($FileType -eq 'LOG') {
        # Log files on Azure SQL DB: Azure manages log backups automatically.
        # Safe to shrink directly. TRUNCATEONLY first, then targeted if still large.
        $tsql = @"
-- Step 1: Try TRUNCATEONLY first (safe — releases only trailing free space, no page movement)
USE [$dbQuoted];
DBCC SHRINKFILE (N'$LogicalName', TRUNCATEONLY);

-- Step 2: If still > 20% free after step 1, shrink to target size with headroom
-- USE [$dbQuoted];
-- DBCC SHRINKFILE (N'$LogicalName', $targetMB);

-- Note: Log file will grow again during the next large transaction batch.
-- Consider whether the log was large due to a one-off operation or routine workload.
"@
        return [PSCustomObject]@{
            Action      = 'SHRINKFILE (log)'
            Risk        = 'Low'
            Description = "Log file: $([math]::Round($FreeMB/1024,2)) GB free ($([math]::Round($WastePct,1))%). TRUNCATEONLY is safe. Shrink if log grew due to one-off operation."
            TSQL        = $tsql
        }
    }

    # Data file (ROWS)
    if ($WastePct -lt 30 -and $FreeMB -lt 5120) {
        # Moderate waste — TRUNCATEONLY only, not worth a full shrink
        $tsql = @"
-- TRUNCATEONLY: safe, no page movement, no index fragmentation.
-- Releases free space only at the END of the file.
-- If the result is disappointing, free space may be scattered — see commented block below.
USE [$dbQuoted];
DBCC SHRINKFILE (N'$LogicalName', TRUNCATEONLY);
"@
        return [PSCustomObject]@{
            Action      = 'TRUNCATEONLY'
            Risk        = 'Low'
            Description = "Data file: $([math]::Round($FreeMB/1024,2)) GB free ($([math]::Round($WastePct,1))%). Moderate waste — TRUNCATEONLY first, monitor result."
            TSQL        = $tsql
        }
    }

    # Significant waste — full shrink with fragmentation warning
    $tsql = @"
-- ⚠ WARNING: SHRINKFILE moves data pages and WILL cause index fragmentation.
-- Always rebuild or reorganise indexes after shrinking a data file.
-- Run during a maintenance window — causes blocking on busy databases.

-- Step 1: TRUNCATEONLY first (free, safe — do this before the targeted shrink)
USE [$dbQuoted];
DBCC SHRINKFILE (N'$LogicalName', TRUNCATEONLY);
GO

-- Step 2: Targeted shrink to used size + 15% headroom ($targetMB MB)
USE [$dbQuoted];
DBCC SHRINKFILE (N'$LogicalName', $targetMB);
GO

-- Step 3: Rebuild indexes to address fragmentation caused by shrink
-- Run this after confirming the shrink completed:
USE [$dbQuoted];
EXEC sp_MSforeachtable 'ALTER INDEX ALL ON ? REBUILD WITH (ONLINE = ON, FILLFACTOR = 80)';
GO

-- Step 4: Update statistics
USE [$dbQuoted];
EXEC sp_updatestats;
GO
"@
        return [PSCustomObject]@{
            Action      = 'SHRINKFILE + REBUILD INDEXES'
            Risk        = 'Medium — run in maintenance window'
            Description = "Data file: $([math]::Round($FreeMB/1024,2)) GB free ($([math]::Round($WastePct,1))%). Significant waste. Full shrink to ${targetMB} MB + index rebuild required."
            TSQL        = $tsql
        }
    }

#endregion

#region ── Validate prerequisites ────────────────────────────────────────────

Write-Step 'Checking prerequisites...'

# PowerShell version
Write-Info "PowerShell version: $($PSVersionTable.PSVersion)"
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7+ required. Current: $($PSVersionTable.PSVersion). Download: https://aka.ms/powershell"
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

# Az.Accounts
Write-Info 'Loading Az.Accounts...'
try   { Import-Module Az.Accounts -ErrorAction Stop }
catch { throw "Az.Accounts not found. Run: Install-Module Az.Accounts -Scope CurrentUser" }
Write-Ok 'Az.Accounts loaded.'

# Az.ResourceGraph
Write-Info 'Loading Az.ResourceGraph...'
try   { Import-Module Az.ResourceGraph -ErrorAction Stop }
catch { throw "Az.ResourceGraph not found. Run: Install-Module Az.ResourceGraph -Scope CurrentUser" }
Write-Ok 'Az.ResourceGraph loaded.'

# Azure context
Write-Info 'Checking Azure context...'
try   { $ctx = Get-AzContext -ErrorAction Stop }
catch { throw 'Not connected to Azure. Run Connect-AzAccount first.' }
if (-not $ctx -or -not $ctx.Account) { throw 'No Azure context found. Run Connect-AzAccount first.' }
Write-Ok "Azure context: $($ctx.Account) / $($ctx.Tenant.Id)"

# Invoke-Sqlcmd
Write-Info 'Checking Invoke-Sqlcmd...'
try   { $null = Get-Command Invoke-Sqlcmd -ErrorAction Stop }
catch { throw "Invoke-Sqlcmd not found. Run: Install-Module SqlServer -Scope CurrentUser" }
Write-Ok 'Invoke-Sqlcmd available.'

$OutputPath = [string](Resolve-Path $OutputPath)
Write-Ok "Output path: $OutputPath"

#endregion

#region ── Enumerate databases ───────────────────────────────────────────────

Write-Step 'Enumerating SQL Databases via Resource Graph...'

# SQL Databases (Azure SQL DB)
$argQueryDb = @'
Resources
| where type =~ 'microsoft.sql/servers/databases'
| where name != 'master'
| extend
    ResourceKind = 'SQL Database',
    ServerFqdn   = strcat(tostring(split(id, '/')[8]), '.database.windows.net'),
    ServerName   = tostring(split(id, '/')[8]),
    Tier         = tostring(sku.tier),
    Edition      = tostring(sku.name),
    Capacity     = toint(sku.capacity),
    MaxSizeBytes = tolong(properties.maxSizeBytes),
    Status       = tostring(properties.status)
| project
    id, name, subscriptionId, resourceGroup, location,
    ResourceKind, ServerFqdn, ServerName, Tier, Edition, Capacity,
    MaxSizeBytes, Status
'@

# Managed Instance databases
# FQDN is on the parent MI resource; join via managedInstanceId property on the DB
$argQueryMi = @'
Resources
| where type =~ 'microsoft.sql/managedinstances/databases'
| where name != 'master'
| extend MiId = tostring(strcat_array(array_slice(split(id, '/'), 0, 9), '/'))
| join kind=inner (
    Resources
    | where type =~ 'microsoft.sql/managedinstances'
    | project MiId = id,
              ServerFqdn = tostring(properties.fullyQualifiedDomainName),
              Tier       = tostring(sku.tier),
              Edition    = tostring(sku.name),
              Capacity   = toint(sku.capacity)
  ) on MiId
| extend
    ResourceKind = 'Managed Instance',
    ServerName   = tostring(split(MiId, '/')[8]),
    MaxSizeBytes = tolong(properties.maxSizeBytes),
    Status       = tostring(properties.status)
| project
    id, name, subscriptionId, resourceGroup, location,
    ResourceKind, ServerFqdn, ServerName, Tier, Edition, Capacity,
    MaxSizeBytes, Status
'@

Write-Info 'Querying SQL Databases via ARG...'
$dbResults = Invoke-ArgQuery -Query $argQueryDb -Subscriptions $SubscriptionIds
Write-Info 'Querying Managed Instance databases via ARG...'
$miResults = Invoke-ArgQuery -Query $argQueryMi -Subscriptions $SubscriptionIds
$databases = @($dbResults) + @($miResults)

if ($databases.Count -eq 0) {
    Write-Warning 'No SQL Databases or Managed Instance databases found.'
    exit 0
}

$dbCount = @($dbResults).Count
$miCount = @($miResults).Count
Write-Info "SQL Databases found   : $dbCount"
Write-Info "MI databases found    : $miCount"

# Resolve subscription names
$subQuery = @'
ResourceContainers
| where type == 'microsoft.resources/subscriptions'
| project subscriptionId, SubscriptionName = name
'@
$subLookup = @{}
Write-Info 'Resolving subscription names...'
foreach ($s in Invoke-ArgQuery -Query $subQuery -Subscriptions $SubscriptionIds) {
    $subLookup[$s.subscriptionId] = $s.SubscriptionName
}

$offlineDbs = @($databases | Where-Object { $_.Status -notin @('Online', 'Ready') })
if ($offlineDbs.Count -gt 0) {
    Write-Warn "$($offlineDbs.Count) databases are not online and will be skipped: $($offlineDbs.name -join ', ')"
}
$databases = @($databases | Where-Object { $_.Status -in @('Online', 'Ready') })

Write-Ok "Found $($databases.Count) online databases across $(@($databases.subscriptionId | Select-Object -Unique).Count) subscriptions."

#endregion

#region ── Acquire Entra access token for Azure SQL ──────────────────────────

Write-Step 'Acquiring Entra access token for Azure SQL Database...'

try {
    Write-Info 'Calling Get-AzAccessToken...'
    $tokenObj    = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/' -ErrorAction Stop
    $accessToken = $tokenObj.Token
    Write-Ok "Token acquired (expires: $($tokenObj.ExpiresOn.ToString('HH:mm:ss')))"
}
catch {
    throw "Could not acquire access token for database.windows.net. Ensure you are logged in with Connect-AzAccount. Error: $_"
}

# T-SQL to query file space per database
$fileSpaceQuery = @'
SELECT
    f.file_id                                                          AS FileId,
    f.name                                                             AS LogicalName,
    f.type_desc                                                        AS FileType,
    f.physical_name                                                    AS PhysicalName,
    CAST(f.size AS bigint) * 8192 / 1048576.0                         AS AllocatedMB,
    CAST(FILEPROPERTY(f.name, 'SpaceUsed') AS bigint) * 8192 / 1048576.0  AS UsedMB,
    (CAST(f.size AS bigint) - CAST(FILEPROPERTY(f.name,'SpaceUsed') AS bigint))
        * 8192 / 1048576.0                                            AS FreeMB,
    CASE f.max_size
        WHEN -1 THEN -1
        ELSE CAST(f.max_size AS bigint) * 8192 / 1048576.0
    END                                                                AS MaxAllowedMB,
    f.is_percent_growth                                                AS IsPercentGrowth,
    f.growth                                                           AS GrowthSetting
FROM sys.database_files AS f;
'@

# T-SQL to get version store (indicates active snapshot isolation / RCSI)
$versionStoreQuery = @'
SELECT
    SUM(version_store_reserved_page_count) * 8192 / 1048576.0 AS VersionStoreMB
FROM sys.dm_db_file_space_usage;
'@

#endregion

#region ── Collect file space data ───────────────────────────────────────────

Write-Step "Querying file space on $($databases.Count) databases..."

$allFileRows = [System.Collections.Generic.List[PSObject]]::new()
$errors      = [System.Collections.Generic.List[PSObject]]::new()
$processed   = 0

$dbsByServer = $databases | Group-Object -Property ServerFqdn

foreach ($serverGroup in $dbsByServer) {
    $serverFqdn = $serverGroup.Name
    $serverDbs  = $serverGroup.Group

    Write-Step "Server: $serverFqdn ($($serverDbs.Count) databases)" 'Yellow'

    foreach ($db in $serverDbs) {
        $processed++
        $pct = [math]::Round(($processed / $databases.Count) * 100)
        Write-Progress -Activity 'Querying file space' `
                       -Status   "$processed / $($databases.Count) — $($db.name)" `
                       -PercentComplete $pct
        Write-Info "$processed/$($databases.Count)  $($db.name)"

        $subName = if ($subLookup.ContainsKey($db.subscriptionId)) { $subLookup[$db.subscriptionId] } else { $db.subscriptionId }

        # Common Invoke-Sqlcmd params
        $sqlParams = @{
            ServerInstance  = $serverFqdn
            Database        = $db.name
            AccessToken     = $accessToken
            QueryTimeout    = $QueryTimeoutSeconds
            ErrorAction     = 'Stop'
            TrustServerCertificate = $true
        }

        try {
            $fileRows     = @(Invoke-Sqlcmd @sqlParams -Query $fileSpaceQuery)
            $versionStore = @(Invoke-Sqlcmd @sqlParams -Query $versionStoreQuery)
            $versionStoreMB = if ($versionStore.Count -gt 0) { ConvertTo-SafeDouble $versionStore[0].VersionStoreMB } else { 0 }

            foreach ($file in $fileRows) {
                $allocMB  = [math]::Round((ConvertTo-SafeDouble $file.AllocatedMB), 2)
                $usedMB   = [math]::Round((ConvertTo-SafeDouble $file.UsedMB), 2)
                $freeMB   = [math]::Round((ConvertTo-SafeDouble $file.FreeMB), 2)
                $wastePct = if ($allocMB -gt 0) { [math]::Round(($freeMB / $allocMB) * 100, 1) } else { 0 }

                $freeGB   = [math]::Round($freeMB / 1024, 3)
                $allocGB  = [math]::Round($allocMB / 1024, 3)
                $usedGB   = [math]::Round($usedMB / 1024, 3)

                # Monthly cost of wasted space
                $tier        = $db.Tier
                $pricePerGB  = if ($StoragePricePerGBMonth.ContainsKey($tier)) { $StoragePricePerGBMonth[$tier] } else { 0 }
                $monthlyWasteCost = [math]::Round($freeGB * $pricePerGB, 2)
                $costNote    = if ($pricePerGB -eq 0) {
                    'DTU tier — storage included (no direct per-GB cost)'
                } else {
                    "€$monthlyWasteCost/month (€$pricePerGB × $freeGB GB)"
                }

                # Only compute recommendation if above thresholds
                $rec = $null
                if ($freeGB -ge $MinWastedGB -and $wastePct -ge $MinWastePct) {
                    $rec = Get-ShrinkRecommendation `
                        -DatabaseName $db.name `
                        -LogicalName  $file.LogicalName `
                        -FileType     $file.FileType `
                        -AllocatedMB  $allocMB `
                        -UsedMB       $usedMB `
                        -FreeMB       $freeMB `
                        -WastePct     $wastePct
                }

                $allFileRows.Add([PSCustomObject]@{
                    SubscriptionName  = $subName
                    SubscriptionId    = $db.subscriptionId
                    ResourceGroup     = $db.resourceGroup
                    ServerName        = $db.ServerName
                    DatabaseName      = $db.name
                    Location          = $db.location
                    Tier              = $tier
                    Edition           = $db.Edition
                    'vCores/DTU'      = $db.Capacity
                    FileId            = $file.FileId
                    LogicalName       = $file.LogicalName
                    FileType          = $file.FileType
                    AllocatedGB       = $allocGB
                    UsedGB            = $usedGB
                    FreeGB            = $freeGB
                    WastePct          = $wastePct
                    VersionStoreMB    = if ($file.FileType -eq 'ROWS') { [math]::Round($versionStoreMB, 1) } else { 0 }
                    PricePerGBMonth   = $pricePerGB
                    MonthlyWasteCost  = $monthlyWasteCost
                    CostNote          = $costNote
                    RecommendedAction = if ($rec) { $rec.Action }      else { 'Below threshold' }
                    Risk              = if ($rec) { $rec.Risk }        else { 'None' }
                    Description       = if ($rec) { $rec.Description } else { "Free space below thresholds (≥${MinWastedGB} GB and ≥${MinWastePct}%)." }
                    ShrinkTSQL        = if ($rec) { $rec.TSQL }        else { '-- No action required.' }
                    DataStatus        = 'OK'
                    ResourceKind      = $db.ResourceKind
                    ResourceId        = $db.id
                })
            }
        }
        catch {
            $errMsg  = $_.ToString()
            $errType = switch -Regex ($errMsg) {
                'Login failed|Cannot open database|permission|EXECUTE permission|VIEW DATABASE' { 'AccessDenied' }
                'timeout|Timeout'                                                                { 'Timeout' }
                'network|server was not found|A network-related'                                { 'NetworkError' }
                default                                                                          { 'Error' }
            }
            Write-Warn "[$errType] $($db.name): $errMsg"
            $errors.Add([PSCustomObject]@{
                ResourceKind  = $db.ResourceKind
                ServerName    = $db.ServerName
                DatabaseName  = $db.name
                DataStatus    = $errType
                Error         = $errMsg
            })
            # Add a placeholder row so the database appears in the report with its status
            $subName = if ($subLookup.ContainsKey($db.subscriptionId)) { $subLookup[$db.subscriptionId] } else { $db.subscriptionId }
            $allFileRows.Add([PSCustomObject]@{
                SubscriptionName  = $subName
                SubscriptionId    = $db.subscriptionId
                ResourceGroup     = $db.resourceGroup
                ServerName        = $db.ServerName
                DatabaseName      = $db.name
                Location          = $db.location
                Tier              = $db.Tier
                Edition           = $db.Edition
                'vCores/DTU'      = $db.Capacity
                FileId            = $null
                LogicalName       = $null
                FileType          = $null
                AllocatedGB       = $null
                UsedGB            = $null
                FreeGB            = $null
                WastePct          = $null
                VersionStoreMB    = $null
                PricePerGBMonth   = $null
                MonthlyWasteCost  = $null
                CostNote          = $null
                RecommendedAction = 'No data'
                Risk              = 'Unknown'
                Description       = "$errType — $errMsg"
                ShrinkTSQL        = $null
                DataStatus        = $errType
                ResourceKind      = $db.ResourceKind
                ResourceId        = $db.id
            })
        }
    }
}

Write-Progress -Activity 'Querying file space' -Completed

#endregion

#region ── Filter and sort ───────────────────────────────────────────────────

Write-Step 'Preparing results...'

$actionRows  = @($allFileRows | Where-Object { $_.DataStatus -eq 'OK' -and $_.RecommendedAction -ne 'Below threshold' }) |
    Sort-Object -Property FreeGB -Descending
$cleanRows   = @($allFileRows | Where-Object { $_.DataStatus -eq 'OK' -and $_.RecommendedAction -eq 'Below threshold' })
$noDataRows  = @($allFileRows | Where-Object { $_.DataStatus -ne 'OK' }) |
    Sort-Object -Property DataStatus, DatabaseName

$totalWastedGB    = [math]::Round((Get-SafeSum -Collection $actionRows -Property FreeGB), 2)
$totalMonthlyCost = [math]::Round((Get-SafeSum -Collection $actionRows -Property MonthlyWasteCost), 2)

Write-Ok "$($actionRows.Count) files above waste thresholds."
Write-Ok "$($cleanRows.Count) files OK (below thresholds)."
Write-Warn "$($noDataRows.Count) databases could not be queried (no data)."
Write-Ok "Total wasted space : $totalWastedGB GB"
Write-Ok "Monthly cost (vCore): €$totalMonthlyCost"

#endregion

#region ── CSV export ────────────────────────────────────────────────────────

Write-Step 'Writing CSV...'

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$csvPath   = Join-Path $OutputPath "AzSql_SpaceWaste_$timestamp.csv"
$htmlPath  = Join-Path $OutputPath "AzSql_SpaceWaste_$timestamp.html"

$allFileRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Info $csvPath

#endregion

#region ── HTML export ───────────────────────────────────────────────────────

Write-Step 'Writing HTML report...'

function Get-WasteColor {
    param([double]$Pct)
    switch ($true) {
        ($Pct -ge 70) { return '#c0392b' }   # red
        ($Pct -ge 50) { return '#e67e22' }   # orange
        ($Pct -ge 30) { return '#f39c12' }   # yellow
        default       { return '#27ae60' }   # green
    }
}

function Get-RiskBadge {
    param([string]$Risk)
    switch -Wildcard ($Risk) {
        'Medium*' { return "<span style='background:#fef3e2;color:#e67e22;padding:2px 8px;border-radius:10px;font-size:11px'>⚠ $Risk</span>" }
        'Low'     { return "<span style='background:#eafaf1;color:#27ae60;padding:2px 8px;border-radius:10px;font-size:11px'>✓ Low</span>" }
        'None'    { return "<span style='background:#f5f5f5;color:#999;padding:2px 8px;border-radius:10px;font-size:11px'>– None</span>" }
        default   { return "<span style='background:#fdecea;color:#c0392b;padding:2px 8px;border-radius:10px;font-size:11px'>$Risk</span>" }
    }
}

$rows = foreach ($r in $actionRows) {
    $wasteColor  = Get-WasteColor -Pct $r.WastePct
    $portalUrl   = "https://portal.azure.com/#resource$($r.ResourceId)/overview"
    $tsqlEscaped = [System.Web.HttpUtility]::HtmlEncode($r.ShrinkTSQL)
    $costCell    = if ($r.PricePerGBMonth -gt 0) {
                       "<strong>€$($r.MonthlyWasteCost)</strong>/month"
                   } else {
                       "<span style='color:#999;font-size:11px'>DTU — included</span>"
                   }
    $versionNote = if ($r.VersionStoreMB -gt 50) {
                       "<br><span style='color:#e67e22;font-size:11px'>⚠ Version store: $($r.VersionStoreMB) MB (RCSI active — used space may appear higher)</span>"
                   } else { '' }
    @"
    <tr>
        <td>$($r.SubscriptionName)</td>
        <td>$($r.ResourceGroup)</td>
        <td><a href='$portalUrl' target='_blank'>$($r.DatabaseName)</a><br><span style='font-size:10px;background:#e8f4fd;color:#2471a3;padding:1px 6px;border-radius:8px'>$($r.ResourceKind)</span></td>
        <td style='font-size:11px;color:#555'>$($r.ServerName)</td>
        <td>$($r.Tier)<br><span style='font-size:11px;color:#888'>$($r.Edition)</span></td>
        <td><span style='color:$wasteColor;font-weight:bold'>$($r.WastePct)%</span></td>
        <td>$($r.AllocatedGB) GB</td>
        <td>$($r.UsedGB) GB$versionNote</td>
        <td><strong>$($r.FreeGB) GB</strong></td>
        <td>$($r.FileType)<br><span style='font-size:11px;color:#888'>$($r.LogicalName)</span></td>
        <td>$costCell</td>
        <td>$(Get-RiskBadge -Risk $r.Risk)<br><span style='font-size:11px;color:#555;margin-top:3px;display:block'>$($r.RecommendedAction)</span></td>
        <td>
            <details>
                <summary style='cursor:pointer;color:#0f3460;font-size:12px'>Show T-SQL ▶</summary>
                <pre style='background:#1e1e1e;color:#d4d4d4;padding:10px;border-radius:4px;font-size:11px;margin-top:6px;white-space:pre-wrap;max-width:600px'>$tsqlEscaped</pre>
            </details>
        </td>
    </tr>
"@
}

# Error rows
# Build no-data section (covers access denied, timeout, network, etc.)
$noDataSection = ''
if ($noDataRows.Count -gt 0) {
    $statusColors = @{
        'AccessDenied' = '#c0392b'
        'Timeout'      = '#e67e22'
        'NetworkError' = '#8e44ad'
        'Error'        = '#c0392b'
    }
    $statusIcons = @{
        'AccessDenied' = '🔒'
        'Timeout'      = '⏱'
        'NetworkError' = '🌐'
        'Error'        = '❌'
    }
    $noDataHtmlRows = foreach ($r in $noDataRows) {
        $color = if ($statusColors.ContainsKey($r.DataStatus)) { $statusColors[$r.DataStatus] } else { '#c0392b' }
        $icon  = if ($statusIcons.ContainsKey($r.DataStatus))  { $statusIcons[$r.DataStatus]  } else { '❌' }
        $badge = "<span style='color:$color;font-weight:bold'>$icon $($r.DataStatus)</span>"
        "<tr><td>$($r.ResourceKind)</td><td>$($r.ServerName)</td><td>$($r.DatabaseName)</td><td>$badge</td><td style='font-size:11px;color:#555'>$([System.Web.HttpUtility]::HtmlEncode($r.Description))</td></tr>"
    }
    $noDataSection = @"
<h2>⚠️ Databases With No Data ($($noDataRows.Count))</h2>
<p>These databases appeared in the inventory but could not be queried.
<strong>No data means no data</strong> — waste cannot be assessed. Resolve the issue and re-run.</p>
<table>
  <thead><tr><th>Kind</th><th>Server</th><th>Database</th><th>Status</th><th>Detail</th></tr></thead>
  <tbody>$($noDataHtmlRows -join "`n")</tbody>
</table>
"@
}

$generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm'

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Azure SQL Space Waste Report — $generatedAt</title>
<style>
  body          { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; background: #f5f5f5; color: #222; margin: 0; padding: 20px; }
  h1            { color: #1a1a2e; margin-bottom: 4px; }
  h2            { color: #16213e; border-bottom: 2px solid #0f3460; padding-bottom: 4px; margin-top: 28px; }
  .meta         { background:#fff; border-radius:6px; padding:12px 18px; margin: 12px 0 18px; box-shadow:0 1px 4px rgba(0,0,0,.1); display:flex; gap:28px; flex-wrap:wrap; }
  .meta-item    { display:flex; flex-direction:column; }
  .meta-label   { font-size:11px; color:#888; text-transform:uppercase; letter-spacing:.5px; }
  .meta-value   { font-size:20px; font-weight:bold; color:#16213e; }
  .meta-sub     { font-size:11px; color:#999; }
  table         { width:100%; border-collapse:collapse; background:#fff; border-radius:6px; overflow:hidden; box-shadow:0 1px 4px rgba(0,0,0,.1); margin-bottom:24px; }
  th            { background:#16213e; color:#fff; padding:8px 10px; text-align:left; font-size:11px; white-space:nowrap; }
  td            { padding:7px 10px; border-bottom:1px solid #eee; vertical-align:top; }
  tr:hover td   { background:#f0f4ff; }
  tr:last-child td { border-bottom:none; }
  a             { color: #0f3460; }
  .note         { background:#fff8e1; border-left:4px solid #f39c12; padding:10px 14px; border-radius:4px; margin:16px 0; }
  .note.info    { background:#e8f4fd; border-color:#3498db; }
  details summary::-webkit-details-marker { display: none; }
  pre           { overflow-x:auto; }
  .footer       { color:#999; font-size:11px; margin-top:28px; }
</style>
</head>
<body>

<h1>💽 Azure SQL — Space Waste Report</h1>

<div class="meta">
  <div class="meta-item">
    <span class="meta-label">Generated</span>
    <span class="meta-value" style="font-size:15px">$generatedAt</span>
  </div>
  <div class="meta-item">
    <span class="meta-label">Databases analysed</span>
    <span class="meta-value">$($databases.Count)</span>
  </div>
  <div class="meta-item">
    <span class="meta-label">Files above threshold</span>
    <span class="meta-value">$($actionRows.Count)</span>
    <span class="meta-sub">≥ ${MinWastedGB} GB free and ≥ ${MinWastePct}% free</span>
  </div>
  <div class="meta-item">
    <span class="meta-label">Total wasted space</span>
    <span class="meta-value" style="color:#c0392b">$totalWastedGB GB</span>
  </div>
  <div class="meta-item">
    <span class="meta-label">Est. monthly cost (vCore)</span>
    <span class="meta-value" style="color:#c0392b">€$totalMonthlyCost</span>
    <span class="meta-sub">DTU-tier waste not included (storage is bundled)</span>
  </div>
</div>

<div class="note info">
  <strong>How to read this report:</strong>
  Each row is a database <em>file</em> (a database can have multiple files).
  <strong>Free GB</strong> = allocated file size minus actual used pages.
  Click <strong>Show T-SQL</strong> to expand the ready-to-run shrink script for that file.
  Always run <strong>TRUNCATEONLY</strong> first — it is safe and causes no fragmentation.
  Only escalate to a full <strong>SHRINKFILE</strong> if TRUNCATEONLY recovers insufficient space.
</div>

<div class="note">
  <strong>⚠ Shrink considerations:</strong>
  Shrinking data files causes index fragmentation — always rebuild indexes afterward.
  A database that was recently shrunk but has ongoing deletes/updates will grow again.
  Consider whether the root cause (bulk delete, migration cleanup, dropped tables) is a one-off or recurring pattern.
  <br><br>
  <strong>Version store note:</strong>
  If Read Committed Snapshot Isolation (RCSI) is enabled, the version store occupies space inside the data file.
  This space appears as "used" — it is not reclaimable via shrink.
  Files with a large version store are marked in the table.
</div>

<h2>📋 Waste by File — sorted by free GB descending</h2>
<table>
  <thead>
    <tr>
      <th>Subscription</th>
      <th>Resource Group</th>
      <th>Database / Kind</th>
      <th>Server</th>
      <th>Tier</th>
      <th>Waste %</th>
      <th>Allocated</th>
      <th>Used</th>
      <th>Free</th>
      <th>File</th>
      <th>Monthly Cost</th>
      <th>Action</th>
      <th>T-SQL</th>
    </tr>
  </thead>
  <tbody>
$($rows -join "`n")
  </tbody>
</table>

$noDataSection

<div class="note info">
  <strong>Pricing basis:</strong> West Europe, 2025-Q1.
  General Purpose / Hyperscale: €0.115/GB/month.
  Business Critical: €0.230/GB/month.
  DTU tiers (Basic/Standard/Premium): storage included in tier price — no direct per-GB charge shown, but over-allocated max size may justify a tier downsize.
  <br>Verify current prices at <a href="https://azure.microsoft.com/en-us/pricing/details/azure-sql-database/" target="_blank">azure.microsoft.com/pricing</a>.
</div>

<p class="footer">
  Generated by Find-AzSqlSpaceWaste.ps1 &nbsp;·&nbsp;
  Data source: sys.database_files + sys.dm_db_file_space_usage &nbsp;·&nbsp;
  Auth: Entra ID access token (no stored credentials).
</p>
</body>
</html>
"@

# HttpUtility for HTML encoding — load assembly if not already present
Add-Type -AssemblyName System.Web
$html | Out-File -FilePath $htmlPath -Encoding UTF8
Write-Info $htmlPath

#endregion

#region ── Console summary ───────────────────────────────────────────────────

Write-Step 'Complete.' 'Green'
Write-Host ''
Write-Host "  Top 10 by wasted space:" -ForegroundColor Yellow
$actionRows | Select-Object -First 10 |
    Format-Table -AutoSize DatabaseName, Tier, AllocatedGB, UsedGB, FreeGB, WastePct, MonthlyWasteCost, RecommendedAction

if ($noDataRows.Count -gt 0) {
    Write-Host "  $($noDataRows.Count) databases returned no data:" -ForegroundColor Yellow
    $noDataRows | Group-Object DataStatus | ForEach-Object {
        Write-Host "    $($_.Name): $($_.Count) database(s)" -ForegroundColor Yellow
    }
    Write-Host "  Required permission: VIEW DATABASE STATE on each database." -ForegroundColor Yellow
}

Write-Host "  CSV  : $csvPath"
Write-Host "  HTML : $htmlPath"

#endregion
