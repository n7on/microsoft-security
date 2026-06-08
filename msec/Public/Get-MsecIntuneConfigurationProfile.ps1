function Get-MsecIntuneConfigurationProfile {
    <#
    .SYNOPSIS
        Lists Intune configuration profiles - Settings Catalog policies and classic device
        configuration profiles - merged into one stream, with the full Graph object kept
        in a Raw column for audit / backup / diff.

    .DESCRIPTION
        Microsoft is migrating Intune configuration from the older "device configuration
        profiles" (Templates) model to the newer "Settings Catalog" model. The Intune
        portal under Devices > Configuration profiles shows both side by side, and most
        tenants have a mix.

        This function queries both Graph endpoints:
          - /beta/deviceManagement/configurationPolicies (Settings Catalog - new; still beta-only)
          - /v1.0/deviceManagement/deviceConfigurations  (classic templates - legacy; GA)

        and projects each entry to a uniform shape with a Source discriminator
        ('SettingsCatalog' or 'Templates') so the rows can be combined or filtered.

        Each row also carries:

          - Assignments (count): pulled via $expand in the same call - no extra round trip.

          - Status (optional, -IncludeStatus): per-policy check-in counts. Templates use
            /deviceStatusOverview (one call per policy); Settings Catalog uses the Intune
            Reports API exportJob (one job per tenant, ~5-15s, results cached in a
            hashtable for the per-policy loop).

          - Raw: the verbatim Graph object for the policy. For Templates this includes
            every configured setting inline (the Graph response is naturally deep). For
            Settings Catalog, Raw only contains the policy metadata unless you pass
            -IncludeSettings, which fetches /configurationPolicies/{id}/settings per
            policy and merges the result into Raw.settings.

        The Raw column replaces the old Export-MsecIntuneConfiguration function - JSON
        backup, change diffs, and audit drill-downs all work directly off Raw:

            # Backup all SC policies' full config as JSON files
            Get-MsecIntuneConfigurationProfile -Source SettingsCatalog -IncludeSettings |
                ForEach-Object {
                    $name = $_.DisplayName -replace '[\/:*?"<>|]', '_'
                    $_.Raw | ConvertTo-Json -Depth 20 | Set-Content "./intune/$name.json"
                }

        Required Graph permission: DeviceManagementConfiguration.Read.All (Application).

    .PARAMETER Source
        Restrict to one generation:
          - 'All'             (default) both endpoints
          - 'SettingsCatalog' only Settings Catalog policies
          - 'Templates'       only classic device configuration profiles

    .PARAMETER IncludeStatus
        Fetch the per-policy device check-in counts. Adds one extra Graph call per policy
        (the Settings Catalog call also paginates per device), so it can be noticeably
        slower on large tenants. Off by default.

    .PARAMETER IncludeSettings
        For Settings Catalog policies: fetch each policy's settings via
        /configurationPolicies/{id}/settings and merge them into Raw.settings. Adds one
        extra Graph call per SC policy. Off by default. Templates already include their
        settings inline in the list response - this switch is a no-op for them.

    .EXAMPLE
        # Quick inventory (fastest)
        Get-MsecIntuneConfigurationProfile | Format-Table

    .EXAMPLE
        # Find policies failing on many devices
        Get-MsecIntuneConfigurationProfile -IncludeStatus |
            Where SuccessPercent -lt 95 |
            Sort SuccessPercent | Select DisplayName, SuccessPercent, ErrorCount

    .EXAMPLE
        # Audit drill-down: pull one specific SC policy's full settings
        $row = Get-MsecIntuneConfigurationProfile -IncludeSettings |
            Where Id -eq 'sc-1'
        $row.Raw | ConvertTo-Json -Depth 20

    .OUTPUTS
        PSCustomObject with PSTypeName 'MsecIntuneConfigurationProfile'. Default
        Format-Table view is: DisplayName, Source, Platform, AssignmentCount, Status
        (last column only present with -IncludeStatus). All other columns including
        Raw remain available via Select-Object / Format-List / direct property access.

        Status values (only present with -IncludeStatus):
          - NotDeployed   - AssignmentCount=0
          - NotReporting  - assigned but no devices currently evaluated
          - Healthy       - 100% success, no errors or conflicts
          - Degraded      - any errors / conflicts / pending or partial success
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('All', 'SettingsCatalog', 'Templates')]
        [string] $Source = 'All',

        [Parameter()]
        [switch] $IncludeStatus,

        [Parameter()]
        [switch] $IncludeSettings
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
    # The Status / Success* / Error* / etc. columns only appear when -IncludeStatus is set.
    # Raw is always set to the (optionally settings-expanded) Graph object.
    $project = {
        param($id, $displayName, $description, $platform, $type, $sourceTag,
              $created, $modified, $assignments, $raw)
        $assignmentCount = @($assignments).Count
        $obj = [ordered]@{
            PSTypeName      = 'MsecIntuneConfigurationProfile'
            Id              = $id
            DisplayName     = $displayName
            Description     = $description
            Platform        = $platform
            Type            = $type
            Source          = $sourceTag
            AssignmentCount = $assignmentCount
        }

        if ($IncludeStatus) {
            # Skip the per-policy status call when AssignmentCount=0 - the answer is
            # "all zeros / NotDeployed" regardless of what the API would return.
            $status = if ($assignmentCount -gt 0) {
                $statusArgs = @{ Id = $id; Source = $sourceTag }
                if ($scStatusCache) { $statusArgs['SettingsCatalogStatusCache'] = $scStatusCache }
                Get-MsecPolicyStatus @statusArgs
            }
            else { $null }

            # Status rollup label - see .OUTPUTS in the help for the meaning of each value.
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
            # NotDeployed and NotReporting both mean "no devices effectively reporting".
            # Zero across the board is the consistent answer in both cases.
            if ($obj.Status -in 'NotDeployed', 'NotReporting') {
                $obj.SuccessCount       = 0
                $obj.ErrorCount         = 0
                $obj.ConflictCount      = 0
                $obj.NotApplicableCount = 0
                $obj.PendingCount       = 0
                $obj.SuccessPercent     = 0
            }
            else {
                $obj.SuccessCount       = $status.SuccessCount
                $obj.ErrorCount         = $status.ErrorCount
                $obj.ConflictCount      = $status.ConflictCount
                $obj.NotApplicableCount = $status.NotApplicableCount
                $obj.PendingCount       = $status.PendingCount
                $obj.SuccessPercent     = $status.SuccessPercent
            }
        }

        # Raw - the full Graph object for the policy. Templates carry their settings
        # inline; Settings Catalog only does when -IncludeSettings was passed (in
        # which case the caller has already attached them as a 'settings' property).
        $obj.Raw = $raw

        [PSCustomObject]$obj
    }

    if ($Source -in 'All', 'SettingsCatalog') {
        Write-Verbose 'Loading Settings Catalog policies (/beta/deviceManagement/configurationPolicies)'
        # NB: configurationPolicies is still in beta only (Microsoft has not GA'd it to /v1.0).
        $scPath = '/beta/deviceManagement/configurationPolicies?$expand=assignments'
        foreach ($p in (Invoke-MsecGraphRequest -Path $scPath -All)) {
            if ($IncludeSettings) {
                # One extra call per SC policy - settings are not inline in the list
                # response. Attach them as a 'settings' property on the raw object so
                # Raw stays a single coherent shape rather than splitting policy/settings.
                $settingsResp = @(Invoke-MsecGraphRequest -Path "/beta/deviceManagement/configurationPolicies/$($p.id)/settings" -All)
                Add-Member -InputObject $p -NotePropertyName 'settings' -NotePropertyValue $settingsResp -Force
            }
            & $project $p.id $p.name $p.description $p.platforms 'Settings Catalog' 'SettingsCatalog' `
                $p.createdDateTime $p.lastModifiedDateTime $p.assignments $p
        }
    }

    if ($Source -in 'All', 'Templates') {
        Write-Verbose 'Loading classic device configurations (/v1.0/deviceManagement/deviceConfigurations)'
        $tPath = '/v1.0/deviceManagement/deviceConfigurations?$expand=assignments'
        foreach ($c in (Invoke-MsecGraphRequest -Path $tPath -All)) {
            $odataType = $c.'@odata.type'
            $typeShort = if ($odataType) { $odataType -replace '^#microsoft\.graph\.', '' } else { $null }

            # Classic configs don't expose a platform field directly; derive it from the type name.
            # 'switch -Wildcard' falls through to every matching case by default; the
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
                $c.createdDateTime $c.lastModifiedDateTime $c.assignments $c
        }
    }
}
