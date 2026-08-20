---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecEntraTenantSecuritySetting

## SYNOPSIS
Tenant-wide Entra security settings in one summary row: security defaults,
which security workloads are licensed, the directory's default user
permissions, and how many people hold privileged roles.

## SYNTAX

```
Get-MsecEntraTenantSecuritySetting [-Strict] [<CommonParameters>]
```

## DESCRIPTION
The tenant-level counterpart to the per-object inventory cmdlets.
Where
Get-MsecEntraConditionalAccessPolicy lists the policies you HAVE, this
answers what the tenant is CAPABLE of and how it is configured by default.

It exists to close a specific blind spot.
A posture collection that hits
403/400 on a workload cannot tell the difference between

  - a permission the app is missing        (fix the app), and
  - a workload the tenant never bought    (nothing to fix - not applicable),

and reporting the second as the first sends people chasing consent grants
that cannot possibly help.
The ServicePlan-derived capability flags below
make that distinction explicit: ConditionalAccessAvailable = $false means
an empty CA policy list is *expected*, because Conditional Access requires
Entra ID premium and this tenant has none.

Composed from four sources, each independently degradable:

  /policies/identitySecurityDefaultsEnforcementPolicy  Policy.Read.All
  /policies/authorizationPolicy                        Policy.Read.All
  Get-MsecEntraLicense (/subscribedSkus)               Organization.Read.All
  Get-MsecEntraRoleHolder (roleManagement)             RoleManagement.Read.Directory
                                                       + User/Group/Application.Read.All
                                                       to name the principals

By default a section that cannot be read leaves its properties $null and
records why in the Notes dictionary, rather than throwing - so one missing
permission still yields a useful row, and the caller can persist the
reason next to the gap.
Use -Strict to get the underlying exception
instead.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraTenantSecuritySetting | Format-List
```

### EXAMPLE 2
```
# The question that started this cmdlet: with no CA policies, is anything
# actually enforcing MFA?
$s = Get-MsecEntraTenantSecuritySetting
if (-not $s.ConditionalAccessAvailable -and -not $s.SecurityDefaultsEnabled) {
    "No Conditional Access (unlicensed) AND security defaults off - " +
    "$($s.GlobalAdministratorCount) Global Admins reachable with password alone."
}
```

### EXAMPLE 3
```
# Why is a posture domain empty? Ask the tenant, not the error code.
Get-MsecEntraTenantSecuritySetting |
    Select-Object ConditionalAccessAvailable, IntuneProvisioned,
                  ExchangeOnlineProvisioned, DefenderForEndpointProvisioned
```

### EXAMPLE 4
```
# Slot it into the posture snapshot next to the other domains.
$snapshot = [pscustomobject]@{
    CapturedAtUtc  = (Get-Date).ToUniversalTime().ToString('u')
    TenantSecurity = Get-MsecEntraTenantSecuritySetting
    CaStats        = Get-MsecEntraConditionalAccessStats -Days 7
}
```

## PARAMETERS

### -Strict
Rethrow instead of degrading.
Any section that fails aborts the call with
the original (permission-annotated) error.
Use when you want a collection
run to fail loudly rather than silently record a null.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject. See .NOTES for every property.
## NOTES
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
  ConditionalAccessAvailable      = P1 or P2.
When $false, CA cannot exist.
  IdentityProtectionAvailable     = P2.
Risk-based policies and the
                                  risky-sign-in signals need P2.
  PimAvailable                    = P2.
Without it, every privileged
                                  assignment is permanent by definition.
  IntuneProvisioned               INTUNE_A service plan present
  ExchangeOnlineProvisioned       a real mailbox plan present.
EXCHANGE_S_FOUNDATION
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

  ActivatedRoleCount              distinct roles with \>= 1 active assignment
  GlobalAdministratorCount        active, permanent Global Admins.
Counted by
                                  roleTemplateId, because Graph reports that
                                  role as 'Company Administrator' on many
                                  tenants and matching the name reports zero
  HighlyPrivilegedMemberCount     distinct principals in any role flagged
                                  highly privileged by
                                  Get-MsecPrivilegedRoleTemplate
  PrivilegedRoleSummary           array of {RoleName, MemberCount} for the
                                  highly-privileged roles that have holders

  Notes                           ordered dictionary of section -\> reason,
                                  populated only for sections that failed.
                                  Empty when everything was readable.

COUNTS ARE OF PEOPLE AND APPLICATIONS, NOT ASSIGNMENTS.
Roles are read via
Get-MsecEntraRoleHolder, which expands role-assignable groups, so somebody
who inherited Global Administrator through a group is counted - the older
/directoryRoles view could only see the group itself.
Where a group could
not be expanded it counts as one principal rather than as zero, which
under-states rather than invents.
A principal holding several privileged
roles, or the same role through two groups, still counts once.

Counts come from ACTIVE, permanent assignments only - PIM-eligible holders
are excluded, so in a tenant using PIM the true administrator population is
larger than these numbers.
That is deliberate: this row answers "what
standing privilege exists", and PimAvailable in the same row tells you
whether to go and ask Get-MsecEntraRoleHolder -AssignmentType Eligible the
other half of the question.

## RELATED LINKS
