#Requires -Version 7.6
<#
.SYNOPSIS
    Installs or updates the standard DBA tool suite on all target instances.
    Tools: Ola Hallengren MaintenanceSolution, FirstResponderKit, DarlingData, sp_WhoIsActive.

.DESCRIPTION
    All downloads happen on the CLIENT machine, then SQL is pushed to each target
    via Invoke-DbaQuery. No outbound internet access required on SQL Server or MI.

    Version comparison: the date is parsed from the downloaded SQL content itself
    (which is already on the client), then compared to the date in the installed
    procedure header. No GitHub API calls needed for version comparison — the
    downloaded content IS the latest version.

    Installed in:
        SQL VM  : [DBA]
        SQL MI  : [AzDBA]

.PARAMETER VmServers
    Pre-connected SMO objects for SQL Server VMs (from Connect-DbaInstance).

.PARAMETER MiServers
    Pre-connected SMO objects for Managed Instances.

.PARAMETER VmDbaDatabase
    DBA database name on SQL VMs. Default: DBA

.PARAMETER MiDbaDatabase
    DBA database name on SQL MIs. Default: AzDBA

.PARAMETER Force
    Re-install even if the installed version is current.

.PARAMETER GitHubToken
    Optional GitHub PAT. Avoids the 60 req/h unauthenticated rate limit.
    Only needed for the raw file downloads; not used for API calls.

.EXAMPLE
    $miServers = @('mi01.xxx.database.windows.net') | ForEach-Object {
        Connect-DbaInstance -SqlInstance $_ -AccessToken $token
    }
    $vmServers = @('SQLVM01') | ForEach-Object { Connect-DbaInstance -SqlInstance $_ }

    .\Install-DbaToolSuite.ps1 -VmServers $vmServers -MiServers $miServers
#>

param(
    [object[]]$VmServers      = @(),
    [object[]]$MiServers      = @(),
    [string]  $VmDbaDatabase  = 'DBA',
    [string]  $MiDbaDatabase  = 'AzDBA',
    [string]  $GitHubToken    = '',
    [switch]  $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module dbatools -Force

#region ── Helpers ───────────────────────────────────────────────────────────────

function Write-Status {
    param([string]$Instance, [string]$Tool, [string]$Status, [string]$Detail = '')
    $ts  = Get-Date -Format 'HH:mm:ss'
    $msg = "[$ts] $($Instance.PadRight(40)) | $($Tool.PadRight(20)) | $Status"
    if ($Detail) { $msg += " — $Detail" }
    Write-Host $msg
}

function Get-RawFile {
    param([string]$Url)
    $headers = @{}
    if ($script:GitHubToken) { $headers.Authorization = "Bearer $script:GitHubToken" }
    (Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -ErrorAction Stop).Content
}

function Get-ZipExtracted {
    param([string]$Repo, [string]$Branch = 'main')
    $tmpZip = [System.IO.Path]::GetTempFileName() + '.zip'
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) `
                        ([System.IO.Path]::GetRandomFileName())
    $url    = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
    $headers = @{}
    if ($script:GitHubToken) { $headers.Authorization = "Bearer $script:GitHubToken" }

    Invoke-WebRequest -Uri $url -Headers $headers -OutFile $tmpZip `
                      -UseBasicParsing -ErrorAction Stop
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    Remove-Item $tmpZip -Force
    return (Get-ChildItem $tmpDir -Directory | Select-Object -First 1).FullName
}

function Get-HeaderDate {
    <#
    Parses the first date-like string from a block of SQL text.
    Handles:
      YYYY-MM-DD  (Ola, FRK, DarlingData)
      vXXXX.YYYYMMDD  (sp_WhoIsActive new scheme)
    Returns $null if no date found.
    #>
    param([string]$Sql)
    if ([string]::IsNullOrWhiteSpace($Sql)) { return $null }

    if ($Sql -match '(\d{4}-\d{2}-\d{2})') {
        return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
    }
    if ($Sql -match 'v\d{4}\.(\d{8})') {
        return [datetime]::ParseExact($Matches[1], 'yyyyMMdd', $null)
    }
    return $null
}

