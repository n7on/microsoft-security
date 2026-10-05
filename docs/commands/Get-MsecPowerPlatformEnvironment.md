---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecPowerPlatformEnvironment

## SYNOPSIS
Power Platform environments and whether a connector DLP policy actually covers each
one - the control that decides what a Power Automate flow is allowed to connect to.

## SYNTAX

```
Get-MsecPowerPlatformEnvironment [-UncoveredOnly] [<CommonParameters>]
```

## DESCRIPTION
A Power Automate flow runs as the person who built it, needs no approval, and can move
data between any two connectors it is permitted to use.
The only thing constraining
that is a connector DLP policy, and a policy constrains an environment only if it is
scoped to include it.

AN ENVIRONMENT WITH NO DLP POLICY HAS NO CONNECTOR RESTRICTIONS AT ALL.
Not weak ones -
none.
SharePoint to a personal Gmail is an ordinary afternoon's work for a maker in an
uncovered environment, and nothing in Secure Score, DLP for Microsoft 365, or a
Conditional Access review mentions it.

RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP.
The Power Platform admin APIs return
403 to the app certificate: app-only access requires the application to be registered
as a Power Platform MANAGEMENT APPLICATION, which grants administrative - not read-only
- access to the whole Power Platform estate.
Taking that route would break the promise
that the certificate in Key Vault cannot change the tenant, so this command follows the
same pattern as Search-MsecAzureResourceGraph and runs on your Az context instead.
One
command, one identity.

DLP SCOPE IS A FILTER TYPE, NOT A LIST.
A policy carries environmentFilterType of
'none' (every environment), 'include' (only the listed ones) or 'exclude' (all but the
listed ones).
Reading only the environment list would report a tenant-wide policy as
covering nothing, which is the most dangerous possible way to be wrong here.

UNREADABLE IS NOT UNCOVERED.
If the policy list cannot be read, IsCoveredByDlp is
$null on every row rather than $false - an environment nobody could check must not
render as one that is definitely unprotected.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecPowerPlatformEnvironment
```

Every environment, with the policies covering it.

### EXAMPLE 2
```
Get-MsecPowerPlatformEnvironment -UncoveredOnly
```

The environments where a maker may connect anything to anything.

## PARAMETERS

### -UncoveredOnly
Only environments no DLP policy applies to.

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

### System.Management.Automation.PSObject
## NOTES

## RELATED LINKS
