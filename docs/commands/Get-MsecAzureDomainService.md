---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDomainService

## SYNOPSIS
Every Microsoft Entra Domain Services managed domain, the security settings that decide
what its authentication may look like, and where its security audit logs go.

## SYNTAX

```
Get-MsecAzureDomainService [[-Subscription] <String[]>]
 [<CommonParameters>]
```

## DESCRIPTION
A managed domain is a pair of Microsoft-run domain controllers holding a synchronised
copy of the directory, so that things which cannot speak modern protocols - VPN
concentrators, RADIUS, file servers, line-of-business software - can authenticate
against Kerberos, NTLM and LDAP using people's ordinary accounts.
That convenience is
the entire security question: it puts the tenant's identities behind protocols the rest
of the estate has spent a decade moving away from.

A MANAGED DOMAIN SHIPS WITH ITS WEAK SETTINGS ON.
NTLM v1, RC4 Kerberos encryption and
unsigned LDAP are enabled on a new managed domain by default, and NTLM password hashes
are synchronised into it by default as well.
None of that is a mistake anybody made,
which is exactly why it survives review: there is no change to find in a change log, and
the portal spreads the toggles across two blades.
WeakSettings names the ones currently
in the weak state in one string, so the answer does not depend on remembering which
direction is safe for each of nine fields.

WHAT THIS DOES NOT TELL YOU IS WHETHER ANY OF IT IS USED.
Turning NTLM v1 off is a
change that breaks whatever still relies on it, and this command cannot say what that
is.
The audit log can:

    $domain = Get-MsecAzureDomainService
    $used   = Search-MsecLogAnalytics -Subject DomainServices -Days 30 \`
                  -WorkspaceName $domain.AuditLogWorkspace
    $used | Where-Object Method -eq 'NTLM' | Group-Object Account

THE LOG SAYS 'NTLM', NOT 'NTLM v1'.
Event 4776 does not record which NTLM version was
negotiated, so that query lists accounts using NTLM of ANY version - and turning the
NtlmV1 setting off leaves NTLM v2 working.
It answers the question in one direction
only: no NTLM at all means nothing breaks; some NTLM is a list to check, not a list that
would break.

AuditLogWorkspace exists for that handoff.
It is the workspace NAME, which is what
Search-MsecLogAnalytics -WorkspaceName takes - a tenant of any size has dozens of
workspaces and the one a managed domain writes to is not guessable, it is whatever a
diagnostic setting points at.

NO AUDIT LOG IS THE COMMON CASE AND IT IS A FINDING.
Security audit is off by default on
a managed domain: no diagnostic setting, no events, and nothing anywhere that says so.
AuditLogsEnabled is then $false, and every authentication against the domain - including
every failure - is unrecorded and unrecoverable, because there is no local store to go
back to.
$false and $null are different answers here: $null means the diagnostic
settings could not be READ, which is a permission problem rather than a finding.

CATEGORY GROUPS, NOT CATEGORIES.
A diagnostic setting can select individual log
categories or a whole group ('audit', 'allLogs'), and when it selects a group the
per-category fields come back null.
AuditLogCategories reports whichever form is in use
rather than an empty string, since "allLogs" and "no categories" are opposite answers.

## EXAMPLES

### EXAMPLE 1
```
Connect-AzAccount
Get-MsecAzureDomainService | Format-List Domain, WeakSettings, AuditLogsEnabled, AuditLogWorkspace
```

### EXAMPLE 2
```
# The settings, and then who would actually break if NTLM were turned off.
$domain = Get-MsecAzureDomainService
Search-MsecLogAnalytics -Subject DomainServices -Name Accounts -Days 30 `
    -WorkspaceName $domain.AuditLogWorkspace |
    Where-Object { $_.Methods -match 'NTLM' }
```

### EXAMPLE 3
```
# Managed domains nobody is auditing.
Get-MsecAzureDomainService | Where-Object { -not $_.AuditLogsEnabled }
```

## PARAMETERS

### -Subscription
Limit to these subscriptions, by name or id.
Omit for every subscription the Az context
can see - managed domains are rare and easy to miss, so the default is wide.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### One PSCustomObject per managed domain, PSTypeName 'MsecAzureDomainService'.
## NOTES
Needs an Az context (Connect-AzAccount) and Reader on the subscriptions holding the
managed domains.
It does NOT need Connect-Msec - this is ARM, not Graph.

The settings come from Resource Graph in one request; the audit-log destination is a
child resource Resource Graph does not project, so it costs one ARM call per domain.
Managed domains are counted in single figures, so that is a handful of calls.

## RELATED LINKS