function Get-InstalledProcDate {
    param([object]$Server, [string]$Database, [string]$ProcName)
    $query = @"
SELECT OBJECT_DEFINITION(OBJECT_ID(N'$ProcName')) AS def
WHERE  OBJECT_ID(N'$ProcName') IS NOT NULL;
"@
    try {
        $def = Invoke-DbaQuery -SqlInstance $Server -Database $Database `
                               -Query $query -As SingleValue -EnableException
        if ([string]::IsNullOrWhiteSpace($def)) { return $null }
        return Get-HeaderDate -Sql $def
    } catch {
        return $null
    }
}

function Invoke-SqlScript {
    <#
    Splits on GO batch separators, executes each batch individually.
    Invoke-DbaQuery does not handle GO natively.
    #>
    param([object]$Server, [string]$Database, [string]$Sql)
    $batches = $Sql -split '(?m)^\s*GO\s*$' |
               Where-Object { $_.Trim() -ne '' }
    foreach ($batch in $batches) {
        Invoke-DbaQuery -SqlInstance $Server -Database $Database `
                        -Query $batch -EnableException -Verbose:$false
    }
}

#endregion

#region ── Download all tools to client ──────────────────────────────────────────

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Downloading tool sources from GitHub ..."

# ── Ola Hallengren ────────────────────────────────────────────────────────────
$olaSql  = Get-RawFile `
    'https://raw.githubusercontent.com/olahallengren/sql-server-maintenance-solution/master/MaintenanceSolution.sql'
$olaDate = Get-HeaderDate -Sql $olaSql
Write-Host "  Ola date in download   : $($olaDate?.ToString('yyyy-MM-dd') ?? 'not found')"

# ── sp_WhoIsActive ─────────────────────────────────────────────────────────────
# Root = SQL 2022+; /2019 subfolder = SQL 2019 and earlier
$wiaSql2022 = Get-RawFile `
    'https://raw.githubusercontent.com/amachanic/sp_whoisactive/master/sp_WhoIsActive.sql'
