---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecPurviewDlpPolicy

## SYNOPSIS
Data Loss Prevention policies, one row each, with where they apply and whether they
actually enforce.

## SYNTAX

```
Get-MsecPurviewDlpPolicy [[-Name] <String>] [-IncludeRule]
 [<CommonParameters>]
```

## DESCRIPTION
CONFIGURED IS NOT THE SAME AS ENFORCING, and the count people quote is the configured
one.
A DLP policy has a Mode independent of its Enabled flag: 'Disable' means it does
nothing, 'TestWithNotifications' means it reports without blocking, and only 'Enable'
stops anything.
IsEnforcing collapses that into the answer most questions actually want,
while Mode and Enabled stay on the row so nothing is hidden behind the derivation.

WHERE A POLICY APPLIES IS NOT A BOOLEAN.
Each workload gets a Scope of All, Named or
None, plus a count of named locations.
'All' and 'one location happening to be called
All' are indistinguishable in the raw data until you inspect the collection, which is
the sort of thing that turns an estate-wide policy into a footnote.
NB a Named count is
not coverage - two named SharePoint sites out of nine hundred is technically 'Named'.

DO NOT BELIEVE THE Workload PROPERTY.
It is declarative, not derived: measured live,
every policy on one tenant listed "Exchange" in Workload while every single Exchange
targeting property - ExchangeLocation, ExchangeSender, ExchangeSenderMemberOf,
ExchangeAdaptiveScopes - was empty, which per Microsoft's own parameter reference means
email is NOT included.
("If you don't want to include email messages in the policy, don't
use this parameter.") Workload is surfaced here anyway, because reading it and believing
email was covered is exactly the mistake this column exists to expose - WorkloadClaims is
the list it asserts, and the *Scope columns are what is actually targeted.
Where they
disagree, the scopes are right.

EXCHANGE IS THE ONE TO CHECK.
Its location is empty on a policy that covers nothing in
mail, and because every other workload can look healthy at the same time, an uncovered
Exchange is easy to miss - measured on one tenant, every enforcing policy had an empty
Exchange location.

A RENAMED POLICY HAS TWO NAMES, AND THE PORTAL SHOWS THE ONE THIS DID NOT REPORT.
Renaming a DLP policy changes its DisplayName and leaves Name at whatever it was created
as, so the two drift apart the moment anyone tidies a name up.
Measured live: a policy
the portal calls "DLP - Confidential document shared" is still Name
"TEST - Label-based DLP (pilot)" underneath.
Name here is therefore the DISPLAY name -
the one a reader can find in the portal - and InternalName carries the original, which is
what Set-DlpCompliancePolicy -Identity and the rule join both need.
-Name matches either.

Rules are summarised on the policy row (how many, how many block, the highest severity)
because a policy with no blocking rule enforces nothing regardless of its mode.
Pass
-IncludeRule for the rules themselves; see Get-MsecPurviewDlpRule for the detail.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecPurviewDlpPolicy | Format-Table Name, Mode, IsEnforcing, ExchangeScope, SharePointScope
```

### EXAMPLE 2
```
# The policies that CLAIM email coverage in Workload but target no mailboxes.
Get-MsecPurviewDlpPolicy |
    Where-Object ClaimsEmailWithoutTarget |
    Format-Table Name, IsEnforcing, ExchangeScope, WorkloadClaims
```

### EXAMPLE 3
```
# Policies with no rule that blocks - on paper enforcing, in practice reporting.
Get-MsecPurviewDlpPolicy | Where-Object { $_.IsEnforcing -and $_.BlockingRuleCount -eq 0 }
```

## PARAMETERS

### -Name
Limit to policies whose display name OR internal name matches.
Wildcards allowed - both
are checked, because a renamed policy is findable under either.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeRule
Attach the policy's rules as a Rules property, in full.

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

### One PSCustomObject per policy, PSTypeName 'MsecPurviewDlpPolicy'.
## NOTES
Needs Connect-Msec.
The compliance session is opened automatically on first use - that
handshake takes a few seconds and imports a few hundred cmdlets, so it is reported rather
than done silently.
Call Connect-MsecPurview yourself to control -Organization, or to
choose when those 102 cmdlet names land in your runspace.

Read-only.

## RELATED LINKS
