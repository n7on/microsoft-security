---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# New-MsecDefenderDetectionRule

## SYNOPSIS
Creates a Defender XDR custom detection rule from an advanced hunting query, after
running the query to check it works.
Runs as YOU, not as the msec app.

## SYNTAX

### Query
```
New-MsecDefenderDetectionRule -DisplayName <String> -Query <String> -Description <String>
 [-AlertTitle <String>] [-Severity <String>] [-Frequency <String>] [-DeviceIdColumn <String>]
 [-DeviceNameColumn <String>] [-RecommendedActions <String>] [-Tactic <String>] [-Technique <String[]>]
 [-Disabled] [-Id <String>] [-MaxExpectedRows <Int32>] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

### File
```
New-MsecDefenderDetectionRule -DisplayName <String> -QueryPath <String> -Description <String>
 [-AlertTitle <String>] [-Severity <String>] [-Frequency <String>] [-DeviceIdColumn <String>]
 [-DeviceNameColumn <String>] [-RecommendedActions <String>] [-Tactic <String>] [-Technique <String[]>]
 [-Disabled] [-Id <String>] [-MaxExpectedRows <Int32>] [-WhatIf]
 [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
THE QUERY IS RUN BEFORE THE RULE IS CREATED, AND THAT IS THE POINT.
A custom detection
whose query is malformed, references a table this tenant does not have, or omits the
columns the entity mapping names, is accepted by the portal and by this API and then
fails on its schedule - at which point Defender eventually marks it autoDisabled.
The
rule sits in the list looking live.
So the query is executed first, through the app's
read-only hunting access, and creation is refused if it does not run.

ROW COUNT IS CHECKED TOO, because the other way a new detection goes wrong is working
perfectly and matching eight hundred things.
The count over the validation window is
reported, and a query that matches a lot warns before anything is created - one alert
per match is how a detection gets switched off by the people it pages.

TWO IDENTITIES, DELIBERATELY.
Validation reads through the app certificate
(ThreatHunting.Read.All); creation writes through your delegated session from
Connect-MsecAdmin.
The app cannot create detections and is not asked to - a read-only
app that could add alert rules is not read-only in any sense that matters.

REQUIRES Connect-MsecAdmin -Scope CustomDetection.ReadWrite.All.
That is the only
permission the API accepts; there is no lesser one.
The signed-in user also needs
Detection tuning (Manage), Security Administrator, or Security Operator.

TIMESTAMP IS ALWAYS REQUIRED IN THE QUERY, and so is every column named by an entity
mapping.
Defender rejects a rule whose mapping points at a column the query does not
project, but the message does not say which, so both are checked here against the real
result and the missing column is named.

## EXAMPLES

### EXAMPLE 1
```
Connect-MsecAdmin -Scope CustomDetection.ReadWrite.All
New-MsecDefenderDetectionRule -DisplayName 'Allow-listed publisher certificate rotated' `
    -QueryPath ./cert-rotation.kql -Severity informational -Frequency 24h `
    -Description 'A publisher we allow-list by certificate started signing with a new one. Create an indicator for the new thumbprint, then add it to ApprovedThumbprints in this rule.' `
    -WhatIf
```

## PARAMETERS

### -DisplayName
The rule name, as it appears in the portal.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Query
The advanced hunting KQL.
Must project Timestamp and the entity columns below.

```yaml
Type: String
Parameter Sets: Query
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -QueryPath
A .kql file to read the query from instead of -Query.
Keeps rules in version control.

```yaml
Type: String
Parameter Sets: File
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Description
Why this rule exists and what to do when it fires.
The only explanation that travels
with the rule, so it is mandatory here even though the API treats it as optional.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -AlertTitle
Title of the alert raised on a match.
Defaults to the rule name.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Severity
informational, low, medium or high.
Defaults to informational.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: Informational
Accept pipeline input: False
Accept wildcard characters: False
```

### -Frequency
How often it runs: 1h, 3h, 12h or 24h.
Defaults to 24h.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 24h
Accept pipeline input: False
Accept wildcard characters: False
```

### -DeviceIdColumn
Column holding the device id, mapped as the impacted host.
Defaults to DeviceId; pass
an empty string for a query with no device.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: DeviceId
Accept pipeline input: False
Accept wildcard characters: False
```

### -DeviceNameColumn
Column holding the device name.
Defaults to DeviceName when the query projects it.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: DeviceName
Accept pipeline input: False
Accept wildcard characters: False
```

### -RecommendedActions
What the responder should do.
Shown on the alert.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Tactic
MITRE ATT&CK tactic, e.g.
'DefenseEvasion'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Technique
MITRE technique ids, e.g.
'T1562.009'.
Requires -Tactic.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Disabled
Create the rule switched off.

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

### -Id
Client-supplied rule id.
Derived from the display name when omitted.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -MaxExpectedRows
Warn when validation returns more rows than this.
Default 50.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 50
Accept pipeline input: False
Accept wildcard characters: False
```

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject describing the created rule, PSTypeName 'MsecDefenderDetectionRule'.
## NOTES
Beta endpoint: custom detection rules are beta-only in Microsoft Graph at present.

## RELATED LINKS
