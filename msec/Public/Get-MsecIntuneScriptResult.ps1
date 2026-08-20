function Get-MsecIntuneScriptResult {
    <#
    .SYNOPSIS
        Per-device results from every kind of Intune script - remediations, platform
        scripts, macOS custom attributes and custom compliance scripts - as flat rows, one
        per (script, device).

    .DESCRIPTION
        This is the data behind the Excel export on a script's "Device status" blade in the
        Intune portal, in PowerShell objects instead of a download.

        FIVE features, one row shape, because the question is the same one throughout: what
        did my script return, on which device, and when? These five are the complete set of
        script collections Intune exposes under /deviceManagement - taken from Graph's own
        $metadata rather than from the portal's navigation, which groups them differently.

          -Source Remediation       deviceHealthScripts
                                    Windows. The portal calls these Remediations, formerly
                                    Proactive Remediations. A detection script plus an
                                    optional remediation script, so TWO outputs per device -
                                    before and after the fix ran. The only source with two.

          -Source PlatformScript    deviceManagementScripts     (Windows, PowerShell)
                                    deviceShellScripts          (macOS, shell)
                                    One blade in the portal, two collections in Graph, one
                                    -Source here: the Platform column tells them apart, and
                                    their run states are the same Graph type.

          -Source CustomAttribute   deviceCustomAttributeShellScripts
                                    macOS. A shell script whose stdout becomes the
                                    attribute's value.

          -Source ComplianceScript  deviceComplianceScripts
                                    Windows. The discovery script behind a custom compliance
                                    policy: its stdout is the JSON the policy's rules are
                                    evaluated against, so a custom compliance policy is only
                                    ever as trustworthy as this output. Pairs with
                                    Get-MsecIntuneCompliancePolicy.

        -Source is mandatory and has no default. The features overlap in shape but not in
        meaning, and a command that silently swept all of them would make "no results"
        ambiguous between "that platform has no scripts" and "I did not ask about it". Pass
        'All' explicitly to get every source in one stream - and note that 'All' means all
        five, so it costs one request per script across the whole tenant.

        WHAT 'Output' HOLDS, per source, because this is the column you came for:

          PlatformScript    resultMessage - whatever the script wrote to stdout.
          CustomAttribute   resultMessage - the same field, and here it IS the attribute
                            value, which is the reason the attribute exists.
          ComplianceScript  scriptOutput - the JSON the compliance rules parse.
          Remediation       postRemediationDetectionScriptOutput if the remediation ran,
                            otherwise preRemediationDetectionScriptOutput. That is "the most
                            recent thing the detection script said", which is what the
                            portal's status column reflects. Both are also kept verbatim in
                            PreRemediationOutput and PostRemediationOutput, so a row where
                            the remediation changed the answer is still legible.

        NOT COVERED: userRunStates. Every one of the five also reports per-USER results, and
        a Windows platform script set to run in the user's context produces them. This
        command reads deviceRunStates only, so a user-context script's results are absent
        rather than empty - worth knowing before reading a thin result as "it has not run".

        A SCRIPT WITH NO RESULTS YIELDS NO ROWS, which is correct - nothing has run - but it
        is reported when you asked for that script by name, because silence in response to a
        specific request reads as "nothing found" rather than "nothing ran yet".

        Device names come from $expand=managedDevice in the same request, so there is no
        second lookup per device. If Graph rejects the expand, the query is retried without
        it and the device columns fall back to ids - one warning, and the script output
        itself is unaffected.

        Requires 'DeviceManagementScripts.Read.All' for the scripts and their run states, and
        'DeviceManagementManagedDevices.Read.All' to name the devices.

        The scripts scope is easy to get wrong: deviceHealthScripts and
        deviceCustomAttributeShellScripts sit under /deviceManagement alongside the
        configuration policies, but 'DeviceManagementConfiguration.Read.All' - which every
        other Intune command in msec uses - does not cover them, and they answer 403 without
        the scripts scope. If you set the app up before this command existed, re-run
        New-MsecApp to add it, then Disconnect-Msec / Connect-Msec: consent does not apply to
        a token that was already issued.

        BETA ENDPOINTS. Neither feature has a /v1.0 surface, the same situation as
        Settings Catalog policies in Get-MsecIntuneConfigurationProfile.

    .PARAMETER Source
        Which script feature to read: 'Remediation', 'PlatformScript', 'CustomAttribute',
        'ComplianceScript', or 'All' for every one of them. Mandatory - see .DESCRIPTION for
        why there is no default, and for what each one maps to in Graph.

    .PARAMETER Name
        Limit to named scripts, by display name or id, case-insensitively. An unrecognised
        name is a terminating error listing what the tenant has, rather than an empty
        result - a typo that returned nothing would read as "this script has never run".

    .EXAMPLE
        # Every Windows remediation result.
        Get-MsecIntuneScriptResult -Source Remediation

    .EXAMPLE
        # Platform scripts across both operating systems - the Platform column separates
        # the Windows PowerShell ones from the macOS shell ones.
        Get-MsecIntuneScriptResult -Source PlatformScript |
            Format-Table ScriptName, Platform, DeviceName, State, Output

    .EXAMPLE
        # Custom compliance discovery output. A device can be reported compliant on the
        # strength of whatever this returned, so it is worth reading directly.
        Get-MsecIntuneScriptResult -Source ComplianceScript |
            Where-Object State -ne 'success'

    .EXAMPLE
        # Everything, one sheet. Source and Platform keep the five features distinguishable
        # once they are in the same table.
        Get-MsecIntuneScriptResult -Source All |
            Export-Excel ./intune-scripts.xlsx -AutoSize -TableName Results -WorksheetName Results

    .EXAMPLE
        # Scripts failing anywhere, across every feature at once - the shared row shape is
        # what makes one Where-Object enough.
        Get-MsecIntuneScriptResult -Source All |
            Where-Object State -in 'fail', 'scriptError' |
            Group-Object ScriptName, State -NoElement | Sort-Object Count -Descending

    .EXAMPLE
        # The macOS custom attribute values, which is what the attribute exists to collect.
        Get-MsecIntuneScriptResult -Source CustomAttribute |
            Format-Table ScriptName, DeviceName, Output

    .EXAMPLE
        # One script, straight to a spreadsheet. msec returns rows; ImportExcel writes the
        # workbook - the module deliberately does not depend on it.
        Get-MsecIntuneScriptResult -Source Remediation -Name 'Check-BitLocker' |
            Export-Excel ./bitlocker.xlsx -AutoSize -TableName Results

    .EXAMPLE
        # Devices where the detection script found a problem and the remediation did not fix
        # it. The pair of columns is the point: same script, two different answers.
        Get-MsecIntuneScriptResult -Source Remediation |
            Where-Object { $_.RemediationState -eq 'remediationFailed' } |
            Format-Table ScriptName, DeviceName, PreRemediationOutput, Error

    .EXAMPLE
        # Group macOS devices by what the attribute actually returned - the fastest way to
        # see the spread of a value across the estate.
        Get-MsecIntuneScriptResult -Source CustomAttribute -Name 'FileVault-Status' |
            Group-Object Output | Sort-Object Count -Descending

    .EXAMPLE
        # Results that have gone stale: the script has not reported in a fortnight, so its
        # State describes a device that may have changed since.
        Get-MsecIntuneScriptResult -Source All |
            Where-Object { $_.LastStateUpdateDateTime -lt (Get-Date).AddDays(-14) }

    .OUTPUTS
        PSCustomObject per (script, device), PSTypeName 'MsecIntuneScriptResult'. See .NOTES.

    .NOTES
        Default table view (registered in msec.psm1): ScriptName, Source, DeviceName, State,
        Output. Output is last so a long script result truncates gracefully rather than
        pushing other columns off the terminal.

        Projection:
          script.id / displayName          -> ScriptId, ScriptName
          (which endpoint it came from)    -> Source    'Remediation' / 'CustomAttribute'
          (derived from Source)            -> Platform  'Windows' / 'macOS'
          managedDevice.id                 -> DeviceId
          managedDevice.deviceName         -> DeviceName
          managedDevice.userPrincipalName  -> UserPrincipalName
          detectionState | runState        -> State
          remediationState                 -> RemediationState  (Remediation only)
          (see .DESCRIPTION)               -> Output
          pre/postRemediationDetectionScriptOutput
                                           -> PreRemediationOutput, PostRemediationOutput
                                              (Remediation only)
          errorDescription | errorCode | scriptError | remediationScriptError |
          pre/post detection errors        -> Error
          lastStateUpdateDateTime          -> LastStateUpdateDateTime
          <the run-state object verbatim>  -> Raw

        Platform is derived from the collection, not read from Graph: each of the five is a
        single-OS feature, so the endpoint the row came from determines it. For
        -Source PlatformScript it is the only thing separating the Windows PowerShell
        scripts from the macOS shell ones, since both share a -Source value and a run-state
        type.

        State keeps Graph's own vocabulary ('success', 'fail', 'scriptError', 'pending',
        'notApplicable', 'unknown') rather than being prettified. The portal renders these
        as phrases like "With issues"; the raw value is what you can filter on exactly, and
        the mapping to a phrase is a presentation choice this command leaves to the caller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('Remediation', 'PlatformScript', 'CustomAttribute', 'ComplianceScript', 'All')]
        [string] $Source,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string[]] $Name
    )

    Assert-MsecSession

    # Every script collection Intune exposes under /deviceManagement, in one table - so the
    # loop below is about run states rather than about which endpoint it is talking to.
    # Verified against Graph's own $metadata: these five ARE the complete set.
    #
    # StateShape, not Source, drives the projection. Platform scripts and custom attributes
    # are different features on different operating systems, but their deviceRunStates are
    # the SAME Graph type (deviceManagementScriptDeviceState), so they share a branch. Keying
    # the projection on Source instead would have meant three copies of identical code.
    $features = @(
        @{ Source = 'Remediation'
           Platform = 'Windows'
           StateShape = 'Remediation'                                    # deviceHealthScriptDeviceState
           Collection = '/beta/deviceManagement/deviceHealthScripts'
           Label = 'Windows remediation' }

        @{ Source = 'PlatformScript'
           Platform = 'Windows'
           StateShape = 'Script'                                         # deviceManagementScriptDeviceState
           Collection = '/beta/deviceManagement/deviceManagementScripts'
           Label = 'Windows platform script' }

        # Same -Source, same Graph type, different OS and endpoint: one blade in the portal
        # ("Platform scripts"), two collections in Graph. The Platform column tells them
        # apart, which is why they do not need separate -Source values.
        @{ Source = 'PlatformScript'
           Platform = 'macOS'
           StateShape = 'Script'
           Collection = '/beta/deviceManagement/deviceShellScripts'
           Label = 'macOS platform script' }

        @{ Source = 'CustomAttribute'
           Platform = 'macOS'
           StateShape = 'Script'
           Collection = '/beta/deviceManagement/deviceCustomAttributeShellScripts'
           Label = 'macOS custom attribute' }

        @{ Source = 'ComplianceScript'
           Platform = 'Windows'
           StateShape = 'Compliance'                                     # deviceComplianceScriptDeviceState
           Collection = '/beta/deviceManagement/deviceComplianceScripts'
           Label = 'Windows custom compliance script' }
    )
    if ($Source -ne 'All') { $features = @($features | Where-Object Source -eq $Source) }

    # Reported once per run rather than per script: an expand Graph will not honour is a
    # property of the tenant's API version, not of the script being read.
    $expandState = @{ Warned = $false }

    $getRunStates = {
        param([string] $Collection, [string] $ScriptId, [string] $ScriptName)

        $base = "$Collection/$ScriptId/deviceRunStates"
        try {
            return @(Invoke-MsecGraphRequest -Path "$base`?`$expand=managedDevice" -All)
        }
        catch {
            $detail = $_.Exception.Message
            # A rejected $expand must not lose the script output, which is the point of the
            # call - so fall back to the unexpanded collection and say what was lost.
            if ($detail -match '\b400\b|BadRequest|expand') {
                if (-not $expandState.Warned) {
                    $expandState.Warned = $true
                    Write-Warning "Graph rejected `$expand=managedDevice on deviceRunStates, so DeviceName and UserPrincipalName are unavailable and DeviceId falls back to the run-state id. Script output is unaffected. Graph said: $detail"
                }
                try   { return @(Invoke-MsecGraphRequest -Path $base -All) }
                catch { Write-Warning "Could not read run states for '$ScriptName': $($_.Exception.Message)"; return @() }
            }
            Write-Warning "Could not read run states for '$ScriptName': $detail"
            return @()
        }
    }

    # ---- Pass 1: list the scripts and resolve -Name ------------------------------------
    # Resolved BEFORE any row is emitted. An unrecognised name has to be fatal (a typo that
    # returned nothing would read as "this script has never run"), and a terminating error
    # halfway through a stream leaves the caller holding a partial result that looks whole.
    $work = [System.Collections.Generic.List[object]]::new()
    $available = [System.Collections.Generic.List[string]]::new()
    $matched = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($feature in $features) {
        try {
            $scripts = @(Invoke-MsecGraphRequest -Path $feature.Collection -All)
        }
        catch {
            $detail = $_.Exception.Message
            if ($detail -match '\b403\b|Forbidden') {
                # DeviceManagementScripts.Read.All, NOT the Configuration scope every other
                # Intune command in msec uses. Both endpoints live under /deviceManagement
                # next to the configuration policies, so the obvious guess is wrong - and an
                # error naming a permission the app already holds sends the reader looking in
                # exactly the wrong place.
                throw "Forbidden when calling $($feature.Collection). The msec app needs the 'DeviceManagementScripts.Read.All' application permission (admin consent required) - Intune scripts are a SEPARATE scope from DeviceManagementConfiguration.Read.All, which does not cover them. Re-run New-MsecApp to add and consent it, then Disconnect-Msec / Connect-Msec so the new token carries it. Original error: $detail"
            }
            throw
        }

        foreach ($s in $scripts) {
            if ($s.displayName) { $available.Add("$($s.displayName) [$($feature.Label)]") }

            if (-not $Name) {
                $work.Add([pscustomobject]@{ Feature = $feature; Script = $s })
                continue
            }

            # A name matches on display name or id, case-insensitively. With -Source All it
            # only has to match ONE feature - a Windows remediation name is not expected to
            # exist among the macOS scripts - so misses are judged across both, below.
            foreach ($value in $Name) {
                $key = ([string]$value).Trim()
                if (-not $key) { continue }
                if ($key -eq [string]$s.displayName -or $key -eq [string]$s.id) {
                    $work.Add([pscustomobject]@{ Feature = $feature; Script = $s })
                    $matched.Add($key) | Out-Null
                }
            }
        }
    }

    if ($Name) {
        $missing = @($Name | Where-Object { $_ -and -not $matched.Contains(([string]$_).Trim()) })
        if ($missing.Count) {
            $plural = if ($missing.Count -gt 1) { 's' } else { '' }
            throw ("Unrecognised script name$plural`: $($missing -join ', '). Pass a script's display name or its id, exactly as Intune reports it - matching is case-insensitive. Available: $(@($available | Sort-Object -Unique) -join '; ')")
        }
        if (-not $work.Count) { return }
    }

    # ---- Pass 2: read each script's run states and emit --------------------------------
    foreach ($item in $work) {
        $feature = $item.Feature
        $s       = $item.Script

        $runStates = & $getRunStates $feature.Collection $s.id $s.displayName

        if (-not @($runStates).Count) {
            $message = "Script '$($s.displayName)' ($($feature.Label)) has no device run states - nothing has reported yet."
            # Only worth saying out loud when this script was asked for by name.
            if ($Name) { Write-Warning $message } else { Write-Verbose $message }
            continue
        }

        foreach ($r in $runStates) {
            $device = $r.managedDevice

            # One branch per deviceRunStates TYPE, not per feature - see the $features
            # table for why those are not the same thing.
            switch ($feature.StateShape) {

                # deviceHealthScriptDeviceState. The only shape with two outputs, because
                # a remediation has a before and an after.
                'Remediation' {
                    $pre  = $r.preRemediationDetectionScriptOutput
                    $post = $r.postRemediationDetectionScriptOutput
                    # The most recent thing the detection script said. Post only exists
                    # once a remediation has actually run, so pre is the answer until then.
                    $output = if ($null -ne $post -and $post -ne '') { $post } else { $pre }
                    $state  = $r.detectionState
                    $remediationState = $r.remediationState
                    # First non-empty, in the order the failures happen.
                    $errorText = @(
                        $r.preRemediationDetectionScriptError
                        $r.remediationScriptError
                        $r.postRemediationDetectionScriptError
                    ) | Where-Object { $_ } | Select-Object -First 1
                }

                # deviceComplianceScriptDeviceState. A discovery script for a custom
                # compliance policy: its stdout is the JSON the policy's rules are
                # evaluated against, so scriptOutput is the whole point of the row.
                'Compliance' {
                    $pre = $null
                    $post = $null
                    $output = $r.scriptOutput
                    $state  = $r.detectionState
                    $remediationState = $null
                    $errorText = $r.scriptError
                }

                # deviceManagementScriptDeviceState - platform scripts (both OSes) AND
                # custom attributes. Different features, identical run-state type.
                default {
                    $pre = $null
                    $post = $null
                    $output = $r.resultMessage
                    $state  = $r.runState
                    $remediationState = $null
                    $errorText = @($r.errorDescription, $r.errorCode) | Where-Object { $_ } | Select-Object -First 1
                }
            }

            [PSCustomObject]@{
                PSTypeName             = 'MsecIntuneScriptResult'

                ScriptId               = [string]$s.id
                ScriptName             = $s.displayName
                Source                 = $feature.Source
                Platform               = $feature.Platform

                # Falls back to the run-state id so a row is never unattributable, which
                # is what happens when the managedDevice expand was refused.
                DeviceId               = if ($device -and $device.id) { [string]$device.id } else { [string]$r.id }
                DeviceName             = $device.deviceName
                UserPrincipalName      = $device.userPrincipalName

                State                  = $state
                RemediationState       = $remediationState

                Output                 = $output
                PreRemediationOutput   = $pre
                PostRemediationOutput  = $post
                Error                  = $errorText

                LastStateUpdateDateTime = if ($r.lastStateUpdateDateTime) { [datetime]$r.lastStateUpdateDateTime } else { $null }

                Raw                    = $r
            }
        }
    }
}
