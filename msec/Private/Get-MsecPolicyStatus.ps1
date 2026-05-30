function Get-MsecPolicyStatus {
    <#
    .SYNOPSIS
        Returns per-policy check-in counts (success / error / conflict / notApplicable /
        pending) plus a SuccessPercent computed across applicable devices.

    .DESCRIPTION
        Graph exposes per-policy device check-in status differently depending on the policy kind:

          - Templates (device configurations) and Compliance policies expose a single
            aggregated object at /{id}/deviceStatusOverview - one call, ready to use.
          - Settings Catalog policies have no equivalent navigation property. The data comes
            from the Reports API as an async exportJob covering ALL policies at once. To
            avoid re-running that job per policy, the caller pre-fetches the report via
            Get-MsecSettingsCatalogStatusReport and passes the resulting hashtable in
            -SettingsCatalogStatusCache. When the cache is missing or the policy isn't in it,
            SC rows return all-null status (graceful degradation).

        SuccessPercent denominator excludes notApplicable (those devices aren't a target),
        matching what the Intune portal shows next to each policy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Id,

        [Parameter(Mandatory)]
        [ValidateSet('SettingsCatalog', 'Templates', 'CompliancePolicy')]
        [string] $Source,

        # Pre-fetched cache for Settings Catalog (key=PolicyId). Ignored for other sources.
        [Parameter()]
        [hashtable] $SettingsCatalogStatusCache
    )

    $nullStatus = [PSCustomObject]@{
        SuccessCount       = $null
        ErrorCount         = $null
        ConflictCount      = $null
        NotApplicableCount = $null
        PendingCount       = $null
        SuccessPercent     = $null
    }

    if ($Source -eq 'SettingsCatalog') {
        if (-not $SettingsCatalogStatusCache) {
            Write-Verbose "Settings Catalog status cache not provided; emitting nulls for policy $Id."
            return $nullStatus
        }
        $hit = $SettingsCatalogStatusCache[$Id]
        if (-not $hit) {
            Write-Verbose "Policy $Id not present in Settings Catalog status report (perhaps unassigned or newly created); emitting nulls."
            return $nullStatus
        }
        $counts = @{
            success       = $hit.SuccessCount
            error         = $hit.ErrorCount
            conflict      = $hit.ConflictCount
            notApplicable = $hit.NotApplicableCount
            pending       = $hit.PendingCount
        }
    }
    else {
        $path = if ($Source -eq 'Templates') {
            "/v1.0/deviceManagement/deviceConfigurations/$Id/deviceStatusOverview"
        }
        else {
            "/v1.0/deviceManagement/deviceCompliancePolicies/$Id/deviceStatusOverview"
        }
        $r = Invoke-MsecGraphRequest -Path $path
        $counts = @{
            success       = [int]$r.successCount
            error         = [int]$r.errorCount
            conflict      = [int]$r.conflictCount
            notApplicable = [int]$r.notApplicableCount
            pending       = [int]$r.pendingCount
        }
    }

    $applicable = $counts.success + $counts.error + $counts.conflict + $counts.pending
    $percent = if ($applicable -gt 0) {
        [math]::Round(($counts.success / $applicable) * 100, 1)
    }
    else {
        $null
    }

    [PSCustomObject]@{
        SuccessCount       = $counts.success
        ErrorCount         = $counts.error
        ConflictCount      = $counts.conflict
        NotApplicableCount = $counts.notApplicable
        PendingCount       = $counts.pending
        SuccessPercent     = $percent
    }
}
