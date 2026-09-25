function Get-MsecAzureDomainService {
    <#
    .SYNOPSIS
        Every Microsoft Entra Domain Services managed domain, the security settings that decide
        what its authentication may look like, and where its security audit logs go.

    .DESCRIPTION
        A managed domain is a pair of Microsoft-run domain controllers holding a synchronised
        copy of the directory, so that things which cannot speak modern protocols - VPN
        concentrators, RADIUS, file servers, line-of-business software - can authenticate
        against Kerberos, NTLM and LDAP using people's ordinary accounts. That convenience is
        the entire security question: it puts the tenant's identities behind protocols the rest
        of the estate has spent a decade moving away from.

        A MANAGED DOMAIN SHIPS WITH ITS WEAK SETTINGS ON. NTLM v1, RC4 Kerberos encryption and
        unsigned LDAP are enabled on a new managed domain by default, and NTLM password hashes
        are synchronised into it by default as well. None of that is a mistake anybody made,
        which is exactly why it survives review: there is no change to find in a change log, and
        the portal spreads the toggles across two blades. WeakSettings names the ones currently
        in the weak state in one string, so the answer does not depend on remembering which
        direction is safe for each of nine fields.

        WHAT THIS DOES NOT TELL YOU IS WHETHER ANY OF IT IS USED. Turning NTLM v1 off is a
        change that breaks whatever still relies on it, and this command cannot say what that
        is. The audit log can:

            $domain = Get-MsecAzureDomainService
            $used   = Search-MsecLogAnalytics -Subject DomainServices -Days 30 `
                          -WorkspaceName $domain.AuditLogWorkspace
            $used | Where-Object Method -eq 'NTLM' | Group-Object Account

        THE LOG SAYS 'NTLM', NOT 'NTLM v1'. Event 4776 does not record which NTLM version was
        negotiated, so that query lists accounts using NTLM of ANY version - and turning the
        NtlmV1 setting off leaves NTLM v2 working. It answers the question in one direction
        only: no NTLM at all means nothing breaks; some NTLM is a list to check, not a list that
        would break.

        AuditLogWorkspace exists for that handoff. It is the workspace NAME, which is what
        Search-MsecLogAnalytics -WorkspaceName takes - a tenant of any size has dozens of
        workspaces and the one a managed domain writes to is not guessable, it is whatever a
        diagnostic setting points at.

        NO AUDIT LOG IS THE COMMON CASE AND IT IS A FINDING. Security audit is off by default on
        a managed domain: no diagnostic setting, no events, and nothing anywhere that says so.
        AuditLogsEnabled is then $false, and every authentication against the domain - including
        every failure - is unrecorded and unrecoverable, because there is no local store to go
        back to. $false and $null are different answers here: $null means the diagnostic
        settings could not be READ, which is a permission problem rather than a finding.

        CATEGORY GROUPS, NOT CATEGORIES. A diagnostic setting can select individual log
        categories or a whole group ('audit', 'allLogs'), and when it selects a group the
        per-category fields come back null. AuditLogCategories reports whichever form is in use
        rather than an empty string, since "allLogs" and "no categories" are opposite answers.

    .PARAMETER Subscription
        Limit to these subscriptions, by name or id. Omit for every subscription the Az context
        can see - managed domains are rare and easy to miss, so the default is wide.

    .EXAMPLE
        Connect-AzAccount
        Get-MsecAzureDomainService | Format-List Domain, WeakSettings, AuditLogsEnabled, AuditLogWorkspace

    .EXAMPLE
        # The settings, and then who would actually break if NTLM were turned off.
        $domain = Get-MsecAzureDomainService
        Search-MsecLogAnalytics -Subject DomainServices -Name Accounts -Days 30 `
            -WorkspaceName $domain.AuditLogWorkspace |
            Where-Object { $_.Methods -match 'NTLM' }

    .EXAMPLE
        # Managed domains nobody is auditing.
        Get-MsecAzureDomainService | Where-Object { -not $_.AuditLogsEnabled }

    .OUTPUTS
        One PSCustomObject per managed domain, PSTypeName 'MsecAzureDomainService'.

    .NOTES
        Needs an Az context (Connect-AzAccount) and Reader on the subscriptions holding the
        managed domains. It does NOT need Connect-Msec - this is ARM, not Graph.

        The settings come from Resource Graph in one request; the audit-log destination is a
        child resource Resource Graph does not project, so it costs one ARM call per domain.
        Managed domains are counted in single figures, so that is a handful of calls.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string[]] $Subscription
    )

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount first - this command reads ARM, not Microsoft Graph.'
    }

    $query = @{ ResourceType = 'DomainServices' }
    if ($Subscription) { $query['Subscription'] = $Subscription }

    $domains = @(Search-MsecAzureResourceGraph @query)

    if (-not $domains.Count) {
        # Not a warning: most tenants genuinely have none, and a tenant that has one knows it.
        Write-Verbose 'No Microsoft Entra Domain Services managed domains found in the subscriptions searched.'
        return
    }

    foreach ($domain in $domains) {
        # $null, not $false, until a successful read says otherwise - see the help. A domain
        # whose diagnostic settings were refused must not read as a domain with none.
        $enabled = $null
        $workspaceId = $null
        $workspaceName = $null
        $categories = $null
        $settingName = $null
        $otherDestinations = $null

        try {
            $response = Invoke-AzRestMethod -Method GET `
                -Path "$($domain.Id)/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" `
                -ErrorAction Stop

            if ($response.StatusCode -eq 200) {
                $settings = @(($response.Content | ConvertFrom-Json).value)

                # A setting with no enabled log entry is a setting that sends nothing, so the
                # answer is the same as having none - matched on the logs rather than on the
                # existence of the setting.
                $logging = @($settings | Where-Object { @($_.properties.logs | Where-Object enabled).Count })

                $enabled = [bool] $logging.Count

                if ($logging.Count) {
                    $settingName = ($logging.name | Sort-Object) -join '; '

                    $workspaceIds = @($logging.properties.workspaceId | Where-Object { $_ } | Sort-Object -Unique)
                    if ($workspaceIds.Count) {
                        $workspaceId = $workspaceIds -join '; '
                        # The NAME is what Search-MsecLogAnalytics -WorkspaceName takes.
                        $workspaceName = (@($workspaceIds | ForEach-Object { ($_ -split '/')[-1] }) | Sort-Object -Unique) -join '; '
                    }

                    # See the help: a group selection leaves category null, and reporting that
                    # as no categories would say the opposite of what it means.
                    $names = foreach ($log in @($logging.properties.logs | Where-Object enabled)) {
                        if ($log.category) { [string] $log.category }
                        elseif ($log.categoryGroup) { "$($log.categoryGroup) (group)" }
                    }
                    $categories = (@($names | Sort-Object -Unique)) -join '; '

                    # Audit can be sent somewhere this module cannot query. Named so a $null
                    # AuditLogWorkspace is not mistaken for audit going nowhere at all.
                    $other = @()
                    if (@($logging.properties.storageAccountId | Where-Object { $_ }).Count) { $other += 'Storage account' }
                    if (@($logging.properties.eventHubAuthorizationRuleId | Where-Object { $_ }).Count) { $other += 'Event hub' }
                    if ($other.Count) { $otherDestinations = $other -join '; ' }
                }
            }
            else {
                Write-Warning "Diagnostic settings for '$($domain.Domain)' returned HTTP $($response.StatusCode), so its audit columns are `$null rather than false."
            }
        }
        catch {
            Write-Warning "Could not read diagnostic settings for '$($domain.Domain)', so its audit columns are `$null rather than false: $($_.Exception.Message)"
        }

        # Every Resource Graph column is carried through unchanged and the audit columns added,
        # rather than a hand-picked subset - a setting this command has not been taught about is
        # still worth seeing.
        $row = [ordered]@{ PSTypeName = 'MsecAzureDomainService' }
        foreach ($property in $domain.PSObject.Properties) {
            if ($property.Name -eq 'PSTypeName') { continue }
            $row[$property.Name] = $property.Value
        }

        $row['AuditLogsEnabled']          = $enabled
        $row['AuditLogWorkspace']         = $workspaceName
        $row['AuditLogCategories']        = $categories
        $row['AuditLogOtherDestinations'] = $otherDestinations
        $row['DiagnosticSettingName']     = $settingName
        $row['AuditLogWorkspaceId']       = $workspaceId

        [PSCustomObject] $row
    }
}
