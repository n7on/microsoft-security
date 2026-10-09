---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderEmail

## SYNOPSIS
Messages from the Defender advanced-hunting EmailEvents table, one row each, with the
sending server's country resolved - narrowed server-side, then filtered in PowerShell.

## SYNTAX

```
Get-MsecDefenderEmail [[-Days] <Int32>] [[-Direction] <String>] [[-SenderCountry] <String[]>]
 [[-SenderDomain] <String[]>] [[-SenderAddress] <String[]>] [[-RecipientAddress] <String[]>]
 [[-SenderIp] <String[]>] [[-Subject] <String[]>] [[-ThreatType] <String[]>] [[-DeliveryLocation] <String[]>]
 [-ThreatsOnly] [[-MaxMessages] <Int32>] [<CommonParameters>]
```

## DESCRIPTION
The general mail-flow pivot.
Returns messages as objects and leaves the question to the
caller, rather than shipping a command per question:

    Get-MsecDefenderEmail -Days 30 -SenderCountry Israel
    Get-MsecDefenderEmail -Days 30 | Group-Object SenderCountry | Sort-Object Count -Descending
    Get-MsecDefenderEmail -Days 30 | Where-Object { $_.AuthenticationDetails -match 'dmarc.*fail' }

EmailEvents IS NOT A SPAM TABLE.
It holds every message Exchange Online Protection
processed - inbound, outbound and intra-org, clean mail included, one row per recipient.
The verdict is a column, not a filter: ThreatTypes is empty on clean mail, and
DeliveryAction and LatestDeliveryLocation say what happened to it.

SENDERCOUNTRY IS THE SENDING INFRASTRUCTURE, NOT THE AUTHOR.
SenderIPv4 is the last SMTP
hop that connected to Exchange Online - the server Microsoft accepted the message from.
A message relayed through Gmail or SendGrid geolocates to that provider's egress and says
nothing about where the person was; a self-hosted sender's own server does appear.
Nothing in EmailEvents holds the author's client address - it never reaches the
recipient's mail system.
AuthenticationDetails is the stronger signal next to it: SPF,
DKIM and DMARC answer whether that infrastructure was AUTHORISED to send for the domain
it claims, which geography cannot.

A MESSAGE THAT ARRIVED OVER IPv6 HAS NO COUNTRY AT ALL.
geo_info_from_ip_address resolves
IPv4, so an IPv6 delivery carries SenderCountry = '(IPv6 - not geolocated)' rather than a
blank or a guess.
Those rows are in the output like any other - a country filter that
silently omitted them would read as "there was none from there" when it means "this one
could not be placed anywhere".

THE FILTER PARAMETERS EXIST TO KEEP THE FETCH HONEST, not to replace Where-Object.
Every
one of them is applied in KQL before the row ceiling, so narrowing server-side changes
WHICH messages are available to filter downstream.
Filtering a truncated fetch in
PowerShell does not: ask for a window holding 40,000 messages, get the newest ceiling-
worth, filter to one country, and the answer looks complete and is wrong.

THE CEILING CANNOT BE REMOVED, ONLY MOVED.
/security/runHuntingQuery caps its own result
set, so a command with no -MaxMessages would still be truncated - it would just stop
saying so.
MaxMessages therefore defaults to that API ceiling rather than to a smaller
number of msec's own invention: it binds only where the service would have bound anyway,
and the total matching count is measured separately so truncation is reported either
way, with both numbers.

Runs as the msec app and needs 'ThreatHunting.Read.All'.
Advanced hunting retains 30
days, which is what -Days is capped at - a larger window would silently return a smaller
one.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderEmail -Days 30 -Direction Inbound |
    Group-Object SenderCountry | Sort-Object Count -Descending
```

Inbound volume by sending country - the summary, built client-side.

### EXAMPLE 2
```
Get-MsecDefenderEmail -Days 30 -Direction Inbound -SenderCountry Israel, Lithuania
```

Two countries' sending infrastructure, narrowed before the row ceiling applies.

### EXAMPLE 3
```
Get-MsecDefenderEmail -Days 30 -ThreatsOnly -DeliveryLocation Inbox
```

Threats still sitting in a mailbox after ZAP - what a user could actually open.

### EXAMPLE 4
```
Get-MsecDefenderEmail -Days 30 -Subject 'invoice', 'payment' -ThreatsOnly |
    Select-Object Timestamp, SenderFromAddress, RecipientEmailAddress, Subject
```

Who got the invoice-themed run, and from where.

### EXAMPLE 5
```
Get-MsecDefenderEmail -Days 30 -Direction Inbound |
    Where-Object { $_.AuthenticationDetails -match 'dmarc.*fail' } |
    Group-Object SenderFromDomain
```

Domains whose claimed identity the sending infrastructure was not authorised to use.

## PARAMETERS

### -Days
How far back to look.
Default 7, maximum 30 - the advanced-hunting retention ceiling.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 7
Accept pipeline input: False
Accept wildcard characters: False
```

### -Direction
Inbound, Outbound, IntraOrg, or All.
Default All.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: All
Accept pipeline input: False
Accept wildcard characters: False
```

### -SenderCountry
Country of the sending server, as the geo database spells it ("United States", not "US").
Case-insensitive.
The unplaceable buckets can be asked for by name too:
'(IPv6 - not geolocated)', '(no sender IP)', '(IP not in geo database)'.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -SenderDomain
Matches EITHER the header From domain or the envelope MailFrom domain.
Relayed mail
carries different values in the two, and matching only one would quietly miss it.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -SenderAddress
Matches either the header From address or the envelope MailFrom address, for the same
reason.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -RecipientAddress
The internal recipient.
One row per recipient, so a message to five people is five rows.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -SenderIp
Sending server address.
Matches IPv4 or IPv6.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Subject
Substring match, case-insensitive, any of the given strings.
\`contains\` rather than
\`has\`: \`has\` matches whole tokens, so it would find "Invoice" in "Invoice due" and NOT
in "Invoice-2451", which is the wrong half of the time for subject lines.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ThreatType
Phish, Spam or Malware.
ThreatTypes is multi-valued - one message can be both Phish and
Spam - so asking for one does not exclude the other.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 9
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -DeliveryLocation
Where the message ENDED UP, after ZAP (LatestDeliveryLocation) - Inbox, 'Junk folder',
Quarantine, 'Deleted items'.
Not where it was first delivered: a phish that reached a
mailbox and was pulled back later is not something a user could still open.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 10
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ThreatsOnly
Any verdict at all - ThreatTypes non-empty.
Broader than -ThreatType, and the cheapest
way to cut volume when the question is about threats rather than about one kind.

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

### -MaxMessages
Row ceiling, newest first.
Defaults to the /security/runHuntingQuery ceiling, so it only
binds where the service would have.
Lower it deliberately when a quick look will do.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 11
Default value: 100000
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per message, PSTypeName 'MsecDefenderEmail'.
## NOTES
NetworkMessageId is the join key to EmailUrlInfo, EmailAttachmentInfo,
EmailPostDeliveryEvents and UrlClickEvents - the message, its links, what happened after
delivery, and whether anybody clicked.

## RELATED LINKS
