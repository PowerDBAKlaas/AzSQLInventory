#Requires -Version 7.6
<#
.SYNOPSIS
    Installs or updates the standard DBA tool suite on all target instances.
    Tools: Ola Hallengren MaintenanceSolution, FirstResponderKit, DarlingData, sp_WhoIsActive.

.DESCRIPTION
    All downloads happen on the CLIENT machine (where this script runs), then SQL
    is pushed to each target via Invoke-DbaQuery. This avoids requiring outbound
    internet access on the target SQL Server or Managed Instance.

    Installed in:
        SQL VM  : [DBA]
        SQL MI  : [AzDBA]

    Version detection: parses the YYYY-MM-DD date from each procedure's header
    comment. Compares against the latest GitHub release date (API call from client).
    Installs only when absent, outdated, or -Force is specified.

    sp_WhoIsActive versioning: the new scheme embeds YYYYMMDD (no dashes) in the
    version string. Both formats are handled.

.PARAMETER VmServers
    Pre-connected SMO objects for SQL Server VMs (from Connect-DbaInstance).

.PARAMETER MiServers
    Pre-connected SMO objects for Managed Instances.

.PARAMETER VmDbaDatabase
    DBA database name on SQL VMs. Default: DBA

.PARAMETER MiDbaDatabase
    DBA database name on SQL MIs. Default: sqldb-dba-we-001

.PARAMETER Force
    Re-install even if the installed version is current.

.PARAMETER GitHubToken
    Optional GitHub PAT to avoid the 60 req/h unauthenticated API rate limit.
    Only needed if running against many instances in a short window.

.EXAMPLE
    $token = New-DbaAzAccessToken -Type RenewableServicePrincipal `
                 -Tenant $tid -Credential $spCred

    $miServers = @('mi01.xxx.database.windows.net') | ForEach-Object {
        Connect-DbaInstance -SqlInstance $_ -AccessToken $token
    }
    $vmServers = @('SQLVM01') | ForEach-Object {
        Connect-DbaInstance -SqlInstance $_
    }

    .\Install-DbaToolSuite.ps1 -VmServers $vmServers -MiServers $miServers
#>

param(
    [object[]]$VmServers = @(),
    [object[]]$MiServers = @(),
    [string]  $VmDbaDatabase = 'DBA',
    [string]  $MiDbaDatabase = 'AzDBA',
    [string]  $GitHubToken = '',
    [switch]  $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module dbatools -Force

#region ── Helpers ───────────────────────────────────────────────────────────────

function Write-Status {
    param([string]$Instance, [string]$Tool, [string]$Status, [string]$Detail = '')
    $ts = Get-Date -Format 'HH:mm:ss'
    $msg = "[$ts] $($Instance.PadRight(40)) | $($Tool.PadRight(20)) | $Status"
    if ($Detail) { $msg += " — $Detail" }
    Write-Host $msg
}

function Invoke-GitHubApi {
    param([string]$Uri)
    $headers = @{ Accept = 'application/vnd.github+json' }
    if ($script:GitHubToken) {
        $headers.Authorization = "Bearer $script:GitHubToken"
    }
    Invoke-RestMethod -Uri $Uri -Headers $headers -UseBasicParsing -ErrorAction Stop
}

function Get-GitHubLatestReleaseDate {
    <#
    Fetch latest release date from GitHub API.
    Some repos (Ola, sp_WhoIsActive) use tags rather than releases — fall back
    to the most recent tag commit date when no release exists.
    #>
    param([string]$Repo)
    try {
        $resp = Invoke-GitHubApi -Uri "https://api.github.com/repos/$Repo/releases/latest"
        return [datetime]$resp.published_at
    } catch {
        # Try latest tag as fallback
        try {
            $tags = Invoke-GitHubApi -Uri "https://api.github.com/repos/$Repo/tags"
            if ($tags -and $tags.Count -gt 0) {
                $sha = $tags[0].commit.sha
                $commit = Invoke-GitHubApi `
                    -Uri "https://api.github.com/repos/$Repo/commits/$sha"
                return [datetime]$commit.commit.committer.date
            }
        } catch {}
        Write-Warning "Could not determine latest release date for $Repo"
        return $null
    }
}

function Get-GitHubRawFile {
    param([string]$Url)
    $headers = @{}
    if ($script:GitHubToken) {
        $headers.Authorization = "Bearer $script:GitHubToken"
    }
    (Invoke-WebRequest -Uri $Url -Headers $headers -UseBasicParsing -ErrorAction Stop).Content
}

