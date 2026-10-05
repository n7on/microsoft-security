function Get-MsecAzureDevOpsWorkItem {
    <#
    .SYNOPSIS
        Work items from an Azure DevOps project with their tags, state category and age - for
        tracking whether security findings are actually being closed.

    .DESCRIPTION
        THIS MEASURES YOUR PROCESS, NOT YOUR TENANT. Every other Get-Msec* command reads a
        Microsoft system and tells you how it is configured. This one reads your own backlog
        and tells you how your team is responding to it. Both are security questions, but they
        are different ones, and this deliberately stays out of Export-MsecPostureReport so a
        remediation count never blurs into a posture score.

        NO BUNDLED QUERIES. Area paths, tags, states and work item type names differ in every
        organisation - 'Tech Backlog Item' is not even a type in a default project - so the
        conventions are PARAMETERS rather than shipped WIQL files. That is what keeps the
        command useful in a tenant other than the one it was written in.

        'OPEN' IS NOT A STATE NAME, IT IS A STATE CATEGORY. Agile uses New/Active/Resolved/
        Closed, Scrum uses New/Approved/Committed/Done, Basic uses To Do/Doing/Done, and a
        custom process may use anything. Filtering on a state name would silently return
        nothing on a process that does not use it. So -OpenOnly resolves each type's states to
        their CATEGORY (Proposed, InProgress, Resolved, Completed, Removed) and keeps anything
        not Completed or Removed. StateCategory is returned on every row for the same reason.

        A STATE THAT COULD NOT BE CLASSIFIED IS KEPT, NOT DROPPED. If a type's state list is
        unreadable, StateCategory is $null and -OpenOnly still returns the row - excluding an
        item because msec could not work out whether it was closed would quietly shrink exactly
        the list someone is using to chase outstanding work.

        WORK ITEMS THE CALLER CANNOT SEE ARE SIMPLY ABSENT. Azure DevOps answers a WIQL query
        with the items the identity may read and no indication that anything was withheld, so
        a short answer is not proof of a short backlog. Compare against the portal before
        treating a count as complete.

    .PARAMETER Organization
        Azure DevOps organization name.

    .PARAMETER Project
        Project name. Omit to query every project the identity can see.

    .PARAMETER Tag
        Only items carrying this tag. Matched with CONTAINS, so it also matches one tag out of
        a semicolon-separated list.

    .PARAMETER Team
        A team name in -Project. The team's area paths are read from Azure DevOps and turned
        into the query, honouring each path's includeChildren flag. A team backlog is usually
        several area paths and not all of them take their children, so this is safer than
        writing -AreaPath by hand.

    .PARAMETER AreaPath
        One or more area paths, OR'd together. Each matches the path and everything beneath it.
        Prefer -Team when you mean a team's backlog.

    .PARAMETER ChangedWithinDays
        Only items changed within this many days. Narrows the query server-side, which is the
        only thing that helps when a project exceeds the 20,000-item limit Azure DevOps
        enforces before returning any result.

    .PARAMETER Type
        Only these work item types, e.g. 'Task', 'Bug'.

    .PARAMETER OpenOnly
        Only items whose state category is neither Completed nor Removed.

    .PARAMETER MaxItems
        Safety cap on how many items are fetched. Default 2000.

    .EXAMPLE
        Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -OpenOnly |
            Sort-Object BacklogRank | Format-Table Id, BacklogRank, BoardColumn, Title

        Backlog order. Rows come back newest-first by Id, NOT in board order - that order is a
        drag-and-drop rank, so sort on BacklogRank to reproduce it. Two caveats: a board shows
        one backlog LEVEL at a time with children nested underneath, so a flat sort over mixed
        types will not look identical; and an item never ranked on a backlog has a null rank,
        which Sort-Object puts first.

    .EXAMPLE
        Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -OpenOnly |
            ForEach-Object Tags | Group-Object | Sort-Object Count -Descending

        A count per individual tag. Tags is a string[], so expanding it first counts each tag
        separately - Group-Object Tags would instead group by the whole combination and report
        'Exchange; Internal IT' as its own bucket.

    .EXAMPLE
        Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Viedoc4 `
            -Team 'Security and Regulatory compliance' -OpenOnly

        One team's backlog. The team's area paths are resolved from Azure DevOps, including
        whether each one takes its children, so the result matches what the team sees in the
        portal rather than a guess at the path.

    .EXAMPLE
        Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -OpenOnly |
            Where-Object Tags -contains 'Internal IT'

        Every open item carrying that tag, including those that carry others alongside it.
        Use -contains, not -in or -eq: those compare against the whole array and silently miss
        any item with more than one tag.

    .EXAMPLE
        Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -Tag security -OpenOnly |
            Where-Object AgeDays -gt 90 | Sort-Object AgeDays -Descending

        Security findings open for more than ninety days, oldest first.

    .EXAMPLE
        Get-MsecAzureDevOpsWorkItem -Organization contoso -Project Security -OpenOnly |
            Where-Object { -not $_.Tags } | Format-Table Id, Type, Title

        Open items nobody has tagged - the ones no tag-based report will ever show.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string] $Organization,

        [string] $Project,

        [string] $Tag,

        # A TEAM'S BACKLOG IS SEVERAL AREA PATHS, NOT ONE, and each carries its own
        # includeChildren flag - so this resolves the team's real definition rather than
        # making the caller guess it. Measured on one project, 'Security and Regulatory
        # compliance' spans four area paths and one of them excludes its children; a single
        # -AreaPath with UNDER would both miss three of them and over-reach on the fourth.
        [string] $Team,

        # Several are OR'd together. Each matches the path and everything beneath it (UNDER).
        # Use -Team instead when you mean a team's backlog.
        [string[]] $AreaPath,

        [string[]] $Type,

        [switch] $OpenOnly,

        # Narrows the query SERVER-SIDE, which -MaxItems cannot: Azure DevOps refuses a WIQL
        # query whose result exceeds 20,000 items before returning anything, so a cap applied
        # after the fact is no help on a large project. WIQL has no TOP clause on this
        # endpoint (it answers TF51006), so a date bound is the usable lever.
        [ValidateRange(1, 36500)]
        [int] $ChangedWithinDays,

        [ValidateRange(1, 20000)]
        [int] $MaxItems = 2000
    )

    # WIQL string literals are single-quoted, so an apostrophe in a tag or area path has to be
    # doubled or the query fails to parse rather than returning nothing.
    $escape = { param($Value) ([string] $Value) -replace "'", "''" }

    $where = @()
    if ($Project)  { $where += "[System.TeamProject] = '$(& $escape $Project)'" }
    if ($Tag)      { $where += "[System.Tags] CONTAINS '$(& $escape $Tag)'" }
    if ($AreaPath) {
        $where += '(' + ((@($AreaPath) | ForEach-Object { "[System.AreaPath] UNDER '$(& $escape $_)'" }) -join ' OR ') + ')'
    }

    if ($Team) {
        if (-not $Project) { throw 'A team belongs to a project, so -Team requires -Project.' }

        $teamField = $null
        try {
            $teamField = Invoke-MsecAzureDevOpsRequest -Organization $Organization -HostName 'dev.azure.com' `
                -Path "$Project/$([uri]::EscapeDataString($Team))/_apis/work/teamsettings/teamfieldvalues" -ApiVersion '7.1'
        }
        catch {
            throw ("Could not read the area paths for team '$Team' in project '$Project'. " +
                   'Team names are per-project and must match exactly, including spaces and capitalisation. ' +
                   "Original error: $($_.Exception.Message)")
        }

        # The field is System.AreaPath on every project seen so far, but teamfieldvalues names
        # it explicitly and a project may use a different one - so honour what it returns
        # rather than hard-coding the common case.
        $field = if ($teamField.field.referenceName) { [string] $teamField.field.referenceName } else { 'System.AreaPath' }

        # includeChildren decides UNDER versus =. Using UNDER for everything silently pulls in
        # sub-areas a team deliberately excluded, which over-reports; using = for everything
        # drops the sub-areas that are the bulk of most backlogs.
        $clauses = @(foreach ($value in @($teamField.values)) {
            $operator = if ($value.includeChildren) { 'UNDER' } else { '=' }
            "[$field] $operator '$(& $escape $value.value)'"
        })

        if (-not $clauses.Count) {
            throw "Team '$Team' in project '$Project' has no area paths assigned, so its backlog cannot be resolved to a query."
        }
        Write-Verbose "Team '$Team' resolves to $($clauses.Count) area path clause(s)."
        $where += '(' + ($clauses -join ' OR ') + ')'
    }
    # @Today is evaluated by Azure DevOps in the ORGANIZATION's timezone, not this machine's,
    # so the boundary can differ by a day from a locally computed date. That is the right
    # trade: it matches what the same query returns in the portal.
    if ($PSBoundParameters.ContainsKey('ChangedWithinDays')) {
        $where += "[System.ChangedDate] >= @Today - $ChangedWithinDays"
    }
    if ($Type)     { $where += '(' + ((@($Type) | ForEach-Object { "[System.WorkItemType] = '$(& $escape $_)'" }) -join ' OR ') + ')' }

    $query = 'SELECT [System.Id] FROM WorkItems'
    if ($where.Count) { $query += ' WHERE ' + ($where -join ' AND ') }
    $query += ' ORDER BY [System.Id] DESC'
    Write-Verbose "WIQL: $query"

    # The project-scoped wiql endpoint resolves area paths relative to the project; the
    # organization-scoped one is needed when no project was named.
    $wiqlPath = if ($Project) { "$Project/_apis/wit/wiql" } else { '_apis/wit/wiql' }

    $ids = @()
    try {
        $result = Invoke-MsecAzureDevOpsRequest -Organization $Organization -HostName 'dev.azure.com' `
            -Path $wiqlPath -ApiVersion '7.1' -Method POST -Body @{ query = $query }
        $ids = @($result.workItems | ForEach-Object { $_.id })
    }
    catch {
        # A 404 here is AMBIGUOUS and the response does not disambiguate it: a misspelled
        # organization, a misspelled project, and a project the identity cannot see all return
        # the same Not Found. Naming only one of them sends the reader to check a spelling that
        # was already right - the first time this fired, the organization was missing a letter
        # and the message pointed at neither.
        # The 20,000 limit is enforced BEFORE anything is returned, so -MaxItems cannot help -
        # it caps a list Azure DevOps refused to produce. The only lever is a narrower query.
        if ($_.Exception.Message -match 'VS402337|size limit') {
            $advice = if ($PSBoundParameters.ContainsKey('ChangedWithinDays')) {
                "Narrow further: lower -ChangedWithinDays (currently $ChangedWithinDays), or add -Tag, -AreaPath or -Type."
            }
            else {
                'Narrow the query with -ChangedWithinDays, -Tag, -AreaPath or -Type. -MaxItems cannot help here: the limit is applied by Azure DevOps before any result is returned.'
            }
            throw "The query matched more than the 20,000 work items Azure DevOps will return$(if ($Project) { " in project '$Project'" }). $advice Original error: $($_.Exception.Message)"
        }
        if ($_.Exception.Message -match '\b404\b|Not Found') {
            $target = if ($Project) { "organization '$Organization' or project '$Project'" }
                      else          { "organization '$Organization'" }
            throw ("Work item query returned 404. The $target does not exist, is spelled differently, " +
                   'or is not visible to the msec app. Azure DevOps returns the same 404 for all three, ' +
                   'so check the spelling of both before looking at permissions. ' +
                   "Original error: $($_.Exception.Message)")
        }
        throw "Work item query failed in '$Organization'. $($_.Exception.Message)"
    }

    if (-not $ids.Count) { return }

    if ($ids.Count -gt $MaxItems) {
        Write-Warning "The query matched $($ids.Count) work items; only the $MaxItems most recent are returned. Raise -MaxItems or narrow the query - this is a truncated answer, not the whole backlog."
        $ids = @($ids | Select-Object -First $MaxItems)
    }

    $fields = @(
        'System.WorkItemType', 'System.Title', 'System.State', 'System.Tags'
        'System.AreaPath', 'System.IterationPath', 'System.AssignedTo'
        'System.CreatedBy', 'System.CreatedDate', 'System.ChangedDate', 'System.TeamProject'
        # Backlog order is a drag-and-drop rank, and WHICH FIELD HOLDS IT DEPENDS ON THE
        # PROCESS: Scrum writes BacklogPriority, Agile and CMMI write StackRank. Asking for
        # both and taking whichever is populated avoids having to detect the process.
        'Microsoft.VSTS.Common.BacklogPriority', 'Microsoft.VSTS.Common.StackRank'
        # The board column is NOT the state - a board can have several columns mapped to one
        # state, which is exactly where work sits when it is 'in progress' in two senses.
        'System.BoardColumn'
    )

    $items = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $ids.Count; $i += 200) {
        $slice = @($ids[$i..([math]::Min($i + 199, $ids.Count - 1))])
        try {
            # Invoke-MsecAzureDevOpsRequest already unwraps the response's 'value' array, so
            # this is the work items themselves - NOT an envelope to take .value from again.
            # The wiql call above is the other shape: that response has no 'value' property, so
            # the helper hands back the envelope and .workItems is the right way in.
            $batch = Invoke-MsecAzureDevOpsRequest -Organization $Organization -HostName 'dev.azure.com' `
                -Path '_apis/wit/workitemsbatch' -ApiVersion '7.1' -Method POST `
                -Body @{ ids = $slice; fields = $fields; errorPolicy = 'omit' }
            $items.AddRange(@($batch))
        }
        catch {
            Write-Warning "Could not read a batch of $($slice.Count) work item(s), so they are MISSING from this output rather than reported as empty: $($_.Exception.Message)"
        }
    }

    # State -> category, resolved per (project, type). Built lazily because a query spanning
    # several projects would otherwise pay for types it never sees.
    $categoryCache = @{}
    $categoryOf = {
        param($ItemProject, $ItemType, $State)
        if (-not $ItemProject -or -not $ItemType -or -not $State) { return $null }
        $key = "$ItemProject/$ItemType"
        if (-not $categoryCache.ContainsKey($key)) {
            $map = $null
            try {
                $states = Invoke-MsecAzureDevOpsRequest -Organization $Organization -HostName 'dev.azure.com' `
                    -Path "$ItemProject/_apis/wit/workitemtypes/$([uri]::EscapeDataString($ItemType))/states" -ApiVersion '7.1'
                $map = @{}
                foreach ($s in @($states)) { $map[[string] $s.name] = [string] $s.category }
            }
            catch {
                Write-Warning "Could not read the state list for '$ItemType' in '$ItemProject', so StateCategory is null for those items and -OpenOnly keeps them rather than guessing: $($_.Exception.Message)"
            }
            $categoryCache[$key] = $map
        }
        $map = $categoryCache[$key]
        if ($null -eq $map) { return $null }
        if ($map.ContainsKey([string] $State)) { return $map[[string] $State] }
        $null
    }

    $now = (Get-Date).ToUniversalTime()

    foreach ($item in $items) {
        $f = $item.fields
        $itemProject = [string] $f.'System.TeamProject'
        $itemType    = [string] $f.'System.WorkItemType'
        $state       = [string] $f.'System.State'

        $category = & $categoryOf $itemProject $itemType $state

        # Unclassifiable is kept: dropping it would shrink the very list someone is using to
        # chase outstanding work.
        if ($OpenOnly -and $category -in 'Completed', 'Removed') { continue }

        $created = if ($f.'System.CreatedDate') { [datetime] $f.'System.CreatedDate' } else { $null }
        $changed = if ($f.'System.ChangedDate') { [datetime] $f.'System.ChangedDate' } else { $null }

        [PSCustomObject]@{
            PSTypeName       = 'MsecAzureDevOpsWorkItem'
            Id               = $item.id
            Project          = $itemProject
            Type             = $itemType
            Title            = [string] $f.'System.Title'
            State            = $state
            StateCategory    = $category
            # AN ARRAY, NOT THE JOINED STRING Azure DevOps sends. ADO returns tags as
            # 'Exchange; Internal IT', and keeping that shape forces every caller onto
            # -like '*Internal IT*' - which also matches a tag called 'Internal IT Legacy',
            # and silently returns nothing for the -contains and -in that people reach for
            # first. msec.format.ps1xml flattens it for display; the data stays typed.
            Tags             = @(([string] $f.'System.Tags') -split ';' |
                                    ForEach-Object { $_.Trim() } | Where-Object { $_ })
            AreaPath         = [string] $f.'System.AreaPath'
            IterationPath    = [string] $f.'System.IterationPath'
            # The board column, which is NOT the state: several columns can map to one state.
            BoardColumn      = [string] $f.'System.BoardColumn'
            # Backlog order. NULL - never 0 - when the item has never been ranked on a
            # backlog, which is a real and common state: 0 would sort it to the top as though
            # someone had deliberately put it first.
            BacklogRank      = $(
                $rank = if ($null -ne $f.'Microsoft.VSTS.Common.BacklogPriority') { $f.'Microsoft.VSTS.Common.BacklogPriority' }
                        else { $f.'Microsoft.VSTS.Common.StackRank' }
                if ($null -eq $rank) { $null } else { [double] $rank })
            AssignedTo       = [string] $f.'System.AssignedTo'.displayName
            CreatedBy        = [string] $f.'System.CreatedBy'.displayName
            CreatedDate      = $created
            ChangedDate      = $changed
            # Null rather than 0 when the date is missing: 0 would read as "created today".
            AgeDays          = if ($created) { [int] ($now - $created.ToUniversalTime()).TotalDays } else { $null }
            DaysSinceChanged = if ($changed) { [int] ($now - $changed.ToUniversalTime()).TotalDays } else { $null }
            Url              = "https://dev.azure.com/$Organization/$itemProject/_workitems/edit/$($item.id)"
        }
    }
}
