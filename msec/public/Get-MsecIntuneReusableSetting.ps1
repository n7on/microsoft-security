function Get-MsecIntuneReusableSetting {
    <#
    .SYNOPSIS
        Intune reusable settings - the device groups and setting blocks that endpoint security
        policies point at - with how many policies reference each, and what is inside them.

    .DESCRIPTION
        A Device Control policy says "Allow only authorized USBs" and then references a reusable
        setting by GUID. The policy is the rule; the reusable setting is the ANSWER - which USB
        devices, by serial number. Reading the policy alone tells you a decision is being made
        and not what it decides.

        AN UNREFERENCED REUSABLE SETTING IS A LEFTOVER, AND INTUNE DOES NOT CLEAN THEM UP.
        Deleting a policy leaves its reusable settings behind, unreferenced and invisible -
        measured on one tenant, deleting two Device Control policies left two orphans that no
        blade shows as unused. ReferencingPolicyCount is the whole point: zero means nothing
        uses it, and that is a finding rather than a state to tidy away silently.

        THE REFERENCE COUNT AND THE CONTENTS ARE BOTH ABSENT WITHOUT AN EXPLICIT $SELECT. A
        plain GET of this collection returns id, displayName, description, settingDefinitionId
        and lastModifiedDateTime - and silently omits referencingConfigurationPolicyCount and
        settingInstance. Not an error, not an empty value: the properties simply are not there,
        so code that reads them gets $null and reports every setting as unreferenced and empty.
        This command always asks for them.

        ID IS THE JOIN TO THE POLICY. A Device Control policy's rule carries
        `groupid = <guid>`, and that guid is this object's Id. Get-MsecIntuneAsrRule shows the
        raw guid; this is what turns it into a name and a list of devices.

        ENTRIES ARE THE ACCESS-CONTROL LIST. For a Device Control group they are the permitted
        (or denied) devices, each with a friendly name and a serial number or instance path.
        They are projected because an allow-list nobody can read is an allow-list nobody
        reviews - measured on one tenant, 17 entries mixing asset-tagged sticks with 'New test'
        and 'Feng's USB STICK', last edited with no owner and no review date.

    .PARAMETER Name
        Substring match on the display name, case-insensitive.

    .PARAMETER UnreferencedOnly
        Only settings no policy references - the leftovers.

    .EXAMPLE
        Get-MsecIntuneReusableSetting -UnreferencedOnly

        Reusable settings nothing points at. These survive the deletion of the policy that used
        them and are invisible in the portal's policy list.

    .EXAMPLE
        Get-MsecIntuneReusableSetting -Name 'Authorized USBs' | Select-Object -ExpandProperty Entries

        The actual USB allow-list behind "Allow only authorized USBs".

    .EXAMPLE
        Get-MsecIntuneReusableSetting | Format-Table DisplayName, ReferencingPolicyCount, EntryCount, LastModified

        Everything, with how many policies use each and how big it is.

    .OUTPUTS
        PSCustomObject per reusable setting, PSTypeName 'MsecIntuneReusableSetting'.

    .NOTES
        Needs 'DeviceManagementConfiguration.Read.All', which New-MsecApp grants.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $Name,

        [switch] $UnreferencedOnly
    )

    Assert-MsecSession

    # EVERY ONE OF THESE IS LOAD-BEARING. Without the $select, referencingConfigurationPolicyCount
    # and settingInstance are absent from the response rather than null, and the command would
    # report every setting as orphaned and empty.
    $select = @(
        'id'
        'displayName'
        'description'
        'settingDefinitionId'
        'lastModifiedDateTime'
        'referencingConfigurationPolicyCount'
        'settingInstance'
    ) -join ','

    try {
        $settings = @(Invoke-MsecGraphRequest -Path "/beta/deviceManagement/reusablePolicySettings?`$select=$select" -All)
    }
    catch {
        if ("$($_.Exception.Message)" -match '403|Forbidden') {
            throw "Forbidden reading reusable policy settings. The msec app needs 'DeviceManagementConfiguration.Read.All'. Re-run New-MsecApp if it is missing. Original error: $($_.Exception.Message)"
        }
        throw
    }

    if (-not $settings.Count) {
        Write-Verbose 'No reusable policy settings exist in this tenant.'
        return
    }

    foreach ($s in $settings) {
        if ($Name -and "$($s.displayName)" -notmatch [regex]::Escape($Name)) { continue }

        # The count is an integer that is legitimately 0. Tested for presence rather than
        # truthiness, so a missing property is reported as $null - unknown - and never as zero,
        # which would read as "orphaned" and could get something deleted that is in use.
        $refCount = if ($null -ne $s.referencingConfigurationPolicyCount) { [int] $s.referencingConfigurationPolicyCount } else { $null }

        if ($UnreferencedOnly -and $refCount -ne 0) { continue }

        # Walk the setting instance for the leaf values that describe each entry. The shape
        # nests differently per setting type, so this collects name/serial/path wherever they
        # appear rather than assuming a fixed depth.
        $names = [System.Collections.Generic.List[string]]::new()
        $ids = [System.Collections.Generic.List[string]]::new()
        $stack = [System.Collections.Generic.Stack[object]]::new()
        if ($s.settingInstance) { $stack.Push($s.settingInstance) }
        while ($stack.Count) {
            $node = $stack.Pop()
            if ($null -eq $node) { continue }
            if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
                foreach ($i in $node) { $stack.Push($i) }
                continue
            }
            if ($node -isnot [psobject]) { continue }

            $defId = [string] $node.settingDefinitionId
            $value = $node.simpleSettingValue.value
            if ($null -ne $value -and $defId) {
                switch -Wildcard ($defId) {
                    '*_name'            { $names.Add([string] $value); break }
                    '*serialnumberid'   { $ids.Add([string] $value); break }
                    '*instancepathid'   { $ids.Add([string] $value); break }
                    '*deviceid'         { $ids.Add([string] $value); break }
                }
            }
            foreach ($prop in $node.PSObject.Properties) {
                if ($prop.Value -is [psobject] -or ($prop.Value -is [System.Collections.IEnumerable] -and $prop.Value -isnot [string])) {
                    $stack.Push($prop.Value)
                }
            }
        }

        # The kind, from the setting definition. 'policygroups' is a Device Control device
        # group; firewall rule collections and others appear here too.
        $kind = switch -Wildcard ([string] $s.settingDefinitionId) {
            '*devicecontrol_policygroups*' { 'DeviceControlGroup'; break }
            '*firewall*'                   { 'FirewallRule'; break }
            default                        { [string] $s.settingDefinitionId }
        }

        [PSCustomObject]@{
            PSTypeName             = 'MsecIntuneReusableSetting'
            # What a policy's `groupid` points at - the join to Get-MsecIntuneAsrRule's raw output.
            Id                     = [string] $s.id
            DisplayName            = "$($s.displayName)".Trim()
            Description            = [string] $s.description
            Kind                   = $kind
            SettingDefinitionId    = [string] $s.settingDefinitionId
            ReferencingPolicyCount = $refCount
            # $null when the count is unknown, never $true - deleting something on a guess is
            # the one outcome worth designing against here.
            IsUnreferenced         = if ($null -eq $refCount) { $null } else { $refCount -eq 0 }
            EntryCount             = $names.Count
            Entries                = $names.ToArray()
            EntryIdentifiers       = $ids.ToArray()
            LastModified           = if ($s.lastModifiedDateTime) { [datetime] $s.lastModifiedDateTime } else { $null }
            Raw                    = $s
        }
    }
}
