---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecExchangeMailbox

## SYNOPSIS
Mailboxes with the two things that actually leak mail: where it is forwarded, and which
legacy protocols are open.

## SYNTAX

```
Get-MsecExchangeMailbox [[-RecipientTypeDetails] <String[]>] [-ForwardingOnly] [<CommonParameters>]
```

## DESCRIPTION
FORWARDING IS THE EXFILTRATION CONTROL, and it comes in two shapes that are NOT the same
risk.
ForwardingSmtpAddress is a raw address that can point anywhere, including outside
the tenant.
ForwardingAddress must resolve to an existing recipient object, so it cannot
name an arbitrary stranger.
Reporting them as one column loses that, so both are on the
row and ForwardingKind says which is in play.
Measured on one tenant: 34 of 305 mailboxes
forwarded, 11 by raw SMTP, four of those to addresses outside every accepted domain.

THE POINT IS NOT THAT FORWARDING IS BAD.
Most of it is deliberate - ticketing systems,
Teams, product feedback tools.
The point is that nothing tells you when a new one
appears, and an attacker's forward looks exactly like a legitimate one in the portal.
This command exists to be diffed, not to be read once.

DeliverToMailboxAndForward DECIDES WHETHER THE USER EVER SEES THE MAIL.
False means the
message leaves and no copy stays behind - the mailbox owner has no way to notice.
That
is the more dangerous configuration and it is a separate column for that reason.

SMTP AUTH IS RESOLVED, NOT REPORTED RAW.
The per-mailbox setting is often $null, meaning
"inherit the tenant default", and $null read as a boolean is false - so an unresolved
value claims SMTP AUTH is off on every mailbox that never set it.
SmtpAuthEnabled is the
EFFECTIVE answer and SmtpAuthSource says whether it came from the mailbox or the tenant.
It is the protocol worth caring about most, because it bypasses multi-factor
authentication outright.

POP, IMAP and ActiveSync are reported as found.
On most tenants they are enabled
everywhere because that is the default nobody changed, which is attack surface rather
than a misconfiguration - judge it against whether anyone actually uses them.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecExchangeMailbox -ForwardingOnly |
    Format-Table UserPrincipalName, ForwardingKind, ForwardingTarget, IsForwardingExternal, DeliverToMailboxAndForward
```

### EXAMPLE 2
```
# Mail leaving the tenant with no copy left behind - the owner cannot notice.
Get-MsecExchangeMailbox -ForwardingOnly |
    Where-Object { $_.IsForwardingExternal -and -not $_.DeliverToMailboxAndForward }
```

### EXAMPLE 3
```
# SMTP AUTH is the one that bypasses MFA.
Get-MsecExchangeMailbox | Where-Object SmtpAuthEnabled |
    Format-Table UserPrincipalName, SmtpAuthEnabled, SmtpAuthSource
```

## PARAMETERS

### -RecipientTypeDetails
Mailbox types to include.
Defaults to All, unlike Get-MsecExchangeMailboxPermission -
forwarding matters on every mailbox, not only shared ones.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: All
Accept pipeline input: False
Accept wildcard characters: False
```

### -ForwardingOnly
Only mailboxes that forward somewhere.

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

### One PSCustomObject per mailbox, PSTypeName 'MsecExchangeMailbox'.
## NOTES
Needs Connect-Msec.
The Exchange session is opened on first use.

Two bulk calls (Get-EXOMailbox, Get-EXOCasMailbox) rather than one per mailbox, so this
stays workable on a large tenant.
Read-only.

## RELATED LINKS
