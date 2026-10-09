---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecPurviewActivity

## SYNOPSIS
Purview Activity Explorer events - DLP rule matches, label applications and file activity
- one row each, with policy, rule and label names resolved.

## SYNTAX

```
Get-MsecPurviewActivity [[-Days] <Int32>] [[-Activity] <String[]>] [[-MaxEvents] <Int32>] [<CommonParameters>]
```

## DESCRIPTION
The only way to measure DLP and labelling in a tenant without Defender for Cloud Apps.
Advanced hunting has no DLP table, and CloudAppEvents is empty unless Defender for Cloud
Apps is onboarded, so Export-ActivityExplorerData is where these questions are answered:
how often a DLP rule actually fires, which policy fired it, who triggered it, and which
sensitivity labels are being applied where.

THE API HAS THREE WAYS OF SILENTLY RETURNING NOTHING, and this command exists mostly to
stop each of them from reading as "there was no activity".

A WINDOW OF 30 DAYS OR MORE RETURNS A COMPLETELY EMPTY RESPONSE - no rows, no total, no
result code, and NO error.
29 days works and returns everything.
Measured directly: 29
days returned 143,952 events and 30 days returned nothing at all.
-Days is therefore
capped at 29 rather than the 30 the documentation implies, because the 30th day does not
return less, it returns silence.

THE FILTER TAKES THE ActivityId TOKEN, NOT THE DISPLAYED NAME.
'DLPRuleMatch' returns
matches; 'DLP rule matched' - the string the portal and the Activity column both show -
returns an empty result rather than an error.
-Activity therefore validates against the
token form and tells you the mapping, so a filter can't quietly match nothing.

A SINGLE CALL RETURNS ONE PAGE, NOT THE RESULT SET.
The response carries
TotalResultCount for the whole query and at most PageSize rows, and paging continues
through WaterMark until LastPage.
Reading one page and summarising it gives an answer
that looks complete and is a sample - a 5,000-row page of a 29,000-row week is 17% of
it.
This command pages to the end and warns if it stopped early, and the row count it
returns is always comparable with TotalResultCount.

NESTED FIELDS ARE FLATTENED because the useful ones are not top-level.
PolicyName and
RuleName live inside PolicyMatchInfo, so grouping by PolicyName on the raw output
silently groups everything under one blank key.
SensitivityLabel is a bare GUID, which
is resolved to the label's display name - and left as the GUID, prefixed, when the label
no longer exists, because a deleted label still appears in historical events.

Runs as the msec app through the compliance endpoint, like the other Purview commands.
Needs a role group that exposes Export-ActivityExplorerData - Global Reader is enough.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecPurviewActivity -Days 7 -Activity DLPRuleMatch |
    Group-Object PolicyName, RuleName, Workload | Select-Object Count, Name
```

Which DLP policies actually fired, where, and how often.

### EXAMPLE 2
```
Get-MsecPurviewActivity -Days 7 -Activity LabelApplied |
    Group-Object SensitivityLabelName, Workload | Sort-Object Count -Descending
```

Where each sensitivity label is really being applied - the denominator for any
label-conditioned DLP policy.

### EXAMPLE 3
```
Get-MsecPurviewActivity -Days 7 -Activity DLPRuleMatch |
    Where-Object PolicyName -like '*Confidential*' |
    Select-Object Happened, User, Workload, ItemName
```

Whether a specific policy has fired at all.
An empty result here is a real answer,
because the pull is complete and the window is within the measured ceiling.

### EXAMPLE 4
```
Get-MsecPurviewActivity -Days 1 | Group-Object Activity | Sort-Object Count -Descending
```

What Activity Explorer is recording at all, to find the token for a narrower query.

## PARAMETERS

### -Days
How far back to look.
Default 7, maximum 29 - see the description; 30 returns silence.

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

### -Activity
One or more ActivityId tokens, filtered server-side.
Observed in this tenant:
DLPRuleMatch, DlpClassification, LabelApplied, LabelChanged, FileCreated, FileModified,
FileRead, FileRenamed, FileArchived, FilePrinted, FileCopiedToNetworkShare,
FileUploadedToCloud, ArchiveCreated, CopilotInteraction.
Not a ValidateSet - Microsoft
adds activity types, and rejecting an unknown one here would hide activity rather than
reveal it.

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

### -MaxEvents
Row ceiling.
Default 50000.
Hitting it warns, because a truncated pull that looks
complete is the failure this command is built around.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: 50000
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per event, PSTypeName 'MsecPurviewActivity'.
## NOTES
Connect-MsecPurview must have been run.
SensitiveInfoTypeData and PolicyMatchInfo are
returned whole as RawSensitiveInfo and RawPolicyMatch for the detail this command does
not flatten.

## RELATED LINKS
