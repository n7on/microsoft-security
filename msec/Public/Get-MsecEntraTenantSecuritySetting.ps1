function Get-MsecEntraTenantSecuritySetting {
    <#
    .SYNOPSIS
        Tenant-wide Entra security settings in one summary row: security defaults,
        which security workloads are licensed, the directory's default user
        permissions, and how many people hold privileged roles.

    .DESCRIPTION
        The tenant-level counterpart to the per-object inventory cmdlets. Where
        Get-MsecEntraConditionalAccessPolicy lists the policies you HAVE, this
        answers what the tenant is CAPABLE of and how it is configured by default.

        It exists to close a specific blind spot. A posture collection that hits
        403/400 on a workload cannot tell the difference between

          - a permission the app is missing        (fix the app), and
          - a workload the tenant never bought    (nothing to fix - not applicable),

        and reporting the second as the first sends people chasing consent grants
        that cannot possibly help. The ServicePlan-derived capability flags below
        make that distinction explicit: ConditionalAccessAvailable = $false means
        an empty CA policy list is *expected*, because Conditional Access requires
        Entra ID premium and this tenant has none.

        Composed from four sources, each independently degradable:

          /policies/identitySecurityDefaultsEnforcementPolicy  Policy.Read.All
          /policies/authorizationPolicy                        Policy.Read.All
          Get-MsecEntraLicense (/subscribedSkus)               Organization.Read.All
          Get-MsecEntraDirectoryRoleMember (/directoryRoles)   RoleManagement.Read.Directory

        By default a section that cannot be read leaves its properties $null and
        records why in the Notes dictionary, rather than throwing - so one missing
        permission still yields a useful row, and the caller can persist the
        reason next to the gap. Use -Strict to get the underlying exception
        instead.

    .PARAMETER Strict
        Rethrow instead of degrading. Any section that fails aborts the call with
        the original (permission-annotated) error. Use when you want a collection
        run to fail loudly rather than silently record a null.

    .EXAMPLE
        Get-MsecEntraTenantSecuritySetting | Format-List

    .EXAMPLE
        # The question that started this cmdlet: with no CA policies, is anything
        # actually enforcing MFA?
        $s = Get-MsecEntraTenantSecuritySetting
        if (-not $s.ConditionalAccessAvailable -and -not $s.SecurityDefaultsEnabled) {
            "No Conditional Access (unlicensed) AND security defaults off - " +
            "$($s.GlobalAdministratorCount) Global Admins reachable with password alone."
        }

    .EXAMPLE
        # Why is a posture domain empty? Ask the tenant, not the error code.
        Get-MsecEntraTenantSecuritySetting |
            Select-Object ConditionalAccessAvailable, IntuneProvisioned,
                          ExchangeOnlineProvisioned, DefenderForEndpointProvisioned

    .EXAMPLE
        # Slot it into the posture snapshot next to the other domains.
        $snapshot = [pscustomobject]@{
            CapturedAtUtc  = (Get-Date).ToUniversalTime().ToString('u')
            TenantSecurity = Get-MsecEntraTenantSecuritySetting
            CaStats        = Get-MsecEntraConditionalAccessStats -Days 7
        }

    .OUTPUTS
        One PSCustomObject. See .NOTES for every property.

    .NOTES
        PSTypeName 'MsecEntraTenantSecuritySetting'; DefaultDisplayPropertySet
        (SecurityDefaultsEnabled, ConditionalAccessAvailable,
        GlobalAdministratorCount, EntraIdPremium) is registered in msec.psm1.

        Properties:
          TenantId                        the session's tenant

          SecurityDefaultsEnabled         $true/$false, or $null if unreadable.
                                          Mutually exclusive with Conditional
                                          Access: enabling CA disables these, so
                                          $false is normal and correct in a
                                          premium tenant that uses CA instead.

          EntraIdPremium                  'P2' / 'P1' / $null - highest tier found
          EntraIdPremiumP1 / ...P2        per-tier booleans
          ConditionalAccessAvailable      = P1 or P2. When $false, CA cannot exist.
          IdentityProtectionAvailable     = P2. Risk-based policies and the
                                          risky-sign-in signals need P2.
          PimAvailable                    = P2. Without it, every privileged
                                          assignment is permanent by definition.
          IntuneProvisioned               INTUNE_A service plan present
          ExchangeOnlineProvisioned       a real mailbox plan present. EXCHANGE_S_FOUNDATION
                                          does NOT count - it is a stub bundled with
                                          unrelated SKUs and grants no mailboxes.
          DefenderForEndpointProvisioned  WINDEFATP plan present
          DefenderForOffice365Provisioned ATP_ENTERPRISE or THREAT_INTELLIGENCE
          ServicePlans                    every distinct successfully-provisioned
                                          service plan name in the tenant
          LicensedSkuCount                SKUs with at least one enabled unit

          DefaultUserRoleCanCreateApps    directory default: can any user register
                                          an application?
          DefaultUserRoleCanCreateSecurityGroups
          DefaultUserRoleCanReadOtherUsers
          GuestUserRoleId                 guest access level (GUID; see
                                          GuestUserRole for the friendly name)
          GuestUserRole                   'Member-equivalent' / 'Guest' /
                                          'Restricted guest' / $null
          AllowInvitesFrom                who may invite guests
          AllowEmailVerifiedUsersToJoin   self-service sign-up into the tenant

          ActivatedRoleCount              directory roles with >= 1 active member
          GlobalAdministratorCount        active, permanent Global Admins
          HighlyPrivilegedMemberCount     distinct principals in any role flagged
                                          highly privileged (see
                                          Get-MsecEntraDirectoryRoleMember)
          PrivilegedRoleSummary           array of {RoleName, MemberCount} for the
                                          highly-privileged roles that have members

          Notes                           ordered dictionary of section -> reason,
                                          populated only for sections that failed.
                                          Empty when everything was readable.

        Counts come from permanent assignments only; see
        Get-MsecEntraDirectoryRoleMember for why PIM-eligible holders are not
        included and when that matters.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $Strict
    )

    Assert-MsecSession

    $notes = [ordered]@{}

    # Run one section, returning $null and recording why on failure. -Strict turns
    # every failure back into a throw so a collection run can fail loudly.
    $section = {
        param([string] $Name, [scriptblock] $Action)
        try { & $Action }
        catch {
            if ($Strict) { throw }
            $notes[$Name] = $_.Exception.Message
            $null
        }
    }

    # ---- 1. Security defaults ------------------------------------------------
    $securityDefaults = & $section 'securityDefaults' {
        try {
            $r = Invoke-MsecGraphRequest -Path '/v1.0/policies/identitySecurityDefaultsEnforcementPolicy'
            [bool] $r.isEnabled
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden') {
                throw "Forbidden when calling /policies/identitySecurityDefaultsEnforcementPolicy. The msec app needs the 'Policy.Read.All' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $($_.Exception.Message)"
            }
            throw
        }
    }

    # ---- 2. Authorization policy (directory defaults) ------------------------
    $authPolicy = & $section 'authorizationPolicy' {
        try {
            Invoke-MsecGraphRequest -Path '/v1.0/policies/authorizationPolicy'
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden') {
                throw "Forbidden when calling /policies/authorizationPolicy. The msec app needs the 'Policy.Read.All' application permission (admin consent required). Re-run New-MsecApp to add and consent it. Original error: $($_.Exception.Message)"
            }
            throw
        }
    }

    # Graph returns authorizationPolicy as a single object on some tenants and a
    # one-element collection on others; normalise before reading fields.
    if ($authPolicy -and $authPolicy.value) { $authPolicy = @($authPolicy.value)[0] }
    $defaultUserRole = $authPolicy.defaultUserRolePermissions

    # ---- 3. Licences -> capability flags ------------------------------------
    $licences = & $section 'licenses' { @(Get-MsecEntraLicense) }

    # Distinct successfully-provisioned plan names across every SKU. Membership in
    # this set is the honest "is the workload usable here" test - see
    # Get-MsecEntraLicense .NOTES on provisioningStatus.
    $plans = @($licences | ForEach-Object { $_.ServicePlans } | Sort-Object -Unique)
    $hasPlan = { param([string[]] $Names) [bool] @($plans | Where-Object { $_ -in $Names }).Count }

    $p1 = & $hasPlan @('AAD_PREMIUM')
    $p2 = & $hasPlan @('AAD_PREMIUM_P2')

    # ---- 4. Privileged roles -------------------------------------------------
    $roleMembers = & $section 'directoryRoles' { @(Get-MsecEntraDirectoryRoleMember) }

    $privileged  = @($roleMembers | Where-Object IsHighlyPrivileged)
    $roleSummary = @(
        $privileged | Group-Object RoleName | Sort-Object Count -Descending | ForEach-Object {
            [PSCustomObject]@{ RoleName = $_.Name; MemberCount = $_.Count }
        }
    )

    # A principal in several privileged roles must count once, not once per role.
    $privilegedPrincipals = @($privileged | Select-Object -ExpandProperty MemberId -Unique).Count

    # Distinguish "read it, found none" from "could not read it". A tenant with no
    # licences at all is a real, meaningful answer (it says the workloads aren't
    # there); a failed call must not be reported as the same thing.
    $licencesRead = -not $notes.Contains('licenses')
    $rolesRead    = -not $notes.Contains('directoryRoles')

    [PSCustomObject]@{
        PSTypeName                              = 'MsecEntraTenantSecuritySetting'

        TenantId                                = $script:MsecSession.TenantId

        SecurityDefaultsEnabled                 = $securityDefaults

        EntraIdPremium                          = if (-not $licencesRead) { $null }
                                                  elseif ($p2) { 'P2' } elseif ($p1) { 'P1' } else { $null }
        EntraIdPremiumP1                        = if ($licencesRead) { $p1 } else { $null }
        EntraIdPremiumP2                        = if ($licencesRead) { $p2 } else { $null }
        ConditionalAccessAvailable              = if ($licencesRead) { [bool]($p1 -or $p2) } else { $null }
        IdentityProtectionAvailable             = if ($licencesRead) { $p2 } else { $null }
        PimAvailable                            = if ($licencesRead) { $p2 } else { $null }
        IntuneProvisioned                       = if ($licencesRead) { & $hasPlan @('INTUNE_A') } else { $null }
        # EXCHANGE_S_FOUNDATION is deliberately excluded. It is a stub plan bundled with
        # many unrelated SKUs (Power BI Standard, Dynamics, ...) purely to provide
        # directory scaffolding - it grants NO mailboxes and no Exchange Online
        # Protection. Counting it would report a mail estate that does not exist, and
        # then an absent emailStats domain reads as a fault to fix rather than as
        # not-applicable. Match real mailbox plans only.
        ExchangeOnlineProvisioned               = if ($licencesRead) {
                                                      [bool] @($plans | Where-Object {
                                                          $_ -like 'EXCHANGE_*' -and $_ -ne 'EXCHANGE_S_FOUNDATION'
                                                      }).Count
                                                  } else { $null }
        DefenderForEndpointProvisioned          = if ($licencesRead) { & $hasPlan @('WINDEFATP') } else { $null }
        DefenderForOffice365Provisioned         = if ($licencesRead) {
                                                      & $hasPlan @('ATP_ENTERPRISE', 'THREAT_INTELLIGENCE')
                                                  } else { $null }
        ServicePlans                            = if ($licencesRead) { $plans } else { $null }
        LicensedSkuCount                        = if ($licencesRead) {
                                                      @($licences | Where-Object Enabled -gt 0).Count
                                                  } else { $null }

        DefaultUserRoleCanCreateApps            = $defaultUserRole.allowedToCreateApps
        DefaultUserRoleCanCreateSecurityGroups  = $defaultUserRole.allowedToCreateSecurityGroups
        DefaultUserRoleCanReadOtherUsers        = $defaultUserRole.allowedToReadOtherUsers
        GuestUserRoleId                         = $authPolicy.guestUserRoleId
        GuestUserRole                           = switch ([string]$authPolicy.guestUserRoleId) {
                                                      'a0b1b346-4d3e-4e8b-98f8-753987be4970' { 'Member-equivalent' }
                                                      '10dae51f-b6af-4016-8d66-8c2a99b929b3' { 'Guest' }
                                                      '2af84b1e-32c8-42b7-82bc-daa82404023b' { 'Restricted guest' }
                                                      default { $null }
                                                  }
        AllowInvitesFrom                        = $authPolicy.allowInvitesFrom
        AllowEmailVerifiedUsersToJoin           = $authPolicy.allowEmailVerifiedUsersToJoinOrganization

        ActivatedRoleCount                      = if ($rolesRead) {
                                                      @($roleMembers | Select-Object -ExpandProperty RoleName -Unique).Count
                                                  } else { $null }
        GlobalAdministratorCount                = if ($rolesRead) {
                                                      @($roleMembers | Where-Object RoleName -eq 'Global Administrator').Count
                                                  } else { $null }
        HighlyPrivilegedMemberCount             = if ($rolesRead) { $privilegedPrincipals } else { $null }
        PrivilegedRoleSummary                   = if ($rolesRead) { $roleSummary } else { $null }

        Notes                                   = $notes
    }
}
