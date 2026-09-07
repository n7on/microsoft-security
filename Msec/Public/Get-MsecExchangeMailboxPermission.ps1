function Get-MsecExchangeMailboxPermission {
    <#
    .SYNOPSIS
        Who can open which mailbox - one row per (mailbox, grantee, access right).

    .DESCRIPTION
        Shared mailbox access is a standing grant that survives the person who set it up, and
        it is invisible to every Entra-side review: a Full Access grant on a shared mailbox
        does not appear in group membership, in a directory role, or in any Conditional Access
        report. This is the only place it shows up.

        NOT AVAILABLE THROUGH GRAPH, and that is why this needs ExchangeOnlineManagement rather
        than Invoke-MsecGraphRequest like the rest of the module. Mailbox permissions are an
        Exchange concept - there is no /users/{id}/mailboxPermissions endpoint. Every other
        identity command here reads Graph; this one cannot.

        NT AUTHORITY\SELF IS EXCLUDED. Exchange grants every mailbox Full Access to itself, so
        it appears on every row and means nothing. Including it would put a meaningless finding
        on every mailbox and train the reader to skim past the column that matters.

        ONE ROW PER (MAILBOX, GRANTEE, RIGHT). A grantee holding both FullAccess and SendAs on
        one mailbox is two rows, because they are two separate grants made in two places -
        collapsing them would hide one of them being removed.

    .PARAMETER RecipientTypeDetails
        Which mailbox kinds to inspect. Default SharedMailbox, which is where standing
        delegated access accumulates. 'UserMailbox' covers delegate access to people's own
        mailboxes - a bigger and noisier set, but the same question.

    .PARAMETER IncludeInherited
        Include permissions inherited from a parent object rather than set on the mailbox
        itself. Excluded by default: an inherited right is a property of the organisation's
        RBAC, not a decision someone made about this mailbox.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Connect-MsecExchangeOnline -Organization contoso.onmicrosoft.com
        Get-MsecExchangeMailboxPermission

    .EXAMPLE
        # The access review question: who can read mailboxes they do not own?
        Get-MsecExchangeMailboxPermission |
            Where-Object AccessRights -match 'FullAccess' |
            Sort-Object MailboxUserPrincipalName, Grantee

    .EXAMPLE
        # Grantees with access to several mailboxes - usually a service account or a leaver.
        Get-MsecExchangeMailboxPermission |
            Group-Object Grantee | Where-Object Count -gt 1 | Sort-Object Count -Descending

    .OUTPUTS
        PSCustomObject per grant, PSTypeName 'MsecExchangeMailboxPermission'.

    .NOTES
        Needs Connect-MsecExchangeOnline first - see that command for why Exchange requires a
        DIRECTORY ROLE and not just the Exchange.ManageAsApp app role.

        A mailbox whose permissions cannot be read emits a row with Grantee 'Unreadable' rather
        than contributing nothing, so a permission failure cannot read as a mailbox nobody has
        access to.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [ValidateSet('SharedMailbox', 'UserMailbox', 'RoomMailbox', 'EquipmentMailbox', 'All')]
        [string[]] $RecipientTypeDetails = 'SharedMailbox',

        [switch] $IncludeInherited
    )

    if (-not (Get-Command Get-EXOMailbox -ErrorAction SilentlyContinue)) {
        throw 'Not connected to Exchange Online. Run Connect-MsecExchangeOnline -Organization <domain> first.'
    }

    $mailboxParams = @{ ErrorAction = 'Stop' }
    if ($RecipientTypeDetails -notcontains 'All') {
        $mailboxParams['RecipientTypeDetails'] = $RecipientTypeDetails
    }

    $mailboxes = @()
    try {
        $mailboxes = @(Get-EXOMailbox @mailboxParams -ResultSize Unlimited)
    }
    catch {
        throw "Could not list mailboxes. The msec app needs Exchange.ManageAsApp AND a directory role (Exchange Administrator, Exchange Recipient Administrator or Global Reader) - the app role alone is not enough, and Exchange reports the difference as a plain authorisation failure. Original error: $($_.Exception.Message)"
    }

    if (-not $mailboxes.Count) {
        Write-Warning "No mailboxes of type $($RecipientTypeDetails -join ', ') found."
        return
    }

    foreach ($mailbox in $mailboxes) {
        $common = [ordered]@{
            MailboxDisplayName       = $mailbox.DisplayName
            MailboxUserPrincipalName = $mailbox.UserPrincipalName
            MailboxPrimarySmtpAddress = $mailbox.PrimarySmtpAddress
            MailboxType              = $mailbox.RecipientTypeDetails
        }

        $permissions = $null
        try {
            $permissions = @(Get-EXOMailboxPermission -Identity $mailbox.UserPrincipalName -ErrorAction Stop)
        }
        catch {
            # A mailbox that could not be read must not look like a mailbox nobody can open.
            Write-Warning "Could not read permissions on '$($mailbox.UserPrincipalName)': $($_.Exception.Message)"
            [PSCustomObject]($common + [ordered]@{
                PSTypeName   = 'MsecExchangeMailboxPermission'
                Grantee      = 'Unreadable'
                AccessRights = $null
                IsInherited  = $null
                Deny         = $null
            })
            continue
        }

        $emitted = 0
        foreach ($permission in $permissions) {
            # Exchange grants every mailbox Full Access to itself - see .DESCRIPTION.
            if ($permission.User -eq 'NT AUTHORITY\SELF') { continue }
            if (-not $IncludeInherited -and $permission.IsInherited) { continue }

            $emitted++
            [PSCustomObject]($common + [ordered]@{
                PSTypeName   = 'MsecExchangeMailboxPermission'
                Grantee      = [string] $permission.User
                AccessRights = (@($permission.AccessRights) -join ', ')
                IsInherited  = [bool] $permission.IsInherited
                Deny         = [bool] $permission.Deny
            })
        }

        if (-not $emitted) {
            # Nobody but the mailbox itself. A real answer, and a good one - said explicitly so
            # it is distinguishable from the Unreadable row above.
            [PSCustomObject]($common + [ordered]@{
                PSTypeName   = 'MsecExchangeMailboxPermission'
                Grantee      = 'None'
                AccessRights = $null
                IsInherited  = $null
                Deny         = $null
            })
        }
    }
}
