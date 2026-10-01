function Get-MsecExchangeMailbox {
    <#
    .SYNOPSIS
        Mailboxes with the two things that actually leak mail: where it is forwarded, and which
        legacy protocols are open.

    .DESCRIPTION
        FORWARDING IS THE EXFILTRATION CONTROL, and it comes in two shapes that are NOT the same
        risk. ForwardingSmtpAddress is a raw address that can point anywhere, including outside
        the tenant. ForwardingAddress must resolve to an existing recipient object, so it cannot
        name an arbitrary stranger. Reporting them as one column loses that, so both are on the
        row and ForwardingKind says which is in play. Measured on one tenant: 34 of 305 mailboxes
        forwarded, 11 by raw SMTP, four of those to addresses outside every accepted domain.

        THE POINT IS NOT THAT FORWARDING IS BAD. Most of it is deliberate - ticketing systems,
        Teams, product feedback tools. The point is that nothing tells you when a new one
        appears, and an attacker's forward looks exactly like a legitimate one in the portal.
        This command exists to be diffed, not to be read once.

        DeliverToMailboxAndForward DECIDES WHETHER THE USER EVER SEES THE MAIL. False means the
        message leaves and no copy stays behind - the mailbox owner has no way to notice. That
        is the more dangerous configuration and it is a separate column for that reason.

        SMTP AUTH IS RESOLVED, NOT REPORTED RAW. The per-mailbox setting is often $null, meaning
        "inherit the tenant default", and $null read as a boolean is false - so an unresolved
        value claims SMTP AUTH is off on every mailbox that never set it. SmtpAuthEnabled is the
        EFFECTIVE answer and SmtpAuthSource says whether it came from the mailbox or the tenant.
        It is the protocol worth caring about most, because it bypasses multi-factor
        authentication outright.

        POP, IMAP and ActiveSync are reported as found. On most tenants they are enabled
        everywhere because that is the default nobody changed, which is attack surface rather
        than a misconfiguration - judge it against whether anyone actually uses them.

    .PARAMETER RecipientTypeDetails
        Mailbox types to include. Defaults to All, unlike Get-MsecExchangeMailboxPermission -
        forwarding matters on every mailbox, not only shared ones.

    .PARAMETER ForwardingOnly
        Only mailboxes that forward somewhere.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecExchangeMailbox -ForwardingOnly |
            Format-Table UserPrincipalName, ForwardingKind, ForwardingTarget, IsForwardingExternal, DeliverToMailboxAndForward

    .EXAMPLE
        # Mail leaving the tenant with no copy left behind - the owner cannot notice.
        Get-MsecExchangeMailbox -ForwardingOnly |
            Where-Object { $_.IsForwardingExternal -and -not $_.DeliverToMailboxAndForward }

    .EXAMPLE
        # SMTP AUTH is the one that bypasses MFA.
        Get-MsecExchangeMailbox | Where-Object SmtpAuthEnabled |
            Format-Table UserPrincipalName, SmtpAuthEnabled, SmtpAuthSource

    .OUTPUTS
        One PSCustomObject per mailbox, PSTypeName 'MsecExchangeMailbox'.

    .NOTES
        Needs Connect-Msec. The Exchange session is opened on first use.

        Two bulk calls (Get-EXOMailbox, Get-EXOCasMailbox) rather than one per mailbox, so this
        stays workable on a large tenant. Read-only.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('SharedMailbox', 'UserMailbox', 'RoomMailbox', 'EquipmentMailbox', 'All')]
        [string[]] $RecipientTypeDetails = 'All',

        [switch] $ForwardingOnly
    )

    Initialize-MsecExoSession -Endpoint Exchange

    $mailboxParams = @{ ErrorAction = 'Stop' }
    if ($RecipientTypeDetails -notcontains 'All') {
        $mailboxParams['RecipientTypeDetails'] = $RecipientTypeDetails
    }

    # PropertySets keeps the response small; Delivery carries the forwarding fields.
    $mailboxes = @(Get-EXOMailbox @mailboxParams -PropertySets Minimum, Delivery -ResultSize Unlimited)

    # Accepted domains decide what "external" means. If this fails, IsForwardingExternal goes
    # $null rather than $false - claiming a forward is internal when it was never checked is
    # the one answer that would matter and be wrong.
    $domains = $null
    try {
        $domains = @((Get-AcceptedDomain -ErrorAction Stop).DomainName | ForEach-Object { "$_".ToLower() })
    }
    catch {
        Write-Warning "Could not read accepted domains, so IsForwardingExternal is null rather than false: $($_.Exception.Message)"
    }

    # The tenant default that a $null per-mailbox SMTP AUTH setting inherits.
    $tenantSmtpAuthDisabled = $null
    try { $tenantSmtpAuthDisabled = (Get-TransportConfig -ErrorAction Stop).SmtpClientAuthenticationDisabled }
    catch {
        Write-Warning "Could not read the tenant SMTP AUTH default, so SmtpAuthEnabled is null where a mailbox inherits it: $($_.Exception.Message)"
    }

    $cas = @{}
    try {
        foreach ($c in @(Get-EXOCasMailbox -ResultSize Unlimited -ErrorAction Stop)) {
            $cas[[string] $c.ExternalDirectoryObjectId] = $c
        }
    }
    catch {
        Write-Warning "Could not read CAS mailbox settings, so the protocol columns are null rather than false: $($_.Exception.Message)"
    }

    foreach ($mailbox in $mailboxes) {
        $smtpTarget = "$($mailbox.ForwardingSmtpAddress)" -replace '^smtp:', ''
        $objTarget  = "$($mailbox.ForwardingAddress)"

        $kind = if ($smtpTarget) { 'SmtpAddress' } elseif ($objTarget) { 'Recipient' } else { 'None' }
        if ($ForwardingOnly -and $kind -eq 'None') { continue }

        # Only a raw SMTP address can be judged here. A ForwardingAddress names a recipient
        # object, which needs a lookup this command does not do - so it is $null, not $false.
        $isExternal = $null
        if ($kind -eq 'SmtpAddress' -and $null -ne $domains) {
            $suffix = ($smtpTarget -split '@')[-1]
            $isExternal = [bool] ($suffix -and $suffix.ToLower() -notin $domains)
        }

        $c = $cas[[string] $mailbox.ExternalDirectoryObjectId]

        # $null when the mailbox does not set it: the tenant default applies, and reading $null
        # as a boolean would report "disabled" for every mailbox that simply never set it.
        $smtpAuthEnabled = $null
        $smtpAuthSource  = $null
        if ($c) {
            if ($null -ne $c.SmtpClientAuthenticationDisabled) {
                $smtpAuthEnabled = -not $c.SmtpClientAuthenticationDisabled
                $smtpAuthSource  = 'Mailbox'
            }
            elseif ($null -ne $tenantSmtpAuthDisabled) {
                $smtpAuthEnabled = -not $tenantSmtpAuthDisabled
                $smtpAuthSource  = 'Tenant'
            }
        }

        [PSCustomObject]@{
            PSTypeName                 = 'MsecExchangeMailbox'
            DisplayName                = [string] $mailbox.DisplayName
            UserPrincipalName          = [string] $mailbox.UserPrincipalName
            PrimarySmtpAddress         = [string] $mailbox.PrimarySmtpAddress
            MailboxType                = [string] $mailbox.RecipientTypeDetails
            ForwardingKind             = $kind
            ForwardingTarget           = $(if ($smtpTarget) { $smtpTarget } elseif ($objTarget) { $objTarget } else { $null })
            ForwardingSmtpAddress      = $(if ($smtpTarget) { $smtpTarget } else { $null })
            ForwardingAddress          = $(if ($objTarget) { $objTarget } else { $null })
            # $null for a Recipient forward - see the comment above, it is not "internal".
            IsForwardingExternal       = $isExternal
            # False means no copy stays behind, so the owner cannot notice the mail leaving.
            DeliverToMailboxAndForward = $(if ($kind -eq 'None') { $null } else { [bool] $mailbox.DeliverToMailboxAndForward })
            SmtpAuthEnabled            = $smtpAuthEnabled
            SmtpAuthSource             = $smtpAuthSource
            PopEnabled                 = $(if ($c) { [bool] $c.PopEnabled } else { $null })
            ImapEnabled                = $(if ($c) { [bool] $c.ImapEnabled } else { $null })
            ActiveSyncEnabled          = $(if ($c) { [bool] $c.ActiveSyncEnabled } else { $null })
            OwaEnabled                 = $(if ($c) { [bool] $c.OWAEnabled } else { $null })
        }
    }
}
