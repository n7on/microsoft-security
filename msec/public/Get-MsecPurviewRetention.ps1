function Get-MsecPurviewRetention {
    <#
    .SYNOPSIS
        Retention labels and retention policies, with whether either is actually in force.

    .DESCRIPTION
        Records management has two halves that are easy to mistake for one. A retention LABEL
        says what to do with an item; a retention POLICY says where the rule applies. A label
        with no policy publishing it does nothing at all, and the label list gives no hint of
        that - which is how a tenant ends up appearing to have retention while retaining
        nothing. Measured on one tenant: one label, published by nothing, and zero policies.

        BOTH KINDS COME BACK IN ONE STREAM, tagged by Kind ('Label' or 'Policy'), because the
        question is almost always "what retention do we have" rather than one or the other. Use
        -Kind to take a side. IsInForce is the column that matters: false on an unpublished
        label, false on a disabled policy.

        THE DEFAULT FOR A TENANT WITH NOTHING CONFIGURED IS AN EMPTY RESULT, and that is a real
        answer rather than a failure - which is exactly why the command does not throw on it.
        Callers writing a report should say "no retention is configured" rather than omitting
        the section.

    .PARAMETER Kind
        Limit to 'Label' or 'Policy'. Both by default.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecPurviewRetention | Format-Table Kind, Name, Action, Duration, IsInForce

    .EXAMPLE
        # Labels that exist but are published by no policy, so retain nothing.
        Get-MsecPurviewRetention -Kind Label | Where-Object { -not $_.IsInForce }

    .OUTPUTS
        One PSCustomObject per label or policy, PSTypeName 'MsecPurviewRetention'.

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
        [ValidateSet('Label', 'Policy')]
        [string] $Kind
    )

    Initialize-MsecExoSession -Endpoint Compliance

    # Checked per half, and only for the half actually being read: a tenant that exposes one and
    # not the other can still answer -Kind for the side that works, and the message says so.
    if (-not $Kind -or $Kind -eq 'Label') {
        Assert-MsecExoCmdlet -Name 'Get-ComplianceTag' -Feature 'retention labels' `
            -Hint 'Use -Kind Policy to read the half that is available.'
    }
    if (-not $Kind -or $Kind -eq 'Policy') {
        Assert-MsecExoCmdlet -Name 'Get-RetentionCompliancePolicy' -Feature 'retention policies' `
            -Hint 'Use -Kind Label to read the half that is available.'
    }

    if (-not $Kind -or $Kind -eq 'Label') {
        foreach ($tag in @(Get-ComplianceTag -ErrorAction Stop)) {
            [PSCustomObject]@{
                PSTypeName    = 'MsecPurviewRetention'
                Kind          = 'Label'
                Name          = [string] $tag.Name
                Action        = [string] $tag.RetentionAction
                Duration      = [string] $tag.RetentionDuration
                RetentionType = [string] $tag.RetentionType
                IsRecordLabel = [bool] $tag.IsRecordLabel
                # A label nothing publishes cannot apply to anything.
                IsInForce     = [bool] $tag.Published
                Enabled       = $null
                Locations     = $null
                Notes         = [string] $tag.Notes
                WhenChangedUtc = $tag.WhenChanged
            }
        }
    }

    if (-not $Kind -or $Kind -eq 'Policy') {
        foreach ($policy in @(Get-RetentionCompliancePolicy -ErrorAction Stop)) {
            $locations = @(
                foreach ($n in 'ExchangeLocation', 'SharePointLocation', 'OneDriveLocation',
                               'ModernGroupLocation', 'TeamsChannelLocation', 'TeamsChatLocation') {
                    $resolved = Resolve-MsecPurviewLocation $policy.$n
                    if ($resolved.Scope -ne 'None') { "$($n -replace 'Location','')=$($resolved.Scope)" }
                }
            )

            [PSCustomObject]@{
                PSTypeName    = 'MsecPurviewRetention'
                Kind          = 'Policy'
                Name          = [string] $policy.Name
                Action        = $null
                Duration      = $null
                RetentionType = $null
                IsRecordLabel = $null
                IsInForce     = [bool] $policy.Enabled
                Enabled       = [bool] $policy.Enabled
                Locations     = $locations
                Notes         = [string] $policy.Comment
                WhenChangedUtc = $policy.WhenChanged
            }
        }
    }
}
