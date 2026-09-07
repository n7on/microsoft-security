---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecExchangeMailboxPermission

## SYNOPSIS
Who can open which mailbox - one row per (mailbox, grantee, access right).

## SYNTAX

```
Get-MsecExchangeMailboxPermission [[-RecipientTypeDetails] <String[]>] [-IncludeInherited] [<CommonParameters>]
```

## DESCRIPTION
Shared mailbox access is a standing grant that survives the person who set it up, and
it is invisible to every Entra-side review: a Full Access grant on a shared mailbox
does not appear in group membership, in a directory role, or in any Conditional Access
report.
This is the only place it shows up.

NOT AVAILABLE THROUGH GRAPH, and that is why this needs ExchangeOnlineManagement rather
than Invoke-MsecGraphRequest like the rest of the module.
Mailbox permissions are an
Exchange concept - there is no /users/{id}/mailboxPermissions endpoint.
Every other
identity command here reads Graph; this one cannot.

NT AUTHORITY\SELF IS EXCLUDED.
Exchange grants every mailbox Full Access to itself, so
it appears on every row and means nothing.
Including it would put a meaningless finding
on every mailbox and train the reader to skim past the column that matters.

ONE ROW PER (MAILBOX, GRANTEE, RIGHT).
A grantee holding both FullAccess and SendAs on
one mailbox is two rows, because they are two separate grants made in two places -
collapsing them would hide one of them being removed.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Connect-MsecExchangeOnline -Organization contoso.onmicrosoft.com
Get-MsecExchangeMailboxPermission
```

### EXAMPLE 2
```
# The access review question: who can read mailboxes they do not own?
Get-MsecExchangeMailboxPermission |
    Where-Object AccessRights -match 'FullAccess' |
    Sort-Object MailboxUserPrincipalName, Grantee
```

### EXAMPLE 3
```
# Grantees with access to several mailboxes - usually a service account or a leaver.
Get-MsecExchangeMailboxPermission |
    Group-Object Grantee | Where-Object Count -gt 1 | Sort-Object Count -Descending
```

## PARAMETERS

### -RecipientTypeDetails
Which mailbox kinds to inspect.
Default SharedMailbox, which is where standing
delegated access accumulates.
'UserMailbox' covers delegate access to people's own
mailboxes - a bigger and noisier set, but the same question.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: SharedMailbox
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeInherited
Include permissions inherited from a parent object rather than set on the mailbox
itself.
Excluded by default: an inherited right is a property of the organisation's
RBAC, not a decision someone made about this mailbox.

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

### PSCustomObject per grant, PSTypeName 'MsecExchangeMailboxPermission'.
## NOTES
Needs Connect-MsecExchangeOnline first - see that command for why Exchange requires a
DIRECTORY ROLE and not just the Exchange.ManageAsApp app role.

A mailbox whose permissions cannot be read emits a row with Grantee 'Unreadable' rather
than contributing nothing, so a permission failure cannot read as a mailbox nobody has
access to.

## RELATED LINKS
