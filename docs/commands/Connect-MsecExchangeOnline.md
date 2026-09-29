---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Connect-MsecExchangeOnline

## SYNOPSIS
Signs the ExchangeOnlineManagement module in using the msec session's token, so
Get-EXO* commands run as the msec app without its private key leaving Key Vault.

## SYNTAX

```
Connect-MsecExchangeOnline [[-Organization] <String>] [[-MinimumMinutes] <Int32>] [-ShowBanner] [<CommonParameters>]
```

## DESCRIPTION
Exchange Online is NOT Graph, and cannot be reached through it.
Mailbox permissions -
Full Access, Send As - are an Exchange concept with no Graph equivalent: there is no
/users/{id}/mailboxPermissions endpoint, and no plan to add one.
So the
ExchangeOnlineManagement module is the only way to answer "who can read this shared
mailbox", and this command exists to authenticate it the way msec authenticates
everything else.

THE TOKEN IS FOR outlook.office365.com, NOT GRAPH.
Exchange issues its own audience, so
a Graph token is rejected here and vice versa.
Both are acquired the same way - a JWT
client assertion signed inside Key Vault - which is what keeps the private key off this
machine.

EXCHANGE NEEDS A DIRECTORY ROLE, NOT JUST AN APP ROLE, and this is the step people
miss.
Exchange.ManageAsApp on the application is necessary but NOT sufficient: the
service principal must also hold a directory role - Exchange Administrator, Exchange
Recipient Administrator, or Global Reader for read-only work.
Without it every cmdlet
fails with an authorisation error that names no missing permission, because from
Exchange's point of view the app is authenticated and simply has no rights.

THE MODULE IS NOT AN msec DEPENDENCY.
It is imported only when this command is called,
so msec installs and runs normally on a machine that has never heard of Exchange.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Connect-MsecExchangeOnline -Organization contoso.onmicrosoft.com
Get-EXOMailbox -RecipientTypeDetails SharedMailbox
```

### EXAMPLE 2
```
# A long run, refusing to start without headroom.
Connect-MsecExchangeOnline -Organization contoso.com -MinimumMinutes 30
```

## PARAMETERS

### -Organization
Optional.
Resolved from Graph (the tenant's default verified domain) when omitted.
The tenant's primary domain, e.g.
contoso.onmicrosoft.com or contoso.com.
Exchange
identifies the tenant by domain rather than by id, and app-only connections require it.

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

### -MinimumMinutes
Fail unless the token has at least this long left.
Default 5.
A long mailbox
enumeration should ask for the time it needs: the module is handed a static token and
cannot renew it, so a short one starts working and then fails partway through.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: 5
Accept pipeline input: False
Accept wildcard characters: False
```

### -ShowBanner
Show the module's own connection banner, which is suppressed by default because it is
noise in a pipeline log.

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
Needs Connect-Msec first, and the ExchangeOnlineManagement module - which is NOT a
dependency of msec.

Disconnect with Disconnect-ExchangeOnline.
The module holds a session; leaving it open
across a long script is fine, but leaving it open across tenants is not.

## RELATED LINKS
