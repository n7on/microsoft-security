function Export-MsecPostureReport {
    <#
    .SYNOPSIS
        Collects the tenant's security posture into an Excel workbook, appending one row
        per measurement per run so the file builds a time series you can chart.

    .DESCRIPTION
        Runs the read-only Get-Msec* commands, then appends a row to each measurement's
        sheet. Nothing is overwritten and nothing is deduped - every run adds rows, so the
        workbook is a growing record of how the tenant's posture moved.

        EVERY CHART IS ON THE DASHBOARD SHEET, first in the workbook, stacked one per row.
        Each plots the RELATED series together - the comparable percentage scores on one
        chart, the four incident severities on another, one line per Azure subscription on a
        third. Related numbers on a shared axis is the point; a chart per metric would tell
        you far less.

        THE DASHBOARD IS SET UP TO PRINT, one chart per page. A4 landscape, fit to one page
        wide and as many tall as it takes, with a page break above every chart and a print
        area covering them - charts are drawings anchored to cells, so they print only if
        those cells are inside it, and without that a PDF export comes out as blank pages.
        Page settings that are a matter of taste (orientation, paper, margins) are written
        only when the sheet is first created, so switching to A3 in Excel is not undone.

        CHARTS ARE SIZED FOR PASTING INTO WORD, not for filling Excel's page. Word pastes a
        copied chart at its true pixel size with no scaling, so the document's printable
        width is the real constraint - about 602 px on A4 portrait at standard margins, 930
        on landscape. A chart sized to fill Excel's own landscape page is wider than either
        and has to be dragged smaller on every paste, so the default (-ChartWidth 600) fits
        the tighter case and therefore any document. Excel printing does not lose out: the
        print area follows the chart width, so fit-to-one-page-wide scales the narrow band
        back up to fill the sheet.

        THE CHARTS ARE NOT REBUILT ON LATER RUNS. Their series use ordinary cell ranges,
        which are pinned to the row count they were written with, so the ranges are refreshed
        in place as rows are appended. Title, size, colours and any series you added yourself
        all survive.

        POSITION IS THE EXCEPTION - it belongs to the layout and is reasserted every run,
        because it is what the page breaks are aligned to. It also has to be: charts are
        packed densely, so a chart that stayed where it was would have its neighbour drawn
        straight on top of it.

        ONLY MEASUREMENTS THAT HAVE ACTUALLY PRODUCED A ROW GET A CHART, and they are packed
        one after another with no gaps. Running a single measurement gives a dashboard with a
        single chart at the top, not one chart several blank pages down. The consequence worth
        knowing: the first time a new measurement lands, every chart below it moves down one
        page. That happens once - a data sheet never loses its rows, so the layout only ever
        settles further - and the alternative was a permanent blank page for every measurement
        this tenant does not collect.

        Series colours are NOT set: Excel's own theme palette applies, so the charts match
        the workbook and follow it if you change the theme.

        Sheets, each data sheet written as an Excel table:
          Dashboard              every chart, first in the workbook
          Scores                 Secure Score, exposure, device configuration score
          SecureScoreByCategory  one column per Secure Score category (Identity, Device, ...)
          AzureSecureScore       one column per Azure subscription
          PolicyCompliance       one column per Azure Policy initiative
          PrivilegedAccess       standing vs PIM-eligible admins, and who else holds a role
          MfaCoverage            MFA capability overall and for admins
          DeviceCompliance       Intune compliance mix, aggregated from Get-MsecIntuneDevice
          DevicePlatform         one column per OS family (Windows, macOS, iOS, Android, ...)
          DeviceOsVersion        one column per OS release (Windows 11, iOS 17, ...)
          Incidents              Defender XDR volume, severity mix and time-to-resolve
          Email                  inbound volume, delivery actions, threat types
          ConditionalAccess      sign-in outcomes, risk, report-only would-blocks
          TenantSettings         security defaults, admin counts, licensing posture
          RunLog                 what ran, what failed and why

        PRIVILEGED ACCESS IS COUNTED IN PEOPLE, NOT ASSIGNMENTS. Someone holding Global
        Administrator, Security Administrator and Exchange Administrator is ONE administrator;
        counting rows would say three, and would move whenever the same faces swapped roles.
        Holders are counted, so a role reaching someone through a role-assignable group counts
        the person, and StandingPrivileged against EligiblePrivileged is the PIM adoption story
        over time.

        GlobalAdminHolders there can exceed GlobalAdministratorCount on TenantSettings. They
        are not in conflict: this one counts effective holders including group-inherited and
        PIM-eligible ones, the other counts the assignment side.

        AZURE SECURE SCORE IS ONE COLUMN PER SUBSCRIPTION, not a tenant-wide average -
        averaging a well-run production subscription with a neglected sandbox produces a
        number that describes neither. That does mean the columns follow your subscriptions:
        a new subscription adds a column (and triggers the one-off reshape described under
        Add-MsecExcelRow), and -Subscription is how you keep the sheet to the ones you
        actually report on.

        DEGRADES RATHER THAN FAILS. Each measurement is collected independently. A tenant
        without Defender for Endpoint, or without Entra ID P1, answers 403 on some of these
        and that is a licensing fact rather than a bug - so the failure is recorded in
        RunLog and every other measurement still lands. A missing measurement contributes
        NO row, which leaves a visible gap in its chart rather than a fabricated zero.

        SECURE SCORE IS TRIMMED TO ITS NEWEST SNAPSHOT. Get-MsecSecureScore returns roughly
        90 days of history on every call. Appending all of it would add ~90 largely
        duplicate rows per run, so only the most recent snapshot is taken and each run
        contributes one row like every other measurement. The consequence worth knowing:
        the chart starts empty and fills in one point per run, rather than arriving with
        three months of backfill.

    .PARAMETER Path
        The .xlsx to append to. Created on first run.

    .PARAMETER Days
        Look-back window for the measurements that summarise a period - incidents, email
        and Conditional Access sign-ins. Default 30. Recorded as WindowDays on those sheets,
        because a row means nothing without knowing what window it covered.

    .PARAMETER Measurement
        Collect only these. Default is all of them. Useful for a quick top-up, or to skip
        one that is slow or unlicensed on this tenant.

    .PARAMETER Subscription
        Which Azure subscriptions the AzureSecureScore sheet covers. Names or ids, or a mix -
        names are resolved through the same lookup Search-MsecAzureResourceGraph uses, and a
        name matching none or several throws with the candidates rather than guessing. Omit
        for every subscription the session can see.

    .PARAMETER PolicyInitiative
        Which Azure Policy initiatives the PolicyCompliance sheet covers, as wildcards matched
        against the initiative's display name. Omit for every initiative grading at least one
        resource - which on a large estate is more lines than one chart can carry, hence the
        warning past eight.

    .PARAMETER Target
        Sheet name mapped to a target value, e.g. @{ MfaCoverage = 95; PolicyCompliance = 80 }.
        Each becomes a Target column on that sheet holding the same number on every row, which
        Excel plots as a flat line across the chart - so the goal sits alongside the trend
        instead of living in someone's head.

        Only the sheets you name get one, so charts you have no target for are untouched. The
        value is in the chart's own units: a percentage on the percentage charts, a count on
        Incidents or TenantSettings (@{ Incidents = 0 } draws a zero line under the severity
        counts). Raising a target later shows as a step in the line rather than rewriting
        history, because it is stored per row.

    .PARAMETER TableStyle
        Excel table style for every data sheet. One of Light1-21, Medium1-28 or Dark1-11 -
        tab-completes. Default Medium2. It is applied on every run, not just when a sheet is
        created, so changing it restyles the existing sheets next time rather than leaving
        the old ones behind.

    .PARAMETER ChartWidth
        Chart width in pixels, default 600. Sized so a chart pasted into Word fits an A4
        PORTRAIT page at standard margins - Word pastes at true pixel size with no scaling,
        so anything wider has to be resized by hand every time. About 900 suits landscape
        documents. Printing from Excel is unaffected either way: the print area follows the
        chart width and fit-to-one-page-wide scales it up to fill the sheet.

    .PARAMETER ChartHeight
        Chart height in pixels, default 370. Also sets the row band each chart occupies, and
        therefore where the page breaks fall.

    .PARAMETER ResetDashboard
        Rebuild the Dashboard sheet from scratch. Charts are created once and afterwards only
        range-refreshed, so a change to -ChartWidth or -ChartHeight does not reach charts that
        already exist - this is how to apply one. It discards manual edits on the Dashboard;
        the data sheets and their accumulated history are untouched.

    .PARAMETER PassThru
        Emit the collected rows as objects as well as writing them.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Export-MsecPostureReport -Path ./posture.xlsx

    .EXAMPLE
        # Monthly, with a matching window, straight into a synced SharePoint library.
        $lib = "$HOME/Library/CloudStorage/OneDrive-SharedLibraries-Contoso/Security - Documents"
        Export-MsecPostureReport -Path "$lib/tenant-posture.xlsx" -Days 30

    .EXAMPLE
        # Only the production subscriptions on the Azure sheet, by name.
        Export-MsecPostureReport -Path ./posture.xlsx -Subscription 'PROD', 'PROD-EU'

    .EXAMPLE
        # Just the scores, and see what came back.
        Export-MsecPostureReport -Path ./posture.xlsx -Measurement Scores -PassThru

    .OUTPUTS
        With -PassThru, one PSCustomObject per sheet written, each carrying Sheet, RowCount
        and the row itself. Always writes the workbook.

    .NOTES
        Needs the ImportExcel module: Install-Module ImportExcel -Scope CurrentUser.

        RunUtc is written as an ISO-8601 STRING, not a DateTime. Excel dates round-trip
        through Import-Excel as OADate serial numbers, and re-exporting them turns a date
        column into five-digit integers on the second run. A string survives the
        read-modify-write intact and charts fine as a category axis.

        The workbook must not be open in Excel while this runs - the file is locked and the
        write fails.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [ValidateRange(1, 180)]
        [int] $Days = 30,

        [ValidateSet('Scores', 'SecureScoreByCategory', 'AzureSecureScore', 'MfaCoverage',
                     'Incidents', 'Email', 'ConditionalAccess', 'TenantSettings', 'DeviceCompliance',
                     'PolicyCompliance', 'PrivilegedAccess',
                     'DevicePlatform', 'DeviceOsVersion')]
        [string[]] $Measurement,

        [string[]] $Subscription,

        # Wildcards, matched against the initiative's display name. Omit for every initiative
        # that grades at least one resource.
        [string[]] $PolicyInitiative,

        # Sheet name -> target value, e.g. @{ MfaCoverage = 95; PolicyCompliance = 80 }.
        [hashtable] $Target = @{},

        # [string], not the EPPlus enum: that type only exists once ImportExcel is imported,
        # and a parameter's type is resolved when the function is DEFINED - naming it here
        # would break `Import-Module Msec` on any machine without ImportExcel. Validated by
        # the cast below instead, which gives the same error surface a shade later.
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            # Enumerated from EPPlus when it is loaded, so the list cannot drift from the
            # library; the literal groups are the fallback for completing before first use.
            $names = if ('OfficeOpenXml.Table.TableStyles' -as [type]) {
                [Enum]::GetNames([OfficeOpenXml.Table.TableStyles])
            }
            else {
                @('None') + (1..21 | ForEach-Object { "Light$_" }) +
                            (1..28 | ForEach-Object { "Medium$_" }) +
                            (1..11 | ForEach-Object { "Dark$_" })
            }
            $names | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
        })]
        [string] $TableStyle = 'Medium2',

        # Chart size in pixels. The default fits an A4 PORTRAIT Word page at standard
        # margins (~602 px of printable width), so a chart copied out of Excel and pasted
        # into a document arrives at a usable size without being dragged smaller. Raise to
        # about 900 if your documents are landscape and you want the extra width.
        [ValidateRange(200, 2000)]
        [int] $ChartWidth = 600,

        [ValidateRange(150, 1200)]
        [int] $ChartHeight = 370,

        # Rebuild the Dashboard sheet from scratch. Charts are otherwise created once and
        # never resized, so a workbook built before a -ChartWidth change keeps the old size
        # until this is passed. Discards manual edits on that sheet - the data sheets and
        # their history are untouched.
        [switch] $ResetDashboard,

        [switch] $PassThru
    )

    Assert-MsecSession

    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        throw 'ImportExcel is required for Export-MsecPostureReport. Install with: Install-Module ImportExcel -Scope CurrentUser'
    }
    Import-Module ImportExcel -ErrorAction Stop

    # Validated here rather than by a parameter type, for the reason noted on -TableStyle.
    # Done BEFORE any collection, so a typo costs nothing - collecting nine measurements and
    # then failing on the write would be minutes of Graph calls thrown away.
    if (-not ($TableStyle -as [OfficeOpenXml.Table.TableStyles])) {
        throw "'$TableStyle' is not an Excel table style. Use one of Light1-21, Medium1-28 or Dark1-11 (for example Medium2, the default)."
    }

    $runUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')
    $tenantId = $script:MsecSession.TenantId
    $wanted   = if ($Measurement) { $Measurement } else {
        @('Scores', 'SecureScoreByCategory', 'AzureSecureScore', 'MfaCoverage',
          'Incidents', 'Email', 'ConditionalAccess', 'TenantSettings', 'DeviceCompliance',
          'PolicyCompliance', 'PrivilegedAccess',
          'DevicePlatform', 'DeviceOsVersion')
    }

    # Resolved up front, outside the per-measurement try/catch, so a name that matches
    # nothing fails immediately and loudly rather than being recorded as "Azure Secure Score
    # was unavailable" - a typo in a subscription name should not look like a licensing gap.
    $subscriptionId = if ($Subscription) { @(Resolve-MsecSubscription -Subscription $Subscription) } else { @() }

    $runLog = [System.Collections.Generic.List[object]]::new()

    # Collect one source. Returns $null on failure and records why - the caller decides
    # what a missing source means for its sheet, which is not always "skip the sheet":
    # the Scores row is still worth writing when three of its four sources answered.
    function Get-Source {
        param([string] $Name, [scriptblock] $Command)

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $result = & $Command
            $runLog.Add([pscustomobject]@{
                RunUtc = $runUtc; Source = $Name; Status = 'Succeeded'
                DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1); Message = $null
            })
            return $result
        }
        catch {
            $message = $_.Exception.Message
            Write-Warning "$Name failed and will be absent from this run: $message"
            $runLog.Add([pscustomobject]@{
                RunUtc = $runUtc; Source = $Name; Status = 'Failed'
                DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1); Message = $message
            })
            return $null
        }
    }

    # ---- collect -------------------------------------------------------------------------

    $needScores = ('Scores' -in $wanted) -or ('SecureScoreByCategory' -in $wanted)

    $secureScore = $null
    if ($needScores) {
        $all = Get-Source 'Get-MsecSecureScore' { Get-MsecSecureScore }
        if ($all) {
            # Trim to the newest snapshot: every call returns ~90 days and only the latest
            # is this run's data point.
            #
            # Grouped by DAY, not by exact timestamp. Secure Score snapshots are daily, and
            # today Get-MsecSecureScore parses createdDateTime once per snapshot so every
            # row of one snapshot shares identical ticks - but matching on those ticks makes
            # this silently drop the Overall row the moment that stops holding, leaving the
            # report's headline metric blank while every other column looks fine. Day
            # granularity is what "the newest snapshot" means here anyway.
            $newestDay = ($all | Measure-Object -Property Date -Maximum).Maximum.Date
            $secureScore = @($all | Where-Object { $_.Date.Date -eq $newestDay })
        }
    }

    $exposure = $null; $deviceConfig = $null
    if ('Scores' -in $wanted) {
        $exposure     = Get-Source 'Get-MsecDefenderScoreExposure'            { Get-MsecDefenderScoreExposure }
        $deviceConfig = Get-Source 'Get-MsecDefenderScoreDeviceConfiguration' { Get-MsecDefenderScoreDeviceConfiguration }
    }

    $azureScore = $null
    if ('AzureSecureScore' -in $wanted) {
        $azureScore = Get-Source 'Get-MsecAzureSecureScore' {
            if ($subscriptionId.Count) { Get-MsecAzureSecureScore -SubscriptionId $subscriptionId }
            else                       { Get-MsecAzureSecureScore }
        }
    }

    $mfa       = if ('MfaCoverage' -in $wanted)       { Get-Source 'Get-MsecEntraMfaRegistrationStats'  { Get-MsecEntraMfaRegistrationStats } }
    $incidents = if ('Incidents' -in $wanted)         { Get-Source 'Get-MsecDefenderIncidentStats'      { Get-MsecDefenderIncidentStats -Days $Days } }
    $email     = if ('Email' -in $wanted)             { Get-Source 'Get-MsecDefenderEmailStats'         { Get-MsecDefenderEmailStats -Days $Days } }
    $ca        = if ('ConditionalAccess' -in $wanted) { Get-Source 'Get-MsecEntraConditionalAccessStats' { Get-MsecEntraConditionalAccessStats -Days $Days } }
    $tenant    = if ('TenantSettings' -in $wanted)    { Get-Source 'Get-MsecEntraTenantSecuritySetting'  { Get-MsecEntraTenantSecuritySetting } }

    # Get-MsecIntuneDevice returns one row PER DEVICE, so the compliance mix is aggregated
    # here rather than read off a summary property - there isn't one.
    $needDevices = @('DeviceCompliance', 'DevicePlatform', 'DeviceOsVersion') |
                       Where-Object { $_ -in $wanted }
    $devices = if ($needDevices) { Get-Source 'Get-MsecIntuneDevice' { Get-MsecIntuneDevice } }

    # Every role holder, not just the highly privileged ones: the counts below need to tell
    # 'privileged' from 'any role', and filtering here would make that impossible. Groups are
    # expanded, so a role held through a role-assignable group counts the PEOPLE in it.
    $roleHolders = if ('PrivilegedAccess' -in $wanted) {
        Get-Source 'Get-MsecEntraRoleHolder' { Get-MsecEntraRoleHolder }
    }

    # Azure Policy, via Resource Graph rather than Graph - so this one needs an Az context
    # where the rest need only the msec session. Running without one fails this measurement
    # and nothing else, which is the right shape: a tenant report should not be held hostage
    # to whether Connect-AzAccount has been run.
    $policy = if ('PolicyCompliance' -in $wanted) {
        # msec runs on TWO identities: the app-only session from Connect-Msec (Graph, and so
        # every other measurement here) and your Az context (ARM, and so this one). They move
        # independently, and Connect-Msec does NOT move the Az context.
        #
        # That matters most in the loop this report invites - connect to tenant A, export;
        # connect to tenant B, export. Without switching the Az context too, tenant B's
        # workbook silently gets tenant A's policy compliance: a plausible number, in the
        # wrong file, in a compliance report. So a mismatch SKIPS the measurement rather than
        # writing it. A gap in the chart is recoverable; a wrong number nobody questions is not.
        $azTenant = (Get-AzContext -ErrorAction SilentlyContinue).Tenant.Id
        if ($azTenant -and $tenantId -and $azTenant -ne $tenantId) {
            $message = "Az context is on tenant $azTenant but this session is connected to $tenantId, so Azure Policy compliance would be the WRONG TENANT'S data. Skipped. Move the Az context with Select-MsecAzureContext, or exclude it with -Measurement."
            Write-Warning $message
            $runLog.Add([pscustomobject]@{
                RunUtc = $runUtc; Source = 'Search-MsecAzureResourceGraph (Policy/Compliance)'
                Status = 'Skipped'; DurationSeconds = 0; Message = $message
            })
            $null
        }
        else {
            Get-Source 'Search-MsecAzureResourceGraph (Policy/Compliance)' {
                if ($subscriptionId.Count) {
                    Search-MsecAzureResourceGraph -ResourceType Policy -Name Compliance -Subscription $subscriptionId
                }
                else {
                    Search-MsecAzureResourceGraph -ResourceType Policy -Name Compliance
                }
            }
        }
    }

    # ---- compose ---------------------------------------------------------------------------

    $sheets = [System.Collections.Generic.List[object]]::new()

    # Two charts have series that are not fixed - Graph decides the Secure Score categories,
    # and your estate decides the subscriptions - so the column names are captured as they
    # are composed and handed to the dashboard. Empty means that chart is skipped this run
    # and drawn whenever the measurement next succeeds.
    #
    # Declared HERE, above every composition block. Declaring them further down reset
    # $azureSubscriptionColumn to empty AFTER the Azure block had filled it, which silently
    # dropped that one chart from the dashboard while every other one appeared.
    $secureScoreCategories   = @()
    $azureSubscriptionColumn = @()
    $policyInitiativeColumn  = @()
    $devicePlatformColumn    = @()
    $deviceOsVersionColumn   = @()

    if ('Scores' -in $wanted) {
        $overall = $secureScore | Where-Object ScoreType -eq 'Overall' | Select-Object -First 1

        # DeviceConfigurationScore is raw points, not a percentage. It sits on this sheet
        # beside three 0-100 figures, so plot it on a secondary axis or its own chart - on a
        # shared axis a ~400-point series flattens the percentages into a line at the bottom.
        $row = [ordered]@{
            RunUtc                   = $runUtc
            TenantId                 = $tenantId
            SecureScorePercent       = $overall.ScorePercent
            ExposurePercent          = ($exposure | Select-Object -First 1).ScorePercent
            DeviceConfigurationScore = ($deviceConfig | Select-Object -First 1).Score
        }
        if ($row.Values | Where-Object { $null -ne $_ -and $_ -ne $runUtc -and $_ -ne $tenantId }) {
            $sheets.Add([pscustomobject]@{
                Sheet = 'Scores'
                Table = 'tblScores'
                Row   = [pscustomobject] $row
            })
        }
    }

    if (('AzureSecureScore' -in $wanted) -and $azureScore) {
        $perSubscription = @($azureScore | Where-Object ScoreType -eq 'Overall' | Sort-Object SubscriptionName)

        # Subscription NAMES are the column headers, because a GUID column tells the reader
        # nothing. Names are not unique though - an estate can genuinely hold three
        # subscriptions called 'Cloud Subscription' - so a repeated name is disambiguated
        # with the leading octet of its id rather than silently overwriting the earlier
        # column and losing a whole subscription from the report.
        # NOT named $subscription: that is this function's [string[]] parameter, and a typed
        # parameter keeps its type constraint for the whole scope - so assigning a
        # PSCustomObject to it silently COERCES the object to a string, after which
        # .SubscriptionName is $null and every column header vanishes.
        $seen = @{}
        $row = [ordered]@{ RunUtc = $runUtc; TenantId = $tenantId }
        foreach ($sub in $perSubscription) {
            $name = if ($sub.SubscriptionName) { $sub.SubscriptionName } else { $sub.SubscriptionId }
            if (-not $name) { continue }

            if ($seen.ContainsKey($name)) {
                $name = "$name ($($sub.SubscriptionId.Split('-')[0]))"
            }
            $seen[$name] = $true
            $row[$name] = $sub.ScorePercent
        }
        $azureSubscriptionColumn = @($seen.Keys)

        if ($perSubscription.Count) {
            $sheets.Add([pscustomobject]@{
                Sheet = 'AzureSecureScore'
                Table = 'tblAzureSecureScore'
                Row   = [pscustomobject] $row
            })
        }
    }

    if (('SecureScoreByCategory' -in $wanted) -and $secureScore) {
        $row = [ordered]@{ RunUtc = $runUtc; TenantId = $tenantId }
        $categories = @($secureScore | Where-Object ScoreType -ne 'Overall' | Sort-Object ScoreType)
        foreach ($category in $categories) { $row[$category.ScoreType] = $category.ScorePercent }
        $secureScoreCategories = @($categories.ScoreType)

        if ($categories.Count) {
            $sheets.Add([pscustomobject]@{
                Sheet  = 'SecureScoreByCategory'
                Table  = 'tblSecureScoreByCategory'
                Row    = [pscustomobject] $row
            })
        }
    }

    if ($mfa) {
        $sheets.Add([pscustomobject]@{
            Sheet  = 'MfaCoverage'
            Table  = 'tblMfaCoverage'
            Row    = [pscustomobject]@{
                RunUtc                     = $runUtc
                TenantId                   = $tenantId
                TotalUsers                 = $mfa.TotalUsers
                Members                    = $mfa.Members
                Guests                     = $mfa.Guests
                MfaCapable                 = $mfa.MfaCapable
                MfaCapablePercent          = $mfa.MfaCapablePercent
                NotMfaCapable              = $mfa.NotMfaCapable
                AdminTotal                 = $mfa.AdminTotal
                AdminMfaCapable            = $mfa.AdminMfaCapable
                AdminMfaCapablePercent     = $mfa.AdminMfaCapablePercent
                AdminsNotMfaCapable        = $mfa.AdminsNotMfaCapable
                PasswordlessCapablePercent = $mfa.PasswordlessCapablePercent
                PhoneOnlyMfaCapablePercent = $mfa.PhoneOnlyMfaCapablePercent
                SsprCapablePercent         = $mfa.SsprCapablePercent
            }
        })
    }

    if ($incidents) {
        $sheets.Add([pscustomobject]@{
            Sheet  = 'Incidents'
            Table  = 'tblIncidents'
            Row    = [pscustomobject]@{
                RunUtc                   = $runUtc
                TenantId                 = $tenantId
                WindowDays               = $Days
                TotalCreated             = $incidents.TotalCreated
                High                     = $incidents.High
                Medium                   = $incidents.Medium
                Low                      = $incidents.Low
                Informational            = $incidents.Informational
                TruePositive             = $incidents.TruePositive
                FalsePositive            = $incidents.FalsePositive
                BenignPositive           = $incidents.BenignPositive
                Unclassified             = $incidents.Unclassified
                TotalResolvedInWindow    = $incidents.TotalResolvedInWindow
                MeanTimeToResolveHours   = $incidents.MeanTimeToResolveHours
                MedianTimeToResolveHours = $incidents.MedianTimeToResolveHours
                CurrentlyOpen            = $incidents.CurrentlyOpen
                OldestOpenAgeDays        = $incidents.OldestOpenAgeDays
            }
        })
    }

    if ($email) {
        $sheets.Add([pscustomobject]@{
            Sheet  = 'Email'
            Table  = 'tblEmail'
            Row    = [pscustomobject]@{
                RunUtc          = $runUtc
                TenantId        = $tenantId
                WindowDays      = $Days
                Total           = $email.Total
                Delivered       = $email.Delivered
                Junked          = $email.Junked
                Blocked         = $email.Blocked
                Replaced        = $email.Replaced
                Phishing        = $email.Phishing
                Spam            = $email.Spam
                Malware         = $email.Malware
                DeliveredPercent = $email.DeliveredPercent
                BlockedPercent  = $email.BlockedPercent
                PhishingPercent = $email.PhishingPercent
            }
        })
    }

    if ($ca) {
        $sheets.Add([pscustomobject]@{
            Sheet  = 'ConditionalAccess'
            Table  = 'tblConditionalAccess'
            Row    = [pscustomobject]@{
                RunUtc               = $runUtc
                TenantId             = $tenantId
                WindowDays           = $Days
                TotalSignIns         = $ca.TotalSignIns
                UniqueUsers          = $ca.UniqueUsers
                CaSuccess            = $ca.CaSuccess
                CaFailure            = $ca.CaFailure
                CaNotApplied         = $ca.CaNotApplied
                CaSuccessPercent     = $ca.CaSuccessPercent
                CaFailurePercent     = $ca.CaFailurePercent
                HighRiskSignIns      = $ca.HighRiskSignIns
                MediumRiskSignIns    = $ca.MediumRiskSignIns
                ReportOnlyWouldBlock = $ca.ReportOnlyWouldBlock
                TopFailingPolicies   = $ca.TopFailingPolicies
            }
        })
    }

    if ($tenant) {
        $sheets.Add([pscustomobject]@{
            Sheet  = 'TenantSettings'
            Table  = 'tblTenantSettings'
            Row    = [pscustomobject]@{
                RunUtc                        = $runUtc
                TenantId                      = $tenant.TenantId
                SecurityDefaultsEnabled       = $tenant.SecurityDefaultsEnabled
                ConditionalAccessAvailable    = $tenant.ConditionalAccessAvailable
                EntraIdPremium                = $tenant.EntraIdPremium
                GlobalAdministratorCount      = $tenant.GlobalAdministratorCount
                HighlyPrivilegedMemberCount   = $tenant.HighlyPrivilegedMemberCount
                ActivatedRoleCount            = $tenant.ActivatedRoleCount
                PimAvailable                  = $tenant.PimAvailable
                IdentityProtectionAvailable   = $tenant.IdentityProtectionAvailable
                DefenderForEndpointProvisioned = $tenant.DefenderForEndpointProvisioned
                DefenderForOffice365Provisioned = $tenant.DefenderForOffice365Provisioned
                IntuneProvisioned             = $tenant.IntuneProvisioned
                GuestUserRole                 = $tenant.GuestUserRole
                AllowInvitesFrom              = $tenant.AllowInvitesFrom
                DefaultUserRoleCanCreateApps  = $tenant.DefaultUserRoleCanCreateApps
                LicensedSkuCount              = $tenant.LicensedSkuCount
            }
        })
    }

    if ($devices) {
        $all = @($devices)
        $count = { param($state) @($all | Where-Object ComplianceState -eq $state).Count }

        $compliant = & $count 'compliant'
        $sheets.Add([pscustomobject]@{
            Sheet  = 'DeviceCompliance'
            Table  = 'tblDeviceCompliance'
            Row    = [pscustomobject]@{
                RunUtc           = $runUtc
                TenantId         = $tenantId
                TotalDevices     = $all.Count
                Compliant        = $compliant
                Noncompliant     = (& $count 'noncompliant')
                InGracePeriod    = (& $count 'inGracePeriod')
                ConfigManager    = (& $count 'configManager')
                Error            = (& $count 'error')
                Conflict         = (& $count 'conflict')
                NotAssigned      = (& $count 'notAssigned')
                Unknown          = (& $count 'unknown')
                # Of ALL enrolled devices, not just those in a assigned/known state: a device
                # that errored or was never assigned a policy is not compliant, and counting
                # it out of the denominator would flatter the number exactly where it matters.
                CompliantPercent = $(if ($all.Count) { [math]::Round($compliant / $all.Count * 100, 2) } else { $null })
                Encrypted        = @($all | Where-Object IsEncrypted -eq $true).Count
            }
        })
    }
    # ONE COLUMN PER OS FAMILY, and per RELEASE on the sheet below. Both are counts of devices
    # rather than percentages, because the question is "how many are still on the old one" and
    # a percentage hides an estate that is shrinking or growing underneath it. TotalDevices is
    # carried on both so the columns can be checked against it.
    if (('DevicePlatform' -in $wanted) -and $devices) {
        $all = @($devices)

        $row = [ordered]@{ RunUtc = $runUtc; TenantId = $tenantId; TotalDevices = $all.Count }

        # Sorted, so the column order is stable from run to run rather than following whatever
        # order Intune answered in. A NEW platform still lands at the end - Add-MsecExcelRow
        # takes the union and never reorders history.
        $platforms = @($all | ForEach-Object {
            if ([string]::IsNullOrWhiteSpace($_.Os)) { 'Unknown' } else { $_.Os.Trim() }
        } | Sort-Object -Unique)

        foreach ($platform in $platforms) {
            $row[$platform] = @($all | Where-Object {
                $name = if ([string]::IsNullOrWhiteSpace($_.Os)) { 'Unknown' } else { $_.Os.Trim() }
                $name -eq $platform
            }).Count
        }
        $devicePlatformColumn = @($platforms)

        # A RELEASE THAT EMPTIES OUT MUST READ AS 0, NOT AS BLANK. Columns here are discovered
        # from the data, so the run where the last device leaves iOS 26 simply stops producing
        # that column - and Export-Excel -Append maps by name, leaving the cell EMPTY. Excel
        # plots a blank as a GAP, so the line stops dead exactly where it should have descended
        # to zero: "we stopped measuring" instead of "nobody is on it any more", which is the
        # good news you most want to see.
        #
        # It also stops the sheet being rewritten every time the release set changes - a column
        # going missing is schema drift as much as a column appearing.
        #
        # This is right for COUNTS and wrong for scores, which is why it is not done generally:
        # a subscription that drops out of AzureSecureScore was not measured, and writing 0
        # there would report a perfect-zero score rather than an absence.
        foreach ($column in (Get-MsecExcelHeader -Path $Path -WorksheetName 'DevicePlatform')) {
            if ($column -in 'RunUtc', 'TenantId', 'TotalDevices', 'Target') { continue }
            if (-not $row.Contains($column)) { $row[$column] = 0 }
        }
        $sheets.Add([pscustomobject]@{
            Sheet = 'DevicePlatform'
            Table = 'tblDevicePlatform'
            Row   = [pscustomobject] $row
        })
    }

    if (('DeviceOsVersion' -in $wanted) -and $devices) {
        $all = @($devices)

        # The RELEASE, not the raw version: '10.0.22631.3155' would be a different column on
        # every patch Tuesday, reshaping the sheet every run and turning the chart into a
        # hundred one-point series. See ConvertTo-MsecDeviceOsRelease for why Windows 11 needs
        # the build number to be told from Windows 10 at all.
        $releases = @{}
        foreach ($device in $all) {
            $release = ConvertTo-MsecDeviceOsRelease -Os $device.Os -Version $device.OsVersion
            if (-not $releases.ContainsKey($release)) { $releases[$release] = 0 }
            $releases[$release]++
        }

        $row = [ordered]@{ RunUtc = $runUtc; TenantId = $tenantId; TotalDevices = $all.Count }
        foreach ($release in @($releases.Keys | Sort-Object)) { $row[$release] = $releases[$release] }
        $deviceOsVersionColumn = @($releases.Keys | Sort-Object)

        # A RELEASE THAT EMPTIES OUT MUST READ AS 0, NOT AS BLANK. Columns here are discovered
        # from the data, so the run where the last device leaves iOS 26 simply stops producing
        # that column - and Export-Excel -Append maps by name, leaving the cell EMPTY. Excel
        # plots a blank as a GAP, so the line stops dead exactly where it should have descended
        # to zero: "we stopped measuring" instead of "nobody is on it any more", which is the
        # good news you most want to see.
        #
        # It also stops the sheet being rewritten every time the release set changes - a column
        # going missing is schema drift as much as a column appearing.
        #
        # This is right for COUNTS and wrong for scores, which is why it is not done generally:
        # a subscription that drops out of AzureSecureScore was not measured, and writing 0
        # there would report a perfect-zero score rather than an absence.
        foreach ($column in (Get-MsecExcelHeader -Path $Path -WorksheetName 'DeviceOsVersion')) {
            if ($column -in 'RunUtc', 'TenantId', 'TotalDevices', 'Target') { continue }
            if (-not $row.Contains($column)) { $row[$column] = 0 }
        }

        # Same reasoning as the policy initiative warning: past a certain number of series the
        # chart stops being readable, and it is better to say so than to draw it anyway.
        if ($deviceOsVersionColumn.Count -gt 12) {
            Write-Warning "$($deviceOsVersionColumn.Count) distinct OS releases are in scope, which is more lines than one chart can carry legibly. The DeviceOsVersion sheet still holds every column; consider reading it as a table rather than a chart."
        }

        $sheets.Add([pscustomobject]@{
            Sheet = 'DeviceOsVersion'
            Table = 'tblDeviceOsVersion'
            Row   = [pscustomobject] $row
        })
    }


    if ($policy) {
        # One column per INITIATIVE, aggregated across the subscriptions in scope. The
        # aggregate is recomputed from the resource counts - total compliant / total graded -
        # NOT averaged from the per-subscription percentages. Averaging percentages gives a
        # subscription holding four resources the same weight as one holding four hundred,
        # which produces a number that matches no subscription and moves for no reason.
        $byInitiative = $policy |
            Where-Object { $_.Resources -gt 0 } |
            Group-Object Initiative

        if ($PolicyInitiative) {
            $available = @($byInitiative.Name)

            # A pattern matching nothing is almost always a naming assumption that did not
            # hold - '*ISO27001*' where the assignment is called 'ISO 27001:2013', or a
            # standard nobody has actually assigned. Left silent it costs a column, and a
            # missing line on a compliance chart reads as "we have no data" rather than "you
            # asked for something that is not here". So each pattern is checked on its own.
            foreach ($pattern in $PolicyInitiative) {
                if (-not @($available | Where-Object { $_ -like $pattern }).Count) {
                    Write-Warning "No policy initiative matches '$pattern', so it contributes no column. In scope: $($available -join ', ')"
                }
            }

            $byInitiative = @($byInitiative | Where-Object {
                $name = $_.Name
                @($PolicyInitiative | Where-Object { $name -like $_ }).Count -gt 0
            })
        }

        # Widest coverage first, so the leftmost columns - and therefore the first chart
        # series - are the initiatives grading most of the estate.
        $byInitiative = @($byInitiative | Sort-Object {
            ($_.Group | Measure-Object -Property Resources -Sum).Sum
        } -Descending)

        $row = [ordered]@{ RunUtc = $runUtc; TenantId = $tenantId }
        foreach ($group in $byInitiative) {
            $compliant = ($group.Group | Measure-Object -Property CompliantResources -Sum).Sum
            $graded    = ($group.Group | Measure-Object -Property Resources -Sum).Sum
            if ($graded) { $row[$group.Name] = [math]::Round(100 * $compliant / $graded, 2) }
        }

        $policyInitiativeColumn = @($byInitiative.Name)

        if ($policyInitiativeColumn.Count -gt 8) {
            Write-Warning "$($policyInitiativeColumn.Count) policy initiatives are in scope, so the PolicyCompliance chart will have that many lines and be hard to read. Narrow it with -PolicyInitiative, e.g. -PolicyInitiative '*Benchmark*'."
        }

        if ($policyInitiativeColumn.Count) {
            $sheets.Add([pscustomobject]@{
                Sheet = 'PolicyCompliance'
                Table = 'tblPolicyCompliance'
                Row   = [pscustomobject] $row
            })
        }
    }

    if ($roleHolders) {
        $privileged = @($roleHolders | Where-Object IsHighlyPrivileged)

        # COUNTED AS DISTINCT PEOPLE, not as assignments. Someone holding Global Administrator,
        # Security Administrator and Exchange Administrator is ONE administrator; counting rows
        # would report three and move whenever roles were shuffled between the same faces.
        # EffectiveId is the holder - the person a role reaches through a group, not the group.
        $distinct = {
            param($rows)
            @($rows | Where-Object EffectiveId | Select-Object -ExpandProperty EffectiveId -Unique).Count
        }

        $active   = @($privileged | Where-Object AssignmentType -eq 'Active')
        $eligible = @($privileged | Where-Object AssignmentType -eq 'Eligible')

        $row = [ordered]@{
            RunUtc   = $runUtc
            TenantId = $tenantId

            # The story this chart is for: standing privilege down, eligible up. A person with
            # both an active and an eligible assignment is in both counts - that is not double
            # counting, it is someone who has PIM available and standing access anyway, which
            # is exactly the state worth seeing.
            StandingPrivileged = & $distinct $active
            EligiblePrivileged = & $distinct $eligible

            # Non-human and guest holders, which no amount of PIM or MFA policy covers.
            PrivilegedServicePrincipals = & $distinct @($privileged | Where-Object EffectiveType -eq 'servicePrincipal')
            PrivilegedGuests            = & $distinct @($privileged | Where-Object { $_.UserType -eq 'Guest' })
            # Disabled and still privileged: the account cannot sign in, but the assignment
            # survives re-enabling. Ties directly to Get-MsecEntraDisabledUser.
            PrivilegedDisabled          = & $distinct @($privileged | Where-Object { $_.AccountEnabled -eq $false })

            # Counts effective HOLDERS, so it includes people reached through a role-assignable
            # group and people who are only PIM-eligible. That is why it can exceed the
            # GlobalAdministratorCount on the TenantSettings sheet, which counts the assignment
            # side. Both are right; they answer different questions.
            GlobalAdminHolders = & $distinct @($privileged | Where-Object { $_.RoleName -match 'Global Administrator|Company Administrator' })

            # A holder Graph would not name - an unexpanded group, a deleted object. Carried
            # because an unresolved holder is privilege nobody is reviewing.
            UnresolvedHolders  = @($privileged | Where-Object { -not $_.IsResolved }).Count

            PrivilegedAssignments = $privileged.Count
            AllRoleAssignments    = @($roleHolders).Count
        }

        $sheets.Add([pscustomobject]@{
            Sheet = 'PrivilegedAccess'
            Table = 'tblPrivilegedAccess'
            Row   = [pscustomobject] $row
        })
    }

    # ---- targets ------------------------------------------------------------------------------
    #
    # A target is written as an ordinary column holding the same number on every row, which
    # Excel then plots as a flat line across the chart. No special mechanism, and no clutter
    # where you have not asked for one: a sheet with no target gets no column and therefore
    # no extra series.
    #
    # Stored per row rather than held somewhere as a constant, so RAISING a target shows up as
    # a step in the line. "We moved the bar in March and the number followed" is exactly the
    # thing a posture report should be able to show, and a single stored constant could not.
    $chartSheets = @('Scores', 'SecureScoreByCategory', 'AzureSecureScore', 'PolicyCompliance',
                     'PrivilegedAccess', 'MfaCoverage', 'DeviceCompliance',
                     'DevicePlatform', 'DeviceOsVersion', 'Incidents', 'Email',
                     'ConditionalAccess', 'TenantSettings')

    foreach ($key in @($Target.Keys)) {
        if ($key -notin $chartSheets) {
            Write-Warning "-Target names '$key', which is not one of the sheets: $($chartSheets -join ', '). It will have no effect."
        }
    }

    foreach ($sheet in $sheets) {
        if (-not $Target.ContainsKey($sheet.Sheet)) { continue }
        $sheet.Row | Add-Member -NotePropertyName 'Target' -NotePropertyValue ([double] $Target[$sheet.Sheet]) -Force
    }

    # ---- write -----------------------------------------------------------------------------

    if (-not $PSCmdlet.ShouldProcess($Path, "Append $($sheets.Count) measurement row(s) plus the run log")) {
        return
    }

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    # ONE SHEET FAILING COSTS ONLY ITS OWN ROW. The write half degrades the same way the
    # collect half does. The failure this matters for is Add-MsecExcelRow refusing to rewrite
    # a sheet whose history it could not read back - the file is open in Excel, or mid-sync -
    # where aborting the run would throw away nine successfully collected measurements to
    # protect one.
    $written = foreach ($sheet in $sheets) {
        try {
            $count = Add-MsecExcelRow -Path $Path -WorksheetName $sheet.Sheet -Row $sheet.Row `
                                      -TableName $sheet.Table -TableStyle $TableStyle
            Write-Verbose "$($sheet.Sheet): $count row(s)"
            [pscustomobject]@{ Sheet = $sheet.Sheet; RowCount = $count; Row = $sheet.Row }
        }
        catch {
            Write-Warning "Could not write the '$($sheet.Sheet)' sheet, so this run contributed no row to it. Every other measurement still landed. $($_.Exception.Message)"
            $runLog.Add([pscustomobject]@{
                RunUtc = $runUtc; TenantId = $tenantId
                Source = "Write $($sheet.Sheet)"; Status = 'Failed'
                Detail = $_.Exception.Message
            })
        }
    }

    # RunLog last, so it records the collection outcome of everything above it. No chart -
    # it is a log, and one row per source per run.
    foreach ($entry in $runLog) {
        Add-MsecExcelRow -Path $Path -WorksheetName 'RunLog' -Row $entry -TableName 'tblRunLog' `
                         -TableStyle $TableStyle | Out-Null
    }

    # Charts, all on the Dashboard sheet in front of the data.
    #
    # Built from the CANONICAL list rather than from $sheets, so this run's failures do not
    # decide the ORDER charts appear in - a measurement that failed today keeps its place in
    # the sequence and drops back into it whenever it next succeeds.
    #
    # The list fixes order only, not spacing. Add-MsecExcelDashboard packs the charts that
    # actually exist one after another, so an entry no tenant ever collects costs nothing
    # rather than a permanent blank page.
    $chartSpec = @(
        [pscustomobject]@{ Sheet = 'Scores';                Table = 'tblScores';                XColumn = 'RunUtc'; Title = 'Security scores over time (%)';                         Series = @('SecureScorePercent', 'ExposurePercent') }
        [pscustomobject]@{ Sheet = 'SecureScoreByCategory'; Table = 'tblSecureScoreByCategory'; XColumn = 'RunUtc'; Title = 'Secure Score by category (%)';                           Series = @($secureScoreCategories) }
        [pscustomobject]@{ Sheet = 'AzureSecureScore';      Table = 'tblAzureSecureScore';      XColumn = 'RunUtc'; Title = 'Azure Secure Score by subscription (%)';                Series = @($azureSubscriptionColumn) }
        [pscustomobject]@{ Sheet = 'PolicyCompliance';       Table = 'tblPolicyCompliance';       XColumn = 'RunUtc'; Title = 'Azure Policy compliance by initiative (%)';               Series = @($policyInitiativeColumn) }
        [pscustomobject]@{ Sheet = 'PrivilegedAccess';       Table = 'tblPrivilegedAccess';       XColumn = 'RunUtc'; Title = 'Privileged access over time';                            Series = @('StandingPrivileged', 'EligiblePrivileged', 'PrivilegedServicePrincipals', 'PrivilegedGuests', 'PrivilegedDisabled') }
        [pscustomobject]@{ Sheet = 'MfaCoverage';           Table = 'tblMfaCoverage';           XColumn = 'RunUtc'; Title = 'MFA capability over time (%)';                          Series = @('MfaCapablePercent', 'AdminMfaCapablePercent', 'PasswordlessCapablePercent', 'PhoneOnlyMfaCapablePercent', 'SsprCapablePercent') }
        [pscustomobject]@{ Sheet = 'DeviceCompliance';      Table = 'tblDeviceCompliance';      XColumn = 'RunUtc'; Title = 'Intune device compliance over time';                    Series = @('Compliant', 'Noncompliant', 'InGracePeriod') }
        [pscustomobject]@{ Sheet = 'DevicePlatform';        Table = 'tblDevicePlatform';        XColumn = 'RunUtc'; Title = 'Managed devices by platform';                              Series = @($devicePlatformColumn) }
        [pscustomobject]@{ Sheet = 'DeviceOsVersion';       Table = 'tblDeviceOsVersion';       XColumn = 'RunUtc'; Title = 'Managed devices by OS release';                            Series = @($deviceOsVersionColumn) }
        [pscustomobject]@{ Sheet = 'Incidents';             Table = 'tblIncidents';             XColumn = 'RunUtc'; Title = "Defender XDR incidents by severity (last $Days days)";   Series = @('High', 'Medium', 'Low', 'Informational') }
        [pscustomobject]@{ Sheet = 'Email';                 Table = 'tblEmail';                 XColumn = 'RunUtc'; Title = "Inbound email threats (last $Days days)";                Series = @('Phishing', 'Spam', 'Malware') }
        [pscustomobject]@{ Sheet = 'ConditionalAccess';     Table = 'tblConditionalAccess';     XColumn = 'RunUtc'; Title = "Conditional Access sign-in outcomes (last $Days days)"; Series = @('CaSuccess', 'CaFailure', 'CaNotApplied') }
        [pscustomobject]@{ Sheet = 'TenantSettings';        Table = 'tblTenantSettings';        XColumn = 'RunUtc'; Title = 'Privileged accounts over time';                         Series = @('GlobalAdministratorCount', 'HighlyPrivilegedMemberCount', 'ActivatedRoleCount') }
    )

    # Target LAST in the series list, so it takes the final theme colour and reads as an
    # annotation across the chart rather than as another measurement competing with them.
    foreach ($spec in $chartSpec) {
        if ($Target.ContainsKey($spec.Sheet)) { $spec.Series = @($spec.Series) + 'Target' }
    }

    Add-MsecExcelDashboard -Path $Path -Heading "Security posture - $tenantId" `
        -ChartWidth $ChartWidth -ChartHeight $ChartHeight -Reset:$ResetDashboard -Chart $chartSpec


    $failed = @($runLog | Where-Object Status -eq 'Failed')
    if ($failed.Count) {
        Write-Warning "$($failed.Count) of $($runLog.Count) measurement(s) failed this run and contributed no row. See the RunLog sheet in '$Path'."
    }

    if ($PassThru) { $written }
}
