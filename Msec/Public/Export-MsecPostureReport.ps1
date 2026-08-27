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

        THE CHARTS ARE NOT REBUILT ON LATER RUNS. Their series use ordinary cell ranges,
        which are pinned to the row count they were written with, so the ranges are refreshed
        in place as rows are appended - and nothing else about the chart is touched. Its
        title, position, size, colours and any series you added yourself all survive.

        Series colours are NOT set: Excel's own theme palette applies, so the charts match
        the workbook and follow it if you change the theme.

        Sheets, each data sheet written as an Excel table:
          Dashboard              every chart, first in the workbook
          Scores                 Secure Score, exposure, device configuration score
          SecureScoreByCategory  one column per Secure Score category (Identity, Device, ...)
          AzureSecureScore       one column per Azure subscription
          MfaCoverage            MFA capability overall and for admins
          DeviceCompliance       Intune compliance mix, aggregated from Get-MsecIntuneDevice
          Incidents              Defender XDR volume, severity mix and time-to-resolve
          Email                  inbound volume, delivery actions, threat types
          ConditionalAccess      sign-in outcomes, risk, report-only would-blocks
          TenantSettings         security defaults, admin counts, licensing posture
          RunLog                 what ran, what failed and why

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

    .PARAMETER TableStyle
        Excel table style for every data sheet. One of Light1-21, Medium1-28 or Dark1-11 -
        tab-completes. Default Medium2. It is applied on every run, not just when a sheet is
        created, so changing it restyles the existing sheets next time rather than leaving
        the old ones behind.

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
                     'Incidents', 'Email', 'ConditionalAccess', 'TenantSettings', 'DeviceCompliance')]
        [string[]] $Measurement,

        [string[]] $Subscription,

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
          'Incidents', 'Email', 'ConditionalAccess', 'TenantSettings', 'DeviceCompliance')
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
    $devices = if ('DeviceCompliance' -in $wanted) { Get-Source 'Get-MsecIntuneDevice' { Get-MsecIntuneDevice } }

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

    # ---- write -----------------------------------------------------------------------------

    if (-not $PSCmdlet.ShouldProcess($Path, "Append $($sheets.Count) measurement row(s) plus the run log")) {
        return
    }

    $parent = Split-Path -Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $written = foreach ($sheet in $sheets) {
        $count = Add-MsecExcelRow -Path $Path -WorksheetName $sheet.Sheet -Row $sheet.Row `
                                  -TableName $sheet.Table -TableStyle $TableStyle
        Write-Verbose "$($sheet.Sheet): $count row(s)"
        [pscustomobject]@{ Sheet = $sheet.Sheet; RowCount = $count; Row = $sheet.Row }
    }

    # RunLog last, so it records the collection outcome of everything above it. No chart -
    # it is a log, and one row per source per run.
    foreach ($entry in $runLog) {
        Add-MsecExcelRow -Path $Path -WorksheetName 'RunLog' -Row $entry -TableName 'tblRunLog' `
                         -TableStyle $TableStyle | Out-Null
    }

    # Charts, all on the Dashboard sheet in front of the data.
    #
    # Built from the CANONICAL list rather than from $sheets, so a measurement that failed
    # this run keeps its slot and drops into it whenever it next succeeds - rather than every
    # later chart shuffling up one place and the layout changing from run to run.
    Add-MsecExcelDashboard -Path $Path -Heading "Security posture - $tenantId" -Chart @(
        [pscustomobject]@{ Sheet = 'Scores';                Table = 'tblScores';                XColumn = 'RunUtc'; Title = 'Security scores over time (%)';                         Series = @('SecureScorePercent', 'ExposurePercent') }
        [pscustomobject]@{ Sheet = 'SecureScoreByCategory'; Table = 'tblSecureScoreByCategory'; XColumn = 'RunUtc'; Title = 'Secure Score by category (%)';                           Series = @($secureScoreCategories) }
        [pscustomobject]@{ Sheet = 'AzureSecureScore';      Table = 'tblAzureSecureScore';      XColumn = 'RunUtc'; Title = 'Azure Secure Score by subscription (%)';                Series = @($azureSubscriptionColumn) }
        [pscustomobject]@{ Sheet = 'MfaCoverage';           Table = 'tblMfaCoverage';           XColumn = 'RunUtc'; Title = 'MFA capability over time (%)';                          Series = @('MfaCapablePercent', 'AdminMfaCapablePercent', 'PasswordlessCapablePercent', 'PhoneOnlyMfaCapablePercent', 'SsprCapablePercent') }
        [pscustomobject]@{ Sheet = 'DeviceCompliance';      Table = 'tblDeviceCompliance';      XColumn = 'RunUtc'; Title = 'Intune device compliance over time';                    Series = @('Compliant', 'Noncompliant', 'InGracePeriod') }
        [pscustomobject]@{ Sheet = 'Incidents';             Table = 'tblIncidents';             XColumn = 'RunUtc'; Title = "Defender XDR incidents by severity (last $Days days)";   Series = @('High', 'Medium', 'Low', 'Informational') }
        [pscustomobject]@{ Sheet = 'Email';                 Table = 'tblEmail';                 XColumn = 'RunUtc'; Title = "Inbound email threats (last $Days days)";                Series = @('Phishing', 'Spam', 'Malware') }
        [pscustomobject]@{ Sheet = 'ConditionalAccess';     Table = 'tblConditionalAccess';     XColumn = 'RunUtc'; Title = "Conditional Access sign-in outcomes (last $Days days)"; Series = @('CaSuccess', 'CaFailure', 'CaNotApplied') }
        [pscustomobject]@{ Sheet = 'TenantSettings';        Table = 'tblTenantSettings';        XColumn = 'RunUtc'; Title = 'Privileged accounts over time';                         Series = @('GlobalAdministratorCount', 'HighlyPrivilegedMemberCount', 'ActivatedRoleCount') }
    )


    $failed = @($runLog | Where-Object Status -eq 'Failed')
    if ($failed.Count) {
        Write-Warning "$($failed.Count) of $($runLog.Count) measurement(s) failed this run and contributed no row. See the RunLog sheet in '$Path'."
    }

    if ($PassThru) { $written }
}
