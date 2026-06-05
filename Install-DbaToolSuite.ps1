#Requires -Version 5.1
<#
.SYNOPSIS
    Installs or updates the standard DBA tool suite on all target instances.
    Tools: Ola Hallengren MaintenanceSolution, FirstResponderKit, DarlingData, sp_WhoIsActive.

.DESCRIPTION
    Idempotent — safe to run repeatedly. Each tool is installed to the correct
    database per platform:
        SQL VM  : [DBA]
        SQL MI  : [sqldb-dba-we-001]

    DarlingData and FRK are installed via dbatools cmdlets (GitHub download).
    Ola and sp_WhoIsActive are downloaded directly from GitHub and applied via
    Invoke-DbaQuery.

    Version checking: each tool embeds a date in its procedure header. The script
    compares the installed header date against the latest GitHub release tag date
    and reports whether an update was applied.

.PARAMETER VmServers
    Pre-connected SMO objects for SQL Server VMs (from Connect-DbaInstance).

.PARAMETER MiServers
    Pre-connected SMO objects for Managed Instances.

.PARAMETER AccessToken
    Entra access token for MI connections (used for dbatools cmdlets that need
    to re-connect internally). From New-DbaAzAccessToken.

.PARAMETER VmDbaDatabase
    DBA database name on SQL VMs. Default: DBA

.PARAMETER MiDbaDatabase
    DBA database name on SQL MIs. Default: sqldb-dba-we-001

.PARAMETER Force
    Re-install even if the installed version matches the latest release.

.EXAMPLE
    $token = New-DbaAzAccessToken -Type RenewableServicePrincipal -Tenant $tid -Credential $spCred
    $miServers = @('mi01.xxx.database.windows.net') | ForEach-Object {
        Connect-DbaInstance -SqlInstance $_ -AccessToken $token
    }
    $vmServers = @('SQLVM01') | ForEach-Object { Connect-DbaInstance -SqlInstance $_ }

    .\Install-DbaToolSuite.ps1 -VmServers $vmServers -MiServers $miServers -AccessToken $token
#>

