function Get-MsecPurviewActivity {
    <#
    .SYNOPSIS
        Purview Activity Explorer events - DLP rule matches, label applications and file activity
        - one row each, with policy, rule and label names resolved.

    .DESCRIPTION
        The only way to measure DLP and labelling in a tenant without Defender for Cloud Apps.
        Advanced hunting has no DLP table, and CloudAppEvents is empty unless Defender for Cloud
        Apps is onboarded, so Export-ActivityExplorerData is where these questions are answered:
        how often a DLP rule actually fires, which policy fired it, who triggered it, and which
        sensitivity labels are being applied where.

        THE API HAS THREE WAYS OF SILENTLY RETURNING NOTHING, and this command exists mostly to
        stop each of them from reading as "there was no activity".

        A WINDOW OF 30 DAYS OR MORE RETURNS A COMPLETELY EMPTY RESPONSE - no rows, no total, no
        result code, and NO error. 29 days works and returns everything. Measured directly: 29
        days returned 143,952 events and 30 days returned nothing at all. -Days is therefore
        capped at 29 rather than the 30 the documentation implies, because the 30th day does not
        return less, it returns silence.

        THE FILTER TAKES THE ActivityId TOKEN, NOT THE DISPLAYED NAME. 'DLPRuleMatch' returns
        matches; 'DLP rule matched' - the string the portal and the Activity column both show -
        returns an empty result rather than an error. -Activity therefore validates against the
        token form and tells you the mapping, so a filter can't quietly match nothing.

        A SINGLE CALL RETURNS ONE PAGE, NOT THE RESULT SET. The response carries
        TotalResultCount for the whole query and at most PageSize rows, and paging continues
        through WaterMark until LastPage. Reading one page and summarising it gives an answer
        that looks complete and is a sample - a 5,000-row page of a 29,000-row week is 17% of
        it. This command pages to the end and warns if it stopped early, and the row count it
        returns is always comparable with TotalResultCount.

        NESTED FIELDS ARE FLATTENED because the useful ones are not top-level. PolicyName and
        RuleName live inside PolicyMatchInfo, so grouping by PolicyName on the raw output
        silently groups everything under one blank key. SensitivityLabel is a bare GUID, which
        is resolved to the label's display name - and left as the GUID, prefixed, when the label
        no longer exists, because a deleted label still appears in historical events.

        Runs as the msec app through the compliance endpoint, like the other Purview commands.
        Needs a role group that exposes Export-ActivityExplorerData - Global Reader is enough.

    .PARAMETER Days
        How far back to look. Default 7, maximum 29 - see the description; 30 returns silence.

    .PARAMETER Activity
        One or more ActivityId tokens, filtered server-side. Observed in this tenant:
        DLPRuleMatch, DlpClassification, LabelApplied, LabelChanged, FileCreated, FileModified,
        FileRead, FileRenamed, FileArchived, FilePrinted, FileCopiedToNetworkShare,
        FileUploadedToCloud, ArchiveCreated, CopilotInteraction. Not a ValidateSet - Microsoft
        adds activity types, and rejecting an unknown one here would hide activity rather than
        reveal it.

    .PARAMETER MaxEvents
        Row ceiling. Default 50000. Hitting it warns, because a truncated pull that looks
        complete is the failure this command is built around.

    .EXAMPLE
        Get-MsecPurviewActivity -Days 7 -Activity DLPRuleMatch |
            Group-Object PolicyName, RuleName, Workload | Select-Object Count, Name

        Which DLP policies actually fired, where, and how often.

    .EXAMPLE
        Get-MsecPurviewActivity -Days 7 -Activity LabelApplied |
            Group-Object SensitivityLabelName, Workload | Sort-Object Count -Descending

        Where each sensitivity label is really being applied - the denominator for any
        label-conditioned DLP policy.

    .EXAMPLE
        Get-MsecPurviewActivity -Days 7 -Activity DLPRuleMatch |
            Where-Object PolicyName -like '*Confidential*' |
            Select-Object Happened, User, Workload, ItemName

        Whether a specific policy has fired at all. An empty result here is a real answer,
        because the pull is complete and the window is within the measured ceiling.

    .EXAMPLE
        Get-MsecPurviewActivity -Days 1 | Group-Object Activity | Sort-Object Count -Descending

        What Activity Explorer is recording at all, to find the token for a narrower query.

    .OUTPUTS
        PSCustomObject per event, PSTypeName 'MsecPurviewActivity'.

    .NOTES
        Connect-MsecPurview must have been run. SensitiveInfoTypeData and PolicyMatchInfo are
        returned whole as RawSensitiveInfo and RawPolicyMatch for the detail this command does
        not flatten.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateRange(1, 29)]
        [int] $Days = 7,

        [Parameter()]
        [string[]] $Activity,

        [Parameter()]
        [ValidateRange(1, 500000)]
        [int] $MaxEvents = 50000
    )

    if (-not (Get-Command Export-ActivityExplorerData -ErrorAction SilentlyContinue)) {
        throw 'Export-ActivityExplorerData is not available. Run Connect-MsecPurview first; if it has been run, the connecting identity is in no role group that exposes Activity Explorer.'
    }

    # The displayed name is not the filter token, and passing one returns an empty result rather
    # than an error - the single most expensive mistake available against this API.
    $displayToToken = @{
        'DLP rule matched'             = 'DLPRuleMatch'
        'Classification stamped'       = 'DlpClassification'
        'Label applied'                = 'LabelApplied'
        'Label changed'                = 'LabelChanged'
        'File created'                 = 'FileCreated'
        'File modified'                = 'FileModified'
        'File read'                    = 'FileRead'
        'File renamed'                 = 'FileRenamed'
        'File printed'                 = 'FilePrinted'
        'File copied to network share' = 'FileCopiedToNetworkShare'
        'File copied to cloud'         = 'FileUploadedToCloud'
        'Archive created'              = 'ArchiveCreated'
        'Copilot Interaction'          = 'CopilotInteraction'
    }
    foreach ($a in $Activity) {
        if ($displayToToken.ContainsKey($a)) {
            throw "-Activity takes the ActivityId token, not the displayed name. Use '$($displayToToken[$a])' instead of '$a' - the displayed form returns an empty result rather than an error."
        }
    }

    $start = (Get-Date).AddDays(-$Days).Date
    $end   = (Get-Date).Date

    $events = [System.Collections.Generic.List[object]]::new()
    $watermark = $null
    $total = $null
    $pages = 0
    $lastPage = $false

    do {
        $p = @{ StartTime = $start; EndTime = $end; OutputFormat = 'Json'; PageSize = 5000 }
        if ($Activity)  { $p['Filter1']    = @('Activity') + $Activity }
        if ($watermark) { $p['PageCookie'] = $watermark }

        $response = Export-ActivityExplorerData @p

        # The 30-day failure mode: a response object with every field empty. Checking the rows
        # alone cannot tell it apart from a genuinely quiet window, so the result code is what
        # is tested - a successful query always sets one.
        if ($pages -eq 0 -and -not $response.ResultCode) {
            throw ("Activity Explorer returned an empty response for a {0}-day window (no rows, no total, no result code, no error). Windows of 30 days or more do this; 29 days and under work. Reduce -Days." -f $Days)
        }

        if ($null -eq $total) { $total = [int]($response.TotalResultCount ?? 0) }

        # A valid empty result carries a null ResultData - zero events matched the filter, which
        # is an answer, not a failure. ConvertFrom-Json throws on null, so it is guarded rather
        # than letting "nothing matched" surface as an error.
        if ($response.ResultData) {
            $rows = $response.ResultData | ConvertFrom-Json
            if ($rows) { $events.AddRange(@($rows)) }
        }

        $watermark = $response.WaterMark
        $lastPage  = [bool]$response.LastPage
        $pages++
    } while ($watermark -and -not $lastPage -and $events.Count -lt $MaxEvents)

    if ($events.Count -ge $MaxEvents) {
        Write-Warning ("Stopped at the -MaxEvents ceiling of {0}; {1} event(s) match. Anything you measure from this is a sample, not the window." -f $MaxEvents, $total)
    }
    elseif ($total -and $events.Count -lt $total) {
        # Activity Explorer's own total drifts slightly between pages as new events land, so a
        # small shortfall is normal and a large one is not. Reporting both numbers lets the
        # caller judge rather than trusting a count that might be 17% of the answer.
        $shortfall = $total - $events.Count
        if ($shortfall -gt [math]::Max(200, $total * 0.02)) {
            Write-Warning ("Pulled {0} of {1} event(s) over {2} page(s) - {3} short. Treat aggregates as a sample." -f $events.Count, $total, $pages, $shortfall)
        }
    }

    Write-Verbose ("Pulled {0} of {1} event(s) over {2} page(s) for a {3}-day window." -f $events.Count, $total, $pages, $Days)

    # Label GUID -> display name. Built once; a label deleted since the event was recorded will
    # not resolve, and is reported as its GUID rather than as a blank that reads like "no label".
    $labelNames = @{}
    try {
        foreach ($l in Get-Label -ErrorAction Stop) { $labelNames[[string]$l.Guid] = [string]$l.DisplayName }
    }
    catch {
        Write-Verbose "Could not read sensitivity labels; SensitivityLabelName will carry GUIDs."
    }

    foreach ($e in $events) {
        $labelId = [string]$e.SensitivityLabel
        $labelName = if (-not $labelId) { $null }
                     elseif ($labelNames.ContainsKey($labelId)) { $labelNames[$labelId] }
                     else { "(deleted or unknown label $labelId)" }

        [PSCustomObject]@{
            PSTypeName           = 'MsecPurviewActivity'
            Happened             = if ($e.Happened) { [datetime]$e.Happened } else { $null }
            Activity             = $e.Activity
            ActivityId           = $e.ActivityId
            User                 = $e.User
            UserType             = $e.UserType
            Workload             = $e.Workload
            ItemName             = $e.ItemName
            FilePath             = $e.FilePath
            FileExtension        = $e.FileExtension
            # Flattened out of PolicyMatchInfo - grouping by these on the raw API output puts
            # every row under one blank key, which reads as "no policy matched".
            PolicyName           = $e.PolicyMatchInfo.PolicyName
            RuleName             = $e.PolicyMatchInfo.RuleName
            PolicyMode           = $e.PolicyMatchInfo.PolicyMode
            SensitivityLabelId   = if ($labelId) { $labelId } else { $null }
            SensitivityLabelName = $labelName
            # Manual, Auto, or blank. 'Auto' here is label INHERITANCE or a second workload
            # recording the same human action - it does not imply an auto-labeling policy.
            HowApplied           = $e.HowApplied
            EmailSender          = $e.EmailInfo.Sender
            EmailSubject         = $e.EmailInfo.Subject
            EmailRecipients      = @($e.EmailInfo.Receivers)
            RawPolicyMatch       = $e.PolicyMatchInfo
            RawSensitiveInfo     = $e.SensitiveInfoTypeData
            RecordIdentity       = $e.RecordIdentity
        }
    }
}