$wiaSql2019 = Get-RawFile `
    'https://raw.githubusercontent.com/amachanic/sp_whoisactive/master/2019/sp_WhoIsActive.sql'
$wiaDate    = Get-HeaderDate -Sql $wiaSql2022
Write-Host "  sp_WhoIsActive date    : $($wiaDate?.ToString('yyyy-MM-dd') ?? 'not found')"

# ── First Responder Kit ────────────────────────────────────────────────────────
$frkDir   = Get-ZipExtracted -Repo 'BrentOzarULTD/SQL-Server-First-Responder-Kit' -Branch 'main'
$frkFiles = @(
    'sp_Blitz.sql', 'sp_BlitzCache.sql', 'sp_BlitzFirst.sql',
    'sp_BlitzIndex.sql', 'sp_BlitzAnalysis.sql', 'sp_BlitzQueryStore.sql'
)
$frkSqls = $frkFiles | ForEach-Object {
    $f = Get-ChildItem $frkDir -Filter $_ -Recurse -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($f) { Get-Content $f.FullName -Raw } else { $null }
} | Where-Object { $_ }
# Representative date from sp_Blitz.sql (first file)
$frkDate = Get-HeaderDate -Sql $frkSqls[0]
Write-Host "  FRK date in download   : $($frkDate?.ToString('yyyy-MM-dd') ?? 'not found')"

# ── DarlingData ────────────────────────────────────────────────────────────────
$ddDir   = Get-ZipExtracted -Repo 'erikdarlingdata/DarlingData' -Branch 'main'
$ddProcs = @(
    'sp_HumanEvents', 'sp_HumanEventsBlockViewer', 'sp_PressureDetector',
    'sp_QuickieStore', 'sp_LogHunter', 'sp_HealthParser',
    'sp_IndexCleanup', 'sp_PerfCheck'
)
$ddSqls = $ddProcs | ForEach-Object {
    $f = Get-ChildItem $ddDir -Filter "$_.sql" -Recurse -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($f) { Get-Content $f.FullName -Raw } else { $null }
} | Where-Object { $_ }
$ddDate = Get-HeaderDate -Sql $ddSqls[0]
Write-Host "  DarlingData date       : $($ddDate?.ToString('yyyy-MM-dd') ?? 'not found')"

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Downloads complete."

# Map tool names to their downloaded dates (from content, not API)
$latestDates = @{
    Ola               = $olaDate
    FirstResponderKit = $frkDate
    DarlingData       = $ddDate
    WhoIsActive       = $wiaDate
}

#endregion

#region ── Tool definitions ───────────────────────────────────────────────────────

$tools = [ordered]@{

    Ola = @{
        RepProc   = 'dbo.DatabaseBackup'
        InstallFn = {
            param([object]$Server, [string]$Database)
            $sql = $script:olaSql -replace 'USE \[master\]', "USE [$Database]"
            # On PaaS, sp_add_job in msdb is unavailable without sysadmin.
            # Deploy stored procedures only; Agent jobs must be created separately.
            $isPaas = $Server.DatabaseEngineEdition.ToString() -in
                        @('SqlAzureManagedInstance', 'SqlDatabase')
            if ($isPaas) {
                # Strip everything from the first EXEC msdb.dbo.sp_add_job line onward
                $sql = ($sql -split '(?m)^.*sp_add_job.*$')[0]
            }
            Invoke-SqlScript -Server $Server -Database $Database -Sql $sql
        }
    }

    FirstResponderKit = @{
        RepProc   = 'dbo.sp_Blitz'
        InstallFn = {
            param([object]$Server, [string]$Database)
            foreach ($sql in $script:frkSqls) {
                try   { Invoke-SqlScript -Server $Server -Database $Database -Sql $sql }
                catch { Write-Warning "FRK script error (non-fatal): $($_.Exception.Message)" }
            }
        }
    }

    DarlingData = @{
        RepProc   = 'dbo.sp_HumanEvents'
        InstallFn = {
            param([object]$Server, [string]$Database)
            foreach ($sql in $script:ddSqls) {
                try   { Invoke-SqlScript -Server $Server -Database $Database -Sql $sql }
                catch { Write-Warning "DarlingData script error (non-fatal): $($_.Exception.Message)" }
            }
        }
    }

    WhoIsActive = @{
        RepProc   = 'dbo.sp_WhoIsActive'
        InstallFn = {
            param([object]$Server, [string]$Database)
            # SQL 2022+ uses root; SQL 2019 (VersionMajor 15) and earlier use /2019
            $sql = if ($Server.VersionMajor -le 15) { $script:wiaSql2019 }
                   else                              { $script:wiaSql2022 }
            Invoke-SqlScript -Server $Server -Database $Database -Sql $sql
        }
    }
}

#endregion

#region ── Install loop ───────────────────────────────────────────────────────────

function Install-ToolsOnServer {
    param([object]$Server, [string]$DbName)

    $instanceName = $Server.DomainInstanceName

    if (-not $Server.Databases[$DbName]) {
        Write-Warning "[$instanceName] Database [$DbName] not found — skipping."
        return
    }

    foreach ($toolName in $tools.Keys) {
        $tool        = $tools[$toolName]
        $latestDate  = $latestDates[$toolName]
        $installedDate = Get-InstalledProcDate -Server   $Server `
                                               -Database $DbName `
                                               -ProcName $tool.RepProc

        $notInstalled = ($null -eq $installedDate)

        # If latest date could not be parsed from download, treat as unknown
        # but still install when not present; warn when present.
        $outdated = (
            $latestDate -and
            $installedDate -and
            $installedDate.Date -lt $latestDate.Date
        )

        $unknownLatest = (-not $latestDate)

        if (-not $notInstalled -and -not $outdated -and -not $Force -and -not $unknownLatest) {
            Write-Status $instanceName $toolName 'OK' `
                "Installed: $($installedDate.ToString('yyyy-MM-dd')), " +
                "Latest: $($latestDate.ToString('yyyy-MM-dd'))"
            continue
        }

        if (-not $notInstalled -and $unknownLatest -and -not $Force) {
            Write-Status $instanceName $toolName 'SKIPPED' `
                "Installed: $($installedDate.ToString('yyyy-MM-dd')) — " +
                "could not parse latest version date from download; use -Force to reinstall"
            continue
        }

        $reason = if ($notInstalled) { 'Not installed' }
                  elseif ($outdated) {
                      "Outdated — installed: $($installedDate.ToString('yyyy-MM-dd')), " +
                      "latest: $($latestDate.ToString('yyyy-MM-dd'))"
                  } elseif ($unknownLatest) { 'Version unknown — forcing reinstall' }
                  else                      { 'Force reinstall' }

        Write-Status $instanceName $toolName 'Installing' $reason
        try {
            & $tool.InstallFn $Server $DbName
            # Re-read installed date to confirm
            $newDate = Get-InstalledProcDate -Server $Server -Database $DbName `
                                             -ProcName $tool.RepProc
            $confirmed = if ($newDate) { "Now: $($newDate.ToString('yyyy-MM-dd'))" } `
                         else          { 'WARNING: proc not found after install' }
            Write-Status $instanceName $toolName 'Done' $confirmed
        } catch {
            Write-Status $instanceName $toolName 'FAILED' $_.Exception.Message
        }
    }
}

foreach ($server in $VmServers)  { Install-ToolsOnServer -Server $server -DbName $VmDbaDatabase }
foreach ($server in $MiServers)  { Install-ToolsOnServer -Server $server -DbName $MiDbaDatabase }

# Cleanup temp directories
foreach ($dir in @($frkDir, $ddDir)) {
    $parent = Split-Path $dir -Parent
    if (Test-Path $parent) { Remove-Item $parent -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Done."

#endregion
