function Get-MsecIntuneConfiguration {
    <#
    .SYNOPSIS
        Lists Intune configurations - Settings Catalog policies and classic device configuration
        profiles, merged into one stream.

    .DESCRIPTION
        Microsoft is migrating Intune configuration from the older "device configuration
        profiles" (Templates) model to the newer "Settings Catalog" model. The Intune portal
        under Devices -> Configuration shows both side by side, and most tenants have a mix.

        This function queries both Graph endpoints:
          - /beta/deviceManagement/configurationPolicies (Settings Catalog - new; still beta-only)
          - /v1.0/deviceManagement/deviceConfigurations  (classic templates - legacy; GA)

        and projects each entry to a uniform shape with a Source discriminator
        ('SettingsCatalog' or 'Templates') so the rows can be combined or filtered.

        Assignments are pulled via $expand in the same call - no extra round trip - so
        AssignmentCount is always populated.

        Per-policy check-in status (SuccessCount / ErrorCount / ConflictCount /
        NotApplicableCount / PendingCount / SuccessPercent) is opt-in via -IncludeStatus.

        How status is sourced:
          - Templates: /deviceStatusOverview - one call per policy.
          - Settings Catalog: the Intune Reports API. SC has no per-policy navigation
            property, so we kick off ONE async exportJob (reportName=
            ConfigurationPolicyAggregate) covering all SC policies in the tenant, poll
            until it completes (~5-15s), download the result, and look up each policy's
            counts in the resulting hashtable. The job runs once per -IncludeStatus
            invocation regardless of how many SC policies you have.

        Required Graph permission: DeviceManagementConfiguration.Read.All (Application).

    .PARAMETER Source
        Restrict to one generation:
          - 'All'             (default) both endpoints
          - 'SettingsCatalog' only Settings Catalog policies
          - 'Templates'       only classic device configuration profiles

    .PARAMETER IncludeStatus
        Fetch the per-policy device check-in counts. Adds one extra Graph call per policy
        (the Settings Catalog call also paginates per device), so it can be noticeably slower
        on large tenants. Off by default.

    .EXAMPLE
        # Quick inventory (no status calls):
        Get-MsecIntuneConfiguration | Format-Table -AutoSize

    .EXAMPLE
        # Find policies failing on many devices:
        Get-MsecIntuneConfiguration -IncludeStatus |
            Where-Object { $_.SuccessPercent -ne $null -and $_.SuccessPercent -lt 95 } |
            Sort-Object SuccessPercent |
            Select-Object DisplayName, SuccessPercent, ErrorCount, ConflictCount

    .EXAMPLE
        # Find unassigned policies:
        Get-MsecIntuneConfiguration | Where-Object AssignmentCount -eq 0

    .OUTPUTS
        PSCustomObject: Id, DisplayName, Description, Platform, Type, Source, AssignmentCount,
        CreatedDateTime, LastModifiedDateTime; with -IncludeStatus also Status, SuccessCount,
        ErrorCount, ConflictCount, NotApplicableCount, PendingCount, SuccessPercent.

        Status values (only present with -IncludeStatus):
          - NotDeployed   - AssignmentCount=0
          - NotReporting  - assigned but no devices currently evaluated (empty assignment
                            scope, enrollment-time-only policy like Autopilot device prep)
          - Healthy       - 100% success, no errors or conflicts
          - Degraded      - any errors / conflicts / pending or partial success
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('All', 'SettingsCatalog', 'Templates')]
        [string] $Source = 'All',

        [Parameter()]
        [switch] $IncludeStatus
    )

    Assert-MsecSession

    # If we'll need Settings Catalog status, pre-fetch the Reports API export *once* for
    # the whole tenant so the per-policy loop is just hashtable lookups.
    $scStatusCache = $null
    if ($IncludeStatus -and $Source -ne 'Templates') {
        Write-Verbose 'Pre-fetching Settings Catalog status (Intune Reports exportJob, ~5-15s)'
        $scStatusCache = Get-MsecSettingsCatalogStatusReport
    }

    # Local projection helper so both branches produce the same shape.
    # The Status / Success* / Error* / etc. columns only appear when -IncludeStatus is set,
    # so callers don't see half-populated columns when they did not ask for status.
    $project = {
        param($id, $displayName, $description, $platform, $type, $sourceTag, $created, $modified, $assignments)
        $assignmentCount = @($assignments).Count
        $obj = [ordered]@{
            Id              = $id
            DisplayName     = $displayName
            Description     = $description
            Platform        = $platform
            Type            = $type
            Source          = $sourceTag
            AssignmentCount = $assignmentCount
        }

        if ($IncludeStatus) {
            $statusArgs = @{ Id = $id; Source = $sourceTag }
            if ($scStatusCache) { $statusArgs['SettingsCatalogStatusCache'] = $scStatusCache }
            $status = Get-MsecPolicyStatus @statusArgs

            # Status rollup - a single label that summarises everything else.
            #   NotDeployed   : AssignmentCount=0   (no devices targeted)
            #   NotReporting  : assigned but no status data available (empty assignment scope,
            #                   enrollment-time-only policy like Autopilot device preparation, etc.)
            #   Healthy       : 100% success with no errors or conflicts
            #   Degraded      : any errors / conflicts / pending / partial success
            $obj.Status = if ($assignmentCount -eq 0) {
                'NotDeployed'
            }
            elseif ($null -eq $status.SuccessPercent) {
                'NotReporting'
            }
            elseif ($status.SuccessPercent -eq 100 -and $status.ErrorCount -eq 0 -and $status.ConflictCount -eq 0) {
                'Healthy'
            }
            else {
                'Degraded'
            }
        }

        $obj.CreatedDateTime      = if ($created)  { [datetime]$created }  else { $null }
        $obj.LastModifiedDateTime = if ($modified) { [datetime]$modified } else { $null }

        if ($IncludeStatus) {
            $obj.SuccessCount       = $status.SuccessCount
            $obj.ErrorCount         = $status.ErrorCount
            $obj.ConflictCount      = $status.ConflictCount
            $obj.NotApplicableCount = $status.NotApplicableCount
            $obj.PendingCount       = $status.PendingCount
            $obj.SuccessPercent     = $status.SuccessPercent
        }

        [PSCustomObject]$obj
    }

    if ($Source -in 'All', 'SettingsCatalog') {
        Write-Verbose 'Loading Settings Catalog policies (/beta/deviceManagement/configurationPolicies)'
        # NB: configurationPolicies is still in beta only (Microsoft has not GA'd it to /v1.0).
        $scPath = '/beta/deviceManagement/configurationPolicies?$expand=assignments'
        foreach ($p in (Invoke-MsecGraphRequest -Path $scPath -All)) {
            & $project $p.id $p.name $p.description $p.platforms 'Settings Catalog' 'SettingsCatalog' `
                $p.createdDateTime $p.lastModifiedDateTime $p.assignments
        }
    }

    if ($Source -in 'All', 'Templates') {
        Write-Verbose 'Loading classic device configurations (/v1.0/deviceManagement/deviceConfigurations)'
        $tPath = '/v1.0/deviceManagement/deviceConfigurations?$expand=assignments'
        foreach ($c in (Invoke-MsecGraphRequest -Path $tPath -All)) {
            $odataType = $c.'@odata.type'
            $typeShort = if ($odataType) { $odataType -replace '^#microsoft\.graph\.', '' } else { $null }

            # Classic configs don't expose a platform field directly; derive it from the type name.
            # NB: 'switch -Wildcard' falls through to every matching case by default; the
            # 'break' on each case ensures the most-specific match wins (e.g. windows10*
            # before windows*).
            $platform = $null
            switch -Wildcard ($typeShort) {
                'windows10*'           { $platform = 'windows10';          break }
                'windows*'             { $platform = 'windows';            break }
                'macOS*'               { $platform = 'macOS';              break }
                'ios*'                 { $platform = 'iOS';                break }
                'androidWorkProfile*'  { $platform = 'androidWorkProfile'; break }
                'androidDeviceOwner*'  { $platform = 'androidDeviceOwner'; break }
                'androidForWork*'      { $platform = 'androidForWork';     break }
                'android*'             { $platform = 'android';            break }
            }

            & $project $c.id $c.displayName $c.description $platform $typeShort 'Templates' `
                $c.createdDateTime $c.lastModifiedDateTime $c.assignments
        }
    }
}
