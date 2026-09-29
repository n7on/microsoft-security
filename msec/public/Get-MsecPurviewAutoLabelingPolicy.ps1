function Get-MsecPurviewAutoLabelingPolicy {
    <#
    .SYNOPSIS
        Auto-labeling policies - the thing that applies a sensitivity label without a user.

    .DESCRIPTION
        A SENSITIVITY LABEL THAT NOBODY APPLIES PROTECTS NOTHING, and auto-labeling is the only
        mechanism that applies one without a person choosing it. A tenant with labels published
        and no auto-labeling policy is relying entirely on users to classify their own content,
        which is worth stating plainly in a review rather than leaving as an absence nobody
        noticed. Zero rows here is a finding, not an empty section.

        Same configured-versus-enforcing split as Get-MsecPurviewDlpPolicy: Mode carries
        'Enable', 'TestWithoutNotifications', 'TestWithNotifications' or 'Disable', and only
        'Enable' actually labels anything. Everything else simulates.

        THE COLUMN PROJECTION HERE IS UNVERIFIED AGAINST LIVE DATA. It was written on a tenant
        with no auto-labeling policies at all, and Microsoft's cmdlet reference does not document
        the returned properties, so the columns follow the DLP policy shape this cmdlet family
        shares. Nothing breaks if that is incomplete - a property PowerShell cannot find is
        $null rather than an error - and Raw carries the untouched object so a missing column can
        be recovered without a module change. Check Raw first on a tenant that actually has one.

    .PARAMETER Name
        Limit to policies whose name matches. Wildcards allowed.

    .PARAMETER IncludeRule
        Attach the policy's auto-labeling rules as a Rules property. The rules hold the
        conditions - which sensitive information types trigger the label - so a policy is not
        really reviewable without them.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecPurviewAutoLabelingPolicy | Format-Table Name, Mode, IsEnforcing, AppliedLabel

    .EXAMPLE
        # Labels that are published to users but applied by no automatic policy.
        $auto = Get-MsecPurviewAutoLabelingPolicy
        Get-MsecPurviewSensitivityLabel |
            Where-Object { $_.IsPublished -and $_.DisplayName -notin $auto.AppliedLabel }

    .OUTPUTS
        One PSCustomObject per policy, PSTypeName 'MsecPurviewAutoLabelingPolicy'.

    .NOTES
        Needs Connect-Msec; the compliance session opens on first use.

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
    Assert-MsecExoCmdlet -Name 'Get-AutoSensitivityLabelPolicy' -Feature 'auto-labeling policies'

    $policies = @(Get-AutoSensitivityLabelPolicy -ErrorAction Stop)
    if ($Name) { $policies = @($policies | Where-Object { $_.DisplayName -like $Name -or $_.Name -like $Name }) }

    $rulesByPolicy = @{}
    $ruleError = $null
    if (Get-Command Get-AutoSensitivityLabelRule -ErrorAction SilentlyContinue) {
        try {
            foreach ($rule in @(Get-AutoSensitivityLabelRule -ErrorAction Stop)) {
                $key = [string] $rule.ParentPolicyName
                if (-not $rulesByPolicy.ContainsKey($key)) { $rulesByPolicy[$key] = @() }
                $rulesByPolicy[$key] += $rule
            }
        }
        catch {
            $ruleError = $_
            Write-Warning "Could not read auto-labeling rules, so the rule columns are null rather than zero: $($_.Exception.Message)"
        }
    }
    else {
        # Absent rather than empty: the count must not read as "this policy has no conditions".
        $ruleError = 'not exposed'
        Write-Warning 'Get-AutoSensitivityLabelRule is not available in this session, so rule columns are null rather than zero.'
    }

    foreach ($policy in $policies) {
        $rules = @($rulesByPolicy[[string] $policy.Name])

        $exchange   = Resolve-MsecPurviewLocation $policy.ExchangeLocation
        $sharePoint = Resolve-MsecPurviewLocation $policy.SharePointLocation
        $oneDrive   = Resolve-MsecPurviewLocation $policy.OneDriveLocation

        $row = [PSCustomObject]@{
            PSTypeName      = 'MsecPurviewAutoLabelingPolicy'
            # Display name, with the internal one kept beside it - a renamed policy shows one in
            # the portal and keeps the other for -Identity and the rule join. See the DLP command.
            Name            = [string] $(if ($policy.DisplayName) { $policy.DisplayName } else { $policy.Name })
            InternalName    = [string] $policy.Name
            Mode            = [string] $policy.Mode
            Enabled         = [bool] $policy.Enabled
            # Only 'Enable' labels anything; every Test* mode simulates.
            IsEnforcing     = ([string] $policy.Mode -eq 'Enable')
            AppliedLabel    = [string] $policy.ApplySensitivityLabel
            ExchangeScope   = $exchange.Scope
            SharePointScope = $sharePoint.Scope
            OneDriveScope   = $oneDrive.Scope
            ExchangeCount   = $exchange.Count
            SharePointCount = $sharePoint.Count
            OneDriveCount   = $oneDrive.Count
            RuleCount       = $(if ($ruleError) { $null } else { $rules.Count })
            RuleNames       = $(if ($ruleError) { $null } else { @($rules | ForEach-Object { [string] $_.Name }) })
            CreatedBy       = [string] $policy.CreatedBy
            WhenCreatedUtc  = $policy.WhenCreated
            WhenChangedUtc  = $policy.WhenChanged
            Comment         = [string] $policy.Comment
            # The untouched object, because the projection above is unverified - see the help.
            Raw             = $policy
        }

        if ($IncludeRule) { $row | Add-Member -NotePropertyName Rules -NotePropertyValue $rules }
        $row
    }
}
