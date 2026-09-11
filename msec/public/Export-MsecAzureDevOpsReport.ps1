function Export-MsecAzureDevOpsReport {
    <#
    .SYNOPSIS
        Collects an Azure DevOps organization's security posture into one Excel workbook - a
        sheet of rows per area, a Summary counting each area by category, and a chart per
        area on a Dashboard built to print one chart per page.

    .DESCRIPTION
        A SNAPSHOT, NOT A TREND. Every sheet is replaced on each run; nothing is appended and
        nothing accumulates. This is the evidence half of the module - "here is the state of
        the organization on the day it was collected" - as opposed to Export-MsecPostureReport,
        which appends one row per run to build a time series.

        It runs the Get-MsecAzureDevOps* commands and writes what each returned, unmodified.
        Everything those commands know about the limits of their answers travels with the
        rows, so a column that is $null on a sheet here is $null for the reason that command
        documents, not because this one dropped it.

        DEGRADES RATHER THAN FAILS. Each area is collected independently and a failure is
        recorded on RunLog with the message that caused it, so one area that needs a permission
        this identity does not hold costs that area and nothing else.

        A FAILED AREA GETS NO CHART, deliberately. A chart of zeros and no chart at all say
        different things - "measured, found none" against "could not measure" - and a report
        that drew zeros for a 403 would turn a permission gap into a clean bill of health.
        An area that WAS collected and found nothing does get its chart, with zeros in it.

        CATEGORIES ARE FIXED AND ALWAYS PRESENT, at zero if nothing is in them, so two runs'
        charts line up. A value no category was written for is added as its own bar rather
        than folded into 'Other' - Azure DevOps adds severities, auth schemes and pool types,
        and the one outcome worth avoiding is a bar quietly absorbing something new.

        TWO CHARTS ARE NOT PARTITIONS AND MUST NOT BE SUMMED. On 'Pipeline settings' and
        'Organization policies' each bar is an independent measurement - how many projects
        have that one protection off, and whether that one policy is on - so a project appears
        under every risk it carries and the bars overlap by design. Every other chart divides
        its subject into mutually exclusive categories, where the bars do add up to the total.
        The two are drawn as horizontal bars, partly because their labels are sentences and
        partly so they read differently from the charts that do partition.

        Sheets:
          Dashboard          every chart, first in the workbook, one per printed page
          Summary            Area, Category, Count - what the charts read
          Repositories       branch protection on each default branch
          Alerts             Advanced Security findings (active by default), charted by type
                             as well as severity - see below
          ServiceConnections auth scheme and which pipelines may use each connection
          VariableGroups     how many secrets each holds and who may use it
          SecureFiles        certificates and keys in the pipeline library
          Environments       deployment targets and the checks guarding them
          AgentPools         hosted and self-hosted pools and their agents
          Extensions         marketplace extensions and the access each holds
          PipelineSettings   per-project pipeline security settings
          OrgPolicies        organization policies
          Users              organization members and the groups they are in
          RunLog             what ran, what failed, and why

        A ZERO BAR ON THE ALERT TYPE CHART IS A SCANNER THAT IS OFF, not a clean codebase.
        Azure DevOps rates every secret alert critical, so an organization running secret
        scanning alone fills the critical bar and leaves the other four severities empty -
        which is why alerts are charted by type as well. Which scanners are enabled per
        repository is on the Repositories sheet.

        WHAT IT DOES NOT COLLECT: the contents of secure files or the values of secret
        variables. Neither command reads them and this one does not either - an evidence
        document that gathered private keys into a spreadsheet would be the largest new risk
        in the room.

        Agent pool exposure (which projects can queue work on a pool) is one call per project
        and is off unless -IncludeAgentPoolExposure is given; without it those columns are
        $null, meaning not collected rather than none.

    .PARAMETER Path
        The .xlsx to write. Created if absent. One organization per workbook - the sheets are
        named for areas, not organizations, so a second organization written to the same path
        replaces the first. Give each its own file.

    .PARAMETER Organization
        The Azure DevOps organization name, as in dev.azure.com/<organization>.

    .PARAMETER Area
        Collect only these areas. Default is all of them. Useful for a quick top-up, or to
        skip Alerts and Repositories, which walk every repository and are much the slowest.

    .PARAMETER AlertState
        Which Advanced Security alerts to collect: 'active' (default), 'fixed', 'dismissed'
        or 'all'. The default is the working list - what is outstanding now.

    .PARAMETER IncludeAgentPoolExposure
        Also collect which projects can queue work on each pool. One extra call per project.

    .PARAMETER TableStyle
        Excel table style for every sheet. One of Light1-21, Medium1-28 or Dark1-11. Default
        Medium2.

    .PARAMETER ChartWidth
        Chart width in pixels, default 600 - sized so a chart pasted into Word fits an A4
        portrait page at standard margins, which is the tighter of the two orientations.

    .PARAMETER ChartHeight
        Chart height in pixels, default 370. Also sets where the page breaks fall.

    .PARAMETER Force
        Replace existing sheets without asking. Needed for scheduled runs, which have nobody
        to answer the prompt.

    .PARAMETER PassThru
        Emit one object per area describing what was collected and where it was written.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Export-MsecAzureDevOpsReport -Path ./ado-2026-09.xlsx -Organization contoso

    .EXAMPLE
        # Skip the two slow areas for a quick look at the pipeline library.
        Export-MsecAzureDevOpsReport -Path ./ado.xlsx -Organization contoso `
            -Area VariableGroups, SecureFiles, ServiceConnections, Environments

    .EXAMPLE
        # Scheduled, with no prompt, into a synced SharePoint library.
        $lib = "$HOME/Library/CloudStorage/OneDrive-SharedLibraries-Contoso/Security - Documents"
        Export-MsecAzureDevOpsReport -Path "$lib/ado-posture.xlsx" -Organization contoso -Force

    .OUTPUTS
        With -PassThru, one PSCustomObject per area: Area, Sheet, Status, RowCount and the
        rows themselves. Always writes the workbook.

    .NOTES
        Needs Connect-Msec, plus whatever each area needs in Azure DevOps itself - see the
        permission table in README.md. Azure DevOps permissions are not Entra permissions, and
        an identity that can read one area may be refused another; that is what RunLog is for.

        Needs the ImportExcel module: Install-Module ImportExcel -Scope CurrentUser.

        The workbook must not be open in Excel while this runs - the file is locked and the
        write fails.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [Parameter(Mandatory, Position = 1)]
        [string] $Organization,

        [ValidateSet('Repositories', 'Alerts', 'ServiceConnections', 'VariableGroups',
                     'SecureFiles', 'Environments', 'AgentPools', 'Extensions',
                     'PipelineSettings', 'OrganizationPolicies', 'Users')]
        [string[]] $Area,

        [ValidateSet('active', 'fixed', 'dismissed', 'all')]
        [string] $AlertState = 'active',

        [switch] $IncludeAgentPoolExposure,

        [string] $TableStyle = 'Medium2',

        [ValidateRange(200, 2000)]
        [int] $ChartWidth = 600,

        [ValidateRange(150, 1200)]
        [int] $ChartHeight = 370,

        [switch] $PassThru,

        [switch] $Force
    )

    Assert-MsecSession

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw 'ImportExcel is required for Export-MsecAzureDevOpsReport. Install with: Install-Module ImportExcel -Scope CurrentUser'
    }
    Import-Module ImportExcel -ErrorAction Stop

    if (-not ($TableStyle -as [OfficeOpenXml.Table.TableStyles])) {
        throw "'$TableStyle' is not an Excel table style. Use one of Light1-21, Medium1-28 or Dark1-11 (for example Medium2, the default)."
    }

    # Area name -> worksheet name. Worksheet names are shorter than the area names where the
    # area name would crowd the tab strip; Excel's own limit is 31 characters and none of
    # these come close.
    $sheetOf = [ordered]@{
        Repositories         = 'Repositories'
        Alerts               = 'Alerts'
        ServiceConnections   = 'ServiceConnections'
        VariableGroups       = 'VariableGroups'
        SecureFiles          = 'SecureFiles'
        Environments         = 'Environments'
        AgentPools           = 'AgentPools'
        Extensions           = 'Extensions'
        PipelineSettings     = 'PipelineSettings'
        OrganizationPolicies = 'OrgPolicies'
        Users                = 'Users'
    }

    # NOTE $areas, not $area: $area and the -Area parameter are the same variable, and it is
    # typed [string[]] - so a loop variable named $area would be silently coerced to a
    # one-element array on every iteration, and an array makes a hashtable key nothing can look
    # up again. The loop below uses $areaName for the same reason.
    $areas = if ($Area) { @($sheetOf.Keys | Where-Object { $_ -in $Area }) } else { @($sheetOf.Keys) }

    if (-not $PSCmdlet.ShouldProcess($Path, "Collect Azure DevOps security posture for '$Organization' and write the workbook")) {
        return
    }

    # ASKED BEFORE ANYTHING IS COLLECTED, so declining costs nothing. Collection here walks
    # every repository in the organization and can run for minutes; a prompt at the end would
    # be a prompt after the expensive part had already happened.
    if (-not $Force -and (Test-Path -LiteralPath $Path)) {
        $wanted = @($areas | ForEach-Object { $sheetOf[$_] }) + @('Summary', 'RunLog')
        $present = @()
        try { $present = @(Get-ExcelSheetInfo -Path $Path | Select-Object -ExpandProperty Name) }
        catch { Write-Verbose "Could not list worksheets in '$Path': $($_.Exception.Message)" }

        $clash = @($present | Where-Object { $_ -in $wanted })
        if ($clash.Count) {
            $query = "'$Path' already holds $($clash.Count) sheet(s) this run would replace - a snapshot report does not append: " +
                     (($clash | Sort-Object) -join ', ') + '. Continue?'
            if (-not $PSCmdlet.ShouldContinue($query, 'Replace existing evidence?')) {
                Write-Warning "Skipped - '$Path' was left unchanged. Use -Force to replace without being asked, or write to a different path."
                return
            }
        }
    }

    $collectedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')

    # ---- collect -------------------------------------------------------------------------------
    #
    # One area at a time, each in its own try. An organization where the identity can read
    # repositories but not service connections should get a workbook with repositories in it
    # and a named failure for the rest, not an exception.

    $rowsOf = [ordered]@{}
    $runLog = @()

    foreach ($areaName in $areas) {
        Write-Verbose "Collecting $areaName"
        try {
            $rows = switch ($areaName) {
                'Repositories'         { @(Get-MsecAzureDevOpsRepository       -Organization $Organization) }
                'Alerts'               { @(Get-MsecAzureDevOpsAlert             -Organization $Organization -State $AlertState) }
                'ServiceConnections'   { @(Get-MsecAzureDevOpsServiceConnection -Organization $Organization -IncludeSecurity) }
                'VariableGroups'       { @(Get-MsecAzureDevOpsVariableGroup     -Organization $Organization) }
                'SecureFiles'          { @(Get-MsecAzureDevOpsSecureFile        -Organization $Organization) }
                'Environments'         { @(Get-MsecAzureDevOpsEnvironment       -Organization $Organization) }
                'AgentPools'           { @(Get-MsecAzureDevOpsAgentPool         -Organization $Organization -IncludeExposure:$IncludeAgentPoolExposure) }
                'Extensions'           { @(Get-MsecAzureDevOpsExtension         -Organization $Organization) }
                'PipelineSettings'     { @(Get-MsecAzureDevOpsPipelineSetting   -Organization $Organization) }
                'OrganizationPolicies' { @(Get-MsecAzureDevOpsOrganizationPolicy -Organization $Organization) }
                'Users'                { @(Get-MsecAzureDevOpsUser              -Organization $Organization) }
            }

            $rowsOf[$areaName] = @($rows)
            $runLog += [pscustomobject]@{
                Area = $areaName; Sheet = $sheetOf[$areaName]; Status = 'Collected'
                RowCount = @($rows).Count; Detail = ''; CollectedUtc = $collectedUtc
            }
        }
        catch {
            # NAMED, NOT SWALLOWED. The message is usually the whole story - a 403 naming the
            # permission, or an organization that does not exist.
            $message = $_.Exception.Message
            Write-Warning "$areaName could not be collected for '$Organization', so it has no sheet and no chart: $message"
            $runLog += [pscustomobject]@{
                Area = $areaName; Sheet = $sheetOf[$areaName]; Status = 'Failed'
                RowCount = $null; Detail = $message; CollectedUtc = $collectedUtc
            }
        }
    }

    # ---- count ---------------------------------------------------------------------------------

    # Fixed categories first so every one appears even at zero, then a row is counted into the
    # category its selector names. A selector returning something no category was written for
    # ADDS a bar rather than dropping the row or folding it into 'Other' - Azure DevOps adds
    # severities and auth schemes, and silently absorbing a new one is the failure worth
    # avoiding.
    $countBy = {
        param([object[]] $Row, [string[]] $Category, [scriptblock] $Select)

        # $categoryName, not $category: -Category is typed [string[]] and PowerShell variable
        # names are case-insensitive, so a loop variable named $category IS the parameter and
        # gets coerced back to a one-element array - which then goes in as a key no lookup by
        # string can ever find, and every row lands in a duplicate bar.
        $tally = [ordered]@{}
        foreach ($categoryName in $Category) { $tally[$categoryName] = 0 }
        foreach ($item in $Row) {
            $key = [string] (& $Select $item)
            if (-not $tally.Contains($key)) { $tally[$key] = 0 }
            $tally[$key]++
        }
        $tally
    }

    # Block name -> what to chart. Ordered, and the order charts appear in.
    $blocks = [ordered]@{}

    $add = {
        param([string] $Name, [string] $Title, $Tally, [string] $ChartType = 'ColumnClustered')
        $blocks[$Name] = [pscustomobject]@{ Title = $Title; Tally = $Tally; ChartType = $ChartType }
    }

    if ($rowsOf.Contains('Repositories')) {
        $repositories = $rowsOf['Repositories']

        # A partition of every repository by how far its default branch is actually protected.
        # $null MinimumReviewers is the policy read failing, which is not the same as none.
        & $add 'Branch protection' 'Repositories by default branch protection' (
            & $countBy -Row $repositories -Category @(
                'No reviewer requirement', 'Reviewers, no build validation',
                'Reviewers and build validation', 'Disabled repository', 'Protection unreadable'
            ) -Select {
                param($r)
                if     ($r.IsDisabled)                     { 'Disabled repository' }
                elseif ($null -eq $r.MinimumReviewers)     { 'Protection unreadable' }
                elseif ($r.MinimumReviewers -lt 1)         { 'No reviewer requirement' }
                elseif (-not $r.RequireBuildValidation)    { 'Reviewers, no build validation' }
                else                                       { 'Reviewers and build validation' }
            })

        # Its own chart rather than a fifth branch-protection category, because it is a
        # different control: reviewers decide whether a change is wanted, push protection
        # decides whether a secret can land at all.
        & $add 'Secret push protection' 'Repositories by secret push protection' (
            & $countBy -Row $repositories -Category @('Not enforced', 'Enforced', 'Unreadable') -Select {
                param($r)
                if     ($null -eq $r.BlockSecretPush) { 'Unreadable' }
                elseif ($r.BlockSecretPush)           { 'Enforced' }
                else                                  { 'Not enforced' }
            })
    }

    if ($rowsOf.Contains('Alerts')) {
        # A SECOND CHART, because severity on its own misleads here. Azure DevOps rates every
        # secret alert critical, so an organization running secret scanning and nothing else
        # produces one tall critical bar and four empty ones - which reads as "no medium or low
        # findings" when it means "no scanner that emits them is switched on". Splitting by
        # type says which scanners are actually reporting: a zero bar for dependency or code
        # scanning is a scanner that is off, not a codebase that is clean.
        & $add 'Alert type' "Advanced Security alerts ($AlertState) by type" (
            & $countBy -Row $rowsOf['Alerts'] -Category @('secret', 'dependency', 'code') -Select {
                param($r) if ($r.AlertType) { [string] $r.AlertType } else { '(none reported)' }
            })

        # Severity as Advanced Security reports it, title-cased for reading. Anything outside
        # the known set keeps its own bar.
        & $add 'Alerts' "Advanced Security alerts ($AlertState) by severity" (
            & $countBy -Row $rowsOf['Alerts'] -Category @('Critical', 'High', 'Medium', 'Low', 'Note') -Select {
                param($r)
                $severity = [string] $r.Severity
                if (-not $severity) { return '(none reported)' }
                $severity.Substring(0, 1).ToUpperInvariant() + $severity.Substring(1)
            })
    }

    if ($rowsOf.Contains('ServiceConnections')) {
        $connections = $rowsOf['ServiceConnections']

        # A federated connection holds no secret to leak or expire; a service principal with a
        # key does. That is the difference this chart exists to show.
        & $add 'Connection auth' 'Service connections by authentication scheme' (
            & $countBy -Row $connections -Category @(
                'WorkloadIdentityFederation', 'ServicePrincipal', 'ManagedServiceIdentity',
                'UsernamePassword', 'Token', 'None'
            ) -Select { param($r) if ($r.AuthScheme) { [string] $r.AuthScheme } else { '(unknown)' } })

        & $add 'Connection exposure' 'Service connections by which pipelines may use them' (
            & $countBy -Row $connections -Category @(
                'Open to all pipelines', 'Named pipelines only', 'No pipeline authorized', 'Unreadable'
            ) -Select {
                param($r)
                if     ($null -eq $r.OpenToAllPipelines) { 'Unreadable' }
                elseif ($r.OpenToAllPipelines)           { 'Open to all pipelines' }
                elseif ($r.AuthorizedPipelineCount -gt 0){ 'Named pipelines only' }
                else                                     { 'No pipeline authorized' }
            })
    }

    if ($rowsOf.Contains('VariableGroups')) {
        # Openness alone is not the finding and neither is holding secrets - the two together
        # are, so the partition crosses them rather than charting either on its own.
        & $add 'Variable groups' 'Variable groups by secrets held and pipeline access' (
            & $countBy -Row $rowsOf['VariableGroups'] -Category @(
                'Open to all pipelines, holds secrets', 'Open to all pipelines, no secrets',
                'Restricted, holds secrets', 'Restricted, no secrets', 'Access unreadable'
            ) -Select {
                param($r)
                $secrets = [int] $r.SecretCount -gt 0
                if     ($null -eq $r.OpenToAllPipelines) { 'Access unreadable' }
                elseif ($r.OpenToAllPipelines)           { if ($secrets) { 'Open to all pipelines, holds secrets' } else { 'Open to all pipelines, no secrets' } }
                else                                     { if ($secrets) { 'Restricted, holds secrets' } else { 'Restricted, no secrets' } }
            })
    }

    if ($rowsOf.Contains('SecureFiles')) {
        # Kind is a guess from the file extension - see Get-MsecAzureDevOpsSecureFile. The
        # chart groups; the sheet has the names the guess was made from.
        & $add 'Secure files' 'Secure files by kind (guessed from the extension)' (
            & $countBy -Row $rowsOf['SecureFiles'] -Category @(
                'Certificate', 'Keystore', 'ProvisioningProfile', 'Key', 'Other'
            ) -Select { param($r) [string] $r.Kind })
    }

    if ($rowsOf.Contains('Environments')) {
        # CheckCount 0 and $null are different answers and must stay apart: no checks
        # configured against checks that could not be read.
        & $add 'Environments' 'Deployment environments by the checks guarding them' (
            & $countBy -Row $rowsOf['Environments'] -Category @(
                'No checks', 'Checks, no approval', 'Approval required', 'Checks unreadable'
            ) -Select {
                param($r)
                if     ($null -eq $r.CheckCount) { 'Checks unreadable' }
                elseif ($r.HasApproval)          { 'Approval required' }
                elseif ($r.CheckCount -gt 0)     { 'Checks, no approval' }
                else                             { 'No checks' }
            })
    }

    if ($rowsOf.Contains('AgentPools')) {
        # Self-hosted pools run on machines somebody owns and patches; an agent that has been
        # offline for years while still enabled is a queue entry waiting for a machine that
        # may no longer be the one it was.
        & $add 'Agent pools' 'Agent pools by hosting and agent state' (
            & $countBy -Row $rowsOf['AgentPools'] -Category @(
                'Microsoft-hosted', 'Self-hosted, offline agents still enabled',
                'Self-hosted, all agents online', 'Self-hosted, no agents'
            ) -Select {
                param($r)
                if     ($r.IsHosted)                        { 'Microsoft-hosted' }
                elseif ([int] $r.AgentsOfflineEnabled -gt 0) { 'Self-hosted, offline agents still enabled' }
                elseif ([int] $r.AgentCount -lt 1)           { 'Self-hosted, no agents' }
                else                                        { 'Self-hosted, all agents online' }
            })
    }

    if ($rowsOf.Contains('Extensions')) {
        # Access is derived from the scopes an extension holds, and 'Manage' over code or
        # service connections is the level worth a second look.
        & $add 'Extensions' 'Extensions by the access they hold' (
            & $countBy -Row $rowsOf['Extensions'] -Category @('Manage', 'Write', 'Read', 'None') -Select {
                param($r) [string] $r.Access
            })
    }

    if ($rowsOf.Contains('PipelineSettings')) {
        # NOT A PARTITION. Each bar counts the projects carrying that one risk, so a project
        # with three of them appears under all three and the bars deliberately overlap.
        # Counted only where the setting was actually read - $null is not collected, and
        # counting it as unsafe would invent findings.
        $settings = $rowsOf['PipelineSettings']
        $risk = [ordered]@{
            'Fork builds enabled'                 = { $_.BuildsEnabledForForks -eq $true }
            'Secrets available to fork builds'    = { $_.SecretsWithheldFromForks -eq $false }
            'Job auth scope not limited'          = { $_.JobAuthScopeLimited -eq $false }
            'Release job auth scope not limited'  = { $_.JobAuthScopeLimitedForReleases -eq $false }
            'Settable variables unrestricted'     = { $_.SettableVarsRestricted -eq $false }
            'Shell arguments not sanitised'       = { $_.ShellArgsSanitised -eq $false }
        }

        $tally = [ordered]@{}
        foreach ($name in $risk.Keys) { $tally[$name] = @($settings | Where-Object $risk[$name]).Count }
        & $add 'Pipeline settings' 'Projects carrying each pipeline risk (bars overlap)' $tally 'BarClustered'
    }

    if ($rowsOf.Contains('OrganizationPolicies')) {
        # NOT A PARTITION either: one bar per policy, 1 when it is on and 0 when it is off, so
        # the whole settings page reads at a glance. Shown as the portal shows it - four
        # policies are named for what they FORBID and the page renders them inverted, so the
        # raw value would disagree with what a reviewer is looking at.
        $tally = [ordered]@{}
        foreach ($policy in $rowsOf['OrganizationPolicies']) {
            $on = if ($policy.IsInverted) { -not [bool] $policy.Value } else { [bool] $policy.Value }
            $label = if ($policy.Setting) { [string] $policy.Setting } else { [string] $policy.Policy }
            $tally[$label] = [int] $on
        }
        & $add 'Organization policies' 'Organization policies that are ON (1 = on, 0 = off)' $tally 'BarClustered'
    }

    if ($rowsOf.Contains('Users')) {
        # One row per (user, group), so members are counted once by descriptor. An account
        # whose origin is 'vsts' exists only inside Azure DevOps - it is not in Entra, so no
        # Conditional Access policy, no lifecycle process and no leaver workflow reaches it.
        $members = @($rowsOf['Users'] | Sort-Object Descriptor -Unique)
        & $add 'Users' 'Organization members by identity origin' (
            & $countBy -Row $members -Category @('Entra (aad)', 'Azure DevOps local (vsts)') -Select {
                param($r)
                switch ([string] $r.Origin) {
                    'aad'   { 'Entra (aad)' }
                    'vsts'  { 'Azure DevOps local (vsts)' }
                    default { if ($_) { "Other ($_)" } else { 'Other (unknown)' } }
                }
            })
    }

    # ---- write ---------------------------------------------------------------------------------

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    # Summary first so it sits directly behind the Dashboard, which is moved to the front last.
    $summary = @()
    $chartSpec = @()

    foreach ($name in $blocks.Keys) {
        $block = $blocks[$name]

        # +2 because row 1 is the header and the first data row is 2.
        $rowStart = $summary.Count + 2
        foreach ($category in $block.Tally.Keys) {
            $summary += [pscustomobject]@{
                Area         = $name
                Category     = $category
                Count        = $block.Tally[$category]
                CollectedUtc = $collectedUtc
            }
        }
        $rowEnd = $summary.Count + 1

        $chartSpec += [pscustomobject]@{
            Sheet     = 'Summary'
            Table     = 'tblSummary'
            XColumn   = 'Category'
            Title     = $block.Title
            Series    = @('Count')
            # Every block shares one sheet, so each chart is pinned to its own rows.
            RowStart  = $rowStart
            RowEnd    = $rowEnd
            ChartType = $block.ChartType
            # Named for the block, not the sheet: they all read Summary, and a name derived
            # from the sheet would give every one of them the same name and leave one chart.
            ChartName = 'chart' + ($name -replace '[^A-Za-z0-9]', '')
        }
    }

    if ($summary.Count) {
        Write-MsecExcelTable -Path $Path -WorksheetName 'Summary' -Row $summary `
                             -TableName 'tblSummary' -TableStyle $TableStyle | Out-Null
    }

    $written = @()
    foreach ($areaName in $areas) {
        $sheet = $sheetOf[$areaName]
        $log = $runLog | Where-Object Area -eq $areaName | Select-Object -First 1

        $rows = if ($rowsOf.Contains($areaName)) { @($rowsOf[$areaName]) } else { @() }

        # Raw is the entire endpoint object as Azure DevOps returned it. It exists so a caller
        # can reach a field this module does not model; in a cell it would render as a type
        # name, so the sheet drops it and the object stream keeps it.
        $forSheet = if ($areaName -eq 'ServiceConnections') {
            @($rows | Select-Object -Property * -ExcludeProperty Raw)
        }
        else { $rows }

        $count = 0
        if (@($forSheet).Count) {
            $count = Write-MsecExcelTable -Path $Path -WorksheetName $sheet -Row @($forSheet) `
                                          -TableName ('tbl' + $sheet) -TableStyle $TableStyle
        }

        $written += [pscustomobject]@{
            PSTypeName = 'MsecAzureDevOpsReportArea'
            Area       = $areaName
            Sheet      = $sheet
            Status     = if ($log) { $log.Status } else { 'Skipped' }
            RowCount   = if ($log -and $log.Status -eq 'Failed') { $null } else { $count }
            Detail     = if ($log) { $log.Detail } else { '' }
            Row        = $rows
        }
    }

    # Last of the data sheets, so it sits at the end of the tab strip where a footnote belongs.
    Write-MsecExcelTable -Path $Path -WorksheetName 'RunLog' -Row @($runLog) `
                         -TableName 'tblRunLog' -TableStyle $TableStyle | Out-Null

    # -Reset because this is a snapshot: the sheets underneath were just replaced wholesale, so
    # there is no reader edit on the Dashboard worth preserving against the risk of a chart
    # left pointing at rows that no longer mean what they did.
    if (-not $chartSpec.Count) {
        Write-Warning "No area produced a chart, so '$Path' has a RunLog and nothing else. Every area either failed or was not selected - the RunLog sheet names which."
    }
    else {
        Add-MsecExcelDashboard -Path $Path -Reset `
            -Heading "Azure DevOps security snapshot - $Organization - collected $collectedUtc UTC" `
            -ChartWidth $ChartWidth -ChartHeight $ChartHeight -Chart @($chartSpec)
    }

    $failed = @($runLog | Where-Object Status -eq 'Failed')
    if ($failed.Count) {
        Write-Warning "$($failed.Count) of $($areas.Count) area(s) could not be collected and have no chart: $(($failed.Area | Sort-Object) -join ', '). See the RunLog sheet."
    }

    if ($PassThru) { $written }
}
