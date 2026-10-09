---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecIntuneReusableSetting

## SYNOPSIS
Intune reusable settings - the device groups and setting blocks that endpoint security
policies point at - with how many policies reference each, and what is inside them.

## SYNTAX

```
Get-MsecIntuneReusableSetting [[-Name] <String>] [-UnreferencedOnly]
 [<CommonParameters>]
```

## DESCRIPTION
A Device Control policy says "Allow only authorized USBs" and then references a reusable
setting by GUID.
The policy is the rule; the reusable setting is the ANSWER - which USB
devices, by serial number.
Reading the policy alone tells you a decision is being made
and not what it decides.

AN UNREFERENCED REUSABLE SETTING IS A LEFTOVER, AND INTUNE DOES NOT CLEAN THEM UP.
Deleting a policy leaves its reusable settings behind, unreferenced and invisible -
measured on one tenant, deleting two Device Control policies left two orphans that no
blade shows as unused.
ReferencingPolicyCount is the whole point: zero means nothing
uses it, and that is a finding rather than a state to tidy away silently.

THE REFERENCE COUNT AND THE CONTENTS ARE BOTH ABSENT WITHOUT AN EXPLICIT $SELECT.
A
plain GET of this collection returns id, displayName, description, settingDefinitionId
and lastModifiedDateTime - and silently omits referencingConfigurationPolicyCount and
settingInstance.
Not an error, not an empty value: the properties simply are not there,
so code that reads them gets $null and reports every setting as unreferenced and empty.
This command always asks for them.

ID IS THE JOIN TO THE POLICY.
A Device Control policy's rule carries
\`groupid = \<guid\>\`, and that guid is this object's Id.
Get-MsecIntuneAsrRule shows the
raw guid; this is what turns it into a name and a list of devices.

ENTRIES ARE THE ACCESS-CONTROL LIST.
For a Device Control group they are the permitted
(or denied) devices, each with a friendly name and a serial number or instance path.
They are projected because an allow-list nobody can read is an allow-list nobody
reviews - measured on one tenant, 17 entries mixing asset-tagged sticks with 'New test'
and 'Feng's USB STICK', last edited with no owner and no review date.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecIntuneReusableSetting -UnreferencedOnly
```

Reusable settings nothing points at.
These survive the deletion of the policy that used
them and are invisible in the portal's policy list.

### EXAMPLE 2
```
Get-MsecIntuneReusableSetting -Name 'Authorized USBs' | Select-Object -ExpandProperty Entries
```

The actual USB allow-list behind "Allow only authorized USBs".

### EXAMPLE 3
```
Get-MsecIntuneReusableSetting | Format-Table DisplayName, ReferencingPolicyCount, EntryCount, LastModified
```

Everything, with how many policies use each and how big it is.

## PARAMETERS

### -Name
Substring match on the display name, case-insensitive.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -UnreferencedOnly
Only settings no policy references - the leftovers.

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

### PSCustomObject per reusable setting, PSTypeName 'MsecIntuneReusableSetting'.
## NOTES
Needs 'DeviceManagementConfiguration.Read.All', which New-MsecApp grants.

## RELATED LINKS
