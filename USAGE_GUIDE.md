# Azure SQL Database Analysis Script - Usage Guide

## Prerequisites

Your metrics directory must contain:
- `AzSQLDb_SKU.csv` - Database properties (ServerName, DatabaseName, Edition, SkuName, Capacity, MaxSizeBytes/MaxSizeGB)
- `azsqldb_metric_dtu_consumption_percent.csv` - DTU metrics with Nominal_Value column
- `azsqldb_metric_cpu_percent.csv` - CPU metrics with Nominal_Value column
- `azsqldb_metric_workers_percent.csv` - Workers metrics with Nominal_Value column
- `azsqldb_metric_sessions_percent.csv` - Sessions metrics with Nominal_Value column
- `azsqldb_metric_storage_percent.csv` - Storage metrics
- `azsqldb_metric_connection_successful.csv` - Connection counts
- `azsqldb_metric_log_write_percent.csv` - Log write metrics

Timestamp format: ISO "2026-02-03 16:55:00"

## Basic Usage

```powershell
# Analyze all databases
$results = .\Analyze-AzSqlDatabases.ps1 -MetricsPath "C:\AzureMetrics"

# Export to CSV
$results | Export-Csv "database-recommendations.csv" -NoTypeInformation

# View summary
$results | Format-Table ServerName, DatabaseName, Status, Recommendation -AutoSize
```

## Filtering Examples

```powershell
# Only optimization opportunities
$results | Where-Object { $_.Status -eq 'OPTIMIZE' }

# High priority items
$results | Where-Object { $_.Priority -in 'Immediate', 'High' }

# Databases needing upgrade
$results | Where-Object { $_.Status -eq 'UPGRADE' }

# Serverless candidates
$results | Where-Object { $_.Serverless_Viable -eq $true }

# Elastic pool candidates
$results | Where-Object { $_.ElasticPool_Candidate -eq $true }

# Databases with >€100/month savings
$results | Where-Object { $_.Savings_EUR_Monthly -gt 100 }

# By workload pattern
$results | Group-Object Classification | 
    Select-Object Name, Count, @{N='Avg_Savings';E={($_.Group.Savings_EUR_Monthly | Measure-Object -Average).Average}}
```

## Output Object Properties

### Identity
- **ServerName** - SQL Server name
- **DatabaseName** - Database name

### Current State
- **CurrentEdition** - Basic/Standard/Premium/GeneralPurpose/BusinessCritical
- **CurrentSkuName** - S3, P2, GP_Gen5_4, etc.
- **CurrentCapacity** - DTU count or vCore count
- **CurrentModel** - DTU or vCore
- **CurrentMaxSizeGB** - Maximum storage capacity

### Recommendation
- **Status** - OK / OPTIMIZE / UPGRADE / REVIEW
- **Classification** - BURSTY / PERIODIC / STEADY / SPARSE / CHAOTIC / BATCH_HEAVY / WEEKEND_WEEKDAY / DECLINING / CONSTRAINED / INSUFFICIENT_DATA
- **Recommendation** - Specific action to take
- **RecommendedTier** - Target tier/SKU
- **RecommendedCapacity** - Target capacity
- **Confidence** - High / Medium / Low
- **Priority** - Immediate / High / Medium / Low
- **NextAction** - Next step to take
- **Flags** - Additional notes/warnings

### Statistics - Usage
- **DTU_Avg** - Average DTU usage (DTU databases only)
- **DTU_P95** - 95th percentile DTU
- **DTU_Max** - Peak DTU
- **CPU_Avg** - Average CPU percentage (vCore databases)
- **CPU_P95** - 95th percentile CPU
- **CPU_Max** - Peak CPU
- **CV_DTU** - Coefficient of variation (DTU) - measures volatility
- **CV_CPU** - Coefficient of variation (CPU)
- **Idle_Percent** - Percentage of time usage <5%

### Statistics - Resources
- **Sessions_Peak_Actual** - Peak concurrent sessions (absolute number)
- **Sessions_Peak_Percent** - Peak sessions as % of tier limit
- **Workers_Peak_Actual** - Peak concurrent workers
- **Workers_Peak_Percent** - Peak workers as % of tier limit
- **Storage_Used_GB** - Current storage used
- **Storage_Percent** - Storage used as % of max
- **LogWrite_P95** - 95th percentile log write throughput %

