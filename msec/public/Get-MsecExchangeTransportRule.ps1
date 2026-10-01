function Get-MsecExchangeTransportRule {
    <#
    .SYNOPSIS
        Mail flow rules, with the two things that make one dangerous: whether it bypasses
        filtering, and whether it sends mail somewhere else.

    .DESCRIPTION
        A transport rule runs on every message in the tenant, before the user sees it. That
        makes it a favourite for persistence: one rule can exempt an attacker's sender from
        filtering, or copy every message to an outside address, and it lives in a part of the
        portal nobody browses.

        BYPASSING FILTERING IS A SPAM CONFIDENCE LEVEL OF -1, which does not read as dangerous
        unless you know what it means. SCL -1 tells Exchange to trust the message completely and
        skip spam, phishing and bulk filtering. BypassesFiltering is a derived column saying so
        in words. Measured on one tenant: 7 of 12 rules set it, 3 of them enabled - mostly for
        phishing-simulation training, which is legitimate and is also exactly what an attacker's
        rule would be named.

        THE REDIRECT PROPERTIES ARE FOUR, NOT ONE. RedirectMessageTo diverts the message,
        BlindCopyTo and CopyTo duplicate it, and AddToRecipients adds a recipient. They behave
        differently for the sender and the original recipient; a command that checked only one
        would miss the other three. RedirectsMail is true when any of them is set, and the
        individual columns say which.

        ExternalRecipients NAMES THE ONES OUTSIDE THE TENANT. A rule copying mail to an internal
        archive mailbox is ordinary; the same rule pointing at a personal address is not.
        Resolved against accepted domains, and $null rather than empty when those could not be
        read - "not checked" must not look like "all internal".

        State IS NOT THE WHOLE ANSWER. A rule can be Enabled and still inert because its Mode is
        Audit rather than Enforce; both are on the row, and IsActive is true only when the rule
        is enabled AND enforcing.

    .PARAMETER Name
        Limit to rules whose name matches. Wildcards allowed.

    .PARAMETER RiskyOnly
        Only rules that bypass filtering or redirect mail.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecExchangeTransportRule -RiskyOnly |
            Format-Table Name, IsActive, BypassesFiltering, RedirectsMail, ExternalRecipients

    .EXAMPLE
        # Live rules that exempt a sender from all filtering.
        Get-MsecExchangeTransportRule |
            Where-Object { $_.IsActive -and $_.BypassesFiltering } |
            Format-Table Name, Comments, LastModifiedBy, WhenChangedUtc

    .OUTPUTS
        One PSCustomObject per rule, PSTypeName 'MsecExchangeTransportRule'.

    .NOTES
        Needs Connect-Msec. The Exchange session is opened on first use. Read-only.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string] $Name,

        [Parameter()]
        [switch] $RiskyOnly
    )

    Initialize-MsecExoSession -Endpoint Exchange

    $rules = @(Get-TransportRule -ErrorAction Stop)
    if ($Name) { $rules = @($rules | Where-Object { $_.Name -like $Name }) }

    # Decides what "external" means below. $null when unreadable, so ExternalRecipients can be
    # $null rather than an empty list that would read as "checked, all internal".
    $domains = $null
    try { $domains = @((Get-AcceptedDomain -ErrorAction Stop).DomainName | ForEach-Object { "$_".ToLower() }) }
    catch {
        Write-Warning "Could not read accepted domains, so ExternalRecipients is null rather than empty: $($_.Exception.Message)"
    }

    foreach ($rule in $rules) {
        # All four. They differ for sender and recipient, and checking one misses the rest.
        $redirect = @($rule.RedirectMessageTo  | ForEach-Object { [string] $_ } | Where-Object { $_ })
        $bcc      = @($rule.BlindCopyTo        | ForEach-Object { [string] $_ } | Where-Object { $_ })
        $copy     = @($rule.CopyTo             | ForEach-Object { [string] $_ } | Where-Object { $_ })
        $added    = @($rule.AddToRecipients    | ForEach-Object { [string] $_ } | Where-Object { $_ })
        $allTargets = @($redirect + $bcc + $copy + $added)

        $external = $null
        if ($null -ne $domains) {
            $external = @($allTargets | Where-Object {
                $suffix = ($_ -split '@')[-1]
                $suffix -and ($_ -like '*@*') -and $suffix.ToLower() -notin $domains
            })
        }

        # SCL -1 means "trust completely, skip filtering". The number alone does not say that.
        $bypasses = ([string] $rule.SetSCL -eq '-1')
        $redirects = [bool] $allTargets.Count

        if ($RiskyOnly -and -not ($bypasses -or $redirects)) { continue }

        [PSCustomObject]@{
            PSTypeName          = 'MsecExchangeTransportRule'
            Name                = [string] $rule.Name
            State               = [string] $rule.State
            Mode                = [string] $rule.Mode
            # Enabled AND enforcing. A rule in Audit mode is live and does nothing.
            IsActive            = ([string] $rule.State -eq 'Enabled' -and [string] $rule.Mode -eq 'Enforce')
            Priority            = $rule.Priority
            BypassesFiltering   = $bypasses
            SetScl              = $(if ($null -ne $rule.SetSCL) { [string] $rule.SetSCL } else { $null })
            RedirectsMail       = $redirects
            RedirectMessageTo   = $redirect
            BlindCopyTo         = $bcc
            CopyTo              = $copy
            AddToRecipients     = $added
            # $null when accepted domains could not be read - see the help.
            ExternalRecipients  = $external
            DeletesMessage      = [bool] $rule.DeleteMessage
            SetsHeader          = $(if ($rule.SetHeaderName) { "$($rule.SetHeaderName)=$($rule.SetHeaderValue)" } else { $null })
            FromScope           = [string] $rule.FromScope
            SentToScope         = [string] $rule.SentToScope
            StopRuleProcessing  = [bool] $rule.StopRuleProcessing
            Comments            = [string] $rule.Comments
            CreatedBy           = [string] $rule.CreatedBy
            LastModifiedBy      = [string] $rule.LastModifiedBy
            WhenChangedUtc      = $rule.WhenChanged
        }
    }
}
