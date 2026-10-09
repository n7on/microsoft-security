---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Connect-MsecAdmin

## SYNOPSIS
Signs in AS YOU, with delegated write scopes, for the commands that change something.
Read commands keep using the app; this session is only for writes.

## SYNTAX

```
Connect-MsecAdmin [[-Scope] <String[]>] [[-TenantId] <String>] [-PassThru]
 [<CommonParameters>]
```

## DESCRIPTION
THE APP CANNOT DO THIS, ON PURPOSE.
Every Graph permission New-MsecApp consents is
*.Read.All, so the certificate in Key Vault cannot change anything - that is the
module's central promise and it is enforced by the token, not by naming.
Writes
therefore run as a person instead: attributable to a named account, subject to your
Conditional Access and MFA, bounded by your own Defender RBAC rather than tenant-wide
application permissions, and impossible from an unattended pipeline unless somebody
deliberately sets one up.

NOT THE -AsCurrentUser PATTERN, AND HERE IS WHY.
Connect-MsecTeams borrows the Az
context's token, which works because Azure PowerShell's first-party app holds the
scopes those commands need.
Measured on a live tenant, its Graph token carries
Application.ReadWrite.All, Group.ReadWrite.All, Directory.AccessAsUser.All and
User.Read.All - and nothing for security.
There is no SecurityAlert.ReadWrite.All in
it, so borrowing cannot resolve an alert.
This asks for consent properly instead.

CONSENT REQUESTED IS NOT CONSENT GRANTED.
Connect-MgGraph succeeds when a tenant
declines a scope; the context simply comes back without it, and the first write then
fails with a 403 that names nothing.
Every requested scope is checked against what was
actually granted, and a missing one is reported by name here rather than discovered
later.

IT WILL REFUSE A DIFFERENT TENANT FROM THE ONE YOU ARE READING.
If Connect-Msec holds
a session, this must sign in to the same tenant.
Reading one tenant and writing to
another is the kind of mistake that is obvious afterwards and invisible at the time.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec      # reads, as the app
Connect-MsecAdmin                        # writes, as you
```

### EXAMPLE 2
```
# Only what this session needs.
Connect-MsecAdmin -Scope SecurityAlert.ReadWrite.All
```

## PARAMETERS

### -Scope
Delegated scopes to request.
DEFAULTS TO EVERY SCOPE THE MODULE'S WRITE COMMANDS NEED,
so a bare Connect-MsecAdmin makes all of them work and nobody has to know which consent
belongs to which command.
Pass it explicitly for a least-privilege session covering only
what you intend to do.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: @(
            'SecurityIncident.ReadWrite.All'
            'SecurityAlert.ReadWrite.All'
            'CustomDetection.ReadWrite.All'
        )
Accept pipeline input: False
Accept wildcard characters: False
```

### -TenantId
Tenant to sign in to.
Defaults to the tenant Connect-Msec is using, which is almost
always what you want.

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

### -PassThru
Emit the Graph context as well as the summary.

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

### One PSCustomObject describing the session: Account, TenantId, GrantedScope.
## NOTES
Needs the Microsoft.Graph.Authentication module, which is NOT a dependency of msec -
it is only required by the write commands.

Disconnect with Disconnect-MgGraph.
Connect-Msec and this session are independent;
disconnecting one leaves the other alone.

## RELATED LINKS
