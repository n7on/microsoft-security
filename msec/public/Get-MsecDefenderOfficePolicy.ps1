function Get-MsecDefenderOfficePolicy {
    <#
    .SYNOPSIS
        The Defender for Office 365 and Exchange Online Protection policies that filter mail -
        anti-phishing, Safe Links, Safe Attachments, anti-spam, anti-malware, outbound spam -
        as one row per setting, with whether the policy applies to anyone.

    .DESCRIPTION
        msec already reads Exchange MAIL FLOW: transport rules, remote domains, outbound
        forwarding. This reads the protection stack sitting on top of it, which is where
        phishing and malware are actually caught or missed.

        A POLICY THAT APPLIES TO NOBODY IS THE POINT, not an empty result. In Exchange Online
        Protection a policy and the rule that applies it are separate objects, and a custom
        policy with no rule is inert however carefully it was written. Every row therefore
        carries IsApplied and AppliedBy, so `Where-Object { -not $_.IsApplied }` is the whole
        question.

        HOW A POLICY COMES TO APPLY, in the order this command tests:
          Default    - IsDefault. Applies to everyone not matched by something above it. Never
                       has a rule, and must not be reported as unapplied.
          Preset     - named by an enabled EOP or ATP protection policy rule (the Standard and
                       Strict preset security policies). These also have no rule of their own,
                       for the same reason. Microsoft evaluates presets BEFORE custom policies,
                       so a weak custom policy does not necessarily win just by existing.
          Built-in   - Microsoft's Built-In Protection Policy, the floor for Safe Links and
                       Safe Attachments.
          Rule       - a custom policy named by its own *Rule. AppliedTo carries the rule's
                       recipient conditions.
          (none)     - a custom policy no rule references. Inert.

        PRESET POLICIES ARE NOT MISCONFIGURATION. Reporting 'Strict Preset Security Policy' as
        unapplied because Get-AntiPhishRule does not mention it would be crying wolf on the one
        configuration Microsoft most recommends.

        ADVANCED DELIVERY IS REPORTED AS UNREADABLE WHERE IT CANNOT BE READ. The phishing
        simulation and SecOps overrides fail server-side under an app-only session on at least
        some tenants, and 'could not read' must not render as 'not configured' - that is the
        difference between a tenant with a phishing-simulation exemption and one without.

    .PARAMETER PolicyType
        Which areas to read. Default is all of them.

    .PARAMETER UnappliedOnly
        Only policies that currently apply to nobody.

    .PARAMETER All
        Every property of every policy, not just the security-relevant projection.

    .EXAMPLE
        Get-MsecDefenderOfficePolicy -UnappliedOnly

        Policies someone wrote that are not in force.

    .EXAMPLE
        Get-MsecDefenderOfficePolicy -PolicyType AntiSpam |
            Where-Object Setting -eq 'AllowedSenderDomains'

        Domains exempted from spam filtering - an allow list here bypasses filtering entirely.

    .EXAMPLE
        Get-MsecDefenderOfficePolicy -PolicyType Preset

        Which preset security policies are on, and who they cover.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('Preset', 'AntiPhish', 'SafeLinks', 'SafeAttachment', 'AntiSpam',
                     'AntiMalware', 'OutboundSpam', 'AdvancedDelivery')]
        [string[]] $PolicyType = @('Preset', 'AntiPhish', 'SafeLinks', 'SafeAttachment',
                                   'AntiSpam', 'AntiMalware', 'OutboundSpam', 'AdvancedDelivery'),

        [switch] $UnappliedOnly,

        [switch] $All
    )

    Initialize-MsecExoSession -Endpoint Exchange

    # Which settings matter, per area. Written out rather than derived: "which of these two
    # hundred properties is a security control" is a judgement the reader must be able to check.
    $projection = @{
        AntiPhish = @{
            Policy = 'Get-AntiPhishPolicy'; Rule = 'Get-AntiPhishRule'; Link = 'AntiPhishPolicy'
            Settings = @(
                'Enabled'
                'PhishThresholdLevel'                   # 1 is the least aggressive of four
                'EnableSpoofIntelligence'
                'AuthenticationFailAction'
                'HonorDmarcPolicy'
                'EnableFirstContactSafetyTips'
                'EnableTargetedUserProtection'          # impersonation of named people
                'TargetedUserProtectionAction'          # 'NoAction' detects and does nothing
                'EnableTargetedDomainsProtection'
                'EnableOrganizationDomainsProtection'
                'TargetedDomainProtectionAction'
                'EnableMailboxIntelligence'
                'EnableMailboxIntelligenceProtection'
                'MailboxIntelligenceProtectionAction'
                'EnableUnauthenticatedSender'
                'EnableViaTag'
            )
        }
        SafeLinks = @{
            Policy = 'Get-SafeLinksPolicy'; Rule = 'Get-SafeLinksRule'; Link = 'SafeLinksPolicy'
            Settings = @(
                'EnableSafeLinksForEmail'; 'EnableSafeLinksForTeams'; 'EnableSafeLinksForOffice'
                'ScanUrls'
                'DeliverMessageAfterScan'               # false delivers before the verdict
                'EnableForInternalSenders'              # a compromised insider is a sender too
                'TrackClicks'
                'AllowClickThrough'                     # true lets the user ignore the warning
                'DisableUrlRewrite'
                'DoNotRewriteUrls'                      # an allow list, so worth reading
            )
        }
        SafeAttachment = @{
            Policy = 'Get-SafeAttachmentPolicy'; Rule = 'Get-SafeAttachmentRule'; Link = 'SafeAttachmentPolicy'
            Settings = @('Enable'; 'Action'; 'QuarantineTag'; 'Redirect'; 'RedirectAddress')
        }
        AntiSpam = @{
            Policy = 'Get-HostedContentFilterPolicy'; Rule = 'Get-HostedContentFilterRule'; Link = 'HostedContentFilterPolicy'
            Settings = @(
                'SpamAction'; 'HighConfidenceSpamAction'
                'PhishSpamAction'; 'HighConfidencePhishAction'
                'BulkSpamAction'; 'BulkThreshold'; 'MarkAsSpamBulkMail'
                'SpamZapEnabled'; 'PhishZapEnabled'
                # Allow lists here skip filtering for a whole domain and are trivially spoofed.
                'AllowedSenderDomains'; 'AllowedSenders'
                'BlockedSenderDomains'; 'BlockedSenders'
                'InlineSafetyTipsEnabled'; 'EnableEndUserSpamNotifications'
            )
        }
        AntiMalware = @{
            Policy = 'Get-MalwareFilterPolicy'; Rule = 'Get-MalwareFilterRule'; Link = 'MalwareFilterPolicy'
            Settings = @(
                'EnableFileFilter'; 'FileTypeAction'; 'FileTypes'
                'ZapEnabled'; 'QuarantineTag'
                'EnableInternalSenderAdminNotifications'
            )
        }
        OutboundSpam = @{
            Policy = 'Get-HostedOutboundSpamFilterPolicy'; Rule = 'Get-HostedOutboundSpamFilterRule'; Link = 'HostedOutboundSpamFilterPolicy'
            Settings = @(
                'RecipientLimitExternalPerHour'; 'RecipientLimitInternalPerHour'; 'RecipientLimitPerDay'
                'ActionWhenThresholdReached'
                'AutoForwardingMode'                    # also surfaced by Get-MsecExchangeOrganizationSetting
                'BccSuspiciousOutboundMail'; 'NotifyOutboundSpam'
            )
        }
    }

    $read = {
        param($Cmdlet, $Label)
        try { ,@(& $Cmdlet -ErrorAction Stop) }
        catch {
            Write-Warning "Could not read $Label via $Cmdlet, so it is NOT covered by this output - which is not the same as it being absent. Exchange said: $($_.Exception.Message)"
            ,$null
        }
    }

    $unreadableRow = {
        param($Type, $Name)
        [PSCustomObject]@{
            PSTypeName = 'MsecDefenderOfficePolicy'
            PolicyType = $Type; PolicyName = $Name
            Setting = $null; Value = $null
            IsDefault = $null; IsApplied = $null; AppliedBy = $null; AppliedTo = $null
        }
    }

    # The preset rules name the policies they apply, so one read answers "is this policy a
    # preset that is switched on" for every area at once.
    $presetFor = @{}
    $presetRules = @()
    foreach ($c in 'Get-EOPProtectionPolicyRule', 'Get-ATPProtectionPolicyRule') {
        $rules = & $read $c 'preset security policy rules'
        if ($null -eq $rules) { continue }
        $presetRules += @($rules)
        foreach ($rule in @($rules)) {
            foreach ($link in 'AntiPhishPolicy', 'HostedContentFilterPolicy', 'MalwareFilterPolicy',
                              'SafeLinksPolicy', 'SafeAttachmentPolicy') {
                $named = [string] $rule.$link
                if ($named) {
                    $presetFor[$named] = [pscustomobject]@{
                        RuleName = [string] $rule.Name
                        State    = [string] $rule.State
                        Scope    = (@(
                            foreach ($p in 'SentTo', 'SentToMemberOf', 'RecipientDomainIs') {
                                if ($rule.$p -and @($rule.$p).Count) { "$p=$((@($rule.$p)) -join ';')" }
                            }) -join ' ')
                    }
                }
            }
        }
    }

    if ($PolicyType -contains 'Preset') {
        if (-not $presetRules) { & $unreadableRow 'Preset' 'Unreadable' }
        foreach ($rule in $presetRules) {
            # A preset rule with no recipient condition is NOT self-evidently tenant-wide, and
            # guessing either way would be worse than saying so.
            $scope = (@(
                foreach ($p in 'SentTo', 'SentToMemberOf', 'RecipientDomainIs') {
                    if ($rule.$p -and @($rule.$p).Count) { "$p=$((@($rule.$p)) -join ';')" }
                }) -join ' ')

            foreach ($pair in @(
                @{ S = 'State';    V = [string] $rule.State }
                @{ S = 'Priority'; V = [string] $rule.Priority }
                @{ S = 'Scope';    V = if ($scope) { $scope } else { '(no recipient condition returned - confirm in the portal)' } }
            )) {
                [PSCustomObject]@{
                    PSTypeName = 'MsecDefenderOfficePolicy'
                    PolicyType = 'Preset'
                    PolicyName = [string] $rule.Name
                    Setting    = $pair.S
                    Value      = $pair.V
                    IsDefault  = $false
                    IsApplied  = ([string] $rule.State -eq 'Enabled')
                    AppliedBy  = 'Preset'
                    AppliedTo  = if ($scope) { $scope } else { $null }
                }
            }
        }
    }

    foreach ($type in @($PolicyType | Where-Object { $_ -notin 'Preset', 'AdvancedDelivery' })) {
        $spec = $projection[$type]

        $policies = & $read $spec.Policy "$type policies"
        if ($null -eq $policies) { & $unreadableRow $type 'Unreadable'; continue }

        # A missing rule list is not an empty one: without it, every custom policy would be
        # reported inert.
        $rules = & $read $spec.Rule "$type rules"
        $rulesRead = $null -ne $rules

        foreach ($policy in $policies) {
            $name = [string] $policy.Name
            if (-not $name) { $name = [string] $policy.Identity }

            $isDefault = [bool] $policy.IsDefault
            $preset    = $presetFor[$name]
            $rule      = if ($rulesRead) {
                @($rules | Where-Object { [string] $_.($spec.Link) -eq $name })[0]
            } else { $null }

            # Order matters: a default or preset policy legitimately has no rule.
            $appliedBy = $null; $appliedTo = $null; $isApplied = $null
            if ($isDefault) {
                $appliedBy = 'Default'; $isApplied = $true
                $appliedTo = 'everyone not matched by a higher-priority policy'
            }
            elseif ($preset) {
                $appliedBy = "Preset: $($preset.RuleName)"
                $isApplied = ($preset.State -eq 'Enabled')
                $appliedTo = if ($preset.Scope) { $preset.Scope } else { $null }
            }
            elseif ($name -like '*Built-In Protection*') {
                $appliedBy = 'Built-in'; $isApplied = $true
                $appliedTo = 'Microsoft baseline, minus any exclusions'
            }
            elseif ($rule) {
                $appliedBy = "Rule: $([string] $rule.Name)"
                $isApplied = ([string] $rule.State -eq 'Enabled')
                $appliedTo = (@(
                    foreach ($p in 'SentTo', 'SentToMemberOf', 'RecipientDomainIs') {
                        if ($rule.$p -and @($rule.$p).Count) { "$p=$((@($rule.$p)) -join ';')" }
                    }) -join ' ')
            }
            elseif ($rulesRead) {
                # Custom, rules were read, nothing references it. Inert.
                $isApplied = $false
            }
            # else: rules unreadable - IsApplied stays $null rather than claiming inert.

            if ($UnappliedOnly -and $isApplied -ne $false) { continue }

            $settings = if ($All) {
                @($policy.PSObject.Properties.Name | Where-Object { $_ -notin 'Name', 'Identity' })
            }
            else {
                # Only properties this object actually carries: the set moves between service
                # versions, and asking for an absent one emits a null that reads as "off".
                @($spec.Settings | Where-Object { $_ -in $policy.PSObject.Properties.Name })
            }

            foreach ($setting in $settings) {
                $value = $policy.$setting
                if ($null -ne $value -and $value -isnot [string] -and $value -is [System.Collections.IEnumerable]) {
                    $value = (@($value) | ForEach-Object { "$_" }) -join '; '
                }

                [PSCustomObject]@{
                    PSTypeName = 'MsecDefenderOfficePolicy'
                    PolicyType = $type
                    PolicyName = $name
                    Setting    = $setting
                    Value      = [string] $value
                    IsDefault  = $isDefault
                    IsApplied  = $isApplied
                    AppliedBy  = $appliedBy
                    AppliedTo  = if ($appliedTo) { $appliedTo } else { $null }
                }
            }
        }
    }

    if ($PolicyType -contains 'AdvancedDelivery') {
        foreach ($pair in @(
            @{ C = 'Get-PhishSimOverridePolicy'; N = 'Phishing simulation override' }
            @{ C = 'Get-SecOpsOverridePolicy';   N = 'SecOps mailbox override' }
        )) {
            $got = & $read $pair.C $pair.N
            if ($null -eq $got) { & $unreadableRow 'AdvancedDelivery' $pair.N; continue }
            if (-not @($got).Count) {
                # Genuinely read and genuinely empty, which is a real and different answer.
                [PSCustomObject]@{
                    PSTypeName = 'MsecDefenderOfficePolicy'
                    PolicyType = 'AdvancedDelivery'; PolicyName = $pair.N
                    Setting = 'Configured'; Value = 'False'
                    IsDefault = $false; IsApplied = $false; AppliedBy = $null; AppliedTo = $null
                }
                continue
            }
            foreach ($o in @($got)) {
                [PSCustomObject]@{
                    PSTypeName = 'MsecDefenderOfficePolicy'
                    PolicyType = 'AdvancedDelivery'; PolicyName = $pair.N
                    Setting = 'Enabled'; Value = [string] $o.Enabled
                    IsDefault = $false
                    IsApplied = [bool] $o.Enabled
                    AppliedBy = 'AdvancedDelivery'; AppliedTo = $null
                }
            }
        }
    }
}
