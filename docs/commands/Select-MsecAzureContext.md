---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Select-MsecAzureContext

## SYNOPSIS
Switches to one of your already-signed-in Azure contexts.
Pick the subscription by
name (or id), then the user account if more than one is signed in to it - the
account implies the tenant, so you never deal with tenant ids.
Warns if the switch
leaves your msec app session (Connect-Msec) on a different tenant or cloud.

## SYNTAX

```
Select-MsecAzureContext [-Subscription] <String> [[-User] <String>] [-NoConnect] [<CommonParameters>]
```

## DESCRIPTION
msec uses two identities: your Az context (for ARM / Key Vault / VM run-commands)
and the app-only session from Connect-Msec (for Graph / Defender).
This is the one
deliberate place to move the Az context, choosing among the contexts Az has ALREADY
saved for you (Get-AzContext -ListAvailable) - one per (account, tenant,
subscription, cloud) you've signed in to.

  1.
-Subscription matches a saved context by subscription name or id (tab-completes
     the distinct subscription names).
  2.
-User disambiguates when the same subscription is signed in under more than one
     account (tab-completes the accounts available for the chosen -Subscription).
     Because an account belongs to a tenant, picking the user settles the tenant -
     no tenant id needed.
  3.
The matching context is activated (Select-AzContext).
  4.
If a Connect-Msec session exists and the new context is in a different tenant or
     cloud, Graph/Defender calls would still use the OLD session, so it tells you to
     re-run Connect-Msec.

If the subscription has no saved context yet, sign in first: Connect-AzAccount
\[-Tenant \<id\>\] \[-Environment \<cloud\>\].
Cross-CLOUD moves always need that - a single
Az session is one cloud at a time.

RECONNECTS THE MSEC APP SESSION TO MATCH, when the tenant being switched to has been
connected before.
msec runs on TWO identities - the Az context is you, the msec session
is the app registration - and switching one used to leave the other pointing at the
tenant you just left, so Graph and Defender calls kept answering for the wrong tenant.
Connect-Msec remembers the vault, client id and certificate name per tenant; this
replays them.

No secret is stored and none is needed: signing happens inside Key Vault and the
private key never leaves it.
A tenant with no saved profile behaves as before - the
context switches and a warning says the session is now misaligned.
-NoConnect skips
the reconnect entirely.

A failed reconnect does NOT fail the switch.
The context change is what was asked for
and it stands; the reconnect is a convenience, and losing it warns rather than throws.

## EXAMPLES

### EXAMPLE 1
```
Select-MsecAzureContext -Subscription 'we-prod-sub'
```

### EXAMPLE 2
```
# Same subscription name signed in under two accounts - pick the user:
Select-MsecAzureContext -Subscription PROD -User admin@partner.onmschina.cn
```

## PARAMETERS

### -Subscription
Subscription name or id of the saved context to switch to.
Tab-completes the
distinct subscription names of your signed-in contexts.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -User
Account (sign-in name) owning the context, used when the same subscription is signed
in under more than one account.
Tab-completes the accounts available for the chosen
-Subscription.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -NoConnect
Switch the Azure context only - do not reconnect the msec app session even if this
tenant has a saved profile.

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

### PSCustomObject: SubscriptionName, SubscriptionId, TenantId, Environment, Account.
## NOTES

## RELATED LINKS
