---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAppGatewayClientActivity

## SYNOPSIS
Everything one or more client IP addresses did through an Application Gateway - the
request timeline where it exists, the hourly summary where it does not, and whether the
address ever completed an authentication.

## SYNTAX

```
Get-MsecAppGatewayClientActivity [-ClientIp] <String[]> [-WorkspaceName] <String>
 [[-ResourceGroupName] <String>] [[-Days] <Int32>] [-SummaryOnly]
 [<CommonParameters>]
```

## DESCRIPTION
The pivot for "this address appeared in a report - what did it actually do".
Written
because answering it by hand means knowing which of three tables holds the answer for
which part of the window, and reading an OpenID Connect exchange off raw HTTP.

REACHING A LOGIN PAGE IS NOT LOGGING IN.
A gateway access log has no usernames and no
authentication result, so a 200 on a login page says only that a page was rendered -
crawlers and scanners produce those in volume.
Authentication is inferred from the two
points a client cannot reach unless the identity provider has already authenticated it:

    POST /signin-oidc                 the application accepts an identity token
    GET  /connect/authorize/callback  the authorization code is exchanged

Authenticated is $true only on those.
Treating a login-page 200 as a sign-in turns every
search engine into an intruder, which is the mistake this command exists to prevent.

THE PER-REQUEST LOG AND THE SUMMARY ARE NOT INTERCHANGEABLE, so Grain says which a row
came from.
AzureDiagnostics holds one row per request with method, URI and status.
A
gateway switched to resource-specific logging writes AGWAccessLogs instead - which on the
Basic or Auxiliary plan cannot be read by KQL at all, so the only thing left for that
period is the hourly summary, which has client IP and a status class but NO HTTP method
and NO full URI.
Authentication therefore cannot be determined from summary-only
periods, and those rows carry Authenticated = $null rather than $false: unknown is not
the same as "did not".

THE WINDOW CAN CHANGE GRAIN PART-WAY THROUGH, which is why both are returned together
rather than picking one.
An address whose detail stops on a particular day was not
necessarily quiet from then on - the logging mode changed underneath it.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecAppGatewayClientActivity -ClientIp 79.137.138.24 -WorkspaceName prod-sentinel-log -Days 14
```

Every request from one address, oldest first.

### EXAMPLE 2
```
Get-MsecAppGatewayClientActivity -ClientIp 213.79.68.227, 91.78.130.139 `
    -WorkspaceName prod-sentinel-log -Days 14 -SummaryOnly
```

Several addresses at a glance - did they authenticate, and how much did they do afterwards.

### EXAMPLE 3
```
Get-MsecAppGatewayClientActivity -ClientIp 1.2.3.4 -WorkspaceName prod-sentinel-log |
    Where-Object Authenticated
```

The requests that prove a completed sign-in, if there are any.

## PARAMETERS

### -ClientIp
One or more client addresses.
Validated as IPv4 or IPv6 before anything is sent: an
address with a stray space or a CIDR suffix silently matches nothing, which is
indistinguishable from a quiet address.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -WorkspaceName
Log Analytics workspace holding the gateway logs.
Resolved by name across every
accessible subscription.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ResourceGroupName
Narrows the workspace lookup when a name is ambiguous.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Days
How far back to look.
Default 7.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: 7
Accept pipeline input: False
Accept wildcard characters: False
```

### -SummaryOnly
Return one row per address instead of the request timeline - totals, hosts, whether it
authenticated and when.

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

### PSCustomObject per request (or per address with -SummaryOnly),
### PSTypeName 'MsecAppGatewayClientActivity'.
## NOTES
Runs as the signed-in user against Log Analytics, like Search-MsecLogAnalytics - not as
the msec app.

## RELATED LINKS
