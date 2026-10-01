---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecExchangeTransportRule

## SYNOPSIS
Mail flow rules, with the two things that make one dangerous: whether it bypasses
filtering, and whether it sends mail somewhere else.

## SYNTAX

```
Get-MsecExchangeTransportRule [[-Name] <String>] [-RiskyOnly]
 [<CommonParameters>]
```

## DESCRIPTION
A transport rule runs on every message in the tenant, before the user sees it.
That
makes it a favourite for persistence: one rule can exempt an attacker's sender from
filtering, or copy every message to an outside address, and it lives in a part of the
portal nobody browses.

BYPASSING FILTERING IS A SPAM CONFIDENCE LEVEL OF -1, which does not read as dangerous
unless you know what it means.
SCL -1 tells Exchange to trust the message completely and
skip spam, phishing and bulk filtering.
BypassesFiltering is a derived column saying so
in words.
Measured on one tenant: 7 of 12 rules set it, 3 of them enabled - mostly for
phishing-simulation training, which is legitimate and is also exactly what an attacker's
rule would be named.

THE REDIRECT PROPERTIES ARE FOUR, NOT ONE.
RedirectMessageTo diverts the message,
BlindCopyTo and CopyTo duplicate it, and AddToRecipients adds a recipient.
They behave
differently for the sender and the original recipient; a command that checked only one
would miss the other three.
RedirectsMail is true when any of them is set, and the
individual columns say which.

ExternalRecipients NAMES THE ONES OUTSIDE THE TENANT.
A rule copying mail to an internal
archive mailbox is ordinary; the same rule pointing at a personal address is not.
Resolved against accepted domains, and $null rather than empty when those could not be
read - "not checked" must not look like "all internal".

State IS NOT THE WHOLE ANSWER.
A rule can be Enabled and still inert because its Mode is
Audit rather than Enforce; both are on the row, and IsActive is true only when the rule
is enabled AND enforcing.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecExchangeTransportRule -RiskyOnly |
    Format-Table Name, IsActive, BypassesFiltering, RedirectsMail, ExternalRecipients
```

### EXAMPLE 2
```
# Live rules that exempt a sender from all filtering.
Get-MsecExchangeTransportRule |
    Where-Object { $_.IsActive -and $_.BypassesFiltering } |
    Format-Table Name, Comments, LastModifiedBy, WhenChangedUtc
```

## PARAMETERS

### -Name
Limit to rules whose name matches.
Wildcards allowed.

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

### -RiskyOnly
Only rules that bypass filtering or redirect mail.

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

### One PSCustomObject per rule, PSTypeName 'MsecExchangeTransportRule'.
## NOTES
Needs Connect-Msec.
The Exchange session is opened on first use.
Read-only.

## RELATED LINKS
