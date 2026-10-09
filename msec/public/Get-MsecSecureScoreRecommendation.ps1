function Get-MsecSecureScoreRecommendation {
    <#
    .SYNOPSIS
        Microsoft Secure Score recommended actions as flat rows - what is not done, how many
        points it is worth, and the remediation text - joined from the live control scores and
        the control profiles.

    .DESCRIPTION
        This is the list the Defender portal shows under Secure Score > Recommended actions.
        Get-MsecSecureScore answers "what is the score and how has it moved"; this answers
        "what would move it, and what does each one cost".

        IT IS A JOIN OF TWO ENDPOINTS AND THEY DO NOT COVER THE SAME SET. The current state
        lives in the newest /security/secureScores snapshot's controlScores collection; the
        title, remediation, rank and impact live in /security/secureScoreControlProfiles.
        Measured on one tenant: 244 control scores against 462 profiles. The mismatch is not
        an error - a profile exists for products the tenant does not license - but it means
        the join has to be explicit about which side a row came from:

          Matched        both sides present. The normal case.
          ScoreOnly      a control is being scored with no profile to describe it. Title and
                         Remediation are $null rather than invented, and the row is still
                         emitted - a scored control that nothing can explain is worth seeing.
          ProfileOnly    only with -IncludeNotApplicable. Microsoft publishes the action but
                         this tenant is not being scored on it, usually a licensing gap.
                         CurrentScore is $null, NOT zero: nought points earned and not being
                         measured at all are different facts.

        'on' IS THE STRING "false", NOT A BOOLEAN. Graph returns it as text, so
        `if ($control.on)` is true for both states and silently reports every control as
        enabled. It is converted here, and left $null when absent.

        implementationStatus IS FREE TEXT AND SOMETIMES HTML. Real values from one tenant
        include '0/128 exposed devices' and a paragraph of markup listing preset policy
        coverage. It is passed through untouched because it is genuinely useful to read, but
        nothing should parse it - the numbers in it move without notice.

        AN IGNORED CONTROL IS NOT A COMPLETED ONE. controlStateUpdates.state carries Default,
        Ignored, ThirdParty or Reviewed. A control someone marked Ignored still shows zero
        points earned, so a naive "points available" list presents a deliberate decision as
        outstanding work. State is a column, and -State filters on it.

    .PARAMETER Category
        Identity, Device, Apps, Data or Infrastructure. Tab completes but accepts anything, so
        a category Microsoft adds later is not silently unreachable.

    .PARAMETER State
        Only controls in these review states. Tab completes against the known values but
        accepts anything - this tenant returns AlternateMitigation, which is not in the
        documented list.

    .PARAMETER IncludeCompleted
        Also return controls with no points left. Off by default - this command is the
        recommended-actions list, and a finished control is not a recommended action.

    .PARAMETER IncludeDeprecated
        Also return controls whose profile is marked deprecated. Off by default: Microsoft
        retires actions and they linger in the profile list.

    .PARAMETER IncludeNotApplicable
        Also return ProfileOnly rows - published actions this tenant is not scored on.

    .EXAMPLE
        Get-MsecSecureScoreRecommendation | Sort-Object PointsAvailable -Descending |
            Select-Object -First 10 Title, Category, PointsAvailable, UserImpact

        The ten actions worth the most points.

    .EXAMPLE
        Get-MsecSecureScoreRecommendation -Category Identity |
            Where-Object { $_.UserImpact -eq 'Low' } | Sort-Object Rank

        Identity actions that do not inconvenience anyone, in Microsoft's own priority order.

    .EXAMPLE
        Get-MsecSecureScoreRecommendation -State Ignored -IncludeCompleted |
            Select-Object Title, PointsAvailable, StateUpdatedBy, StateComment

        What has been dismissed, by whom, and what it is costing. Worth re-reading periodically
        - an Ignored control is a risk acceptance that nothing expires.

    .OUTPUTS
        One PSCustomObject per control, PSTypeName 'MsecSecureScoreRecommendation'.

    .NOTES
        Needs Connect-Msec. Reads with SecurityEvents.Read.All, which New-MsecApp grants.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            'Identity', 'Device', 'Apps', 'Data', 'Infrastructure' |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
                }
        })]
        [string[]] $Category,

        # ArgumentCompleter, NOT ValidateSet. The documented states are Default, Ignored,
        # ThirdParty and Reviewed - but this tenant also returns AlternateMitigation, which a
        # ValidateSet would have made unreachable. Microsoft adds these without notice.
        [Parameter()]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            'Default', 'Ignored', 'ThirdParty', 'Reviewed', 'AlternateMitigation' |
                Where-Object { $_ -like "$wordToComplete*" } |
                ForEach-Object {
                    [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
                }
        })]
        [string[]] $State,

        [Parameter()] [switch] $IncludeCompleted,
        [Parameter()] [switch] $IncludeDeprecated,
        [Parameter()] [switch] $IncludeNotApplicable
    )

    Assert-MsecSession

    # Newest snapshot only. The history is Get-MsecSecureScore's job; mixing the two here
    # would mean a "recommended action" list that is partly out of date depending on row.
    $snapshots = @(Invoke-MsecGraphRequest -Path '/v1.0/security/secureScores' -All)
    if (-not $snapshots.Count) {
        Write-Warning 'No Secure Score snapshots returned. That is not the same as a score of zero - check the app has SecurityEvents.Read.All and that Secure Score is enabled for this tenant.'
        return
    }
    $snapshot = $snapshots | Sort-Object { [datetime]$_.createdDateTime } | Select-Object -Last 1
    Write-Verbose "Using snapshot $($snapshot.createdDateTime): $($snapshot.currentScore)/$($snapshot.maxScore) across $(@($snapshot.controlScores).Count) controls."

    $profiles = @(Invoke-MsecGraphRequest -Path '/v1.0/security/secureScoreControlProfiles' -All)
    $byId = @{}
    foreach ($p in $profiles) { if ($p.id) { $byId[[string]$p.id] = $p } }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $emit = {
        param($control, $profile, $source)

        $name = if ($control) { [string]$control.controlName } else { [string]$profile.id }
        [void]$seen.Add($name)

        # maxScore lives on the profile. Without one there is no denominator, so points
        # available is unknowable - $null, not the current score subtracted from nothing.
        $max  = if ($profile -and $null -ne $profile.maxScore) { [double]$profile.maxScore } else { $null }
        $cur  = if ($control -and $null -ne $control.score)    { [double]$control.score }    else { $null }
        $left = if ($null -ne $max -and $null -ne $cur) { [math]::Round($max - $cur, 2) } else { $null }

        $stateUpdate = $profile.controlStateUpdates
        if ($stateUpdate -is [System.Array]) { $stateUpdate = $stateUpdate | Select-Object -Last 1 }

        [PSCustomObject]@{
            PSTypeName           = 'MsecSecureScoreRecommendation'
            ControlName          = $name
            Title                = if ($profile) { [string]$profile.title } else { $null }
            Category             = if ($control) { [string]$control.controlCategory } elseif ($profile) { [string]$profile.controlCategory } else { $null }
            Service              = if ($profile) { [string]$profile.service } else { $null }
            Source               = $source
            CurrentScore         = $cur
            MaxScore             = $max
            PointsAvailable      = $left
            PercentComplete      = if ($control -and $null -ne $control.scoreInPercentage) { [math]::Round([double]$control.scoreInPercentage, 1) } else { $null }
            # Graph sends "true"/"false" as TEXT. Converted once, here, so no caller has to
            # remember that a non-empty string is always truthy.
            Enabled              = if ($control -and $control.on -ne $null -and "$($control.on)" -ne '') { "$($control.on)" -eq 'true' } else { $null }
            State                = if ($stateUpdate) { [string]$stateUpdate.state } else { $null }
            StateUpdatedBy       = if ($stateUpdate) { [string]$stateUpdate.updatedBy } else { $null }
            StateUpdatedUtc      = if ($stateUpdate -and $stateUpdate.updatedDateTime) { [datetime]$stateUpdate.updatedDateTime } else { $null }
            StateComment         = if ($stateUpdate) { [string]$stateUpdate.comment } else { $null }
            Rank                 = if ($profile -and $null -ne $profile.rank) { [int]$profile.rank } else { $null }
            Tier                 = if ($profile) { [string]$profile.tier } else { $null }
            ActionType           = if ($profile) { [string]$profile.actionType } else { $null }
            UserImpact           = if ($profile) { [string]$profile.userImpact } else { $null }
            ImplementationCost   = if ($profile) { [string]$profile.implementationCost } else { $null }
            Threats              = @(if ($profile) { $profile.threats })
            Deprecated           = if ($profile -and $null -ne $profile.deprecated) { [bool]$profile.deprecated } else { $null }
            # Free text, sometimes HTML. Useful to read, unsafe to parse - see the help.
            ImplementationStatus = if ($control) { [string]$control.implementationStatus } else { $null }
            Description          = if ($control) { [string]$control.description } else { $null }
            Remediation          = if ($profile) { [string]$profile.remediation } else { $null }
            RemediationImpact    = if ($profile) { [string]$profile.remediationImpact } else { $null }
            ActionUrl            = if ($profile) { [string]$profile.actionUrl } else { $null }
            LastSyncedUtc        = if ($control -and $control.lastSynced) { [datetime]$control.lastSynced } else { $null }
            SnapshotUtc          = [datetime]$snapshot.createdDateTime
            Raw                  = [PSCustomObject]@{ Control = $control; Profile = $profile }
        }
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($control in @($snapshot.controlScores)) {
        $id = [string]$control.controlName
        $profile = if ($id -and $byId.ContainsKey($id)) { $byId[$id] } else { $null }
        $source = if ($profile) { 'Matched' } else { 'ScoreOnly' }
        $rows.Add((& $emit $control $profile $source))
    }
    if ($IncludeNotApplicable) {
        foreach ($p in $profiles) {
            if ($p.id -and -not $seen.Contains([string]$p.id)) { $rows.Add((& $emit $null $p 'ProfileOnly')) }
        }
    }

    $unmatched = @($rows | Where-Object Source -eq 'ScoreOnly').Count
    if ($unmatched) {
        Write-Verbose "$unmatched scored control(s) have no published profile, so their Title and Remediation are null. They are still returned."
    }

    $out = $rows
    if ($Category)           { $out = $out | Where-Object { $_.Category -in $Category } }
    if ($State)              { $out = $out | Where-Object { $_.State -in $State } }
    if (-not $IncludeDeprecated) { $out = $out | Where-Object { $_.Deprecated -ne $true } }
    # $null PointsAvailable is kept: unknown is not the same as nothing left to do.
    if (-not $IncludeCompleted)  { $out = $out | Where-Object { $_.PointsAvailable -ne 0 } }

    $out | Sort-Object @{ e = 'PointsAvailable'; Descending = $true }, Rank
}
