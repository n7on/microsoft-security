function Get-MsecIntuneAsrRule {
    <#
    .SYNOPSIS
        Every Attack Surface Reduction rule, the mode it is set to, which policy sets it, who
        that policy reaches - and the rules no policy configures at all.

    .DESCRIPTION
        ASR rules are configured as settings INSIDE endpoint security policies, so neither
        "list the policies" nor "list the settings" answers the question anyone actually has,
        which is "which rules are we enforcing, on whom, and which are we not". This flattens
        the policies into one row per rule per policy and fills in the gaps.

        THE RULES NOBODY CONFIGURED ARE THE POINT, AND THEY ARE INVISIBLE IN THE PORTAL. A
        policy blade shows the rules that policy sets; a rule set by no policy appears nowhere,
        so the gap can only be found by diffing against the full catalogue by hand. Every rule
        is emitted, with Configured = $false and Mode = $null where nothing sets it. Measured on
        one tenant: two baseline policies carrying 16 rules each, and 'Block rebooting machine
        in Safe Mode' configured in neither - a gap invisible from either policy blade.

        THE CATALOGUE COMES FROM GRAPH, NOT FROM A LIST IN THIS FILE. The rule set is read from
        the setting definitions, so a rule Microsoft adds appears here the day it ships instead
        of being silently absent until somebody updates the module. Only the GUIDs are local -
        they are not in the definitions and are what documentation and PowerShell use - and a
        rule with no GUID mapping is still emitted, with RuleId $null, rather than dropped.

        MODE IS NOT A BOOLEAN AND 'OFF' IS NOT 'NOT CONFIGURED'. A rule explicitly set to off
        in a policy that reaches a device beats a rule left unconfigured, because the explicit
        value wins conflict resolution. Those two are different rows here - Mode 'off' with
        Configured $true, against Mode $null with Configured $false - and conflating them is how
        a deliberate carve-out gets mistaken for an oversight and quietly 'fixed'.

        TWO MODES IS NOT AUTOMATICALLY A CONFLICT. The most common deliberate ASR design is a
        rule in audit for one group and block for everyone else, with the two policies excluding
        each other's groups - measured on one tenant, the single rule set to two modes was
        exactly that. So ModesDiffer is the fact, and Conflicting is the judgement: it is $true
        only where the policies do NOT carve each other out and a device may therefore receive
        both, which Intune resolves silently with the losing value shown in neither blade.
        Proving real overlap would need group membership evaluation and this does not do it, so
        Conflicting is deliberately the weaker claim of the two.

        PER-RULE EXCLUSIONS TRAVEL WITH THE RULE. Each ASR setting carries its own exclusion
        list, and an exclusion is a deliberate hole in a control - it belongs next to the mode,
        not three blades away. Excluded paths are projected to PerRuleExclusion.

        That list is nested UNDER the rule's own value rather than beside it, which the setting
        id ('<rule>_perruleexclusions') does not suggest. Read at the wrong depth it comes back
        empty, so a policy carrying a real exclusion reports none - measured on one tenant
        against a live Git exclusion. The subtree is walked rather than indexed at a fixed
        depth.

        ONLY SETTINGS CATALOG AND ENDPOINT SECURITY POLICIES ARE PARSED. ASR can also be set
        through the older intents API, classic endpoint protection profiles, Group Policy or
        local PowerShell, and none of those are read here. Where the tenant has any of the first
        two, a warning names them, because an unqualified Configured = $false would be a claim
        this command cannot support.

    .PARAMETER Rule
        Only rules whose name or slug matches this substring, case-insensitive. 'safe mode',
        'psexec', 'office'.

    .PARAMETER Mode
        Only rules set to this mode: 'block', 'audit', 'warn' or 'off'.

    .PARAMETER ConfiguredOnly
        Drop the rules no policy configures. Off by default, because those rows are usually the
        reason to run this.

    .PARAMETER NoGroupNameLookup
        Report assignment group ids instead of resolving their display names. One Graph call per
        distinct group is spent on the lookup otherwise, cached across the run.

    .EXAMPLE
        Get-MsecIntuneAsrRule | Where-Object { -not $_.Configured }

        The rules no policy sets. The gap no portal blade will show you.

    .EXAMPLE
        Get-MsecIntuneAsrRule | Where-Object Conflicting |
            Sort-Object RuleName | Format-Table RuleName, Mode, PolicyName

        Rules set to different modes by two policies. Intune picks a winner silently.

    .EXAMPLE
        Get-MsecIntuneAsrRule -Mode audit

        What is being measured rather than enforced - the staging area of an ASR rollout, and
        the set most likely to have been left there and forgotten.

    .EXAMPLE
        Get-MsecIntuneAsrRule | Where-Object PerRuleExclusion |
            Select-Object RuleName, PolicyName, PerRuleExclusion

        Every deliberate hole in an ASR rule, with the policy it lives in.

    .OUTPUTS
        PSCustomObject per rule-and-policy pair, PSTypeName 'MsecIntuneAsrRule'.

    .NOTES
        Needs 'DeviceManagementConfigurationPolicy.Read.All' or
        'DeviceManagementConfiguration.Read.All', which New-MsecApp grants, plus Group.Read.All
        for the assignment group names.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string] $Rule,

        [ArgumentCompleter({
            param($c, $p, $wordToComplete)
            @('block', 'audit', 'warn', 'off') |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        })]
        [string] $Mode,

        [switch] $ConfiguredOnly,

        [switch] $NoGroupNameLookup
    )

    Assert-MsecSession

    $base = 'device_vendor_msft_policy_config_defender_attacksurfacereductionrules'

    # The catalogue, from Graph. A hardcoded list would go stale the next time Microsoft ships
    # a rule, and the failure mode is the worst one available here: a new rule would be absent
    # from the output entirely rather than reported as unconfigured.
    $catalogue = @{}
    try {
        foreach ($def in @(Invoke-MsecGraphRequest -Path "/beta/deviceManagement/configurationSettings?`$filter=startswith(id,'$base')" -All)) {
            $id = [string] $def.id
            if (-not $id.StartsWith("$base`_", [StringComparison]::OrdinalIgnoreCase)) { continue }
            $slug = $id.Substring($base.Length + 1)
            # Each rule also has a '<slug>_perruleexclusions' definition. That is the rule's
            # exclusion list, not a rule of its own, and must not become a catalogue entry.
            if ($slug -match '_perruleexclusions$') { continue }
            $catalogue[$slug] = [string] $def.displayName
        }
    }
    catch {
        if ("$($_.Exception.Message)" -match '403|Forbidden') {
            throw "Forbidden reading the ASR setting definitions. The msec app needs 'DeviceManagementConfiguration.Read.All'. Re-run New-MsecApp if it is missing. Original error: $($_.Exception.Message)"
        }
        throw
    }
    if (-not $catalogue.Count) {
        Write-Warning "No ASR setting definitions were returned by Graph, so the full rule catalogue is unknown and UNCONFIGURED RULES CANNOT BE REPORTED. Only rules found in a policy will be listed."
    }

    # GUIDs are what Microsoft's documentation, PowerShell and the registry use, and they are
    # not in the setting definitions. Local, and additive only: a slug missing from this map
    # still produces a row, with RuleId $null.
    $guids = @{
        'blockabuseofexploitedvulnerablesigneddrivers'                              = '56a863a9-875e-4185-98a7-b882c64b5ce5'
        'blockcredentialstealingfromwindowslocalsecurityauthoritysubsystem'         = '9e6c4e1f-7d60-472f-ba1a-a39ef669e4b2'
        'blockpersistencethroughwmieventsubscription'                               = 'e6db77e5-3df2-4cf1-b95a-636979351e5b'
        'blockadobereaderfromcreatingchildprocesses'                                = '7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c'
        'blockallofficeapplicationsfromcreatingchildprocesses'                      = 'd4f940ab-401b-4efc-aadc-ad5f3c50688a'
        'blockexecutablecontentfromemailclientandwebmail'                           = 'be9ba2d9-53ea-4cdc-84e5-9b1eeee46550'
        'blockexecutablefilesrunningunlesstheymeetprevalenceagetrustedlistcriterion'= '01443614-cd74-433a-b99e-2ecdc07bfc25'
        'blockexecutionofpotentiallyobfuscatedscripts'                              = '5beb7efe-fd9a-4556-801d-275e5ffc04cc'
        'blockjavascriptorvbscriptfromlaunchingdownloadedexecutablecontent'         = 'd3e037e1-3eb8-44c8-a917-57927947596d'
        'blockofficeapplicationsfromcreatingexecutablecontent'                      = '3b576869-a4ec-4529-8536-b80a7769e899'
        'blockofficeapplicationsfrominjectingcodeintootherprocesses'                = '75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84'
        'blockofficecommunicationappfromcreatingchildprocesses'                     = '26190899-1602-49e8-8b27-eb1d0a1ce869'
        'blockprocesscreationsfrompsexecandwmicommands'                             = 'd1e49aac-8f56-4280-b9ba-993a6d77406c'
        'blockrebootingmachineinsafemode'                                           = '33ddedf1-c6e0-47cb-833e-de6133960387'
        'blockuntrustedunsignedprocessesthatrunfromusb'                             = 'b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4'
        'blockuseofcopiedorimpersonatedsystemtools'                                 = 'c0033c00-d16d-4114-a5a0-dc9b3a7d2ceb'
        'blockwebshellcreationforservers'                                           = 'a8f5898e-1dc8-49a9-9878-85004b8a61e6'
        'blockwin32apicallsfromofficemacros'                                        = '92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b'
        'useadvancedprotectionagainstransomware'                                    = 'c1db55ab-c21a-4637-bb3f-a12568109d35'
    }
    # Microsoft's own 'standard protection' set - the three it recommends enabling in Block
    # without extensive testing. Worth distinguishing from the rest when triaging a gap.
    $standard = @(
        'blockabuseofexploitedvulnerablesigneddrivers'
        'blockcredentialstealingfromwindowslocalsecurityauthoritysubsystem'
        'blockpersistencethroughwmieventsubscription'
    )

    $policies = @(Invoke-MsecGraphRequest -Path "/beta/deviceManagement/configurationPolicies?`$expand=assignments" -All) |
        Where-Object { "$($_.templateReference.templateFamily)" -eq 'endpointSecurityAttackSurfaceReduction' }

    # ASR set anywhere but a Settings Catalog / endpoint security policy is not read here, so
    # say so rather than let Configured=$false imply a completeness this cannot deliver.
    $legacy = @()
    try {
        $intents = @(Invoke-MsecGraphRequest -Path '/beta/deviceManagement/intents?$select=id,displayName' -All)
        if ($intents.Count) { $legacy += "$($intents.Count) endpoint security intent(s) ($(($intents | ForEach-Object { $_.displayName }) -join ', '))" }
    } catch { Write-Verbose "Could not check intents: $($_.Exception.Message)" }
    try {
        $classic = @(Invoke-MsecGraphRequest -Path '/v1.0/deviceManagement/deviceConfigurations' -All) |
            Where-Object { "$($_.'@odata.type')" -match 'EndpointProtection' }
        if ($classic.Count) { $legacy += "$($classic.Count) classic endpoint protection profile(s)" }
    } catch { Write-Verbose "Could not check deviceConfigurations: $($_.Exception.Message)" }

    $groupNames = @{}
    function Resolve-GroupName([string] $GroupId) {
        if (-not $GroupId) { return $null }
        if ($NoGroupNameLookup) { return $GroupId }
        if ($groupNames.ContainsKey($GroupId)) { return $groupNames[$GroupId] }
        # One request per group, not a batched $filter=id in (...): a filtered list silently
        # OMITS ids that no longer exist, so a deleted group would be indistinguishable from an
        # unreadable one. A 404 says which.
        try { $groupNames[$GroupId] = [string] (Invoke-MsecGraphRequest -Path "/v1.0/groups/$GroupId`?`$select=displayName").displayName }
        catch { $groupNames[$GroupId] = "(group $GroupId not readable)" }
        if (-not $groupNames[$GroupId]) { $groupNames[$GroupId] = "(group $GroupId has no name)" }
        $groupNames[$GroupId]
    }

    # Pass one: collect every (slug, policy) pair, so PolicyCount and Conflicting can be filled
    # in before anything is emitted. A conflict is only visible across policies.
    $found = @()
    foreach ($policy in $policies) {
        $settings = @()
        try { $settings = @(Invoke-MsecGraphRequest -Path "/beta/deviceManagement/configurationPolicies/$($policy.id)/settings" -All) }
        catch {
            Write-Warning "Could not read settings from ASR policy '$($policy.name)', so its rules are MISSING from this output rather than reported as unconfigured: $($_.Exception.Message)"
            continue
        }

        $included = @(); $excluded = @(); $allUsers = $false; $allDevices = $false
        foreach ($a in @($policy.assignments)) {
            # EVERY BRANCH BREAKS, and the exclusion test comes first. PowerShell's switch runs
            # every matching branch, not just the first, and 'exclusionGroupAssignmentTarget'
            # also matches the wildcard '*groupAssignmentTarget' - so without these the carve-out
            # groups land in the INCLUDED list as well, and 'everyone except developers' reads as
            # 'everyone, including developers'. That inverts the meaning of the policy.
            switch -Wildcard ("$($a.target.'@odata.type')") {
                '*allLicensedUsersAssignmentTarget'  { $allUsers = $true; break }
                '*allDevicesAssignmentTarget'        { $allDevices = $true; break }
                '*exclusionGroupAssignmentTarget'    { $excluded += (Resolve-GroupName $a.target.groupId); break }
                '*groupAssignmentTarget'             { $included += (Resolve-GroupName $a.target.groupId); break }
            }
        }

        foreach ($setting in $settings) {
            # DEVICE CONTROL POLICIES LIVE IN THE SAME TEMPLATE FAMILY. Intune files USB and
            # device control under Attack Surface Reduction, so templateFamily alone does not
            # mean 'ASR rules' - their settings carry entirely different definition ids, and
            # slicing those at $base.Length produced rows named 'uleid}_ruledata'. The prefix
            # test is what separates the two; the length test alone is not enough.
            foreach ($child in @($setting.settingInstance.groupSettingCollectionValue.children)) {
                $defId = [string] $child.settingDefinitionId
                if (-not $defId.StartsWith("$base`_", [StringComparison]::OrdinalIgnoreCase)) { continue }
                $slug = $defId.Substring($base.Length + 1)
                if ($slug -match '_perruleexclusions$') { continue }

                # The mode is the last segment of the choice value, which repeats the whole
                # definition id as a prefix: '..._blockrebootingmachineinsafemode_block'.
                $value = [string] $child.choiceSettingValue.value
                $ruleMode = if ($value) { ($value -split '_')[-1] } else { $null }

                # THE EXCLUSION LIST IS NESTED UNDER THE RULE, NOT BESIDE IT. The first version
                # of this looked for '<slug>_perruleexclusions' as a SIBLING in the same children
                # collection, which is the shape the id suggests and is wrong: Intune hangs it
                # off the rule's own choiceSettingValue, one level deeper. The symptom was a
                # policy with a real exclusion reporting none - the exact failure this module is
                # supposed to prevent, found only because somebody added one and it did not show.
                #
                # So the search walks the rule's subtree for the id rather than assuming a depth,
                # and still accepts a sibling in case the shape differs elsewhere.
                $exclusionId = "$defId`_perruleexclusions"
                $exclusions = @(
                    $stack = [System.Collections.Generic.Stack[object]]::new()
                    $stack.Push($child)
                    foreach ($sib in @($setting.settingInstance.groupSettingCollectionValue.children)) {
                        if ("$($sib.settingDefinitionId)" -eq $exclusionId) { $stack.Push($sib) }
                    }
                    while ($stack.Count) {
                        $node = $stack.Pop()
                        if ($null -eq $node) { continue }
                        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
                            foreach ($i in $node) { $stack.Push($i) }
                            continue
                        }
                        if ($node -isnot [psobject]) { continue }
                        if ("$($node.settingDefinitionId)" -eq $exclusionId) {
                            foreach ($v in @($node.simpleSettingCollectionValue)) {
                                if ($null -ne $v.value) { [string] $v.value }
                            }
                        }
                        foreach ($prop in $node.PSObject.Properties) {
                            if ($prop.Value -is [psobject] -or
                                ($prop.Value -is [System.Collections.IEnumerable] -and $prop.Value -isnot [string])) {
                                $stack.Push($prop.Value)
                            }
                        }
                    }
                ) | Sort-Object -Unique

                $found += [pscustomobject]@{
                    Slug       = $slug
                    Mode       = $ruleMode
                    Policy     = $policy
                    Included   = @($included)
                    Excluded   = @($excluded)
                    AllUsers   = $allUsers
                    AllDevices = $allDevices
                    Exclusions = @($exclusions)
                    Raw        = $child
                }
            }
        }
    }

    $bySlug = $found | Group-Object Slug
    $modesBySlug = @{}
    $conflictBySlug = @{}
    foreach ($g in $bySlug) {
        $modesBySlug[$g.Name] = @($g.Group | ForEach-Object { $_.Mode } | Sort-Object -Unique)

        # TWO MODES IS NOT AUTOMATICALLY A CONFLICT, and reporting it as one cries wolf at the
        # most common deliberate ASR design there is: a rule in audit for a group and in block
        # for everybody else, with the two policies carving each other out. Measured on one
        # tenant, the only rule set to two modes was exactly that, and flagging it would have
        # sent someone to "fix" a working carve-out.
        #
        # A conflict needs the same DEVICE to receive both. Proving that needs group membership
        # evaluation, which this command does not do; proving the SEPARATION is cheap and is the
        # case worth recognising - policy A includes a group that policy B explicitly excludes.
        # So: separated pairs are not conflicts, everything else is reported as a POSSIBLE one.
        $conflictBySlug[$g.Name] = $false
        if (@($modesBySlug[$g.Name]).Count -le 1) { continue }
        $hitsForSlug = @($g.Group)
        foreach ($a in $hitsForSlug) {
            foreach ($b in $hitsForSlug) {
                if ([object]::ReferenceEquals($a, $b)) { continue }
                if ("$($a.Mode)" -eq "$($b.Mode)") { continue }
                $separated = (@($a.Included | Where-Object { $b.Excluded -contains $_ }).Count -gt 0) -or
                             (@($b.Included | Where-Object { $a.Excluded -contains $_ }).Count -gt 0)
                if (-not $separated) { $conflictBySlug[$g.Name] = $true }
            }
        }
    }

    $conflicts = @($bySlug | Where-Object { $conflictBySlug[$_.Name] })
    $separatedRules = @($bySlug | Where-Object { @($modesBySlug[$_.Name]).Count -gt 1 -and -not $conflictBySlug[$_.Name] })

    # Every slug the tenant uses, plus every slug in the catalogue - so a rule Graph knows about
    # but no policy sets still gets a row, and a rule in a policy but missing from the catalogue
    # (a Microsoft addition this definitions call did not return) is never dropped.
    $allSlugs = @(@($catalogue.Keys) + @($bySlug | ForEach-Object { $_.Name }) | Sort-Object -Unique)

    foreach ($slug in $allSlugs) {
        $name = if ($catalogue.ContainsKey($slug)) { $catalogue[$slug] } else { $slug }
        if ($Rule -and "$name $slug" -notmatch [regex]::Escape($Rule)) { continue }

        $hits = @($found | Where-Object { $_.Slug -eq $slug })

        if (-not $hits.Count) {
            if ($ConfiguredOnly -or $Mode) { continue }
            [PSCustomObject]@{
                PSTypeName         = 'MsecIntuneAsrRule'
                RuleName           = $name
                RuleSlug           = $slug
                RuleId             = $(if ($guids.ContainsKey($slug)) { $guids[$slug] } else { $null })
                StandardProtection = ($standard -contains $slug)
                # $null, not 'off'. An unconfigured rule and one explicitly set to off are
                # different states and only the second one wins a policy conflict.
                Mode               = $null
                Configured         = $false
                PolicyName         = $null
                PolicyId           = $null
                PolicyLastModified = $null
                AssignedGroup      = @()
                ExcludedGroup      = @()
                AssignedAllUsers   = $false
                AssignedAllDevices = $false
                PerRuleExclusion   = @()
                PolicyCount        = 0
                ModesDiffer        = $false
                Conflicting        = $false
                Raw                = $null
            }
            continue
        }

        foreach ($hit in $hits) {
            if ($Mode -and "$($hit.Mode)" -ne $Mode) { continue }
            [PSCustomObject]@{
                PSTypeName         = 'MsecIntuneAsrRule'
                RuleName           = $name
                RuleSlug           = $slug
                RuleId             = $(if ($guids.ContainsKey($slug)) { $guids[$slug] } else { $null })
                StandardProtection = ($standard -contains $slug)
                Mode               = $hit.Mode
                Configured         = $true
                PolicyName         = [string] $hit.Policy.name
                PolicyId           = [string] $hit.Policy.id
                PolicyLastModified = $(if ($hit.Policy.lastModifiedDateTime) { [datetime] $hit.Policy.lastModifiedDateTime } else { $null })
                AssignedGroup      = $hit.Included
                ExcludedGroup      = $hit.Excluded
                AssignedAllUsers   = $hit.AllUsers
                AssignedAllDevices = $hit.AllDevices
                PerRuleExclusion   = $hit.Exclusions
                PolicyCount        = $hits.Count
                # Set in more than one policy, in more than one mode.
                ModesDiffer        = (@($modesBySlug[$slug]).Count -gt 1)
                # ...and the policies are NOT carving each other out, so a device may get both.
                Conflicting        = [bool] $conflictBySlug[$slug]
                Raw                = $hit.Raw
            }
        }
    }

    if (-not $policies.Count) {
        Write-Warning "No endpoint security Attack Surface Reduction policies were found in this tenant. Every rule is therefore reported as unconfigured - which is only the whole answer if ASR is not set through any of the surfaces this command does not read (see below)."
    }
    if ($conflicts.Count) {
        Write-Warning "$($conflicts.Count) ASR rule(s) are set to different modes by policies that do NOT carve each other out, so a device may receive both and Intune will resolve it silently: $(($conflicts | ForEach-Object { $_.Name }) -join ', '). Filter on Conflicting to see them."
    }
    if ($separatedRules.Count) {
        Write-Verbose "$($separatedRules.Count) rule(s) are set to different modes in different policies, but those policies exclude each other's groups - the usual deliberate ring design, reported as ModesDiffer rather than Conflicting: $(($separatedRules | ForEach-Object { $_.Name }) -join ', ')."
    }
    if ($legacy.Count) {
        Write-Warning "ASR can also be configured outside the policies this command reads, and this tenant has $($legacy -join ' and '). Rules reported as Configured = `$false may be set there, or through Group Policy or local PowerShell, none of which are read here."
    }
}
