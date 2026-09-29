function Set-MsecDefenderAlert {
    <#
    .SYNOPSIS
        Resolve, classify or assign Defender XDR alerts. Runs as YOU - the app cannot do this.

    .DESCRIPTION
        Requires the delegated session from Connect-MsecAdmin and refuses the app session: every
        permission New-MsecApp consents is *.Read.All, so the certificate in Key Vault could not
        do this even if asked, and failing here with a sentence beats failing later with a 403
        that names nothing.

        ONE IDENTITY THROUGHOUT. Every call this command makes goes through that one delegated
        session. That is deliberate and was not always true: a -Comment switch existed briefly,
        routed to the Defender for Endpoint API on a separate Az-context token, which put two
        different user identities inside a single command - the alert could be resolved by one
        person and commented by another.

        THERE IS NO COMMENT HERE. Microsoft Graph has no writable comment on an alert -
        `comments` on alerts_v2 is read-only in v1.0 and beta alike, with no navigation property
        and no action. The Defender for Endpoint API does have one, but it only knows ENDPOINT
        alerts: measured on one tenant, 29 of 569, and none of the alerts anyone actually
        triaged. Covering five per cent of the fleet did not justify a second authentication
        path inside one command.

        Put the note on the incident instead - Set-MsecDefenderIncident -ResolvingComment, which
        Microsoft describes as explaining the resolution and the classification choice, and which
        works for every incident whatever its alerts came from.

        THERE IS NO CAP ON HOW MANY ALERTS IT WILL CHANGE. `Get-… | Set-…` works through
        everything the filter selected - on one tenant `Get-MsecDefenderAlert -Status new`
        returns 201 rows. What stands between you and that is ConfirmImpact 'High', so a bare
        call prompts per alert, and -WhatIf, which lists every id it would touch and changes
        nothing. Use -WhatIf first on any pipeline you have not run before; -Confirm:$false
        turns off the only remaining prompt.

        Ids are collected before the first write rather than acted on as they arrive, so
        duplicates in the pipeline are written once.

        IT RE-READS AFTER WRITING, AND WAITS FOR THE SERVICE TO SETTLE. The PATCH response is
        the service echoing the request; a separate GET is the service being asked what the
        alert now IS. But XDR is eventually consistent - measured live, an alert PATCHed at
        16:37:00 still read as unchanged immediately afterwards and was correct moments later -
        so the read-back polls briefly (about ten seconds at most) and stops as soon as the
        values match. A warning is raised only when a field is STILL wrong after the last read,
        which makes it worth acting on. Changed is $null when it could not be verified - an
        unverified write must never render as a confirmed one.

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

    .PARAMETER AssignedTo
        User principal name to assign the alert to.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Connect-MsecAdmin

        Get-MsecDefenderAlert -Days 90 -Severity informational -Status new |
            Set-MsecDefenderAlert -Status resolved -Determination notMalicious -WhatIf

        Shows exactly which alerts would change, and nothing else. Drop -WhatIf once the list
        is the list you meant.

    .EXAMPLE
        Set-MsecDefenderAlert -Id $alertId -Status inProgress -AssignedTo me@contoso.com

        One alert, taken for investigation.

    .OUTPUTS
        One PSCustomObject per alert: Id, Title, Severity, ServiceSource, the status before, the
        state read back afterwards, and Changed.

    .NOTES
        Needs Connect-MsecAdmin with SecurityAlert.ReadWrite.All. One identity throughout: every
        call this command makes goes through that delegated session.

        Resolving an alert is a state change in Defender, not a local edit. -WhatIf lists the
        ids that would be touched.
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

        [string] $AssignedTo
    )

    begin {
        Assert-MsecAdminSession -Scope 'SecurityAlert.ReadWrite.All'

        $body = [ordered]@{}
        if ($PSBoundParameters.ContainsKey('Status'))         { $body['status']         = $Status }
        if ($PSBoundParameters.ContainsKey('Classification')) { $body['classification'] = $Classification }
        if ($PSBoundParameters.ContainsKey('Determination'))  { $body['determination']  = $Determination }
        if ($PSBoundParameters.ContainsKey('AssignedTo'))     { $body['assignedTo']     = $AssignedTo }

        if (-not $body.Count) {
            throw ('Nothing to change. Pass at least one of -Status, -Classification, -Determination ' +
                   'or -AssignedTo.')
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

        $change = ($body.Keys | ForEach-Object { "$_=$($body[$_])" }) -join ', '

        foreach ($alertId in $ids) {
            if (-not $PSCmdlet.ShouldProcess($alertId, "Set $change")) { continue }

            $before = $null
            try { $before = Invoke-MsecAdminGraphRequest -Path "/v1.0/security/alerts_v2/$alertId" }
            catch {
                Write-Warning "Could not read alert $alertId before writing, so there is nothing to compare against: $_"
            }

            $graphWritten = $false
            try {
                $null = Invoke-MsecAdminGraphRequest -Path "/v1.0/security/alerts_v2/$alertId" -Method PATCH -Body $body
                $graphWritten = $true
            }
            catch {
                Write-Warning "Failed to update alert $alertId - $_"
            }

            # Re-read, allowing for eventual consistency - see Get-MsecAdminWriteResult.
            $after    = $null
            $mismatch = @()
            if ($graphWritten) {
                $verify = Get-MsecAdminWriteResult -Path "/v1.0/security/alerts_v2/$alertId" -Expected $body
                $after  = $verify.Object

                if (-not $after) {
                    Write-Warning "Alert $alertId was updated but could not be re-read, so the row below is unverified: $($verify.Error)"
                }
                elseif ($verify.Mismatch.Count) {
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
                Changed             = $(if ($after) { -not $mismatch.Count } else { $null })
            }
        }
    }
}
