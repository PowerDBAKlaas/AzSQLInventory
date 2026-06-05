#Requires -Version 7.6
<#
.SYNOPSIS
    Installs or updates the standard DBA tool suite on all target instances.
    Tools: Ola Hallengren MaintenanceSolution, FirstResponderKit, DarlingData, sp_WhoIsActive.

.DESCRIPTION
    All downloads happen on the CLIENT machine, then SQL is pushed to each target
    via Invoke-DbaQuery / sqlcmd. No outbound internet required on the target.

    Version comparison: the date is parsed from the downloaded SQL content and
    compared to the date in the installed procedure header. No GitHub API calls.

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
    Optional GitHub PAT to avoid unauthenticated rate limits on raw downloads.

.EXAMPLE
    $miServers = @('mi01.xxx.database.windows.net') | ForEach-Object {
        Connect-DbaInstance -SqlInstance $_ -AccessToken $token
    }
    $vmServers = @('SQLVM01') | ForEach-Object { Connect-DbaInstance -SqlInstance $_ }

    .\Install-DbaToolSuite.ps1 -VmServers $vmServers -MiServers $miServers
#>

[CmdletBinding()]
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
    if ($Detail) { $msg += " - $Detail" }
    Write-Host $msg
}

function Get-RawFile {
    param([string]$Url)
    $headers = @{}
    if ($script:GitHubToken) { $headers['Authorization'] = "Bearer $script:GitHubToken" }
    (Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -ErrorAction Stop).Content
}

function Get-ZipExtracted {
    param([string]$Repo, [string]$Branch = 'main')
    $tmpZip = [System.IO.Path]::GetTempFileName() + '.zip'
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) `
                        ([System.IO.Path]::GetRandomFileName())
    $url     = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
    $headers = @{}
    if ($script:GitHubToken) { $headers['Authorization'] = "Bearer $script:GitHubToken" }
    Invoke-WebRequest -Uri $url -Headers $headers -OutFile $tmpZip `
                      -UseBasicParsing -ErrorAction Stop
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    Remove-Item $tmpZip -Force
    return (Get-ChildItem $tmpDir -Directory | Select-Object -First 1).FullName
}

function Get-HeaderDate {
    <#
    Parses the version/release date from a SQL script header.

    Patterns handled (in priority order):
      1. YYYY-MM-DD  — explicit ISO date used by Ola, FRK, DarlingData
         Requires surrounding non-digit context to avoid matching year-only strings.
         Match must have valid month (01-12) and day (01-31).
      2. vXXXX.YYYYMMDD — sp_WhoIsActive new versioning scheme

    Returns [datetime] or $null.
    #>
    param([string]$Sql)
    if ([string]::IsNullOrWhiteSpace($Sql)) { return $null }

    # Pattern 1: strict ISO date — digit boundary prevents matching inside longer numbers
    # Scans only the first 4000 chars (header area) to avoid false positives in SQL body
    $header = if ($Sql.Length -gt 4000) { $Sql.Substring(0, 4000) } else { $Sql }
    $isoPattern = '(?<!\d)(\d{4})-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])(?!\d)'
    if ($header -match $isoPattern) {
        $candidate = "$($Matches[1])-$($Matches[2])-$($Matches[3])"
        [datetime]$parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact(
                $candidate, 'yyyy-MM-dd',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$parsed)) {
            return $parsed
        }
    }

    # Pattern 2: sp_WhoIsActive vXXXX.YYYYMMDD
    if ($Sql -match 'v\d{4}\.(\d{8})') {
        [datetime]$parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact(
                $Matches[1], 'yyyyMMdd',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None,
                [ref]$parsed)) {
            return $parsed
        }
    }

    return $null
}

function Get-InstalledProcDate {
    param([object]$Server, [string]$Database, [string]$ProcName)
    $query = "SELECT OBJECT_DEFINITION(OBJECT_ID(N'$ProcName')) AS def
              WHERE  OBJECT_ID(N'$ProcName') IS NOT NULL;"
    try {
        $def = Invoke-DbaQuery -SqlInstance $Server -Database $Database `
                               -Query $query -As SingleValue -EnableException
        if ([string]::IsNullOrWhiteSpace($def)) { return $null }
        return Get-HeaderDate -Sql $def
    } catch {
        return $null
    }
}

function Test-InstalledProc {
    param([object]$Server, [string]$Database, [string]$ProcName)
    $query = @"
SELECT CASE WHEN OBJECT_ID(N'$ProcName') IS NULL THEN 0 ELSE 1 END AS ProcExists;
"@
    try {
        $exists = Invoke-DbaQuery -SqlInstance $Server -Database $Database `
                                  -Query $query -As SingleValue -EnableException
        return ([int]$exists -eq 1)
    } catch {
        return $false
    }
}

