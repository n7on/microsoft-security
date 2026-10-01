function Get-MsecExchangeOrganizationSetting {
    <#
    .SYNOPSIS
        Tenant-wide Exchange Online posture in one row: the settings that decide whether mail
        can leave, whether SMTP AUTH is possible, and whether anything is audited.

    .DESCRIPTION
        THERE ARE TWO SEPARATE AUTO-FORWARDING CONTROLS and both must be off to stop it. The
        outbound spam filter policy's AutoForwardingMode governs it at the Defender layer;
        the Default remote domain's AutoForwardEnabled governs it at the transport layer.
        Turning off one and leaving the other is a common half-fix, which is why they sit
        beside each other here rather than in two different reports.

        AutoForwardingMode HAS THREE VALUES AND THE SAFE ONE IS NOT "Off". 'Automatic' is
        Microsoft's default and is system-controlled - it blocks most external auto-forwarding
        while allowing legitimate flows. 'On' permits it outright. 'Off' blocks it entirely.
        A tenant reading 'On' has deliberately opened the path that mailbox forwarding rules
        then use.

        SMTP AUTH IS THE ONE THAT BYPASSES MFA. The tenant default here is what every mailbox
        inherits unless it overrides it, so this row and Get-MsecExchangeMailbox answer
        different halves of the same question - this one is the default, that one is the
        effective value per mailbox.

        AUDIT IS REPORTED IN THE POSITIVE. UnifiedAuditLogIngestionEnabled is the switch that
        decides whether anything reaches the audit log at all; with it off, every other control
        here is unverifiable after the fact.

        Each value is read independently and a failure leaves that column $null rather than
        failing the row - a partial answer about tenant posture is worth more than none, as
        long as the gaps are visible as gaps.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecExchangeOrganizationSetting | Format-List

    .EXAMPLE
        # The two controls that must agree.
        Get-MsecExchangeOrganizationSetting |
            Select-Object AutoForwardingMode, RemoteDomainAutoForwardEnabled

    .OUTPUTS
        A single PSCustomObject, PSTypeName 'MsecExchangeOrganizationSetting'.

    .NOTES
        Needs Connect-Msec. The Exchange session is opened on first use. Read-only.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    Initialize-MsecExoSession -Endpoint Exchange

    # Each lookup is independent. One refusal must not cost the whole row.
    function Read-Setting {
        param([string] $Label, [scriptblock] $Script)
        try { & $Script }
        catch {
            Write-Warning "Could not read $Label, so it is reported as null rather than as a value: $($_.Exception.Message)"
            $null
        }
    }

    $spam = Read-Setting 'the outbound spam filter policy' {
        @(Get-HostedOutboundSpamFilterPolicy -ErrorAction Stop)
    }
    $remote = Read-Setting 'remote domains' { @(Get-RemoteDomain -ErrorAction Stop) }
    $transport = Read-Setting 'the transport config' { Get-TransportConfig -ErrorAction Stop }
    $audit = Read-Setting 'the admin audit log config' { Get-AdminAuditLogConfig -ErrorAction Stop }
    $domains = Read-Setting 'accepted domains' { @(Get-AcceptedDomain -ErrorAction Stop) }
    $inbound = Read-Setting 'inbound connectors' { @(Get-InboundConnector -ErrorAction Stop) }
    $outbound = Read-Setting 'outbound connectors' { @(Get-OutboundConnector -ErrorAction Stop) }
    $rules = Read-Setting 'transport rules' { @(Get-TransportRule -ErrorAction Stop) }

    $defaultSpam   = @($spam   | Where-Object { $_.IsDefault -or $_.Name -eq 'Default' })[0]
    $defaultRemote = @($remote | Where-Object { $_.DomainName -eq '*' -or $_.IsDefault })[0]

    [PSCustomObject]@{
        PSTypeName = 'MsecExchangeOrganizationSetting'

        # --- auto-forwarding: two controls, both must be closed ---
        # 'Automatic' is Microsoft's default and the safe one. 'On' opens it outright.
        AutoForwardingMode             = $(if ($defaultSpam) { [string] $defaultSpam.AutoForwardingMode } else { $null })
        RemoteDomainAutoForwardEnabled = $(if ($defaultRemote) { [bool] $defaultRemote.AutoForwardEnabled } else { $null })

        # --- authentication ---
        # Positive form: the raw property is SmtpClientAuthenticationDisabled.
        SmtpAuthEnabledTenantWide      = $(if ($transport) { -not $transport.SmtpClientAuthenticationDisabled } else { $null })

        # --- audit ---
        UnifiedAuditLogEnabled         = $(if ($audit) { [bool] $audit.UnifiedAuditLogIngestionEnabled } else { $null })
        AdminAuditLogEnabled           = $(if ($audit) { [bool] $audit.AdminAuditLogEnabled } else { $null })

        # --- surface ---
        AcceptedDomainCount            = $(if ($null -ne $domains)  { @($domains).Count } else { $null })
        AcceptedDomains                = $(if ($null -ne $domains)  { @($domains.DomainName | ForEach-Object { [string] $_ }) } else { $null })
        InboundConnectorCount          = $(if ($null -ne $inbound)  { @($inbound).Count } else { $null })
        InboundConnectors              = $(if ($null -ne $inbound)  { @($inbound | ForEach-Object { "$($_.Name) (enabled=$($_.Enabled))" }) } else { $null })
        OutboundConnectorCount         = $(if ($null -ne $outbound) { @($outbound).Count } else { $null })
        OutboundConnectors             = $(if ($null -ne $outbound) { @($outbound | ForEach-Object { "$($_.Name) (enabled=$($_.Enabled))" }) } else { $null })

        # --- transport rules, summarised; Get-MsecExchangeTransportRule has the detail ---
        TransportRuleCount             = $(if ($null -ne $rules) { @($rules).Count } else { $null })
        ActiveTransportRuleCount       = $(if ($null -ne $rules) { @($rules | Where-Object { $_.State -eq 'Enabled' -and $_.Mode -eq 'Enforce' }).Count } else { $null })
        FilterBypassRuleCount          = $(if ($null -ne $rules) { @($rules | Where-Object { [string] $_.SetSCL -eq '-1' }).Count } else { $null })
        ActiveFilterBypassRuleCount    = $(if ($null -ne $rules) { @($rules | Where-Object { [string] $_.SetSCL -eq '-1' -and $_.State -eq 'Enabled' -and $_.Mode -eq 'Enforce' }).Count } else { $null })

        # Non-default outbound spam policies can override AutoForwardingMode for their scope.
        NonDefaultSpamPolicyCount      = $(if ($null -ne $spam) { @($spam | Where-Object { -not ($_.IsDefault -or $_.Name -eq 'Default') }).Count } else { $null })
    }
}
