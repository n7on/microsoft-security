function Set-MsecDefenderIncident {
    <#
    .SYNOPSIS
        Resolve, classify or comment on Defender XDR incidents. Runs as YOU, through
        Connect-MsecAdmin.

    .DESCRIPTION
        THE RESOLUTION COMMENT LIVES HERE, NOT ON THE ALERT. Graph has no writable comment on
        an alert: `comments` is read-only on alerts_v2 in both v1.0 and beta, there is no
        comments navigation property and no action to add one, and neither Update alert doc
        lists it as updatable. Incidents have -ResolvingComment, described by Microsoft as
        "user input that explains the resolution of the incident and the classification
        choice" - which is the note people actually want when they close something. Alerts roll
        up into incidents, so commenting on the incident is both the supported path and the one
        an analyst reads first.

        Same guards as Set-MsecDefenderAlert. It requires the Connect-MsecAdmin session and
        refuses the app one; it collects piped ids before the first write so duplicates are written
        once; and it re-reads each incident afterwards and reports what came back,
        not what was asked for - polling briefly, because XDR settles asynchronously and a single
        immediate read reports changes as lost that in fact land a moment later.

        -CustomTags REPLACES the tag array, it does not append - that is how Graph treats the
        collection. The existing tags are shown as CustomTagsBefore so a replacement is at
        least visible; read them first if you meant to add one.

        -Status takes the values that can actually be SET. 'redirected' is excluded on purpose:
        it is what Defender assigns when it merges an incident into another, not a state you
        move an incident to. Note also that 'inProgress' and 'awaitingAction' are real - they
        are in Graph's $metadata even though the Update incident doc lists only active,
        resolved and redirected.

        DETERMINATION VALUES: 'notMalicious' and 'notEnoughDataToValidate', from $metadata.
        Microsoft's own Update alert page still lists the retired 'clean' and 'insufficientData'
        for the very same shared enum - the Update incident page and $metadata agree with each
        other and with this command, so do not "fix" these from that stale page.

    .PARAMETER Id
        Incident ids. Takes pipeline input from Get-MsecDefenderIncident by property name.

    .PARAMETER Status
        active, inProgress, awaitingAction or resolved. See the note above on 'redirected'.

    .PARAMETER Classification
        unknown, falsePositive, truePositive or informationalExpectedActivity.

    .PARAMETER Determination
        The analyst's call on what it actually was.

    .PARAMETER ResolvingComment
        Free text explaining the resolution and the classification choice.

    .PARAMETER AssignedTo
        User principal name to assign the incident to.

    .PARAMETER Severity
        Re-grade the incident: informational, low, medium or high.

    .PARAMETER CustomTags
        REPLACES the incident's custom tags. Not an append.


    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Connect-MsecAdmin -Scope SecurityIncident.ReadWrite.All

        Get-MsecDefenderIncident -Days 90 -Status active |
            Where-Object Severity -eq 'informational' |
            Set-MsecDefenderIncident -Status resolved -Classification informationalExpectedActivity `
                -Determination notMalicious -ResolvingComment 'Expected scanner activity - see CHG0042' -WhatIf

    .EXAMPLE
        Set-MsecDefenderIncident -Id 4711 -Status resolved -Classification falsePositive `
            -Determination notMalicious -ResolvingComment 'Pen test, authorised, ticket SEC-88'

    .OUTPUTS
        One PSCustomObject per incident: Id, DisplayName, Severity, the status before, the
        state read back afterwards, and Changed.

    .NOTES
        Needs Connect-MsecAdmin with SecurityIncident.ReadWrite.All.

        displayName, summary and description are updatable through Graph but are deliberately
        not exposed here - they are the incident's narrative, not a triage decision, and
        rewriting them from a pipeline is a good way to lose Defender's own text.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]] $Id,

        [ValidateSet('active', 'inProgress', 'awaitingAction', 'resolved')]
        [string] $Status,

        [ValidateSet('unknown', 'falsePositive', 'truePositive', 'informationalExpectedActivity')]
        [string] $Classification,

        [ValidateSet('unknown', 'apt', 'malware', 'securityPersonnel', 'securityTesting',
                     'unwantedSoftware', 'other', 'multiStagedAttack', 'compromisedAccount',
                     'phishing', 'maliciousUserActivity', 'notMalicious',
                     'notEnoughDataToValidate', 'confirmedActivity', 'lineOfBusinessApplication')]
        [string] $Determination,

        [string] $ResolvingComment,

        [string] $AssignedTo,

        [ValidateSet('informational', 'low', 'medium', 'high')]
        [string] $Severity,

        [string[]] $CustomTags
    )

    begin {
        Assert-MsecAdminSession -Scope 'SecurityIncident.ReadWrite.All'

        $body = [ordered]@{}
        if ($PSBoundParameters.ContainsKey('Status'))           { $body['status']           = $Status }
        if ($PSBoundParameters.ContainsKey('Classification'))   { $body['classification']   = $Classification }
        if ($PSBoundParameters.ContainsKey('Determination'))    { $body['determination']    = $Determination }
        if ($PSBoundParameters.ContainsKey('ResolvingComment')) { $body['resolvingComment'] = $ResolvingComment }
        if ($PSBoundParameters.ContainsKey('AssignedTo'))       { $body['assignedTo']       = $AssignedTo }
        if ($PSBoundParameters.ContainsKey('Severity'))         { $body['severity']         = $Severity }
        if ($PSBoundParameters.ContainsKey('CustomTags'))       { $body['customTags']       = @($CustomTags) }

        if (-not $body.Count) {
            throw ('Nothing to change. Pass at least one of -Status, -Classification, -Determination, ' +
                   '-ResolvingComment, -AssignedTo, -Severity or -CustomTags.')
        }

        # Collected rather than written as they arrive, so duplicates are written once.
        $pending = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($value in $Id) {
            $key = ([string] $value).Trim()
            if ($key) { $pending.Add($key) }
        }
    }

    end {
        $ids = @($pending | Sort-Object -Unique)
        if (-not $ids.Count) { return }


        $change = ($body.Keys | ForEach-Object {
            if ($_ -eq 'customTags') { "customTags=[$(@($CustomTags) -join '; ')]" } else { "$_=$($body[$_])" }
        }) -join ', '

        foreach ($incidentId in $ids) {
            if (-not $PSCmdlet.ShouldProcess($incidentId, "Set $change")) { continue }

            $before = $null
            try { $before = Invoke-MsecAdminGraphRequest -Path "/v1.0/security/incidents/$incidentId" }
            catch {
                Write-Warning "Could not read incident $incidentId before writing, so there is nothing to compare against: $_"
            }

            if ($PSBoundParameters.ContainsKey('CustomTags') -and $before -and @($before.customTags).Count) {
                Write-Warning ("Incident $incidentId already has tags [$(@($before.customTags) -join '; ')] and " +
                               '-CustomTags replaces rather than appends - those are about to be dropped.')
            }

            try {
                $null = Invoke-MsecAdminGraphRequest -Path "/v1.0/security/incidents/$incidentId" -Method PATCH -Body $body
            }
            catch {
                Write-Warning "Failed to update incident $incidentId - $_"
                continue
            }

            # The PATCH response echoes the request; this asks the service what the incident IS.
            # Polled rather than read once: XDR settles asynchronously and a single immediate
            # read reports changes as lost that land a moment later.
            $verify   = Get-MsecAdminWriteResult -Path "/v1.0/security/incidents/$incidentId" -Expected $body
            $after    = $verify.Object
            $mismatch = @()

            if (-not $after) {
                Write-Warning "Incident $incidentId was updated but could not be re-read, so the row below is unverified: $($verify.Error)"
            }
            elseif ($verify.Mismatch.Count) {
                $mismatch = @($verify.Mismatch)
                Write-Warning ("Incident $incidentId still does not show: $($mismatch -join ', ') after " +
                               "$($verify.Attempts) reads. The columns below are what Defender returned, " +
                               'not what was requested.')
            }

            [PSCustomObject]@{
                PSTypeName            = 'MsecDefenderIncidentChange'
                Id                    = $incidentId
                DisplayName           = [string] $before.displayName
                Severity              = [string] $before.severity
                StatusBefore          = [string] $before.status
                CustomTagsBefore      = @($before.customTags)
                # $null rather than the requested value when the re-read failed: an unverified
                # write must never render as a confirmed one.
                StatusAfter           = $(if ($after) { [string] $after.status } else { $null })
                ClassificationAfter   = $(if ($after) { [string] $after.classification } else { $null })
                DeterminationAfter    = $(if ($after) { [string] $after.determination } else { $null })
                ResolvingCommentAfter = $(if ($after) { [string] $after.resolvingComment } else { $null })
                AssignedToAfter       = $(if ($after) { [string] $after.assignedTo } else { $null })
                CustomTagsAfter       = $(if ($after) { @($after.customTags) } else { $null })
                Changed               = $(if ($after) { -not $mismatch.Count } else { $null })
            }
        }
    }
}