### Statistics - Patterns
- **Connections_Per_Hour_Avg** - Average connections per hour
- **Pattern_Autocorrelation** - 0-1, higher = more predictable (>0.7 = very predictable)
- **Weekly_Variance_Percent** - Difference between weekday/weekend usage
- **Growth_DTU_Trend** - DTU growth % per month
- **Growth_CPU_Trend** - CPU growth % per month
- **Growth_Storage_MB_Per_Month** - Storage growth rate
- **Days_Of_Data** - How many days of metrics analyzed

### Decisions
- **Serverless_Viable** - True if serverless is recommended
- **ElasticPool_Candidate** - True if elastic pool is recommended

### Costs (Belgian pricing, West Europe, EUR)
- **Current_Cost_EUR_Monthly** - Current monthly cost
- **Recommended_Cost_EUR_Monthly** - Projected cost after optimization
- **Savings_EUR_Monthly** - Monthly savings
- **Savings_Percent** - Savings percentage

## Status Meanings

- **OK** - Database is properly sized, no action needed
- **OPTIMIZE** - Optimization opportunity (downgrade, serverless, pool)
- **UPGRADE** - Database hitting constraints, needs more resources
- **REVIEW** - Requires business/manual review (decommission, insufficient data)

## Classification Meanings

- **BURSTY** - High variability, frequent idle periods (serverless candidate)
- **SPARSE** - Low usage most of time, occasional activity
- **PERIODIC** - Predictable patterns (elastic pool candidate)
- **STEADY** - Consistent usage (tier optimization)
- **CHAOTIC** - Unpredictable spikes (conservative sizing)
- **BATCH_HEAVY** - Two distinct usage modes (OLTP + batch)
- **WEEKEND_WEEKDAY** - Different weekday vs weekend patterns
- **DECLINING** - Usage decreasing (decommission candidate)
- **CONSTRAINED** - Hitting resource limits
- **GROWING** - Usage/storage increasing
- **INSUFFICIENT_DATA** - <7 days of metrics

## Advanced Analysis

### Total savings across all databases
```powershell
$totalSavings = ($results | Measure-Object -Property Savings_EUR_Monthly -Sum).Sum
Write-Host "Total potential savings: €$([Math]::Round($totalSavings, 2))/month"
```

### Group by server for elastic pool analysis
```powershell
$poolCandidates = $results | 
    Where-Object { $_.ElasticPool_Candidate -eq $true } |
    Group-Object ServerName

foreach ($group in $poolCandidates) {
    Write-Host "`nServer: $($group.Name)"
    Write-Host "  Databases: $($group.Count)"
    Write-Host "  Combined P95 DTU: $(($group.Group.DTU_P95 | Measure-Object -Sum).Sum)"
    Write-Host "  Current cost: €$(($group.Group.Current_Cost_EUR_Monthly | Measure-Object -Sum).Sum)"
}
```

### Find quick wins (>€100/month, high confidence)
```powershell
$quickWins = $results | Where-Object { 
    $_.Savings_EUR_Monthly -gt 100 -and 
    $_.Confidence -eq 'High' -and
    $_.Status -eq 'OPTIMIZE'
} | Sort-Object -Property Savings_EUR_Monthly -Descending

$quickWins | Format-Table ServerName, DatabaseName, Recommendation, 
    Savings_EUR_Monthly, Priority -AutoSize
```

### Export by priority
```powershell
$results | Where-Object { $_.Priority -eq 'Immediate' } | 
    Export-Csv "immediate-actions.csv" -NoTypeInformation

$results | Where-Object { $_.Priority -eq 'High' } | 
    Export-Csv "high-priority.csv" -NoTypeInformation
```

## Interpreting Key Statistics

### CV (Coefficient of Variation)
- **<50%**: Steady workload
- **50-100%**: Moderate variation
- **>100%**: Highly variable (bursty)

### Pattern Autocorrelation
- **>0.7**: Very predictable (good for scheduled scaling)
- **0.4-0.7**: Somewhat predictable
- **<0.4**: Unpredictable (chaotic)

### Idle Percent
- **>70%**: Sparse usage (serverless candidate)
- **30-70%**: Mixed
- **<30%**: Consistently active

### Weekly Variance
- **>50%**: Strong weekday/weekend difference
- **<20%**: Similar patterns throughout week

## Notes

- Pricing is for West Europe region in EUR (Feb 2025 estimates)
- Serverless pricing assumes ~50% auto-pause time
- Elastic pool recommendations require manual pool sizing across multiple databases
- Cost calculations are estimates; verify with Azure Pricing Calculator
- Script requires minimum 7 days of hourly metrics for analysis
- INSUFFICIENT_DATA databases will be flagged for re-analysis after 30 days