function Invoke-SqlFile {
    <#
    Writes SQL content to a temp file then executes via Invoke-DbaQuery -File.
    dbatools handles GO batch splitting correctly when using -File.
    This avoids the GO-inside-string-literal problem with manual splitting.
    #>
    param([object]$Server, [string]$Database, [string]$Sql)
    # Use a random GUID-based name — GetTempFileName() creates a real .tmp file
    # that would be orphaned if we only write to a .sql-renamed path.
    $tmpFile = Join-Path ([System.IO.Path]::GetTempPath()) ("dba_$(New-Guid).sql")
    try {
        [System.IO.File]::WriteAllText($tmpFile, $Sql,
            [System.Text.Encoding]::UTF8)
        Invoke-DbaQuery -SqlInstance $Server -Database $Database `
                        -File $tmpFile -EnableException -Verbose:$false
    } finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region ── Download all tools to client ──────────────────────────────────────────

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Downloading tool sources from GitHub ..."

# Ola Hallengren
$olaSql  = Get-RawFile `
    'https://raw.githubusercontent.com/olahallengren/sql-server-maintenance-solution/master/MaintenanceSolution.sql'
$olaDate = Get-HeaderDate -Sql $olaSql
$olaDateStr = if ($olaDate) { $olaDate.ToString('yyyy-MM-dd') } else { 'not found' }
Write-Host "  Ola date in download        : $olaDateStr"

# sp_WhoIsActive — root = SQL 2022+; /2019 subfolder = SQL 2019 and earlier
$wiaSql2022 = Get-RawFile `
    'https://raw.githubusercontent.com/amachanic/sp_whoisactive/master/sp_WhoIsActive.sql'
$wiaSql2019 = Get-RawFile `
    'https://raw.githubusercontent.com/amachanic/sp_whoisactive/master/2019/sp_WhoIsActive.sql'
$wiaDate    = Get-HeaderDate -Sql $wiaSql2022
$wiaDateStr = if ($wiaDate) { $wiaDate.ToString('yyyy-MM-dd') } else { 'not found' }
Write-Host "  sp_WhoIsActive date         : $wiaDateStr"

# First Responder Kit
$frkDir   = Get-ZipExtracted -Repo 'BrentOzarULTD/SQL-Server-First-Responder-Kit' -Branch 'main'
$frkFiles = @(
    'sp_Blitz.sql', 'sp_BlitzCache.sql', 'sp_BlitzFirst.sql',
    'sp_BlitzIndex.sql', 'sp_BlitzAnalysis.sql', 'sp_BlitzQueryStore.sql'
)
$frkSqls = foreach ($f in $frkFiles) {
    $found = Get-ChildItem $frkDir -Filter $f -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { Get-Content $found.FullName -Raw }
}
$frkSqls  = @($frkSqls | Where-Object { $_ })
$frkDate  = Get-HeaderDate -Sql $frkSqls[0]
$frkDateStr = if ($frkDate) { $frkDate.ToString('yyyy-MM-dd') } else { 'not found' }
Write-Host "  FRK date in download        : $frkDateStr"

# DarlingData
$ddDir   = Get-ZipExtracted -Repo 'erikdarlingdata/DarlingData' -Branch 'main'
$ddProcs = @(
    'sp_HumanEvents', 'sp_HumanEventsBlockViewer', 'sp_PressureDetector',
    'sp_QuickieStore', 'sp_LogHunter', 'sp_HealthParser',
    'sp_IndexCleanup', 'sp_PerfCheck'
)
$ddSqls = foreach ($p in $ddProcs) {
    $found = Get-ChildItem $ddDir -Filter "$p.sql" -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { Get-Content $found.FullName -Raw }
}
$ddSqls   = @($ddSqls | Where-Object { $_ })
$ddDate   = Get-HeaderDate -Sql $ddSqls[0]
$ddDateStr = if ($ddDate) { $ddDate.ToString('yyyy-MM-dd') } else { 'not found' }
Write-Host "  DarlingData date            : $ddDateStr"

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Downloads complete."

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
            try {
                Invoke-SqlFile -Server $Server -Database $Database -Sql $sql
            } catch {
                # On MI/Azure SQL, SQL Agent job creation sections can fail while proc deploy still succeeds.
                $message = $_.Exception.Message
                $isPaas  = $Server.DatabaseEngineEdition.ToString() -in
                           @('SqlAzureManagedInstance', 'SqlDatabase')
                $jobError = $message -match 'sp_add_job|sp_add_jobstep|msdb|SQLServerAgent'
                if ($isPaas -and $jobError) {
                    Write-Warning "Ola job section skipped on PaaS: $message"
                } else {
                    throw
                }
            }
        }
    }

    FirstResponderKit = @{
        RepProc   = 'dbo.sp_Blitz'
        InstallFn = {
            param([object]$Server, [string]$Database)
            foreach ($sql in $script:frkSqls) {
                try   { Invoke-SqlFile -Server $Server -Database $Database -Sql $sql }
                catch { Write-Warning "FRK script error (non-fatal): $($_.Exception.Message)" }
            }
        }
    }

    DarlingData = @{
        RepProc   = 'dbo.sp_HumanEvents'
        InstallFn = {
            param([object]$Server, [string]$Database)
            foreach ($sql in $script:ddSqls) {
                try   { Invoke-SqlFile -Server $Server -Database $Database -Sql $sql }
                catch { Write-Warning "DarlingData script error (non-fatal): $($_.Exception.Message)" }
            }
        }
    }

    WhoIsActive = @{
        RepProc   = 'dbo.sp_WhoIsActive'
        InstallFn = {
            param([object]$Server, [string]$Database)
            $sql = if ($Server.VersionMajor -le 15) { $script:wiaSql2019 }
                   else                              { $script:wiaSql2022 }
            Invoke-SqlFile -Server $Server -Database $Database -Sql $sql
        }
    }
}

