---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecDefenderTeamsMessage

## SYNOPSIS
Teams messages from the Defender advanced-hunting MessageEvents table, one row each,
with recipients and URL domains resolved - narrowed server-side, then filtered in
PowerShell.

## SYNTAX

```
Get-MsecDefenderTeamsMessage [[-Days] <Int32>] [[-SenderAddress] <String[]>] [[-RecipientAddress] <String[]>]
 [[-Subject] <String[]>] [[-ThreadName] <String[]>] [[-ThreadType] <String[]>] [[-SenderType] <String[]>]
 [-ExternalOnly] [[-ThreatType] <String[]>] [-ThreatsOnly] [[-MaxMessages] <Int32>] [<CommonParameters>]
```

## DESCRIPTION
The Teams counterpart to Get-MsecDefenderEmail, with three differences that are not
cosmetic and will change how you query it.

THERE IS NO SENDER IP, SO THERE IS NO COUNTRY.
Teams is not SMTP: a message arrives
through Microsoft's service from an authenticated identity, and MessageEvents has no
address column of any kind.
The geography question that SenderCountry answers for mail
cannot be asked here at all.
What replaces it is identity and trust boundary -
SenderType (User, Anonymous, Applications), IsExternalThread, and whether the thread is
owned by this tenant.

ONE ROW PER MESSAGE, NOT PER RECIPIENT - the opposite of EmailEvents.
Recipients arrive
as the RecipientDetails JSON array and are flattened into RecipientAddress, a string\[\],
so a message to nine people is one row with nine addresses.
Test it with -contains, not
-eq.
A sum over rows is a count of messages; a count of people needs the array.

SUBJECT IS EMPTY FOR CHAT AND MEETING MESSAGES.
It is populated for channel posts
(ThreadType 'space' and 'topic') and essentially never for one-to-one or group chat,
which is most of the traffic.
-Subject will therefore silently match nothing across the
bulk of the table; -ThreadName is the usable handle for chat, because that carries the
conversation name.
Both are offered rather than one, because channel posts really do
have subjects.

THE MESSAGE BODY IS NOT IN THIS TABLE AND NEITHER IS ANY ATTACHMENT CONTENT.
What is
here is metadata plus Defender's verdict.
For the links, UrlCount and UrlDomains are
joined from MessageUrlInfo on TeamsMessageId - both tables cover the same window, so a
message with no row there genuinely has no URLs and counts as zero rather than unknown.

VERDICT COLUMNS CAN BE EMPTY ACROSS THE WHOLE TABLE AND THAT IS NOT A BUG.
ThreatTypes,
DetectionMethods, ConfidenceLevel and SafetyTip are populated only where Defender for
Office 365 acted on a Teams message.
A tenant that has had none will see them blank
everywhere; they are returned regardless, because their absence is the finding when you
expected otherwise.

POST-DELIVERY ACTIONS ARE NOT JOINED.
MessagePostDeliveryEvents is a separate table
holding what happened to a message after it landed, so there is no equivalent of mail's
LatestDeliveryLocation here: DeliveryLocation says where it was delivered, not whether
it was removed afterwards.

Runs as the msec app and needs 'ThreatHunting.Read.All'.
Advanced hunting retains 30
days, which is what -Days is capped at.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecDefenderTeamsMessage -Days 30 -ExternalOnly |
    Group-Object SenderEmailAddress | Sort-Object Count -Descending
```

Who is talking to this tenant from outside it, and how much.

### EXAMPLE 2
```
Get-MsecDefenderTeamsMessage -Days 30 -SenderType Anonymous, Applications
```

Messages that did not come from a signed-in person in this tenant.

### EXAMPLE 3
```
Get-MsecDefenderTeamsMessage -Days 30 -ExternalOnly |
    Where-Object UrlCount -gt 0 |
    Select-Object Timestamp, SenderEmailAddress, ThreadName, UrlDomains
```

External messages carrying links - the Teams phishing shape.

### EXAMPLE 4
```
Get-MsecDefenderTeamsMessage -Days 30 |
    Where-Object RecipientAddress -contains 'anton.lindstrom@viedoc.com'
```

Everything that reached one person.
-contains, not -eq: recipients are an array.

### EXAMPLE 5
```
Get-MsecDefenderTeamsMessage -Days 30 -ThreatsOnly
```

Every Teams message Defender gave a verdict to.
An empty result is a real answer.

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

### -SenderAddress
Sender's SMTP address.
Exact, case-insensitive.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -RecipientAddress
Substring match against the raw RecipientDetails JSON, because recipients are an array
rather than a column.
An address matches wherever it appears in that array.

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

### -Subject
Substring match, case-insensitive.
Only meaningful for channel posts - see the
description.
Use -ThreadName for chat.

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

### -ThreadName
Substring match on the conversation name.
The usable handle for chat, where Subject is
empty.

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

### -ThreadType
Observed values are 'chat', 'space' (channel), 'meeting' and 'topic'.
Not a ValidateSet
on purpose - Microsoft adds thread types, and rejecting an unknown one here would hide
traffic rather than reveal it.

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

### -SenderType
Observed values are 'User', 'Anonymous' and 'Applications'.
Anonymous and Applications
are worth separating out: one is an unauthenticated participant, the other a bot or
connector posting on its own.

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

### -ExternalOnly
Only threads that cross the tenant boundary (IsExternalThread).
The closest thing Teams
has to mail's inbound direction.

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

### -ThreatType
Phish, Spam or Malware.
ThreatTypes is multi-valued, so asking for one does not exclude
the other.

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

### -ThreatsOnly
Any verdict at all - ThreatTypes non-empty.

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

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 9
Default value: 100000
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per message, PSTypeName 'MsecDefenderTeamsMessage'.
## NOTES
TeamsMessageId is the join key to MessageUrlInfo and MessagePostDeliveryEvents.
ThreadId identifies the conversation across messages.

## RELATED LINKS
