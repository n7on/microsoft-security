---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecExchangeOrganizationSetting

## SYNOPSIS
Tenant-wide Exchange Online posture in one row: the settings that decide whether mail
can leave, whether SMTP AUTH is possible, and whether anything is audited.

## SYNTAX

```
Get-MsecExchangeOrganizationSetting [<CommonParameters>]
```

## DESCRIPTION
THERE ARE TWO SEPARATE AUTO-FORWARDING CONTROLS and both must be off to stop it.
The
outbound spam filter policy's AutoForwardingMode governs it at the Defender layer;
the Default remote domain's AutoForwardEnabled governs it at the transport layer.
Turning off one and leaving the other is a common half-fix, which is why they sit
beside each other here rather than in two different reports.

AutoForwardingMode HAS THREE VALUES AND THE SAFE ONE IS NOT "Off".
'Automatic' is
Microsoft's default and is system-controlled - it blocks most external auto-forwarding
while allowing legitimate flows.
'On' permits it outright.
'Off' blocks it entirely.
A tenant reading 'On' has deliberately opened the path that mailbox forwarding rules
then use.

SMTP AUTH IS THE ONE THAT BYPASSES MFA.
The tenant default here is what every mailbox
inherits unless it overrides it, so this row and Get-MsecExchangeMailbox answer
different halves of the same question - this one is the default, that one is the
effective value per mailbox.

AUDIT IS REPORTED IN THE POSITIVE.
UnifiedAuditLogIngestionEnabled is the switch that
decides whether anything reaches the audit log at all; with it off, every other control
here is unverifiable after the fact.

Each value is read independently and a failure leaves that column $null rather than
failing the row - a partial answer about tenant posture is worth more than none, as
long as the gaps are visible as gaps.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecExchangeOrganizationSetting | Format-List
```

### EXAMPLE 2
```
# The two controls that must agree.
Get-MsecExchangeOrganizationSetting |
    Select-Object AutoForwardingMode, RemoteDomainAutoForwardEnabled
```

## PARAMETERS

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### A single PSCustomObject, PSTypeName 'MsecExchangeOrganizationSetting'.
## NOTES
Needs Connect-Msec.
The Exchange session is opened on first use.
Read-only.

## RELATED LINKS
