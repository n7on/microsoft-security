function Set-MsecDefenderAlert {
    <#
    .SYNOPSIS
        Resolve, classify or comment on Defender XDR alerts. Runs as YOU - the app cannot do this.

    .DESCRIPTION
        Requires the delegated session from Connect-MsecAdmin and refuses the app session: every
        permission New-MsecApp consents is *.Read.All, so the certificate in Key Vault could not
        do this even if asked, and failing here with a sentence beats failing later with a 403
        that names nothing.

        THE COMMENT GOES THROUGH A DIFFERENT API, AND ONLY WORKS ON ENDPOINT ALERTS. Microsoft
        Graph has no writable comment on an alert - `comments` on alerts_v2 is read-only in both
        v1.0 and beta, with no navigation property, no action, and no place in either Update
        alert doc's updatable table. The Defender for Endpoint API does have one, and its docs
        say a comment may be submitted with or without updating any other property. So -Comment
        is sent to `PATCH /api/alerts/{providerAlertId}` on the Defender host while status and
        classification go to Graph. Splitting them that way is what keeps the two vocabularies
        apart: the Defender API spells determinations `InsufficientData` and `CompromisedUser`
        and statuses `Resolved`, where Graph spells them `notEnoughDataToValidate`,
        `compromisedAccount` and `resolved`. Nothing here translates between them, because
        nothing has to.

        The catch is coverage. That API only knows endpoint alerts - measured on this tenant, 29
        of 569 over ninety days; the rest are Defender for Office 365, DLP and serviceSource
        'unknownFutureValue'. -Comment on one of those is REFUSED BY NAME, naming the alert's
        serviceSource and pointing at Set-MsecDefenderIncident -ResolvingComment, rather than
        being quietly dropped. The portal's comment box works on every alert because it uses an
        internal API that is not published.

        -Comment needs an Az sign-in as well as Connect-MsecAdmin, because the Defender host
        will not take a Graph token - different audience. The Az token carries
        user_impersonation, so the comment is bounded by your own Defender role.

        THERE IS NO CAP ON HOW MANY ALERTS IT WILL CHANGE. `Get-… | Set-…` will work through
        everything the filter selected - on this tenant `Get-MsecDefenderAlert -Status new`
        returns 201 rows. What stands between you and that is ConfirmImpact 'High', so a bare
        call prompts per alert, and -WhatIf, which lists every id it would touch and changes
        nothing. Use -WhatIf first on any pipeline you have not run before; -Confirm:$false
        turns off the only remaining prompt.

        Ids are still collected before the first write rather than acted on as they arrive, so
        duplicates in the pipeline are written once.

        IT RE-READS AFTER WRITING, AND WAITS FOR THE SERVICE TO SETTLE. The PATCH response is
        the service echoing the request; a separate GET is the service being asked what the
        alert now IS. But XDR is eventually consistent - measured live, an alert PATCHed at
        16:37:00 still read as unchanged immediately afterwards and was correct moments later -
        so the read-back polls briefly (about ten seconds at most) and stops as soon as the
        values match. A warning is raised only when a field is STILL wrong after the last read,
        which makes it worth acting on. Changed reports whether the Graph fields held;
        CommentAdded reports whether the comment was found on re-read. Either is $null when it
        could not be verified - an unverified write must never render as a confirmed one.

        DETERMINATION VALUES ARE NOT THE OBVIOUS ONES. From Graph's own $metadata:
        'notMalicious' and 'notEnoughDataToValidate', not 'clean' and 'insufficientData'.
        Microsoft's Update alert page still lists the retired names for this shared enum while
        the Update incident page and $metadata agree with the values here - so do not "fix"
        these from that page. Note too that the CSDL calls the first status member 'newAlert'
        while the wire value is 'new'; the wire value is what this takes.

    .PARAMETER Id
        Alert ids. Takes pipeline input from Get-MsecDefenderAlert by property name.

    .PARAMETER Status
        new, inProgress or resolved.

    .PARAMETER Classification
        unknown, falsePositive, truePositive or informationalExpectedActivity.

    .PARAMETER Determination
        The analyst's call on what it actually was. See the note above on the value names.

    .PARAMETER Comment
        Free text added to the alert's comment thread - the same field the portal's Classify
        alert box writes. Endpoint alerts only; see the note above.

    .PARAMETER AssignedTo
        User principal name to assign the alert to.


    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Connect-MsecAdmin

        Get-MsecDefenderAlert -Days 90 -ServiceSource microsoftDefenderForEndpoint -Status new |
            Set-MsecDefenderAlert -Status resolved -Determination notMalicious `
                -Comment 'Authorised red-team exercise, ticket SEC-88' -WhatIf

    .EXAMPLE
        # A comment on its own, with no other change - the Defender API allows that.
        Set-MsecDefenderAlert -Id $alertId -Comment 'Chasing the device owner, see SEC-91'

    .OUTPUTS
        One PSCustomObject per alert: Id, Title, Severity, ServiceSource, the status before, the
        state read back afterwards, Changed and CommentAdded.

    .NOTES
        Needs Connect-MsecAdmin with SecurityAlert.ReadWrite.All. -Comment additionally needs an
        Az context (Connect-AzAccount) and the Defender 'Alerts investigation' role.

        Resolving an alert is a state change in Defender, not a local edit, and a comment cannot
        be unsent. -WhatIf lists the ids that would be touched.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]] $Id,

        [ValidateSet('new', 'inProgress', 'resolved')]
        [string] $Status,

        [ValidateSet('unknown', 'falsePositive', 'truePositive', 'informationalExpectedActivity')]
        [string] $Classification,

        [ValidateSet('unknown', 'apt', 'malware', 'securityPersonnel', 'securityTesting',
                     'unwantedSoftware', 'other', 'multiStagedAttack', 'compromisedAccount',
                     'phishing', 'maliciousUserActivity', 'notMalicious',
                     'notEnoughDataToValidate', 'confirmedActivity', 'lineOfBusinessApplication')]
        [string] $Determination,

        [ValidateNotNullOrEmpty()]
        [string] $Comment,

        [string] $AssignedTo
    )

    begin {
        Assert-MsecAdminSession -Scope 'SecurityAlert.ReadWrite.All'

        # Graph fields only. The comment is not one of them - see the help.
        $body = [ordered]@{}
        if ($PSBoundParameters.ContainsKey('Status'))         { $body['status']         = $Status }
        if ($PSBoundParameters.ContainsKey('Classification')) { $body['classification'] = $Classification }
        if ($PSBoundParameters.ContainsKey('Determination'))  { $body['determination']  = $Determination }
        if ($PSBoundParameters.ContainsKey('AssignedTo'))     { $body['assignedTo']     = $AssignedTo }

        $wantComment = $PSBoundParameters.ContainsKey('Comment')

        if (-not $body.Count -and -not $wantComment) {
            throw ('Nothing to change. Pass at least one of -Status, -Classification, -Determination, ' +
                   '-AssignedTo or -Comment.')
        }

        # Collected rather than written as they arrive, so duplicates are written once.
        $pending = [System.Collections.Generic.List[string]]::new()

        # Alerts whose serviceSource cannot take a comment; reported once at the end.
        $refusedComment = [System.Collections.Generic.List[PSCustomObject]]::new()
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


        $parts = @($body.Keys | ForEach-Object { "$_=$($body[$_])" })
        if ($wantComment) { $parts += "comment='$Comment'" }
        $change = $parts -join ', '

        foreach ($alertId in $ids) {
            if (-not $PSCmdlet.ShouldProcess($alertId, "Set $change")) { continue }

            $before = $null
            try { $before = Invoke-MsecAdminGraphRequest -Path "/v1.0/security/alerts_v2/$alertId" }
            catch {
                Write-Warning "Could not read alert $alertId before writing, so there is nothing to compare against: $_"
            }

            # --- Graph fields ---
            $graphWritten = $false
            if ($body.Count) {
                try {
                    $null = Invoke-MsecAdminGraphRequest -Path "/v1.0/security/alerts_v2/$alertId" -Method PATCH -Body $body
                    $graphWritten = $true
                }
                catch {
                    Write-Warning "Failed to update alert $alertId - $_"
                }
            }

            # --- Comment, via the Defender for Endpoint API ---
            # $null = not asked for or not verifiable; $false = refused or failed; $true = seen
            # on re-read. Never $true just because the PATCH returned 200.
            $commentAdded = $null
            if ($wantComment) {
                $source   = [string] $before.serviceSource
                $provider = [string] $before.providerAlertId

                if (-not $before) {
                    Write-Warning "Alert $alertId could not be read, so its comment was not attempted - the Defender API needs the provider alert id."
                    $commentAdded = $false
                }
                elseif ($source -ne 'microsoftDefenderForEndpoint') {
                    # Collected, not warned about here: this rule fires identically for every
                    # non-endpoint alert, and one near-identical warning per row buries the ones
                    # that are actually specific. Summarised once after the loop instead.
                    $refusedComment.Add([PSCustomObject]@{
                        Id            = $alertId
                        ServiceSource = $source
                        IncidentId    = [string] $before.incidentId
                    })
                    $commentAdded = $false
                }
                elseif (-not $provider) {
                    Write-Warning "Alert $alertId reports no providerAlertId, which is the key the Defender API needs. Comment NOT added."
                    $commentAdded = $false
                }
                else {
                    try {
                        $null = Invoke-MsecAdminDefenderRequest -Path "/api/alerts/$provider" -Method PATCH `
                                    -Body @{ comment = $Comment }

                        # Verify against the thread rather than trusting the 200.
                        try {
                            $mde = Invoke-MsecAdminDefenderRequest -Path "/api/alerts/$provider"
                            $commentAdded = [bool] (@($mde.comments) | Where-Object { $_.comment -eq $Comment })
                            if (-not $commentAdded) {
                                Write-Warning "Alert $alertId accepted the comment but it is not in the thread on re-read."
                            }
                        }
                        catch {
                            Write-Warning "Comment on alert $alertId was accepted but the thread could not be re-read, so it is unverified: $_"
                            $commentAdded = $null
                        }
                    }
                    catch {
                        Write-Warning "Failed to comment on alert $alertId - $_"
                        $commentAdded = $false
                    }
                }
            }

            # --- Re-read the Graph side, allowing for eventual consistency ---
            # Every requested field, not just status: Defender can accept a PATCH and still not
            # hold part of it. But XDR settles asynchronously, so an immediate single read
            # reports false failures - hence the brief poll. See Get-MsecAdminWriteResult.
            $after    = $null
            $mismatch = @()
            if ($graphWritten -or -not $body.Count) {
                $verify = Get-MsecAdminWriteResult -Path "/v1.0/security/alerts_v2/$alertId" -Expected $body
                $after  = $verify.Object

                if (-not $after) {
                    Write-Warning "Alert $alertId was updated but could not be re-read, so the row below is unverified: $($verify.Error)"
                }
                elseif ($body.Count -and $verify.Mismatch.Count) {
                    $mismatch = @($verify.Mismatch)
                    Write-Warning ("Alert $alertId still does not show: $($mismatch -join ', ') after $($verify.Attempts) " +
                                   'reads. The columns below are what Defender returned, not what was requested.')
                }
            }

            [PSCustomObject]@{
                PSTypeName          = 'MsecDefenderAlertChange'
                Id                  = $alertId
                Title               = [string] $before.title
                Severity            = [string] $before.severity
                ServiceSource       = [string] $before.serviceSource
                StatusBefore        = [string] $before.status
                # $null rather than the requested value when the re-read failed: an unverified
                # write must never render as a confirmed one.
                StatusAfter         = $(if ($after) { [string] $after.status } else { $null })
                ClassificationAfter = $(if ($after) { [string] $after.classification } else { $null })
                DeterminationAfter  = $(if ($after) { [string] $after.determination } else { $null })
                AssignedToAfter     = $(if ($after) { [string] $after.assignedTo } else { $null })
                # Graph fields only; $null when none were requested or none could be verified.
                Changed             = $(if ($after -and $body.Count) { -not $mismatch.Count } else { $null })
                CommentAdded        = $commentAdded
            }
        }

        if ($refusedComment.Count) {
            $sources   = @($refusedComment.ServiceSource | Sort-Object -Unique) -join ', '
            $incidents = @($refusedComment.IncidentId | Where-Object { $_ } | Sort-Object -Unique)

            # Says what was NOT done, then hands over the command that does it. CommentAdded is
            # $false on each of those rows too - nothing was dropped quietly.
            $msg = "$($refusedComment.Count) alert(s) did not take a comment: serviceSource $sources, and the " +
                   'Defender for Endpoint API only knows endpoint alerts. Graph has no writable comment on any ' +
                   'alert, so there was nowhere to put it - see CommentAdded on the rows. '
            $msg += if ($incidents.Count) {
                "Put the note on their incident(s) instead: Set-MsecDefenderIncident -Id $($incidents -join ',') -ResolvingComment '...'"
            }
            else {
                'Put the note on the incident instead: Set-MsecDefenderIncident -ResolvingComment.'
            }
            Write-Warning $msg
        }
    }
}
