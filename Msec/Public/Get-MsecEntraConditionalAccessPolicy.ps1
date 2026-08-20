function Get-MsecEntraConditionalAccessPolicy {
    <#
    .SYNOPSIS
        Lists every Microsoft Entra Conditional Access policy as flat rows, with
        the conditions and grant controls flattened to top-level columns.

    .DESCRIPTION
        Calls Microsoft Graph /v1.0/identity/conditionalAccess/policies and
        projects each policy to a PSCustomObject. The Graph response is deeply
        nested (conditions.users.includeGroups, conditions.applications.*, etc.);
        the projection flattens the audit-relevant arrays to top-level columns
        so Where-Object / Group-Object / Export-Excel work naturally.

        Use this for inventory ("what CA policies are configured, what do they
        enforce, who are they targeted at"). For effectiveness data ("did the
        policy fire? was anyone blocked?"), see Get-MsecEntraConditionalAccessSignInLog
        - that comes from sign-in events, not policy objects.

        Requires the 'Policy.Read.All' application permission. A clearer error is
        raised on the typical 403.

    .EXAMPLE
        Get-MsecEntraConditionalAccessPolicy | Group-Object State

    .EXAMPLE
        # Policies that DO require MFA - the headline CA evidence for an audit.
        Get-MsecEntraConditionalAccessPolicy |
            Where-Object Requires -contains 'mfa' |
            Select DisplayName, State, IncludedGroups

    .EXAMPLE
        # Report-only policies — they don't enforce, just observe. Worth tracking.
        Get-MsecEntraConditionalAccessPolicy |
            Where-Object State -eq 'enabledForReportingButNotEnforced'

    .OUTPUTS
        PSCustomObject per policy. See .NOTES for the projection.

    .NOTES
        Each row is a [PSCustomObject] with PSTypeName 'MsecEntraConditionalAccessPolicy'.
        That type has a DefaultDisplayPropertySet (DisplayName, State, Requires,
        IncludedGroups) registered in the module's .psm1 - so Format-Table shows a
        clean 4-column view by default. The Raw column is fully accessible via
        $row.Raw or | Format-List, it just doesn't clutter the default table.

        Projection (Graph field path -> output property):
          id                                            -> Id
          displayName                                   -> DisplayName
          state                                         -> State
          createdDateTime / modifiedDateTime            -> CreatedDateTime / ModifiedDateTime
          conditions.users.includeUsers/Groups/Roles    -> IncludedUsers / IncludedGroups / IncludedRoles
          conditions.users.excludeUsers/Groups/Roles    -> ExcludedUsers / ExcludedGroups / ExcludedRoles
          conditions.applications.includeApplications   -> IncludedApps
          conditions.applications.excludeApplications   -> ExcludedApps
          conditions.applications.includeUserActions    -> UserActions
          conditions.platforms.includePlatforms         -> IncludedPlatforms
          conditions.platforms.excludePlatforms         -> ExcludedPlatforms
          conditions.locations.includeLocations         -> IncludedLocations
          conditions.locations.excludeLocations         -> ExcludedLocations
          conditions.clientAppTypes                     -> ClientAppTypes
          conditions.signInRiskLevels                   -> SignInRiskLevels
          conditions.userRiskLevels                     -> UserRiskLevels
          grantControls.operator                        -> GrantOperator    ('OR' / 'AND')
          grantControls.builtInControls                 -> Requires         (mfa, compliantDevice, ...)
          <entire policy object verbatim from Graph>    -> Raw             (PSObject; full detail)

        Use Raw for audit dives, JSON backup, or change-diff:
          Get-MsecEntraConditionalAccessPolicy |
              ForEach-Object { $_.Raw | ConvertTo-Json -Depth 20 |
                               Set-Content "./ca-policies/$($_.Id).json" }
    #>
    [CmdletBinding()]
    param()

    Assert-MsecSession

    $path = '/v1.0/identity/conditionalAccess/policies'

    try {
        $policies = @(Invoke-MsecGraphRequest -Path $path -All)
    }
    catch {
        if ($_.Exception.Message -match '403|Forbidden') {
            throw "Forbidden when calling /identity/conditionalAccess/policies. The msec app needs the 'Policy.Read.All' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $($_.Exception.Message)"
        }
        throw
    }

    # @($null) returns a single-element array containing $null, NOT an empty
    # array - which then poisons downstream Where-Object -contains and Count
    # checks. Use this helper to coerce missing/null to a real empty array.
    $arr = { param($v) if ($null -eq $v) { @() } else { @($v) } }

    foreach ($p in $policies) {
        $c  = $p.conditions       # may be $null in pathological cases, PS nested access still safe
        $gc = $p.grantControls

        $row = [PSCustomObject]@{
            PSTypeName          = 'MsecEntraConditionalAccessPolicy'

            Id                  = $p.id
            DisplayName         = $p.displayName
            State               = $p.state
            CreatedDateTime     = if ($p.createdDateTime)  { [datetime]$p.createdDateTime }  else { $null }
            ModifiedDateTime    = if ($p.modifiedDateTime) { [datetime]$p.modifiedDateTime } else { $null }

            # Users / groups / roles targeted
            IncludedUsers       = & $arr $c.users.includeUsers
            ExcludedUsers       = & $arr $c.users.excludeUsers
            IncludedGroups      = & $arr $c.users.includeGroups
            ExcludedGroups      = & $arr $c.users.excludeGroups
            IncludedRoles       = & $arr $c.users.includeRoles
            ExcludedRoles       = & $arr $c.users.excludeRoles

            # Apps + user actions
            IncludedApps        = & $arr $c.applications.includeApplications
            ExcludedApps        = & $arr $c.applications.excludeApplications
            UserActions         = & $arr $c.applications.includeUserActions

            # Platforms (entirely absent when no platform restriction is set)
            IncludedPlatforms   = & $arr $c.platforms.includePlatforms
            ExcludedPlatforms   = & $arr $c.platforms.excludePlatforms

            # Locations (entirely absent when no location restriction is set)
            IncludedLocations   = & $arr $c.locations.includeLocations
            ExcludedLocations   = & $arr $c.locations.excludeLocations

            # Risk + client app conditions
            ClientAppTypes      = & $arr $c.clientAppTypes
            SignInRiskLevels    = & $arr $c.signInRiskLevels
            UserRiskLevels      = & $arr $c.userRiskLevels

            # What the policy enforces (when conditions match)
            GrantOperator       = $gc.operator
            Requires            = & $arr $gc.builtInControls

            # Raw - the full nested Graph object. Useful for audit dives /
            # JSON backup / change-diff. Hidden from default Format-Table view
            # by the DefaultDisplayPropertySet registered in msec.psm1.
            Raw                 = $p
        }
        $row
    }
}
