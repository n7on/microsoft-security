---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Connect-MsecTeams

## SYNOPSIS
Signs the MicrosoftTeams module in using the msec session's tokens, so Get-Cs* commands
run as the msec app without its private key leaving Key Vault.
With -AsCurrentUser,
signs in as you instead, reusing the Azure session you already have.

## SYNTAX

```
Connect-MsecTeams [-AsCurrentUser] [[-MinimumMinutes] <Int32>]
 [<CommonParameters>]
```

## DESCRIPTION
Teams admin policies are NOT in Microsoft Graph.
Meeting policies, federation
configuration, app permission policies - the settings that decide whether anonymous
users can join a meeting or staff can chat with anyone outside the tenant - live behind
the Teams admin API and are reachable only through the MicrosoftTeams module.
That is
why this exists rather than another Invoke-MsecGraphRequest.

TWO TOKENS, NOT ONE.
Connect-MicrosoftTeams -AccessTokens takes an ARRAY: one for
Microsoft Graph and one for the 'Skype and Teams Tenant Admin API'.
They are separate
audiences with separate app roles, and passing only the Graph token fails in a way that
looks like a permission problem rather than a missing token.
In app mode both are
minted the same way - a JWT client assertion signed inside Key Vault.

TEAMS NEEDS A DIRECTORY ROLE, like Exchange does.
App roles alone are not enough for
app-only Teams administration: the service principal must also hold Teams
Administrator, Teams Communications Administrator, or Global Reader for read-only work.
Without one the connection succeeds and every Get-Cs* call then fails.

-AsCurrentUser EXISTS BECAUSE INTERACTIVE SIGN-IN IS BROKEN ON MACOS AND LINUX.
Connect-MicrosoftTeams's browser flow calls into kernel32.dll, which is Windows-only,
so it dies with a dlopen error that says nothing about authentication.
Device code flow
is the documented workaround and Conditional Access usually refuses it - a policy
requiring a compliant device cannot be satisfied by a flow where the device entering
the code is not the device being authenticated.
Reusing the Az session sidesteps both:
that session already cleared Conditional Access, and no new interactive auth happens.

THIS IS THE ONE PLACE msec HANDS OVER AN IDENTITY THAT CAN WRITE.
msec has no Set-*
commands and never will, but -AsCurrentUser connects with your rights - so whatever you
can change in the Teams admin centre, you can change from this shell afterwards.
App
mode holds Global Reader and cannot.

THE MODULE IS NOT AN msec DEPENDENCY.
It is imported only when this command is called.

## EXAMPLES

### EXAMPLE 1
```
-ClientId <guid>
Get-MsecTeamsPolicy
```

### EXAMPLE 2
```
# Read as the app, then change something as yourself.
Connect-AzAccount
Connect-MsecTeams -AsCurrentUser
Get-CsTeamsFilesPolicy -Identity Global
Set-CsTeamsFilesPolicy -Identity Global -FileSharingInChatswithExternalUsers Disabled
```

## PARAMETERS

### -AsCurrentUser
Connect as the signed-in Azure user rather than as the msec app, taking both tokens
from the current Az context.
Needs Connect-AzAccount, not Connect-Msec.

Writing needs Teams Administrator on YOUR account.
Global Reader authenticates fine and
then refuses every Set-Cs*, with an error that names no permission.

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

### -MinimumMinutes
Fail unless both tokens have at least this long left.
Default 5.

```yaml
Type: Int32
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: 5
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

## NOTES
Needs Connect-Msec (or -AsCurrentUser and an Az context), and the MicrosoftTeams module
- which is NOT a dependency of msec.
Verified against MicrosoftTeams 7.9.0.

Disconnect with Disconnect-MicrosoftTeams.

## RELATED LINKS
