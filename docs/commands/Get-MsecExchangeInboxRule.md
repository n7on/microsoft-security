---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecExchangeInboxRule

## SYNOPSIS
User-created inbox rules, flagging the ones that send mail out of the tenant or hide it
from the person who owns the mailbox.

## SYNTAX

```
Get-MsecExchangeInboxRule [[-Mailbox] <String[]>] [[-RecipientTypeDetails] <String[]>] [-RiskyOnly] [<CommonParameters>]
```

## DESCRIPTION
Mailbox forwarding is an admin setting and shows up in Get-MsecExchangeMailbox.
An INBOX
RULE is set by the user - or by whoever is holding the user's session - and is where
business email compromise actually lives.
The pattern is well worn: a rule that forwards
anything matching 'invoice' or 'payment' to an outside address, then moves it to RSS
Feeds and marks it read so the owner never sees the thread.

THIS IS SLOW AND SCOPED ON PURPOSE.
There is no bulk endpoint: Get-InboxRule takes one
mailbox at a time, measured at roughly 1.7 seconds each, so the whole tenant is several
minutes.
-Mailbox exists so an investigation can read ten mailboxes in twenty seconds,
and the default is UserMailbox rather than every recipient type for the same reason.

A MAILBOX THAT COULD NOT BE READ GETS A ROW SAYING SO.
Skipping it would make a mailbox
whose rules are unreadable look exactly like a mailbox with no rules, and in an
investigation those are opposite answers.
A mailbox genuinely holding no rules emits
nothing, which is a real measurement.

EXTERNAL IS DECIDED AGAINST ACCEPTED DOMAINS, and if those cannot be read
ForwardsExternally is $null rather than $false - claiming a forward stays inside the
tenant when nothing checked is the one wrong answer that matters.

WHAT COUNTS AS RISKY IS WRITTEN DOWN, not inferred: a rule that forwards or redirects
outside the tenant, a rule that deletes, or a rule that both files mail away and marks
it read.
StopProcessingRules and a plain MoveToFolder are ordinary mail management and
are reported but not flagged.

INVALID RULES ARE REPORTED.
Exchange returns rules it cannot parse with IsValid false
and an ErrorType; they still exist and may still run, and a corrupt rule is as often a
sign of tampering as of a broken client.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecExchangeInboxRule -RiskyOnly
```

Sweeps user mailboxes and returns only the rules worth reading.
Several minutes.

### EXAMPLE 2
```
Get-MsecExchangeInboxRule -Mailbox alice@contoso.com, bob@contoso.com
```

Every rule on two mailboxes, for an investigation.

### EXAMPLE 3
```
Get-MsecExchangeInboxRule -RecipientTypeDetails SharedMailbox -RiskyOnly
```

The mailboxes nobody is watching.

## PARAMETERS

### -Mailbox
Specific mailboxes, by primary SMTP address or UPN.
Omit to sweep every mailbox of the
types in -RecipientTypeDetails.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases: PrimarySmtpAddress, UserPrincipalName

Required: False
Position: 1
Default value: None
Accept pipeline input: True (ByPropertyName)
Accept wildcard characters: False
```

### -RecipientTypeDetails
Which mailbox types to sweep when -Mailbox is not given.
Defaults to UserMailbox.
SharedMailbox is worth a separate pass: shared mailboxes carry rules too and nobody
reads their inbox.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: UserMailbox
Accept pipeline input: False
Accept wildcard characters: False
```

### -RiskyOnly
Only rules that forward or redirect outside the tenant, delete, or hide mail.

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
