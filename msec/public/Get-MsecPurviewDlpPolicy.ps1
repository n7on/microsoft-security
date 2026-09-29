function Get-MsecPurviewDlpPolicy {
    <#
    .SYNOPSIS
        Data Loss Prevention policies, one row each, with where they apply and whether they
        actually enforce.

    .DESCRIPTION
        CONFIGURED IS NOT THE SAME AS ENFORCING, and the count people quote is the configured
        one. A DLP policy has a Mode independent of its Enabled flag: 'Disable' means it does
        nothing, 'TestWithNotifications' means it reports without blocking, and only 'Enable'
        stops anything. IsEnforcing collapses that into the answer most questions actually want,
        while Mode and Enabled stay on the row so nothing is hidden behind the derivation.

        WHERE A POLICY APPLIES IS NOT A BOOLEAN. Each workload gets a Scope of All, Named or
        None, plus a count of named locations. 'All' and 'one location happening to be called
        All' are indistinguishable in the raw data until you inspect the collection, which is
        the sort of thing that turns an estate-wide policy into a footnote. NB a Named count is
        not coverage - two named SharePoint sites out of nine hundred is technically 'Named'.

        DO NOT BELIEVE THE Workload PROPERTY. It is declarative, not derived: measured live,
        every policy on one tenant listed "Exchange" in Workload while every single Exchange
        targeting property - ExchangeLocation, ExchangeSender, ExchangeSenderMemberOf,
        ExchangeAdaptiveScopes - was empty, which per Microsoft's own parameter reference means
        email is NOT included. ("If you don't want to include email messages in the policy, don't
        use this parameter.") Workload is surfaced here anyway, because reading it and believing
        email was covered is exactly the mistake this column exists to expose - WorkloadClaims is
        the list it asserts, and the *Scope columns are what is actually targeted. Where they
        disagree, the scopes are right.

        EXCHANGE IS THE ONE TO CHECK. Its location is empty on a policy that covers nothing in
        mail, and because every other workload can look healthy at the same time, an uncovered
        Exchange is easy to miss - measured on one tenant, every enforcing policy had an empty
        Exchange location.

        A RENAMED POLICY HAS TWO NAMES, AND THE PORTAL SHOWS THE ONE THIS DID NOT REPORT.
        Renaming a DLP policy changes its DisplayName and leaves Name at whatever it was created
        as, so the two drift apart the moment anyone tidies a name up. Measured live: a policy
        the portal calls "DLP - Confidential document shared" is still Name
        "TEST - Label-based DLP (pilot)" underneath. Name here is therefore the DISPLAY name -
        the one a reader can find in the portal - and InternalName carries the original, which is
        what Set-DlpCompliancePolicy -Identity and the rule join both need. -Name matches either.

        Rules are summarised on the policy row (how many, how many block, the highest severity)
        because a policy with no blocking rule enforces nothing regardless of its mode. Pass
        -IncludeRule for the rules themselves; see Get-MsecPurviewDlpRule for the detail.

    .PARAMETER Name
        Limit to policies whose display name OR internal name matches. Wildcards allowed - both
        are checked, because a renamed policy is findable under either.

    .PARAMETER IncludeRule
        Attach the policy's rules as a Rules property, in full.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecPurviewDlpPolicy | Format-Table Name, Mode, IsEnforcing, ExchangeScope, SharePointScope

    .EXAMPLE
        # The policies that CLAIM email coverage in Workload but target no mailboxes.
        Get-MsecPurviewDlpPolicy |
            Where-Object ClaimsEmailWithoutTarget |
            Format-Table Name, IsEnforcing, ExchangeScope, WorkloadClaims

    .EXAMPLE
        # Policies with no rule that blocks - on paper enforcing, in practice reporting.
        Get-MsecPurviewDlpPolicy | Where-Object { $_.IsEnforcing -and $_.BlockingRuleCount -eq 0 }

    .OUTPUTS
        One PSCustomObject per policy, PSTypeName 'MsecPurviewDlpPolicy'.

    .NOTES
        Needs Connect-Msec. The compliance session is opened automatically on first use - that
        handshake takes a few seconds and imports a few hundred cmdlets, so it is reported rather
        than done silently. Call Connect-MsecPurview yourself to control -Organization, or to
        choose when those 102 cmdlet names land in your runspace.

        Read-only.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string] $Name,

        [Parameter()]
        [switch] $IncludeRule
    )

    Initialize-MsecExoSession -Endpoint Compliance
    Assert-MsecExoCmdlet -Name 'Get-DlpCompliancePolicy' -Feature 'Data Loss Prevention policies'

    $policies = @(Get-DlpCompliancePolicy -ErrorAction Stop)
    # Either name: someone reading the portal knows the display name, someone reading a script
    # knows the internal one, and a renamed policy makes those different strings.
    if ($Name) { $policies = @($policies | Where-Object { $_.DisplayName -like $Name -or $_.Name -like $Name }) }

    # One call for every rule, then grouped in memory: the per-policy call costs a round trip
    # each and this endpoint is slow enough for that to be felt on a tenant with many policies.
    $rulesByPolicy = @{}
    $ruleError = $null
    try {
        foreach ($rule in @(Get-DlpComplianceRule -ErrorAction Stop)) {
            $key = [string] $rule.ParentPolicyName
            if (-not $rulesByPolicy.ContainsKey($key)) { $rulesByPolicy[$key] = @() }
            $rulesByPolicy[$key] += $rule
        }
    }
    catch {
        # Rule counts become $null rather than 0 - see below.
        $ruleError = $_
        Write-Warning "Could not read DLP rules, so the rule columns are null rather than zero: $($_.Exception.Message)"
    }

    $severityRank = @{ 'Low' = 1; 'Medium' = 2; 'High' = 3 }

    foreach ($policy in $policies) {
        $rules = @($rulesByPolicy[[string] $policy.Name])

        $exchange   = Resolve-MsecPurviewLocation $policy.ExchangeLocation
        $sharePoint = Resolve-MsecPurviewLocation $policy.SharePointLocation
        $oneDrive   = Resolve-MsecPurviewLocation $policy.OneDriveLocation
        $teams      = Resolve-MsecPurviewLocation $policy.TeamsLocation
        $endpoint   = Resolve-MsecPurviewLocation $policy.EndpointDlpLocation

        $maxSeverity = $null
        if (-not $ruleError -and $rules.Count) {
            $ranked = @($rules | ForEach-Object { $severityRank[[string] $_.ReportSeverityLevel] } | Where-Object { $_ })
            if ($ranked.Count) {
                $top = ($ranked | Measure-Object -Maximum).Maximum
                $maxSeverity = @($severityRank.Keys | Where-Object { $severityRank[$_] -eq $top })[0]
            }
        }

        $row = [PSCustomObject]@{
            PSTypeName        = 'MsecPurviewDlpPolicy'
            # What the portal shows. The rule join above deliberately uses $policy.Name instead -
            # ParentPolicyName tracks the internal name, never the display one.
            Name              = [string] $(if ($policy.DisplayName) { $policy.DisplayName } else { $policy.Name })
            InternalName      = [string] $policy.Name
            Renamed           = ([string] $policy.DisplayName -and [string] $policy.DisplayName -ne [string] $policy.Name)
            Mode              = [string] $policy.Mode
            Enabled           = [bool] $policy.Enabled
            # Only 'Enable' stops anything. TestWithNotifications reports and permits.
            IsEnforcing       = ([string] $policy.Mode -eq 'Enable')
            # Declarative, and routinely contradicts the scopes below - see the help.
            WorkloadClaims    = @(([string] $policy.Workload) -split ',\s*' | Where-Object { $_ })
            # True when the policy ASSERTS email coverage it does not actually have. This is the
            # single most misleading thing about a DLP policy read from PowerShell.
            ClaimsEmailWithoutTarget = (([string] $policy.Workload) -match 'Exchange' -and $exchange.Scope -eq 'None')
            ExchangeScope     = $exchange.Scope
            SharePointScope   = $sharePoint.Scope
            OneDriveScope     = $oneDrive.Scope
            TeamsScope        = $teams.Scope
            EndpointScope     = $endpoint.Scope
            ExchangeCount     = $exchange.Count
            SharePointCount   = $sharePoint.Count
            OneDriveCount     = $oneDrive.Count
            TeamsCount        = $teams.Count
            EndpointCount     = $endpoint.Count
            ExchangeNames     = $exchange.Names
            SharePointNames   = $sharePoint.Names
            OneDriveNames     = $oneDrive.Names
            TeamsNames        = $teams.Names
            EndpointNames     = $endpoint.Names
            # $null, not 0, when the rules could not be read: "no blocking rule" and "could not
            # tell" must not look alike on a control question.
            RuleCount         = $(if ($ruleError) { $null } else { $rules.Count })
            BlockingRuleCount = $(if ($ruleError) { $null } else { @($rules | Where-Object { $_.BlockAccess }).Count })
            MaxRuleSeverity   = $maxSeverity
            RuleNames         = $(if ($ruleError) { $null } else { @($rules | ForEach-Object { [string] $_.Name }) })
            CreatedBy         = [string] $policy.CreatedBy
            WhenCreatedUtc    = $policy.WhenCreated
            WhenChangedUtc    = $policy.WhenChanged
            Comment           = [string] $policy.Comment
        }

        if ($IncludeRule) {
            $row | Add-Member -NotePropertyName Rules -NotePropertyValue $rules
        }

        $row
    }
}
