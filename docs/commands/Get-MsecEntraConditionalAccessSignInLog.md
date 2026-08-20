---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecEntraConditionalAccessSignInLog

## SYNOPSIS
Raw Entra sign-in events with Conditional Access outcomes attached, for the
last N days.
One row per sign-in attempt.

## SYNTAX

```
Get-MsecEntraConditionalAccessSignInLog [[-Days] <Int32>] [[-UserId] <String[]>] [<CommonParameters>]
```

## DESCRIPTION
Calls Microsoft Graph /v1.0/auditLogs/signIns?$filter=createdDateTime ge {start}
and projects each event to a flat PSCustomObject with the CA-relevant
fields surfaced.
Interactive sign-ins only (the kind CA evaluates) -
non-interactive token refreshes are not included by default.
If you need
those, the Graph endpoint supports a signInEventTypes filter (out of scope
here).

This is the data behind the Conditional Access "Insights and reporting"
workbook in the Entra portal.
Aggregate it in PowerShell on the consumer
side - msec only returns the raw rows.

    $log = Get-MsecEntraConditionalAccessSignInLog -Days 1

    # CA outcome counts
    $log | Group-Object ConditionalAccessStatus

    # Sign-ins blocked by CA
    $log | Where ConditionalAccessStatus -eq 'failure' |
        Select CreatedDateTime, UserPrincipalName, AppDisplayName, AppliedPolicies

    # Top failing policies
    $log |
        Where ConditionalAccessStatus -eq 'failure' |
        ForEach-Object { $_.AppliedPolicies | Where-Object result -eq 'failure' } |
        Group-Object displayName | Sort Count -Descending

VOLUME WARNING: in a busy tenant, expect ~10k-100k+ interactive sign-ins
per day.
Default window is intentionally narrow (1 day) so you don't
accidentally pull 700k events.
Widen with -Days deliberately, and consider
using Where-Object on a small column projection if you only need a
subset.

Microsoft Graph caps sign-in log retention at 30 days for the
/auditLogs/signIns endpoint (Premium tenants get longer retention via
Log Analytics export, not via Graph) - hence the -Days max of 30.

Requires the 'AuditLog.Read.All' application permission AND Microsoft Entra ID
P1 or P2 on the tenant - the endpoint is premium-gated independently of
permissions.
A 403 is re-thrown with Graph's own message and is distinguished
between the two causes, because a licensing 403 cannot be fixed by granting a
permission.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraConditionalAccessSignInLog -Days 1 |
    Group-Object ConditionalAccessStatus
```

### EXAMPLE 2
```
# Per-day blocked-by-CA count for a posture-meeting chart.
Get-MsecEntraConditionalAccessSignInLog -Days 7 |
    Where ConditionalAccessStatus -eq 'failure' |
    Group-Object { $_.CreatedDateTime.Date } |
    Select Name, Count
```

## PARAMETERS

### -Days
Window size in days.
Default 1, max 30 (Graph retention cap).

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 1
Accept pipeline input: False
Accept wildcard characters: False
```

### -UserId
Restrict to these user object ids.
Without it every sign-in in the window is
paged, which on a real tenant is tens of thousands of events per day; with it
Graph filters server-side and a handful of users costs almost nothing.
Ids are
batched 15 per request so a long list cannot overflow the URL length limit.

Use the object id, not the UPN - userId is the filterable property here.

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

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per sign-in event. See .NOTES for the projection.
## NOTES
Projection (Graph field path -\> output property):
  id                              -\> Id
  createdDateTime                 -\> CreatedDateTime (\[datetime\])
  userPrincipalName               -\> UserPrincipalName
  userDisplayName                 -\> UserDisplayName
  userId                          -\> UserId
  appDisplayName                  -\> AppDisplayName
  appId                           -\> AppId
  ipAddress                       -\> IpAddress
  location.city                   -\> City
  location.state                  -\> State
  location.countryOrRegion        -\> Country
  clientAppUsed                   -\> ClientAppUsed
  deviceDetail.operatingSystem    -\> DeviceOs
  deviceDetail.browser            -\> DeviceBrowser
  deviceDetail.isCompliant        -\> DeviceCompliant
  deviceDetail.trustType          -\> DeviceTrustType
  conditionalAccessStatus         -\> ConditionalAccessStatus  (success/failure/notApplied)
  appliedConditionalAccessPolicies-\> AppliedPolicies   (array; each row has id/displayName/result)
  riskLevelAggregated             -\> RiskLevelAggregated
  riskLevelDuringSignIn           -\> RiskLevelDuringSignIn
  status.errorCode                -\> ResultCode
  status.failureReason            -\> ResultFailureReason

## RELATED LINKS