function Get-GitHubZipExtracted {
    <#
    Downloads a zip release from GitHub to a temp folder and returns
    the path to the extracted directory. Caller must clean up.
    #>
    param([string]$Repo, [string]$Branch = 'main')
    $tmpZip = [System.IO.Path]::GetTempFileName() + '.zip'
    $tmpDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),
        [System.IO.Path]::GetRandomFileName())
    $url = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
    $headers = @{}
    if ($script:GitHubToken) { $headers.Authorization = "Bearer $script:GitHubToken" }

    Invoke-WebRequest -Uri $url -Headers $headers -OutFile $tmpZip `
        -UseBasicParsing -ErrorAction Stop
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    Remove-Item $tmpZip -Force
    # Return the single subdirectory that zip expands into
    return (Get-ChildItem $tmpDir -Directory | Select-Object -First 1).FullName
}

function Get-InstalledProcDate {
    <#
    Reads the first YYYY-MM-DD or YYYYMMDD date from the installed proc's
    header comment. Returns $null if proc does not exist.
    #>
    param([object]$Server, [string]$Database, [string]$ProcName)
    $query = @"
SELECT OBJECT_DEFINITION(OBJECT_ID(N'$ProcName')) AS def
WHERE  OBJECT_ID(N'$ProcName') IS NOT NULL;
"@
    try {
        $def = Invoke-DbaQuery -SqlInstance $Server -Database $Database `
            -Query $query -As SingleValue -EnableException
        if ([string]::IsNullOrWhiteSpace($def)) { return $null }

        # Format 1: YYYY-MM-DD (Ola, FRK, DarlingData)
        if ($def -match '(\d{4}-\d{2}-\d{2})') {
            return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
        }
        # Format 2: YYYYMMDD (sp_WhoIsActive new versioning scheme)
        if ($def -match 'v\d{4}\.(\d{8})') {
            return [datetime]::ParseExact($Matches[1], 'yyyyMMdd', $null)
        }
        # Proc exists but no parseable date — treat as very old to force install
        return [datetime]::MinValue
    } catch {
        return $null
    }
}

