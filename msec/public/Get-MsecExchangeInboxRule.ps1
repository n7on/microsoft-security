function Get-MsecExchangeInboxRule {
    <#
    .SYNOPSIS
        User-created inbox rules, flagging the ones that send mail out of the tenant or hide it
        from the person who owns the mailbox.

    .DESCRIPTION
        Mailbox forwarding is an admin setting and shows up in Get-MsecExchangeMailbox. An INBOX
        RULE is set by the user - or by whoever is holding the user's session - and is where
        business email compromise actually lives. The pattern is well worn: a rule that forwards
        anything matching 'invoice' or 'payment' to an outside address, then moves it to RSS
        Feeds and marks it read so the owner never sees the thread.

        THIS IS SLOW AND SCOPED ON PURPOSE. There is no bulk endpoint: Get-InboxRule takes one
        mailbox at a time, measured at roughly 1.7 seconds each, so the whole tenant is several
        minutes. -Mailbox exists so an investigation can read ten mailboxes in twenty seconds,
        and the default is UserMailbox rather than every recipient type for the same reason.

        A MAILBOX THAT COULD NOT BE READ GETS A ROW SAYING SO. Skipping it would make a mailbox
        whose rules are unreadable look exactly like a mailbox with no rules, and in an
        investigation those are opposite answers. A mailbox genuinely holding no rules emits
        nothing, which is a real measurement.

        EXTERNAL IS DECIDED AGAINST ACCEPTED DOMAINS, and if those cannot be read
        ForwardsExternally is $null rather than $false - claiming a forward stays inside the
        tenant when nothing checked is the one wrong answer that matters.

        WHAT COUNTS AS RISKY IS WRITTEN DOWN, not inferred: a rule that forwards or redirects
        outside the tenant, a rule that deletes, or a rule that both files mail away and marks
        it read. StopProcessingRules and a plain MoveToFolder are ordinary mail management and
        are reported but not flagged.

        INVALID RULES ARE REPORTED. Exchange returns rules it cannot parse with IsValid false
        and an ErrorType; they still exist and may still run, and a corrupt rule is as often a
        sign of tampering as of a broken client.

    .PARAMETER Mailbox
        Specific mailboxes, by primary SMTP address or UPN. Omit to sweep every mailbox of the
        types in -RecipientTypeDetails.

    .PARAMETER RecipientTypeDetails
        Which mailbox types to sweep when -Mailbox is not given. Defaults to UserMailbox.
        SharedMailbox is worth a separate pass: shared mailboxes carry rules too and nobody
        reads their inbox.

    .PARAMETER RiskyOnly
        Only rules that forward or redirect outside the tenant, delete, or hide mail.

    .EXAMPLE
        Get-MsecExchangeInboxRule -RiskyOnly

        Sweeps user mailboxes and returns only the rules worth reading. Several minutes.

    .EXAMPLE
        Get-MsecExchangeInboxRule -Mailbox alice@contoso.com, bob@contoso.com

        Every rule on two mailboxes, for an investigation.

    .EXAMPLE
        Get-MsecExchangeInboxRule -RecipientTypeDetails SharedMailbox -RiskyOnly

        The mailboxes nobody is watching.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('PrimarySmtpAddress', 'UserPrincipalName')]
        [string[]] $Mailbox,

        [ValidateSet('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox', 'All')]
        [string[]] $RecipientTypeDetails = 'UserMailbox',

        [switch] $RiskyOnly
    )

    begin {
        Initialize-MsecExoSession -Endpoint Exchange

        # Accepted domains decide what external means. Same contract as
        # Get-MsecExchangeMailbox: unreadable leaves the flag null, never false.
        $script:MsecInboxRuleDomains = $null
        try {
            $script:MsecInboxRuleDomains = @((Get-AcceptedDomain -ErrorAction Stop).DomainName |
                ForEach-Object { "$_".ToLower() })
        }
        catch {
            Write-Warning "Could not read accepted domains, so ForwardsExternally is null rather than false on every rule: $($_.Exception.Message)"
        }

        # Folders a rule files mail into to keep it out of sight. Ordinary rules file into
        # project folders; these are the ones that show up in compromise after compromise.
        $concealing = @('RSS Feeds', 'RSS Subscriptions', 'Conversation History', 'Archive',
                        'Junk Email', 'Junk E-mail', 'Deleted Items', 'Notes')

        $collected = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($m in @($Mailbox)) { if ($m) { $collected.Add($m) } }
    }

    end {
        $targets = $null
        if ($collected.Count) {
            $targets = @($collected | Select-Object -Unique | ForEach-Object {
                [pscustomobject]@{ Address = $_; Type = $null }
            })
        }
        else {
            $params = @{ ResultSize = 'Unlimited' }
            if ($RecipientTypeDetails -notcontains 'All') { $params['RecipientTypeDetails'] = $RecipientTypeDetails }
            try {
                $targets = @(Get-EXOMailbox @params -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{ Address = [string] $_.PrimarySmtpAddress; Type = [string] $_.RecipientTypeDetails }
                })
            }
            catch {
                throw "Could not list mailboxes to sweep: $($_.Exception.Message)"
            }
            Write-Verbose "Sweeping $($targets.Count) mailbox(es); Get-InboxRule is one call each, so expect roughly $([int]($targets.Count * 1.7)) seconds."
        }

        # Pulls SMTP addresses out of 'Display Name [SMTP:someone@example.com]'. An EX: entry is
        # a directory object and therefore internal by construction.
        $addressesOf = {
            param($Value)
            @(foreach ($entry in @($Value)) {
                $text = "$entry"
                foreach ($match in [regex]::Matches($text, '(?i)SMTP:([^\]\s;,]+)')) { $match.Groups[1].Value }
            })
        }

        $i = 0
        foreach ($target in $targets) {
            $i++
            Write-Progress -Activity 'Reading inbox rules' -Status $target.Address `
                -PercentComplete ([int](100 * $i / [math]::Max($targets.Count, 1)))

            $rules = $null
            try {
                $rules = @(Get-InboxRule -Mailbox $target.Address -ErrorAction Stop -WarningAction SilentlyContinue)
            }
            catch {
                Write-Warning "Could not read inbox rules for '$($target.Address)', so this mailbox is reported as unreadable rather than as having none: $($_.Exception.Message)"
                [PSCustomObject]@{
                    PSTypeName = 'MsecExchangeInboxRule'
                    Mailbox = $target.Address; MailboxType = $target.Type
                    RuleName = 'Unreadable'; Enabled = $null; Priority = $null
                    ForwardTo = $null; RedirectTo = $null; ForwardAsAttachmentTo = $null
                    ExternalTargets = $null; ForwardsExternally = $null
                    DeleteMessage = $null; SoftDeleteMessage = $null; MoveToFolder = $null
                    MarkAsRead = $null; StopProcessingRules = $null
                    IsRisky = $null; RiskReasons = $null
                    IsValid = $null; ErrorType = $null; Description = $null
                }
                continue
            }

            foreach ($rule in $rules) {
                $fwd      = & $addressesOf $rule.ForwardTo
                $redirect = & $addressesOf $rule.RedirectTo
                $fwdAttach = & $addressesOf $rule.ForwardAsAttachmentTo
                $all = @($fwd + $redirect + $fwdAttach)

                $external = $null
                $externalTargets = @()
                if ($null -ne $script:MsecInboxRuleDomains) {
                    $externalTargets = @($all | Where-Object {
                        $domain = ($_ -split '@')[-1]
                        $domain -and ($domain.ToLower() -notin $script:MsecInboxRuleDomains)
                    })
                    $external = [bool] $externalTargets.Count
                }

                $moveTo    = [string] $rule.MoveToFolder
                $deletes   = [bool] ($rule.DeleteMessage -or $rule.SoftDeleteMessage)
                $marksRead = [bool] $rule.MarkAsRead

                $reasons = @()
                if ($external) { $reasons += 'forwards or redirects outside the tenant' }
                elseif ($null -eq $external -and $all.Count) { $reasons += 'forwards, but external could not be determined' }
                if ($deletes) { $reasons += 'deletes the message' }

                # ONLY a CONCEALING folder counts, not any folder. The first version of this
                # flagged "files somewhere and marks it read" outright, and measured across 265
                # mailboxes that fired on 292 of 1373 rules - almost all of them people filing
                # study correspondence into per-study folders and marking it read, which is
                # exactly what mail rules are for. Flagging 21% of all rules buries the three
                # that forward outside the tenant. MarkAsRead is still a column either way.
                if ($moveTo -and ($moveTo -in $concealing)) {
                    $reasons += if ($marksRead) { "files into '$moveTo' and marks it read" }
                                else { "files into '$moveTo'" }
                }
                if ($rule.IsValid -eq $false) { $reasons += "rule is invalid ($([string] $rule.ErrorType))" }

                $isRisky = if ($null -eq $external -and $all.Count) { $null } else { [bool] $reasons.Count }

                if ($RiskyOnly -and $isRisky -ne $true) { continue }

                [PSCustomObject]@{
                    PSTypeName            = 'MsecExchangeInboxRule'
                    Mailbox               = $target.Address
                    MailboxType           = $target.Type
                    RuleName              = [string] $rule.Name
                    Enabled               = $rule.Enabled
                    Priority              = $rule.Priority
                    ForwardTo             = ($fwd -join '; ')
                    RedirectTo            = ($redirect -join '; ')
                    ForwardAsAttachmentTo = ($fwdAttach -join '; ')
                    ExternalTargets       = if ($null -eq $external) { $null } else { ($externalTargets -join '; ') }
                    ForwardsExternally    = $external
                    DeleteMessage         = [bool] $rule.DeleteMessage
                    SoftDeleteMessage     = [bool] $rule.SoftDeleteMessage
                    MoveToFolder          = $moveTo
                    MarkAsRead            = $marksRead
                    StopProcessingRules   = [bool] $rule.StopProcessingRules
                    IsRisky               = $isRisky
                    RiskReasons           = ($reasons -join '; ')
                    IsValid               = $rule.IsValid
                    ErrorType             = [string] $rule.ErrorType
                    Description           = (("$($rule.Description)") -replace '\s+', ' ').Trim()
                }
            }
        }

        Write-Progress -Activity 'Reading inbox rules' -Completed
    }
}
