function New-MsecDefenderDetectionRule {
    <#
    .SYNOPSIS
        Creates a Defender XDR custom detection rule from an advanced hunting query, after
        running the query to check it works. Runs as YOU, not as the msec app.

    .DESCRIPTION
        THE QUERY IS RUN BEFORE THE RULE IS CREATED, AND THAT IS THE POINT. A custom detection
        whose query is malformed, references a table this tenant does not have, or omits the
        columns the entity mapping names, is accepted by the portal and by this API and then
        fails on its schedule - at which point Defender eventually marks it autoDisabled. The
        rule sits in the list looking live. So the query is executed first, through the app's
        read-only hunting access, and creation is refused if it does not run.

        ROW COUNT IS CHECKED TOO, because the other way a new detection goes wrong is working
        perfectly and matching eight hundred things. The count over the validation window is
        reported, and a query that matches a lot warns before anything is created - one alert
        per match is how a detection gets switched off by the people it pages.

        TWO IDENTITIES, DELIBERATELY. Validation reads through the app certificate
        (ThreatHunting.Read.All); creation writes through your delegated session from
        Connect-MsecAdmin. The app cannot create detections and is not asked to - a read-only
        app that could add alert rules is not read-only in any sense that matters.

        REQUIRES Connect-MsecAdmin -Scope CustomDetection.ReadWrite.All. That is the only
        permission the API accepts; there is no lesser one. The signed-in user also needs
        Detection tuning (Manage), Security Administrator, or Security Operator.

        TIMESTAMP IS ALWAYS REQUIRED IN THE QUERY, and so is every column named by an entity
        mapping. Defender rejects a rule whose mapping points at a column the query does not
        project, but the message does not say which, so both are checked here against the real
        result and the missing column is named.

    .PARAMETER DisplayName
        The rule name, as it appears in the portal.

    .PARAMETER Query
        The advanced hunting KQL. Must project Timestamp and the entity columns below.

    .PARAMETER QueryPath
        A .kql file to read the query from instead of -Query. Keeps rules in version control.

    .PARAMETER Description
        Why this rule exists and what to do when it fires. The only explanation that travels
        with the rule, so it is mandatory here even though the API treats it as optional.

    .PARAMETER AlertTitle
        Title of the alert raised on a match. Defaults to the rule name.

    .PARAMETER Severity
        informational, low, medium or high. Defaults to informational.

    .PARAMETER Frequency
        How often it runs: 1h, 3h, 12h or 24h. Defaults to 24h.

    .PARAMETER DeviceIdColumn
        Column holding the device id, mapped as the impacted host. Defaults to DeviceId; pass
        an empty string for a query with no device.

    .PARAMETER DeviceNameColumn
        Column holding the device name. Defaults to DeviceName when the query projects it.

    .PARAMETER RecommendedActions
        What the responder should do. Shown on the alert.

    .PARAMETER Tactic
        MITRE ATT&CK tactic, e.g. 'DefenseEvasion'.

    .PARAMETER Technique
        MITRE technique ids, e.g. 'T1562.009'. Requires -Tactic.

    .PARAMETER Disabled
        Create the rule switched off.

    .PARAMETER Id
        Client-supplied rule id. Derived from the display name when omitted.

    .PARAMETER MaxExpectedRows
        Warn when validation returns more rows than this. Default 50.

    .EXAMPLE
        Connect-MsecAdmin -Scope CustomDetection.ReadWrite.All
        New-MsecDefenderDetectionRule -DisplayName 'Allow-listed publisher certificate rotated' `
            -QueryPath ./cert-rotation.kql -Severity informational -Frequency 24h `
            -Description 'A publisher we allow-list by certificate started signing with a new one. Create an indicator for the new thumbprint, then add it to ApprovedThumbprints in this rule.' `
            -WhatIf

    .OUTPUTS
        PSCustomObject describing the created rule, PSTypeName 'MsecDefenderDetectionRule'.

    .NOTES
        Beta endpoint: custom detection rules are beta-only in Microsoft Graph at present.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DisplayName,

        [Parameter(Mandatory, ParameterSetName = 'Query')]
        [ValidateNotNullOrEmpty()]
        [string] $Query,

        [Parameter(Mandatory, ParameterSetName = 'File')]
        [ValidateNotNullOrEmpty()]
        [string] $QueryPath,

        # Mandatory although the API allows it to be empty - see the help.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Description,

        [string] $AlertTitle,

        [ValidateSet('informational', 'low', 'medium', 'high')]
        [string] $Severity = 'informational',

        [ValidateSet('1h', '3h', '12h', '24h')]
        [string] $Frequency = '24h',

        [string] $DeviceIdColumn = 'DeviceId',

        [string] $DeviceNameColumn = 'DeviceName',

        [string] $RecommendedActions,

        [string] $Tactic,

        [string[]] $Technique,

        [switch] $Disabled,

        [string] $Id,

        [int] $MaxExpectedRows = 50
    )

    Assert-MsecSession       # the app, for validation
    # Naming the scope here is what turns "403 at the write" into "you connected without this
    # consent" before anything is attempted. Connect-MsecAdmin requests it by default.
    Assert-MsecAdminSession -Scope 'CustomDetection.ReadWrite.All'

    if ($Technique -and -not $Tactic) {
        throw 'A technique without a tactic is rejected by Defender. Pass -Tactic as well.'
    }

    if ($PSCmdlet.ParameterSetName -eq 'File') {
        if (-not (Test-Path -LiteralPath $QueryPath)) { throw "Query file not found: $QueryPath" }
        $Query = Get-Content -LiteralPath $QueryPath -Raw
    }
    if (-not $AlertTitle) { $AlertTitle = $DisplayName }

    # The API requires a client-supplied id. Derived so callers do not have to invent one, and
    # kept stable from the name so re-running with the same name collides loudly rather than
    # silently creating a second identical rule.
    if (-not $Id) {
        $Id = ($DisplayName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
        if (-not $Id) { $Id = "detection-$([guid]::NewGuid().ToString('N').Substring(0,8))" }
    }

    $isoFrequency = switch ($Frequency) {
        '1h'  { 'PT1H';  break }
        '3h'  { 'PT3H';  break }
        '12h' { 'PT12H'; break }
        default { 'P1D' }
    }

    # ---- validation: run the query before creating anything ----------------------------
    Write-Verbose 'Validating the query through advanced hunting before creating the rule.'
    $rows = $null
    try {
        $rows = @(Search-MsecDefenderHunting -Query $Query -Days 1 -ErrorAction Stop)
    }
    catch {
        throw ("The query does not run, so the rule was NOT created. Defender would have accepted it and " +
               "then failed on its schedule, eventually marking it autoDisabled while it still appeared " +
               "in the rule list. Original error: $($_.Exception.Message)")
    }

    # Columns are only observable when at least one row came back. A query that matches nothing
    # today is the NORMAL case for a good detection, so this is a verbose note, not a failure -
    # refusing here would block exactly the rules worth creating.
    if ($rows.Count) {
        $columns = @($rows[0].PSObject.Properties.Name | Where-Object { $_ -notmatch '@odata' })
        $required = @('Timestamp') + @($DeviceIdColumn, $DeviceNameColumn | Where-Object { $_ })
        $missing = @($required | Where-Object { $_ -notin $columns })
        if ($missing.Count) {
            throw ("The query runs but does not project: $($missing -join ', '). Defender rejects a rule " +
                   "whose entity mapping names a column the query does not return, and its message does not " +
                   "say which one. Projected columns: $($columns -join ', ').")
        }
        Write-Verbose "Query returned $($rows.Count) row(s) over 1 day; required columns present."
        if ($rows.Count -gt $MaxExpectedRows) {
            Write-Warning ("The query matched $($rows.Count) row(s) in the last day. This rule would raise " +
                           "roughly that many alerts per run. Tune it before relying on it - a detection that " +
                           "pages people hundreds of times is one somebody switches off.")
        }
    }
    else {
        Write-Verbose 'Query ran and matched nothing over 1 day. Column names could not be checked against a result - that is expected for a detection that is meant to be quiet.'
    }

    # ---- build and create ---------------------------------------------------------------
    $alertTemplate = [ordered]@{
        title       = $AlertTitle
        description = $Description
        severity    = $Severity
    }
    if ($RecommendedActions) { $alertTemplate['recommendedActions'] = $RecommendedActions }

    $hosts = @()
    if ($DeviceIdColumn -or $DeviceNameColumn) {
        $hostMap = [ordered]@{}
        if ($DeviceIdColumn)   { $hostMap['deviceIdColumn'] = $DeviceIdColumn }
        if ($DeviceNameColumn) { $hostMap['nameColumn']     = $DeviceNameColumn }
        $hosts = @($hostMap)
    }
    if ($hosts.Count) { $alertTemplate['entityMappings'] = [ordered]@{ hosts = $hosts } }

    if ($Tactic) {
        $alertTemplate['tactics'] = @(
            [ordered]@{
                tactic     = $Tactic
                techniques = @(foreach ($t in @($Technique)) { @{ technique = $t } })
            }
        )
    }

    $body = [ordered]@{
        '@odata.type'  = '#microsoft.graph.security.detectionRule'
        id             = $Id
        displayName    = $DisplayName
        description    = $Description
        status         = if ($Disabled) { 'disabled' } else { 'enabled' }
        queryCondition = [ordered]@{ queryText = $Query }
        schedule       = [ordered]@{ frequency = $isoFrequency }
        detectionAction = [ordered]@{ alertTemplate = $alertTemplate }
    }

    $operation = "Create $($body.status) detection rule running every $Frequency at $Severity severity"
    if (-not $PSCmdlet.ShouldProcess($DisplayName, $operation)) { return }

    try {
        $created = Invoke-MsecAdminGraphRequest -Path '/beta/security/rules/detectionRules' -Method POST -Body $body
    }
    catch {
        $detail = "$($_.Exception.Message)"
        if ($detail -match '403|Forbidden') {
            throw ("Forbidden creating the detection rule. Connect-MsecAdmin must have been given " +
                   "-Scope CustomDetection.ReadWrite.All - there is no read-only or lesser scope for this API - " +
                   "and your account needs Detection tuning (Manage), Security Administrator or Security " +
                   "Operator. This is YOUR authorization, not the msec app's. Original error: $detail")
        }
        if ($detail -match '409|Conflict|already exists') {
            throw "A detection rule with id '$Id' already exists. Pass a different -Id, or update the existing rule instead of creating a second one. Original error: $detail"
        }
        throw "Could not create the detection rule: $detail"
    }

    [PSCustomObject]@{
        PSTypeName      = 'MsecDefenderDetectionRule'
        Id              = [string] $created.id
        DisplayName     = [string] $created.displayName
        Description     = [string] $created.description
        Status          = [string] $created.status
        IsRunning       = ("$($created.status)" -eq 'enabled')
        Frequency       = [string] $created.schedule.frequency
        NextRun         = if ($created.schedule.nextRunDateTime) { [datetime] $created.schedule.nextRunDateTime } else { $null }
        AlertTitle      = [string] $created.detectionAction.alertTemplate.title
        Severity        = [string] $created.detectionAction.alertTemplate.severity
        Category        = [string] $created.detectionAction.alertTemplate.category
        Query           = [string] $created.queryCondition.queryText
        CreatedBy       = [string] $created.createdBy
        CreatedUtc      = if ($created.createdDateTime) { [datetime] $created.createdDateTime } else { $null }
        LastModifiedBy  = [string] $created.lastModifiedBy
        LastModifiedUtc = if ($created.lastModifiedDateTime) { [datetime] $created.lastModifiedDateTime } else { $null }
        ValidationRows  = $rows.Count
        Raw             = $created
    }
}
