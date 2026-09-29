---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Connect-MsecPurview

## SYNOPSIS
Opens an app-only Security & Compliance PowerShell session for the Get-MsecPurview*
commands.

## SYNTAX

```
Connect-MsecPurview [[-Organization] <String>] [-ShowBanner]
 [<CommonParameters>]
```

## DESCRIPTION
CALLING THIS IS OPTIONAL.
The Get-MsecPurview* commands open a session themselves on
first use, so Connect-Msec is normally all you need.
Use this directly when the tenant
domain has to be given explicitly, or to choose when a few hundred compliance cmdlet
names are imported into your runspace.
Measured: 102 cmdlets, none of them clashing with
the ExchangeOnlineManagement module's own exports - so the import is bulk rather than
destructive, and a Get- command doing it unasked is still a side effect worth knowing about.

Purview's configuration is not in Microsoft Graph.
Retention labels have a v1.0 endpoint
and eDiscovery cases have one, but DLP policies, DLP rules, sensitivity label actions and
label policies do not - the only complete source is Security & Compliance PowerShell,
which is why this exists rather than another Invoke-MsecGraphRequest caller.

NO NEW CONSENT IS NEEDED.
Connect-IPPSSession accepts -AccessToken and -AppId, the same
shape Connect-MsecExchangeOnline uses, so the existing Key Vault certificate reaches the
compliance endpoint as the app.
The resource differs
(ps.compliance.protection.outlook.com rather than outlook.office365.com) but the identity
and the trust do not.

The app still needs a directory role to be allowed in - Global Reader or Compliance
Administrator.
New-MsecApp assigns Global Reader when asked for -Workload Exchange, and a
403 here almost always means that assignment is missing rather than that a permission is.

-Organization is optional: left off, the tenant's default verified domain is read from
Graph, which the app can already do.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecPurviewDlpPolicy      # connects by itself
```

# Explicit, when the domain must be given or the import timed deliberately:
Connect-MsecPurview -Organization contoso.onmicrosoft.com

## PARAMETERS

### -Organization
Tenant domain, e.g.
contoso.onmicrosoft.com.
Resolved from Graph when omitted.

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

### -ShowBanner
Show the ExchangeOnlineManagement banner.
Suppressed by default.

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

## NOTES
Needs the ExchangeOnlineManagement module, which is not a dependency of msec - only the
Exchange and Purview commands require it.

NB this shares cmdlet names with an Exchange Online session.
Connecting both into one
runspace lets the later connection win for overlapping names; connect Purview in its own
session if you also need Get-Mailbox.

## RELATED LINKS