#endregion

#region ── Install loop ───────────────────────────────────────────────────────────

function Install-ToolsOnServer {
    param([object]$Server, [string]$DbName)

    $instanceName = $Server.DomainInstanceName

    if (-not $Server.Databases[$DbName]) {
        Write-Warning "[$instanceName] Database [$DbName] not found - skipping."
        return
    }

    foreach ($toolName in $script:tools.Keys) {
        $tool          = $script:tools[$toolName]
        $latestDate    = $script:latestDates[$toolName]
        $installedProc = Test-InstalledProc -Server   $Server `
                                            -Database $DbName `
                                            -ProcName $tool.RepProc
        $installedDate = Get-InstalledProcDate -Server   $Server `
                                               -Database $DbName `
                                               -ProcName $tool.RepProc

        $notInstalled  = -not $installedProc
        $outdated      = (
            $null -ne $latestDate -and
            $null -ne $installedDate -and
            $installedDate.Date -lt $latestDate.Date
        )
        $latestUnknown = ($null -eq $latestDate)

        # Determine action
        if ($Force) {
            $reason = 'Force reinstall'
        } elseif ($notInstalled) {
            $reason = 'Not installed'
        } elseif ($outdated) {
            $installedStr = $installedDate.ToString('yyyy-MM-dd')
            $latestStr    = $latestDate.ToString('yyyy-MM-dd')
            $reason = "Outdated - installed: $installedStr, latest: $latestStr"
        } elseif ($latestUnknown -and -not $notInstalled) {
            # Installed but we cannot determine if it is current
            $installedStr = if ($null -ne $installedDate) {
                $installedDate.ToString('yyyy-MM-dd')
            } else {
                'unknown'
            }
            Write-Status $instanceName $toolName 'SKIPPED' `
                "Installed: $installedStr - latest date not parsed from download; use -Force to reinstall"
            continue
        } else {
            # Up to date
            if ($null -ne $installedDate -and $null -ne $latestDate) {
                $installedStr = $installedDate.ToString('yyyy-MM-dd')
                $latestStr    = $latestDate.ToString('yyyy-MM-dd')
                Write-Status $instanceName $toolName 'OK' `
                    "Installed: $installedStr, Latest: $latestStr"
            } else {
                Write-Status $instanceName $toolName 'OK' `
                    'Installed; date comparison not available'
            }
            continue
        }

        Write-Status $instanceName $toolName 'Installing' $reason
        try {
            & $tool.InstallFn $Server $DbName
            # Re-read to confirm
            $newExists = Test-InstalledProc -Server   $Server `
                                            -Database $DbName `
                                            -ProcName $tool.RepProc
            $newDate   = Get-InstalledProcDate -Server   $Server `
                                               -Database $DbName `
                                               -ProcName $tool.RepProc
            $confirmed = if ($newExists -and $null -ne $newDate) {
                "Confirmed: installed, header date $($newDate.ToString('yyyy-MM-dd'))"
            } elseif ($newExists) {
                'Confirmed: installed (header date not parseable)'
            } else {
                'WARNING: proc not found after install - check for errors above'
            }
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
    if (Test-Path $parent) {
        Remove-Item $parent -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Done."

#endregion