param(
    [object[]]$VmServers    = @(),
    [object[]]$MiServers    = @(),
    [object]  $AccessToken  = $null,
    [string]  $VmDbaDatabase = 'DBA',
    [string]  $MiDbaDatabase = 'sqldb-dba-we-001',
    [switch]  $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module dbatools -Force

#region ── Helpers ──────────────────────────────────────────────────────────────

function Get-InstalledProcDate {
    <#
    .SYNOPSIS
        Reads the first date-like token (YYYY-MM-DD) from the header of a
        stored procedure's definition in the target database.
        Returns $null if the procedure does not exist.
    #>
    param(
        [object]$Server,
        [string]$Database,
        [string]$ProcName
    )
    $query = @"
SELECT OBJECT_DEFINITION(OBJECT_ID(N'$ProcName')) AS [def]
WHERE  OBJECT_ID(N'$ProcName') IS NOT NULL;
"@
    try {
        $result = Invoke-DbaQuery -SqlInstance $Server -Database $Database `
                                   -Query $query -EnableException
        if (-not $result -or [string]::IsNullOrWhiteSpace($result.def)) {
            return $null
        }
        # Extract first YYYY-MM-DD from header comment
        if ($result.def -match '(\d{4}-\d{2}-\d{2})') {
            return [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null)
        }
        return $null
    } catch {
        return $null
    }
}

function Write-Status {
    param([string]$Instance, [string]$Tool, [string]$Status, [string]$Detail = '')
    $ts = Get-Date -Format 'HH:mm:ss'
    $msg = "[$ts] $Instance | $Tool | $Status"
    if ($Detail) { $msg += " — $Detail" }
    Write-Host $msg
}

function Get-GitHubLatestReleaseDate {
    param([string]$Repo)   # e.g. 'olahallengren/sql-server-maintenance-solution'
    try {
        $uri  = "https://api.github.com/repos/$Repo/releases/latest"
        $resp = Invoke-RestMethod -Uri $uri -UseBasicParsing -ErrorAction Stop
        return [datetime]$resp.published_at
    } catch {
        Write-Warning "Could not fetch latest release date for $Repo : $_"
        return $null
    }
}

function Get-GitHubRawContent {
    param([string]$Url)
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -ErrorAction Stop
    return $resp.Content
}

#endregion

#region ── Tool definitions ─────────────────────────────────────────────────────

# Each entry describes one tool suite:
#   Procs     : list of proc names to check for presence and version
#   InstallFn : scriptblock that installs/updates on a single $Server / $Database pair
$tools = [ordered]@{

    Ola = @{
        Procs    = @('dbo.DatabaseBackup', 'dbo.DatabaseIntegrityCheck',
                     'dbo.IndexOptimize',  'dbo.CommandExecute')
        InstallFn = {
            param($Server, $Database, $Force, $Token)
            $rawUrl = 'https://raw.githubusercontent.com/olahallengren/' +
                      'sql-server-maintenance-solution/master/MaintenanceSolution.sql'
            $sql = Get-GitHubRawContent -Url $rawUrl
            # Ola targets master by default; redirect to $Database
            $sql = $sql -replace "USE \[master\]", "USE [$Database]"
            Invoke-DbaQuery -SqlInstance $Server -Database $Database `
                            -Query $sql -EnableException -Verbose:$false
        }
        # Ola uses plain date comments in headers like: -- Date:         2024-10-13
        VersionRepo = 'olahallengren/sql-server-maintenance-solution'
    }

    FirstResponderKit = @{
        Procs    = @('dbo.sp_Blitz', 'dbo.sp_BlitzCache',
                     'dbo.sp_BlitzFirst', 'dbo.sp_BlitzIndex')
        InstallFn = {
            param($Server, $Database, $Force, $Token)
            $installParams = @{
                SqlInstance = $Server
                Database    = $Database
                Branch      = 'main'
                EnableException = $true
            }
            if ($Token) { $installParams.AccessToken = $Token }
            Install-DbaFirstResponderKit @installParams
        }
        VersionRepo = 'BrentOzarULTD/SQL-Server-First-Responder-Kit'
    }

    DarlingData = @{
        Procs    = @('dbo.sp_HumanEvents', 'dbo.sp_PressureDetector',
                     'dbo.sp_QuickieStore', 'dbo.sp_LogHunter',
                     'dbo.sp_HealthParser')
        InstallFn = {
            param($Server, $Database, $Force, $Token)
            $installParams = @{
                SqlInstance = $Server
                Database    = $Database
                Procedure   = 'All'
                EnableException = $true
            }
            if ($Token) { $installParams.AccessToken = $Token }
            Install-DbaDarlingData @installParams
        }
        VersionRepo = 'erikdarlingdata/DarlingData'
    }

    WhoIsActive = @{
        Procs    = @('dbo.sp_WhoIsActive')
        InstallFn = {
            param($Server, $Database, $Force, $Token)
            $rawUrl = 'https://raw.githubusercontent.com/amachanic/sp_whoisactive/' +
                      'master/sp_WhoIsActive.sql'
            $sql = Get-GitHubRawContent -Url $rawUrl
            Invoke-DbaQuery -SqlInstance $Server -Database $Database `
                            -Query $sql -EnableException -Verbose:$false
        }
        VersionRepo = 'amachanic/sp_whoisactive'
    }
}

#endregion

#region ── Main installation loop ───────────────────────────────────────────────

function Install-ToolsOnServer {
    param(
        [object]$Server,
        [string]$DbName,
        [object]$Token,
        [switch]$Force
    )

    $instanceName = $Server.Name

    # Ensure target database exists
    $dbExists = $Server.Databases[$DbName]
    if (-not $dbExists) {
        Write-Warning "[$instanceName] Database [$DbName] not found — skipping. Create it first."
        return
    }

    foreach ($toolName in $tools.Keys) {
        $tool = $tools[$toolName]

        # Check installed version (use first proc as representative)
        $repProc        = $tool.Procs[0]
        $installedDate  = Get-InstalledProcDate -Server $Server -Database $DbName -ProcName $repProc
        $latestDate     = Get-GitHubLatestReleaseDate -Repo $tool.VersionRepo
        $notInstalled   = ($null -eq $installedDate)
        $outdated       = ($latestDate -and $installedDate -and $installedDate -lt $latestDate.Date)

        if ($notInstalled) {
            $reason = 'Not installed'
        } elseif ($outdated) {
            $reason = "Outdated (installed: $($installedDate.ToString('yyyy-MM-dd')), " +
                      "latest: $($latestDate.ToString('yyyy-MM-dd')))"
        } elseif ($Force) {
            $reason = 'Force reinstall'
        } else {
            Write-Status $instanceName $toolName 'OK' `
                "Installed: $($installedDate.ToString('yyyy-MM-dd'))"
            continue
        }

        Write-Status $instanceName $toolName 'Installing' $reason
        try {
            & $tool.InstallFn $Server $DbName $Force.IsPresent $Token
            Write-Status $instanceName $toolName 'Done'
        } catch {
            Write-Status $instanceName $toolName 'FAILED' $_.Exception.Message
        }
    }
}

# SQL VMs
foreach ($server in $VmServers) {
    Install-ToolsOnServer -Server $server -DbName $VmDbaDatabase `
                          -Token $null -Force:$Force
}

# Managed Instances
foreach ($server in $MiServers) {
    Install-ToolsOnServer -Server $server -DbName $MiDbaDatabase `
                          -Token $AccessToken -Force:$Force
}

Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Tool suite install/update complete."

#endregion
