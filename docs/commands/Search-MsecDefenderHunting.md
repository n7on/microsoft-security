---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Search-MsecDefenderHunting

## SYNOPSIS
Runs a bundled advanced hunting KQL query against the Defender XDR event store.

## SYNTAX

### File (Default)
```
Search-MsecDefenderHunting -Subject <String> [-Name <String>] [-Days <Int32>] [-Timespan <TimeSpan>] [<CommonParameters>]
```

### Query
```
Search-MsecDefenderHunting -Query <String> [-Days <Int32>] [-Timespan <TimeSpan>] [<CommonParameters>]
```

## DESCRIPTION
The third of the three search commands, and the one people reach for by mistake.
Each
searches a DIFFERENT store, and no amount of KQL moves a question from one to another:

    Search-MsecDefenderHunting     what a device, user or mailbox DID     ~30 days
    Search-MsecAzureResourceGraph  how an Azure resource is CONFIGURED    current state
    Search-MsecLogAnalytics        what a service LOGGED to a workspace   your retention

Advanced hunting reads Defender XDR's own event lake, holding roughly thirty days of
raw telemetry written directly by the onboarded Defender workloads.
It is NOT a Log
Analytics workspace: nothing you route with a diagnostic setting appears here, and
nothing here reaches a workspace unless the Sentinel connector is wired up.
Entra
Domain Services audit logs, for one, will never show up - those are Search-MsecLogAnalytics.

WHICH TABLES EXIST DEPENDS ENTIRELY ON WHAT IS ONBOARDED.
A table belonging to a product
you do not run is not empty, it fails to resolve, and the error says so rather than
returning nothing - a query that answers "0 rows" for "this product is not installed"
is the worst outcome here.
Measured on one tenant: Device* and Email* tables full,
AADSignInEventsBeta carrying 2.4M sign-ins, and every Identity* table at zero because
Defender for Identity has no sensors on a managed domain.

THE .kql FILES CARRY NO TIME FILTER.
The window goes to the API as its own timespan
parameter, the same split Search-MsecLogAnalytics uses, so one file serves every window
and there is no \`ago()\` to forget to update.
Verified against a live tenant: the same
query returns 12 / 57 / 2245 / 6544 rows at PT1H / P1D / P7D / P30D.

SOME TABLES IGNORE THE WINDOW, AND CANNOT DO OTHERWISE.
DeviceTvmSoftwareVulnerabilities
and the other DeviceTvm* tables are current-state snapshots with no Timestamp column at
all, so -Days on Vulnerability changes nothing.
That is a property of the table, not a
bug here, and the .kql says so at the top.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Search-MsecDefenderHunting -Subject SignIn -Name Failed -Days 1 |
    Sort-Object { [int]$_.Failures } -Descending | Select-Object -First 20
```

Failed Entra sign-ins in the last day, worst first.
Note the cast - Failures arrives as
a string, and '9' sorts after '10' without it.

### EXAMPLE 2
```
Search-MsecDefenderHunting -Query 'DeviceLogonEvents | where IsLocalAdmin == true | take 50' -Days 7
```

## PARAMETERS

### -Subject
The folder under kql/Hunting/.
Tab-completes from the folders that actually hold a .kql.

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

### -Name
KQL file base name.
Defaults to 'All'.
Tab-completes from the chosen -Subject.

```yaml
Type: String
Parameter Sets: File
Aliases:

Required: False
Position: Named
Default value: All
Accept pipeline input: False
Accept wildcard characters: False
```

### -Query
Run literal KQL instead of a bundled file, for one-off hunting.
Mutually exclusive with
-Subject.

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

### -Days
Window, 1-30.
Defaults to 7.
Advanced hunting keeps about thirty days, so 30 is the
ceiling rather than an arbitrary cap.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: 7
Accept pipeline input: False
Accept wildcard characters: False
```

### -Timespan
Sub-day windows, e.g.
-Timespan 04:00:00.
A BARE INTEGER IS READ AS TICKS - -Timespan 7
means 700 nanoseconds, not seven days - so anything under a minute is refused with a
message pointing at -Days.

```yaml
Type: TimeSpan
Parameter Sets: (All)
Aliases:

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

### PSCustomObject rows shaped by the query's own project or summarize clause.
## NOTES
Needs the 'ThreatHunting.Read.All' application permission, which New-MsecApp consents.
Runs as the app, read-only.

EVERY VALUE COMES BACK AS A STRING.
The hunting API returns JSON without types, so a
count is '1234' and a boolean is 'false' - and 'false' is TRUTHY in PowerShell.
Cast
before comparing or sorting; see the example.

## RELATED LINKS
