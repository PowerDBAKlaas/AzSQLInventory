# Azure SQL Auditing — Complete Reference Manual

> Author: Klaas Vandenberghe (@PowerDBAKlaas)  
> Date: 2026-03-18  
> Covers: SQL Server on Azure VM · Azure SQL Managed Instance · Azure SQL Database  
> Techniques: Azure Portal · PowerShell (Az.Sql / Az.Monitor / dbatools) · T-SQL

---

## Table of Contents

1. [Platform Overview](#1-platform-overview)
2. [Master Capability Matrix](#2-master-capability-matrix)
3. [Audit Destinations](#3-audit-destinations)
4. [SQL Server on Azure VM](#4-sql-server-on-azure-vm)
5. [Azure SQL Managed Instance](#5-azure-sql-managed-instance)
6. [Azure SQL Database](#6-azure-sql-database)
7. [CRUD Quick Reference](#7-crud-quick-reference)
8. [Permissions Reference](#8-permissions-reference)
9. [Log Analytics Field Mapping](#9-log-analytics-field-mapping)
10. [Gotchas & Pitfalls](#10-gotchas--pitfalls)

---

## 1. Platform Overview

| | 🖥 SQL Server on Azure VM | 🛡 Azure SQL Managed Instance | ☁ Azure SQL Database |
|---|---|---|---|
| **Type** | IaaS — full OS + SQL access | PaaS — instance-level control | PaaS — logical server model |
| **Audit objects** | Server Audit + Server/DB Audit Spec | Server Audit + Server/DB Audit Spec | DB Audit Specification only (T-SQL) |
| **Destinations** | FILE, AppLog, SecurityLog, Blob (2022+) | Blob (URL), Log Analytics, Event Hub | Blob, Log Analytics, Event Hub |
| **Portal scope** | Defender/Diagnostics only — no SQL Audit | Full audit config via Auditing blade | Full audit config via Auditing blade |
| **PowerShell module** | `dbatools` / `SqlServer` (SMO) | `Az.Monitor` (`Set-AzDiagnosticSetting`) | `Az.Sql` (`*-AzSqlServerAudit`, `*-AzSqlDatabaseAudit`) |
| **Predicate (WHERE)** | T-SQL ✅ SMO ⚠ Portal ❌ | T-SQL ✅ Portal ❌ PS ❌ | T-SQL ✅ PS ✅ (`-PredicateExpression`) Portal ❌ |
| **`CREATE SERVER AUDIT` (T-SQL)** | ✅ | ✅ | ❌ (MSG 40514) |
| **Audit additive behavior** | N/A | N/A | ⚠ Server + DB audit both fire if both enabled |

> [!NOTE]
> **Do the 3 Azure defaults satisfy compliance frameworks (DISA STIG / NIST SP 800-53)?**
>
> The DISA STIG for SQL Server 2016 Instance (V-214016) requires **30 named action groups** — covering DDL, permission changes, logins, logouts, backups, impersonation, DBCC, role membership, and more.
>
> The Azure Portal defaults (`BATCH_COMPLETED_GROUP`, `SUCCESSFUL_DATABASE_AUTHENTICATION_GROUP`, `FAILED_DATABASE_AUTHENTICATION_GROUP`) go a long way because `BATCH_COMPLETED_GROUP` captures the full text + result of every T-SQL batch, stored procedure, and transaction operation. This means DDL (`CREATE`/`ALTER`/`DROP`), permission changes (`GRANT`/`REVOKE`/`DENY`), `BACKUP`/`RESTORE`, `sp_addrole`, etc. all appear in BATCH_COMPLETED with their full statement text.
>
> **However, the 3 defaults are not sufficient for strict STIG compliance:**
> - `LOGOUT_GROUP` — logoff is a connection event, not a T-SQL batch; not captured by BATCH_COMPLETED
> - `DATABASE_PRINCIPAL_IMPERSONATION_GROUP` — implicit engine event, not always a client batch
> - `AUDIT_CHANGE_GROUP`, `SERVER_ROLE_MEMBER_CHANGE_GROUP`, `DATABASE_ROLE_MEMBER_CHANGE_GROUP` — missing structured metadata even if the underlying statement appears in a batch
>
> **On-premises SQL VM caveat:** `BATCH_COMPLETED_GROUP` is only available on **SQL Server 2022 (16.x) and later**. On SQL 2016–2019, all 30 STIG groups must be explicitly listed in the server audit specification.
>
> **Practical guidance:** For Azure SQL DB / MI with BATCH_COMPLETED as the baseline, add at minimum: `LOGOUT_GROUP`, `AUDIT_CHANGE_GROUP`, `DATABASE_ROLE_MEMBER_CHANGE_GROUP`, `SERVER_ROLE_MEMBER_CHANGE_GROUP`. For strict STIG compliance on SQL VM, use the full 30-group list (see §4b).

> [!IMPORTANT]
> There are **no `*-AzSqlInstanceAudit` cmdlets** in `Az.Sql` or any other Az module. Managed Instance audit is configured via T-SQL and/or `Set-AzDiagnosticSetting` (Az.Monitor) — not via dedicated audit cmdlets.

---

## 2. Master Capability Matrix

Legend: ✅ Full support · ⚠ Partial/limited · ❌ Not supported · — N/A for this platform

### 2a. By Feature

| Feature | SQL VM — Portal | SQL VM — PS | SQL VM — T-SQL | MI — Portal | MI — PS | MI — T-SQL | SQL DB — Portal | SQL DB — PS | SQL DB — T-SQL |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| Create / Configure Audit | ❌ | ⚠ dbatools/SMO | ✅ | ✅ | ⚠ `Set-AzDiagnosticSetting` | ✅ | ✅ | ✅ `Set-AzSqlServerAudit` | ❌ no `CREATE SERVER AUDIT` |
| Server Audit Specification | ❌ | ⚠ dbatools/SMO | ✅ | ❌ | ❌ | ✅ | — | — | — |
| Database Audit Specification | ❌ | ⚠ dbatools/SMO | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ |
| Audit Predicate (WHERE clause) | ❌ | ⚠ SMO only | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ `-PredicateExpression` | ✅ DB spec only |
| Enable / Disable Audit | ❌ | ⚠ dbatools | ✅ | ✅ | ⚠ via Diag Settings | ✅ | ✅ | ✅ | — ARM-level |
| Get / Inventory Audit Config | ❌ | ⚠ dbatools/SMO | ✅ `sys.server_audits` | ✅ | ⚠ `Get-AzDiagnosticSetting` | ✅ | ✅ | ✅ `Get-AzSqlServerAudit` | ⚠ DB spec catalog only |
| Remove / Drop Audit | ❌ | ⚠ dbatools | ✅ | ✅ | ⚠ `Remove-AzDiagnosticSetting` | ✅ | ✅ | ✅ `Remove-AzSqlServerAudit` | ✅ |
| Audit Retention Config | ❌ | ⚠ file only (dbatools) | ✅ `MAX_ROLLOVER_FILES` etc. | ✅ | ✅ Diag Settings | — | ✅ | ✅ `-RetentionInDays` | — |
| Read via `sys.fn_get_audit_file` | — | ⚠ via `Invoke-Sqlcmd` | ✅ | — | ⚠ via `Invoke-Sqlcmd` | ✅ from blob URL | — | ⚠ via `Invoke-Sqlcmd` | ✅ from blob URL |
| Query via KQL (Log Analytics) | ✅ `AzureDiagnostics` | — | — | ✅ `SQLSecurityAuditEvents` | — | — | ✅ `SQLSecurityAuditEvents` | — | — |
| Microsoft Defender for SQL | ✅ Defender for Cloud | ✅ | — | ✅ | ✅ | — | ✅ | ✅ | — |

### 2b. By Destination

| Destination | SQL VM | MI | SQL DB | T-SQL Keyword |
|---|:---:|:---:|:---:|---|
| File (.xel) | ✅ | ❌ | ❌ | `TO FILE (FILEPATH='...')` |
| Azure Blob Storage | ⚠ SQL 2022+ | ✅ | ✅ | `TO URL (PATH='https://...')` |
| Log Analytics | ⚠ via AMA | ✅ | ✅ | ARM resource — not T-SQL |
| Event Hub | ⚠ via Diag Settings | ✅ | ✅ | ARM resource — not T-SQL |
| Application Log | ✅ | ❌ | ❌ | `TO APPLICATION_LOG` |
| Security Log | ✅ | ❌ | ❌ | `TO SECURITY_LOG` |
| External Monitor (MI LA/EH) | — | ✅ | — | `TO EXTERNAL_MONITOR` |

> [!NOTE]
> For MI, `TO EXTERNAL_MONITOR` is the T-SQL destination for both Log Analytics and Event Hub. The actual target (LA workspace / Event Hub) is configured separately via Portal Diagnostic Settings or `Set-AzDiagnosticSetting`.

---

## 3. Audit Destinations

| Destination | Detail |
|---|---|
| **File (.xel)** | VM only. Supports `MAXSIZE`, `MAX_ROLLOVER_FILES`, `RESERVE_DISK_SPACE`. Read via `sys.fn_get_audit_file`. |
| **Azure Blob Storage** | MI and SQL DB natively; VM on SQL 2022+. Auth: SAS token or Managed Identity. Produces `.xel` blobs. Retention in Portal/PS. |
| **Log Analytics** | MI and SQL DB via ARM Diagnostic Settings. Table: `SQLSecurityAuditEvents`. VM via AMA → `AzureDiagnostics`. Column names differ (see §9). |
| **Event Hub** | Near-realtime streaming to SIEM/SOAR. Requires Event Hub namespace + SAS Authorization Rule. |
| **Application Log** | VM only. Windows Event Log. Read via Event Viewer or `Get-WinEvent`. |
| **Security Log** | VM only. Tamper-resistant. Requires "Generate security audits" local policy on SQL service account. |
| **External Monitor** | MI only (T-SQL). Logical destination for LA + Event Hub — actual target set in Diagnostic Settings. |

---

## 4. SQL Server on Azure VM

> [!NOTE]
> Full IaaS — you manage the OS and SQL Server. The Azure Portal has no visibility into SQL Server Audit objects. Use T-SQL or PowerShell (dbatools / SMO) for all audit management.

### 4a. Audit Object Model

| Object | Scope | T-SQL DDL | dbatools Cmdlet |
|---|---|---|---|
| Server Audit | Instance-level; defines destination | `CREATE SERVER AUDIT` | `New-DbaServerAudit` |
| Server Audit Specification | Instance-level events (logins, DDL, etc.) | `CREATE SERVER AUDIT SPECIFICATION` | `New-DbaServerAuditSpecification` |
| Database Audit Specification | Per-database events (DML, SELECT, etc.) | `CREATE DATABASE AUDIT SPECIFICATION` | `New-DbaDatabaseAuditSpecification` |

### 4b. T-SQL — Full Lifecycle

```sql
/* ═══════════════════════════════════════════════════════════════
   Author : Klaas Vandenberghe ( @PowerDBAKlaas )
   Date   : 2026-03-18
   Purpose: Create and enable SQL Server Audit to FILE on Azure VM
   ═══════════════════════════════════════════════════════════════ */

USE master;
GO

/* ── Create Server Audit ── */
CREATE SERVER AUDIT [AuditSecurityEvents]
TO FILE (
    FILEPATH           = N'D:\SQLAudit\',
    MAXSIZE            = 100 MB,
    MAX_ROLLOVER_FILES = 50,
    RESERVE_DISK_SPACE = OFF
)
WITH (
    QUEUE_DELAY = 1000,          /* ms — 0 = synchronous, risks blocking */
    ON_FAILURE  = CONTINUE,      /* or SHUTDOWN | FAIL_OPERATION */
    AUDIT_GUID  = 'your-guid'    /* required for FCI — same on all nodes */
)
WHERE (
    [application_name] NOT LIKE '%ReportingServices%'
    AND [statement] NOT LIKE '%sp_reset_connection%'
);
GO

ALTER SERVER AUDIT [AuditSecurityEvents] WITH (STATE = ON);
GO

/* ── Server Audit Specification ── */
CREATE SERVER AUDIT SPECIFICATION [AuditSpec_SecurityEvents]
FOR SERVER AUDIT [AuditSecurityEvents]
ADD (FAILED_LOGIN_GROUP),
ADD (SUCCESSFUL_LOGIN_GROUP),
ADD (LOGOUT_GROUP),
ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
ADD (DATABASE_PERMISSION_CHANGE_GROUP),
ADD (SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP),
ADD (AUDIT_CHANGE_GROUP)
WITH (STATE = ON);
GO

/* ── Database Audit Specification ── */
USE MyDatabase;
GO
CREATE DATABASE AUDIT SPECIFICATION [DBAuditSpec_Sensitive]
FOR SERVER AUDIT [AuditSecurityEvents]
ADD (SELECT, INSERT, UPDATE, DELETE ON dbo.SensitiveTable BY PUBLIC),
ADD (EXECUTE ON SCHEMA::[dbo] BY PUBLIC)
WITH (STATE = ON);
GO

/* ── Disable (spec first, then audit) ── */
ALTER SERVER AUDIT SPECIFICATION [AuditSpec_SecurityEvents] WITH (STATE = OFF);
ALTER SERVER AUDIT [AuditSecurityEvents] WITH (STATE = OFF);

/* ── Drop (spec first, then audit) ── */
DROP SERVER AUDIT SPECIFICATION [AuditSpec_SecurityEvents];
DROP SERVER AUDIT [AuditSecurityEvents];

/* ── Inventory ── */
SELECT
    sa.name                AS audit_name,
    sa.type_desc           AS destination_type,
    sa.is_state_enabled,
    sa.log_file_path,
    sa.on_failure_desc,
    sa.queue_delay,
    sa.predicate,
    ds.status_desc         AS runtime_status
FROM   sys.server_audits  sa
LEFT JOIN sys.dm_server_audit_status ds ON ds.audit_id = sa.audit_id;

SELECT * FROM sys.server_audit_specifications;
SELECT * FROM sys.server_audit_specification_details;
SELECT * FROM sys.database_audit_specifications;
SELECT * FROM sys.database_audit_specification_details;

/* ── Read Audit File ── */
SELECT
    event_time, server_principal_name, database_name,
    object_name, statement, action_id, succeeded,
    client_ip, application_name
FROM sys.fn_get_audit_file(
    N'D:\SQLAudit\AuditSecurityEvents*.sqlaudit',
    DEFAULT, DEFAULT
)
WHERE event_time >= DATEADD(HOUR, -24, GETUTCDATE())
ORDER BY event_time DESC;
```

### 4c. PowerShell — dbatools

```powershell
<#
    .SYNOPSIS  Manage SQL Server Audits on Azure VM via dbatools
    .AUTHOR    Klaas Vandenberghe ( @PowerDBAKlaas )
    .DATE      2026-03-18
#>
#Requires -Modules dbatools

$sqlInstance = 'myvm.westeurope.cloudapp.azure.com'
$auditPath   = 'D:\SQLAudit\'
$auditName   = 'AuditSecurityEvents'

/* Inventory */
Get-DbaServerAudit              -SqlInstance $sqlInstance
Get-DbaServerAuditSpecification -SqlInstance $sqlInstance
Get-DbaDatabaseAuditSpecification -SqlInstance $sqlInstance -Database MyDatabase

/* Create */
New-DbaServerAudit -SqlInstance $sqlInstance -Name $auditName `
    -FilePath $auditPath -MaxSize '100MB' -MaxFiles 50

/* Enable / Disable */
Enable-DbaServerAudit  -SqlInstance $sqlInstance -Audit $auditName
Disable-DbaServerAudit -SqlInstance $sqlInstance -Audit $auditName

/* Remove */
Remove-DbaServerAudit -SqlInstance $sqlInstance -Audit $auditName -Confirm:$false
```

> [!WARNING]
> `New-DbaServerAudit` has no `-Predicate` parameter. To set a WHERE clause via PowerShell, pipe through `Invoke-DbaQuery` with raw T-SQL `ALTER SERVER AUDIT … WHERE (…)`.

### 4d. Azure Portal — VM Scope

| ✅ Supported in Portal | ❌ Not supported |
|---|---|
| Enable Microsoft Defender for SQL | View/manage SQL Server Audit objects |
| Configure Diagnostic Settings (Windows logs → LA / Event Hub) | Create Server Audit / Specifications |
| View Defender for Cloud alerts | Configure FILE / AppLog / SecLog destinations |
| Configure Azure Monitor Agent (AMA) for custom .xel log collection | Read or query audit event files |

---

## 5. Azure SQL Managed Instance

> [!IMPORTANT]
> **No `*-AzSqlInstanceAudit` cmdlets exist in any PowerShell module.** MI audit destinations for Log Analytics and Event Hub are configured via T-SQL (`TO EXTERNAL_MONITOR`) + Portal Diagnostic Settings, or via `Set-AzDiagnosticSetting` (Az.Monitor module). Blob storage is configured via T-SQL (`TO URL`) with a SAS credential. There is no FILE or Security Log destination.

### 5a. T-SQL — Full Lifecycle

```sql
/* ═══════════════════════════════════════════════════════════════
   Author : Klaas Vandenberghe ( @PowerDBAKlaas )
   Date   : 2026-03-18
   Purpose: SQL Audit on Managed Instance
   Note   : Blob → TO URL + credential
             LA/Event Hub → TO EXTERNAL_MONITOR (target set in Diag Settings)
   ═══════════════════════════════════════════════════════════════ */

/* ── Option A: Blob Storage (SAS credential) ── */
CREATE CREDENTIAL [https://mystorageacct.blob.core.windows.net/sqlaudit]
    WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
    SECRET = 'sv=2020-08-04&ss=b&...';  /* SAS token — omit leading '?' */
GO

CREATE SERVER AUDIT [MI_AuditBlob]
TO URL (
    PATH           = N'https://mystorageacct.blob.core.windows.net/sqlaudit',
    RETENTION_DAYS = 90
)
WITH (
    QUEUE_DELAY = 1000,
    ON_FAILURE  = CONTINUE
)
WHERE ([application_name] NOT LIKE 'MS%');  /* predicate — T-SQL only */
GO

ALTER SERVER AUDIT [MI_AuditBlob] WITH (STATE = ON);
GO

/* ── Option B: Log Analytics / Event Hub (External Monitor) ── */
CREATE SERVER AUDIT [MI_AuditExt]
TO EXTERNAL_MONITOR           /* actual LA/EH target set in Diagnostic Settings */
WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
GO

ALTER SERVER AUDIT [MI_AuditExt] WITH (STATE = ON);
GO

/* ── Server Audit Specification ── */
CREATE SERVER AUDIT SPECIFICATION [MI_AuditSpec]
FOR SERVER AUDIT [MI_AuditBlob]
ADD (FAILED_LOGIN_GROUP),
ADD (SUCCESSFUL_LOGIN_GROUP),
ADD (SERVER_PRINCIPAL_CHANGE_GROUP),
ADD (DATABASE_OBJECT_PERMISSION_CHANGE_GROUP),
ADD (AUDIT_CHANGE_GROUP)
WITH (STATE = ON);
GO

/* ── Database Audit Specification ── */
USE MyDatabase;
GO
CREATE DATABASE AUDIT SPECIFICATION [MI_DBAuditSpec]
FOR SERVER AUDIT [MI_AuditBlob]
ADD (SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[dbo] BY PUBLIC)
WITH (STATE = ON);
GO

/* ── Disable (spec first, then audit) ── */
ALTER SERVER AUDIT SPECIFICATION [MI_AuditSpec] WITH (STATE = OFF);
ALTER SERVER AUDIT [MI_AuditBlob] WITH (STATE = OFF);

/* ── Drop (spec first, then audit) ── */
DROP SERVER AUDIT SPECIFICATION [MI_AuditSpec];
DROP SERVER AUDIT [MI_AuditBlob];

/* ── Read from Blob ── */
SELECT event_time, action_id, server_principal_name, database_name, object_name, statement, succeeded
FROM sys.fn_get_audit_file(
    N'https://mystorageacct.blob.core.windows.net/sqlaudit/MI_AuditBlob/*.xel',
    DEFAULT, DEFAULT
)
WHERE event_time >= DATEADD(DAY, -7, GETUTCDATE())
ORDER BY event_time DESC;
```

### 5b. PowerShell — Az.Monitor (Diagnostic Settings)

This is the only PowerShell path for MI audit — used to configure Log Analytics and Event Hub targets.

```powershell
<#
    .SYNOPSIS  Configure MI audit destinations via Diagnostic Settings (Az.Monitor)
    .AUTHOR    Klaas Vandenberghe ( @PowerDBAKlaas )
    .DATE      2026-03-18
    .NOTE      No *-AzSqlInstanceAudit cmdlets exist. Use Az.Monitor for LA/EventHub.
               Blob storage is configured entirely in T-SQL (TO URL + credential).
#>
#Requires -Modules Az.Monitor

$miResourceId   = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Sql/managedInstances/<mi-name>'
$workspaceId    = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws-name>'
$eventHubRuleId = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.EventHub/namespaces/<ns>/authorizationRules/RootManageSharedAccessKey'

/* ── Get current diagnostic settings ── */
Get-AzDiagnosticSetting -ResourceId $miResourceId

/* ── Enable Log Analytics ── */
$log = New-AzDiagnosticSettingLogSettingsObject `
    -Category 'SQLSecurityAuditEvents' `
    -Enabled $true

New-AzDiagnosticSetting `
    -Name            'MI-SQLAudit-LA' `
    -ResourceId      $miResourceId `
    -WorkspaceId     $workspaceId `
    -Log             $log

/* ── Enable Event Hub ── */
New-AzDiagnosticSetting `
    -Name                           'MI-SQLAudit-EH' `
    -ResourceId                     $miResourceId `
    -EventHubAuthorizationRuleId    $eventHubRuleId `
    -EventHubName                   'sqlaudit-hub' `
    -Log                            $log

/* ── Remove diagnostic setting ── */
Remove-AzDiagnosticSetting -ResourceId $miResourceId -Name 'MI-SQLAudit-LA'
```

### 5c. Azure Portal — Managed Instance

Navigate: **MI → Monitoring → Diagnostic settings**  
- Add diagnostic setting → enable `SQLSecurityAuditEvents` category → select LA workspace and/or Event Hub → Save  
- Then in T-SQL: `CREATE SERVER AUDIT … TO EXTERNAL_MONITOR` and enable

> [!WARNING]
> Predicate (WHERE) configuration is **not available** in Portal or PowerShell for MI. Set it in T-SQL on the `CREATE SERVER AUDIT` statement.

---

## 6. Azure SQL Database

> [!NOTE]
> Two audit levels: **Logical Server** (all databases; ARM resource via Portal/PS) and **Database** (per-DB; ARM resource for destination + T-SQL for audit specifications). `CREATE SERVER AUDIT` is **not supported** in T-SQL for Azure SQL DB. Server + DB audits are **additive** — if both active, events are written to both destinations simultaneously.

### 6a. T-SQL — Database Audit Specification

```sql
/* ═══════════════════════════════════════════════════════════════
   Author : Klaas Vandenberghe ( @PowerDBAKlaas )
   Date   : 2026-03-18
   Note   : CREATE SERVER AUDIT not supported in Azure SQL DB.
             Server-level audit destination configured via Portal/PS.
             DB Audit Specification references the ARM-provisioned audit.
   ═══════════════════════════════════════════════════════════════ */

USE MyDatabase;
GO

CREATE DATABASE AUDIT SPECIFICATION [DBAudit_SensitiveData]
FOR SERVER AUDIT [server_audit_default]   /* name from sys.server_audits */
ADD (SELECT ON dbo.PatientRecords BY PUBLIC),
ADD (INSERT, UPDATE, DELETE ON SCHEMA::[dbo] BY PUBLIC),
ADD (EXECUTE ON dbo.usp_GetSensitive BY PUBLIC)
WITH (STATE = ON);
GO

/* ── Alter (disable → alter → enable) ── */
ALTER DATABASE AUDIT SPECIFICATION [DBAudit_SensitiveData] WITH (STATE = OFF);
ALTER DATABASE AUDIT SPECIFICATION [DBAudit_SensitiveData]
    ADD (DATABASE_OBJECT_PERMISSION_CHANGE_GROUP);
ALTER DATABASE AUDIT SPECIFICATION [DBAudit_SensitiveData] WITH (STATE = ON);
GO

/* ── Drop ── */
ALTER DATABASE AUDIT SPECIFICATION [DBAudit_SensitiveData] WITH (STATE = OFF);
DROP DATABASE AUDIT SPECIFICATION [DBAudit_SensitiveData];
GO

/* ── Inventory ── */
SELECT * FROM sys.database_audit_specifications;
SELECT * FROM sys.database_audit_specification_details;

/* ── Read from Blob ── */
SELECT event_time, server_principal_name, database_name, object_name, statement, action_id, succeeded
FROM sys.fn_get_audit_file(
    N'https://mystorageacct.blob.core.windows.net/sqldbaudit/MyServer/MyDatabase/*.xel',
    DEFAULT, DEFAULT
)
WHERE event_time >= DATEADD(DAY, -7, GETUTCDATE())
ORDER BY event_time DESC;
```

### 6b. PowerShell — Az.Sql

```powershell
<#
    .SYNOPSIS  Manage Audit on Azure SQL Database via Az.Sql
    .AUTHOR    Klaas Vandenberghe ( @PowerDBAKlaas )
    .DATE      2026-03-18
    .NOTE      *ServerAudit  = logical server (covers all DBs).
               *DatabaseAudit = per-DB level.
               Both support -PredicateExpression for WHERE filtering.
               Neither creates T-SQL audit specs — do that in T-SQL.
#>
#Requires -Modules Az.Sql

$resourceGroup   = 'rg-sqldb-prod'
$serverName      = 'sql-logical-server-01'
$databaseName    = 'MyDatabase'
$storageAcctId   = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/mystorageacct'
$workspaceId     = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<ws>'
$eventHubRuleId  = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.EventHub/namespaces/<ns>/authorizationRules/RootManageSharedAccessKey'

/* ── SERVER-LEVEL (all databases) ── */

Get-AzSqlServerAudit `
    -ResourceGroupName $resourceGroup `
    -ServerName        $serverName

Set-AzSqlServerAudit `
    -ResourceGroupName       $resourceGroup `
    -ServerName              $serverName `
    -BlobStorageTargetState  Enabled `
    -StorageAccountResourceId $storageAcctId `
    -RetentionInDays         90 `
    -PredicateExpression     "[server_principal_name] != 'sa' AND [database_name] != 'master'"

Set-AzSqlServerAudit `
    -ResourceGroupName       $resourceGroup `
    -ServerName              $serverName `
    -LogAnalyticsTargetState Enabled `
    -WorkspaceResourceId     $workspaceId

Set-AzSqlServerAudit `
    -ResourceGroupName              $resourceGroup `
    -ServerName                     $serverName `
    -EventHubTargetState            Enabled `
    -EventHubName                   'sqlaudit-hub' `
    -EventHubAuthorizationRuleResourceId $eventHubRuleId

/* ── Disable all targets ── */
Set-AzSqlServerAudit `
    -ResourceGroupName       $resourceGroup `
    -ServerName              $serverName `
    -BlobStorageTargetState  Disabled `
    -LogAnalyticsTargetState Disabled `
    -EventHubTargetState     Disabled

Remove-AzSqlServerAudit `
    -ResourceGroupName $resourceGroup `
    -ServerName        $serverName

/* ── DATABASE-LEVEL (per-DB) ── */

Get-AzSqlDatabaseAudit `
    -ResourceGroupName $resourceGroup `
    -ServerName        $serverName `
    -DatabaseName      $databaseName

Set-AzSqlDatabaseAudit `
    -ResourceGroupName       $resourceGroup `
    -ServerName              $serverName `
    -DatabaseName            $databaseName `
    -LogAnalyticsTargetState Enabled `
    -WorkspaceResourceId     $workspaceId `
    -RetentionInDays         365 `
    -PredicateExpression     "statement NOT LIKE 'exec sp_%'"

Remove-AzSqlDatabaseAudit `
    -ResourceGroupName $resourceGroup `
    -ServerName        $serverName `
    -DatabaseName      $databaseName
```

> [!CAUTION]
> `Set-AzSqlServerAudit` and `Set-AzSqlDatabaseAudit` **overwrite** the existing configuration on every call. When adding a `-PredicateExpression` or changing `-AuditActionGroup`, always re-specify all target states you want to keep active.

### 6c. Azure Portal — Azure SQL Database

- **Server level**: Logical Server → Security → Auditing  
- **Database level**: Database → Security → Auditing  
- All three destinations available. Predicate ❌ not supported in Portal — use `-PredicateExpression` in PowerShell.

> [!CAUTION]
> **Additive audit behavior**: if server-level and database-level audits are both enabled, events are written to both destinations. This produces duplicate events in Log Analytics and doubles storage consumption. Only enable DB-level audit when server-level cannot meet requirements for a specific database.

---

## 7. CRUD Quick Reference

| Operation | Technique | SQL VM | Managed Instance | Azure SQL Database |
|---|---|---|---|---|
| **CREATE** | T-SQL | `CREATE SERVER AUDIT` | `CREATE SERVER AUDIT … TO URL` or `TO EXTERNAL_MONITOR` | `CREATE DATABASE AUDIT SPECIFICATION` only |
| | PowerShell | `New-DbaServerAudit` | T-SQL only for blob; `New-AzDiagnosticSetting` for LA/EH | `Set-AzSqlServerAudit` / `Set-AzSqlDatabaseAudit` |
| | Portal | ❌ | Diagnostic Settings blade | Server/DB → Security → Auditing |
| **ENABLE** | T-SQL | `ALTER SERVER AUDIT … WITH (STATE=ON)` | `ALTER SERVER AUDIT … WITH (STATE=ON)` | `ALTER DATABASE AUDIT SPECIFICATION … WITH (STATE=ON)` |
| | PowerShell | `Enable-DbaServerAudit` | `Set-AzDiagnosticSetting` (enable log category) | `Set-AzSqlServerAudit -BlobStorageTargetState Enabled` |
| | Portal | ❌ | Toggle ON in Auditing blade | Toggle ON in Auditing blade |
| **ALTER** | T-SQL | Disable spec → `ALTER SERVER AUDIT` → enable | Same as VM | Disable spec → `ALTER DATABASE AUDIT SPECIFICATION` → enable |
| | PowerShell | `Invoke-DbaQuery` + T-SQL | Re-run `New-AzDiagnosticSetting` with new params | Re-run `Set-AzSqlServerAudit` / `Set-AzSqlDatabaseAudit` with new params |
| | Portal | ❌ | Update Diagnostic Settings, Save | Update Auditing blade, Save |
| **DISABLE** | T-SQL | `ALTER … WITH (STATE=OFF)` — spec first | `ALTER … WITH (STATE=OFF)` — spec first | `ALTER DATABASE AUDIT SPECIFICATION … WITH (STATE=OFF)` |
| | PowerShell | `Disable-DbaServerAudit` | `Remove-AzDiagnosticSetting` or disable log category | `Set-AzSqlServerAudit -BlobStorageTargetState Disabled` (per target) |
| | Portal | ❌ | Toggle OFF in Auditing blade | Toggle OFF in Auditing blade |
| **DROP / REMOVE** | T-SQL | Disable → `DROP SERVER AUDIT SPECIFICATION` → `DROP SERVER AUDIT` | Same order as VM | Disable → `DROP DATABASE AUDIT SPECIFICATION` |
| | PowerShell | `Remove-DbaServerAudit` / `Remove-DbaServerAuditSpecification` | `Remove-AzDiagnosticSetting` | `Remove-AzSqlServerAudit` / `Remove-AzSqlDatabaseAudit` |
| | Portal | ❌ | Toggle OFF + Save | Toggle OFF + Save |
| **INVENTORY** | T-SQL | `sys.server_audits`, `sys.server_audit_specifications`, `sys.dm_server_audit_status` | Same + `sys.database_audit_specifications` | `sys.database_audit_specifications`, `sys.database_audit_specification_details` |
| | PowerShell | `Get-DbaServerAudit` / `Get-DbaServerAuditSpecification` | `Get-AzDiagnosticSetting` | `Get-AzSqlServerAudit` / `Get-AzSqlDatabaseAudit` |
| | Portal | ❌ | Auditing blade shows state | Auditing blade shows state |
| **READ EVENTS** | T-SQL | `sys.fn_get_audit_file(N'path\*.sqlaudit', DEFAULT, DEFAULT)` | `sys.fn_get_audit_file(N'https://.../*.xel', DEFAULT, DEFAULT)` | Same URL path pattern as MI |
| | KQL | `AzureDiagnostics \| where Category == "SQLSecurityAuditEvents"` | `SQLSecurityAuditEvents \| where ...` | `SQLSecurityAuditEvents \| where ...` |
| | Portal | Azure Monitor → Logs | MI → Security → Auditing → View audit logs | DB → Security → Auditing → View audit logs |

---

## 8. Permissions Reference

| Operation | SQL VM | Managed Instance | Azure SQL Database |
|---|---|---|---|
| Create/Alter Server Audit | `CONTROL SERVER` or `ALTER ANY AUDIT` | SQL: `ALTER ANY SERVER AUDIT` or sysadmin · RBAC: SQL Security Manager | Not T-SQL (ARM only) · RBAC: SQL Security Manager, Contributor, or Owner |
| Create DB Audit Specification | `ALTER ANY DATABASE AUDIT` or db_owner | `ALTER ANY DATABASE AUDIT` or db_owner | `ALTER ANY DATABASE AUDIT` or db_owner |
| Enable/Disable Audit (T-SQL) | `ALTER ANY AUDIT` | `ALTER ANY AUDIT` | `ALTER ANY DATABASE AUDIT` |
| View Audit Configuration | `VIEW SERVER STATE` + `VIEW ANY DEFINITION` | Same as VM | `VIEW DATABASE STATE` for DB-level views |
| Read Audit Files | `CONTROL SERVER` or `VIEW SERVER STATE` | SQL same as VM + Storage Blob Data Reader on container | db_owner or `VIEW DATABASE STATE` + Storage Blob Data Reader |
| Configure via PowerShell | dbatools: sysadmin or `CONTROL SERVER` | RBAC: Contributor or Owner on MI (for `Set-AzDiagnosticSetting`) | RBAC: SQL Security Manager or Contributor on logical server |
| Configure via Portal | N/A | RBAC: SQL Security Manager or Contributor | RBAC: SQL Security Manager or Contributor |
| Security Log destination | SQL service account: "Generate security audits" local policy | N/A | N/A |

> [!TIP]
> For read-only compliance/reporting: grant `VIEW SERVER STATE` + `VIEW ANY DEFINITION` on VM/MI. For Azure SQL DB blob reads, assign **Storage Blob Data Reader** on the container — never pass a storage account key directly.

---

## 9. Log Analytics Field Mapping

> [!WARNING]
> Column names differ between `sys.fn_get_audit_file` (T-SQL) and Log Analytics (KQL). Fields get type suffixes in KQL: `_s` (string), `_d` (double/numeric), `_b` (boolean). The timestamp column is renamed entirely.

| `sys.fn_get_audit_file` (T-SQL) | `SQLSecurityAuditEvents` (KQL — MI & SQL DB) | `AzureDiagnostics` (KQL — SQL VM) | Type |
|---|---|---|---|
| `event_time` | `TimeGenerated` | `TimeGenerated` | datetime |
| `server_principal_name` | `server_principal_name_s` | `server_principal_name_s` | string |
| `database_name` | `database_name_s` | `database_name_s` | string |
| `object_name` | `object_name_s` | `object_name_s` | string |
| `statement` | `statement_s` | `statement_s` | string |
| `action_id` | `action_id_s` | `action_id_s` | string |
| `action_name` | `event_type_s` | `event_type_s` | string |
| `application_name` | `application_name_s` | `application_name_s` | string |
| `client_ip` | `client_ip_s` | `client_ip_s` | string |
| `server_principal_id` | `server_principal_id_d` | `server_principal_id_d` | double |
| `session_id` | `session_id_d` | `session_id_d` | double |
| `duration_milliseconds` | `duration_milliseconds_d` | `duration_milliseconds_d` | double |
| `succeeded` | `succeeded_b` | `succeeded_b` | bool |
| `is_column_permission` | `is_column_permission_b` | `is_column_permission_b` | bool |
| `server_instance_name` | `LogicalServerName_s` | `Resource` | string |

```kusto
// ── MI / Azure SQL DB ──
SQLSecurityAuditEvents
| where TimeGenerated >= ago(24h)
| where succeeded_b == false
| where action_id_s in ("SL", "IN", "UP", "DL")
| project TimeGenerated, server_principal_name_s, database_name_s,
          object_name_s, statement_s, client_ip_s, application_name_s
| order by TimeGenerated desc

// ── SQL VM (via AMA) ──
AzureDiagnostics
| where Category == "SQLSecurityAuditEvents"
| where TimeGenerated >= ago(24h)
| project TimeGenerated, server_principal_name_s, database_name_s,
          statement_s, succeeded_b, client_ip_s
| order by TimeGenerated desc
```

---

## 10. Gotchas & Pitfalls

> [!CAUTION]
> **No `*-AzSqlInstanceAudit` cmdlets exist.**  
> `Get-AzSqlServerAudit` / `Set-AzSqlServerAudit` target Azure SQL DB logical servers only — they error or silently fail against a Managed Instance. For MI, use T-SQL + `Set-AzDiagnosticSetting` (Az.Monitor). There is no dedicated PS audit cmdlet family for MI.

> [!WARNING]
> **Log Analytics column name suffix mismatch.**  
> KQL queries use `application_name_s`, `statement_s`, `succeeded_b`. T-SQL `sys.fn_get_audit_file` returns `application_name`, `statement`, `succeeded`. MI/SQL DB table: `SQLSecurityAuditEvents`. SQL VM via AMA: `AzureDiagnostics` with `Category == "SQLSecurityAuditEvents"`.

> [!WARNING]
> **`CREATE SERVER AUDIT` not supported in Azure SQL DB.**  
> Returns Msg 40514. The audit destination is an ARM resource (Portal/PS only). The only T-SQL object for SQL DB is `DATABASE AUDIT SPECIFICATION`, which references the ARM-provisioned audit by its system-generated name (check `sys.server_audits` for the exact name — often `server_audit_default`).

> [!WARNING]
> **`-PredicateExpression` overwrites on every `Set-AzSqlServerAudit` / `Set-AzSqlDatabaseAudit` call.**  
> Both cmdlets replace the full policy — not merge. Always re-specify all target states, action groups, and predicate in a single call. Omitting `-AuditActionGroup` resets to the three default groups.

> [!WARNING]
> **Specification must be disabled before altering or dropping an audit.**  
> On VM and MI: (1) disable specification, (2) disable audit, (3) alter/drop, (4) re-enable. Attempting to alter an active audit while a specification is running will fail.

> [!CAUTION]
> **Azure SQL DB audit is additive — not exclusive.**  
> Server-level and database-level audits both fire independently if enabled. Events appear in both destinations, resulting in duplicate events in Log Analytics and doubled storage costs.

> [!WARNING]
> **MI: FILE destination is not supported.**  
> `CREATE SERVER AUDIT … TO FILE` fails on Managed Instance. Destinations: `TO URL` (blob via T-SQL) or `TO EXTERNAL_MONITOR` (LA/EH via Diagnostic Settings).

> [!WARNING]
> **Blob wildcard required for `sys.fn_get_audit_file` on MI/SQL DB.**  
> Path must end with `*.xel`: `https://account.blob.core.windows.net/container/*.xel`. Omitting the wildcard returns 0 rows without an error. The executing account needs **Storage Blob Data Reader** on the container.

> [!CAUTION]
> **`QUEUE_DELAY = 0` with `ON_FAILURE = SHUTDOWN` can take down the instance.**  
> Synchronous audit with shutdown-on-failure will stop SQL Server if the audit destination becomes unavailable. Use `CONTINUE` or `FAIL_OPERATION` with a non-zero queue delay in production unless a hard compliance requirement mandates synchronous logging.

> [!WARNING]
> **Security Log destination requires OS policy change.**  
> The SQL Server service account needs the Windows local policy "Generate security audits". Not configurable in SQL — requires Group Policy or local security policy on the VM. Without it, `TO SECURITY_LOG` succeeds but events are silently dropped.

> [!WARNING]
> **Audit GUID required in SQL Server FCI (Failover Cluster on VM).**  
> Specify the same `AUDIT_GUID` in `CREATE SERVER AUDIT` on all nodes. Omitting it means each node uses a different GUID and log files appear fragmented after failover.

> [!WARNING]
> **Azure SQL DB: server audit name is auto-generated.**  
> When enabling via Portal or `Set-AzSqlServerAudit`, the backing SERVER AUDIT object gets a system-generated name. Check `sys.server_audits` for the exact name before creating a `DATABASE AUDIT SPECIFICATION` in T-SQL.

> [!WARNING]
> **`-WorkspaceResourceId` requires the full ARM resource ID — not the workspace name.**  
> For `Set-AzSqlServerAudit` and `Set-AzDiagnosticSetting`: pass `/subscriptions/.../workspaces/myworkspace` — not the workspace name or workspace GUID alone. Using a short name fails silently or returns an error.

> [!WARNING]
> **Diagnostic Settings deletion silently breaks MI audit to LA/Event Hub.**  
> If the Diagnostic Setting named `SQLSecurityAuditEvents_XXXX` is deleted (manually or via IaC), audit events stop flowing to LA/EH without any error on the T-SQL side. Configure an Activity Log alert for Diagnostic Setting deletion events.

> [!WARNING]
> **Retention: Portal/PS vs T-SQL are independent.**  
> `Set-AzSqlServerAudit -RetentionInDays` sets blob container lifecycle retention. For Log Analytics, retention is governed by workspace settings — not the audit cmdlet. T-SQL `RETENTION_DAYS` in `TO URL` is an additional blob-level control but independent of ARM retention.

---

*Manual v1.2 — Klaas Vandenberghe (@PowerDBAKlaas) — 2026-03-18 — SQL Server 2016–2022, Azure SQL MI, Azure SQL DB, Az.Sql, Az.Monitor, dbatools*