function Invoke-SqlScript {
    param([object]$Server, [string]$Database, [string]$Sql)
    # Split on GO statements so batches execute correctly
    $batches = $Sql -split '\r?\nGO\r?\n|\r?\nGO$' |
        Where-Object { $_.Trim() -ne '' }
    foreach ($batch in $batches) {
        Invoke-DbaQuery -SqlInstance $Server -Database $Database `
            -Query $batch -EnableException -Verbose:$false
    }
}

#endregion

#region ── Download all tools to client once ─────────────────────────────────────

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Downloading tool sources from GitHub ..."

# Ola Hallengren — single SQL file, no zip needed
$olaSql = Get-GitHubRawFile `
    -Url 'https://raw.githubusercontent.com/olahallengren/sql-server-maintenance-solution/master/MaintenanceSolution.sql'
$olaDate = if ($olaSql -match '(\d{4}-\d{2}-\d{2})') {
    [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
} else { [datetime]::Today }

# sp_WhoIsActive — single SQL file, root targets SQL 2022+
# For SQL 2019 use the /2019/ subfolder variant
$wiaRootSql = Get-GitHubRawFile `
    -Url 'https://raw.githubusercontent.com/amachanic/sp_whoisactive/master/sp_WhoIsActive.sql'
$wia2019Sql = Get-GitHubRawFile `
    -Url 'https://raw.githubusercontent.com/amachanic/sp_whoisactive/master/2019/sp_WhoIsActive.sql'

# FRK — download zip, collect .sql files we need
$frkDir = Get-GitHubZipExtracted -Repo 'BrentOzarULTD/SQL-Server-First-Responder-Kit' -Branch 'main'
$frkFiles = @(
    'sp_Blitz.sql', 'sp_BlitzCache.sql', 'sp_BlitzFirst.sql',
    'sp_BlitzIndex.sql', 'sp_BlitzAnalysis.sql', 'sp_BlitzQueryStore.sql'
)
$frkSqls = $frkFiles | ForEach-Object {
    $path = Get-ChildItem $frkDir -Filter $_ -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($path) { Get-Content $path.FullName -Raw } else { $null }
    } | Where-Object { $_ }

# DarlingData — download zip, collect .sql files
$ddDir = Get-GitHubZipExtracted -Repo 'erikdarlingdata/DarlingData' -Branch 'main'
$ddProcs = @(
    'sp_HumanEvents', 'sp_HumanEventsBlockViewer', 'sp_PressureDetector',
    'sp_QuickieStore', 'sp_LogHunter', 'sp_HealthParser',
    'sp_IndexCleanup', 'sp_PerfCheck'
)
$ddSqls = $ddProcs | ForEach-Object {
    $procName = $_
    $path = Get-ChildItem $ddDir -Filter "$procName.sql" -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
        if ($path) { Get-Content $path.FullName -Raw } else { $null }
    } | Where-Object { $_ }

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Downloads complete."

# Get latest release dates from GitHub API (runs on client — always works)
$latestDates = @{
    Ola               = Get-GitHubLatestReleaseDate -Repo 'olahallengren/sql-server-maintenance-solution'
    FirstResponderKit = Get-GitHubLatestReleaseDate -Repo 'BrentOzarULTD/SQL-Server-First-Responder-Kit'
    DarlingData       = Get-GitHubLatestReleaseDate -Repo 'erikdarlingdata/DarlingData'
    WhoIsActive       = Get-GitHubLatestReleaseDate -Repo 'amachanic/sp_whoisactive'
}

#endregion

#region ── Tool install definitions ──────────────────────────────────────────────

$tools = [ordered]@{

    Ola               = @{
        RepProc   = 'dbo.DatabaseBackup'
        InstallFn = {
            param([object]$Server, [string]$Database, [string]$EngineEdition)
            # Redirect USE [master] to DBA database; suppress Agent job creation
            # on MI (no WMI access) and Azure SQL DB (no Agent)
            $sql = $script:olaSql -replace 'USE \[master\]', "USE [$Database]"
            if ($EngineEdition -in 'SqlAzureManagedInstance', 'SqlDatabase') {
                # Skip job creation — MI can run jobs but MaintenanceSolution
                # creates them in msdb via sp_add_job which requires sysadmin.
                # Deploy stored procedures only; schedule jobs manually.
                $sql = $sql -replace '(?s)-- Create jobs.*', '-- Job creation skipped for PaaS'
            }
            Invoke-SqlScript -Server $Server -Database $Database -Sql $sql
        }
    }

    FirstResponderKit = @{
        RepProc   = 'dbo.sp_Blitz'
        InstallFn = {
            param([object]$Server, [string]$Database, [string]$EngineEdition)
            foreach ($sql in $script:frkSqls) {
                try {
                    Invoke-SqlScript -Server $Server -Database $Database -Sql $sql
                } catch {
                    Write-Warning "FRK script error (non-fatal): $($_.Exception.Message)"
                }
            }
        }
    }

    DarlingData       = @{
        RepProc   = 'dbo.sp_HumanEvents'
        InstallFn = {
            param([object]$Server, [string]$Database, [string]$EngineEdition)
            foreach ($sql in $script:ddSqls) {
                try {
                    Invoke-SqlScript -Server $Server -Database $Database -Sql $sql
                } catch {
                    Write-Warning "DarlingData script error (non-fatal): $($_.Exception.Message)"
                }
            }
        }
    }

    WhoIsActive       = @{
        RepProc   = 'dbo.sp_WhoIsActive'
        InstallFn = {
            param([object]$Server, [string]$Database, [string]$EngineEdition)
            # Root script targets SQL 2022+; use /2019 subfolder for SQL 2019
            $sql = if ($Server.VersionMajor -le 15) {
                $script:wia2019Sql
            } else {
                $script:wiaRootSql
            }
            Invoke-SqlScript -Server $Server -Database $Database -Sql $sql
        }
    }
}

#endregion

#region ── Install loop ───────────────────────────────────────────────────────────

function Install-ToolsOnServer {
    param([object]$Server, [string]$DbName)

    $instanceName = $Server.DomainInstanceName
    $engineEdition = $Server.DatabaseEngineEdition.ToString()

    # Confirm target database exists
    if (-not $Server.Databases[$DbName]) {
        Write-Warning "[$instanceName] [$DbName] not found — skipping. Create the database first."
        return
    }

    foreach ($toolName in $tools.Keys) {
        $tool = $tools[$toolName]
        $installedDate = Get-InstalledProcDate -Server $Server `
            -Database $DbName `
            -ProcName $tool.RepProc
        $latestDate = $latestDates[$toolName]
        $notInstalled = ($null -eq $installedDate)
        $outdated = ($latestDate -and $installedDate -and
            $installedDate -ne [datetime]::MinValue -and
            $installedDate.Date -lt $latestDate.Date)

        if (-not ($notInstalled -or $outdated -or $Force)) {
            Write-Status $instanceName $toolName 'OK' `
                "Installed: $($installedDate.ToString('yyyy-MM-dd'))"
            continue
        }

        $reason = if ($notInstalled) { 'Not installed' }
        elseif ($outdated) {
            "Outdated — installed: $($installedDate.ToString('yyyy-MM-dd')), " +
            "latest: $($latestDate.ToString('yyyy-MM-dd'))"
        } else { 'Force reinstall' }

        Write-Status $instanceName $toolName 'Installing' $reason
        try {
            & $tool.InstallFn $Server $DbName $engineEdition
            Write-Status $instanceName $toolName 'Done'
        } catch {
            Write-Status $instanceName $toolName 'FAILED' $_.Exception.Message
        }
    }
}

foreach ($server in $VmServers) {
    Install-ToolsOnServer -Server $server -DbName $VmDbaDatabase
}

foreach ($server in $MiServers) {
    Install-ToolsOnServer -Server $server -DbName $MiDbaDatabase
}

# Cleanup temp directories
@($frkDir, $ddDir) | ForEach-Object {
    $parent = Split-Path $_ -Parent
    if (Test-Path $parent) { Remove-Item $parent -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Tool suite install/update complete."

#endregion
