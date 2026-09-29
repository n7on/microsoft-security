function Get-MsecPurviewSensitivityLabel {
    <#
    .SYNOPSIS
        Sensitivity labels, with what protection each one actually applies and which policy
        publishes it.

    .DESCRIPTION
        THE PROTECTION SETTINGS ARE NOT WHERE YOU WOULD LOOK FOR THEM. Get-Label has no
        EncryptionEnabled property - asking for one returns empty on every label, which reads
        exactly like "no label encrypts anything" and is wrong. The settings live in
        LabelActions, a collection of JSON strings, one per action, each carrying its own
        settings including whether that action is switched off.

        SO CONFIGURED AND ENABLED ARE SEPARATE COLUMNS, because they genuinely differ. Measured
        on one tenant: Internal and Confidential both carry an encrypt action, and both have it
        disabled. The effect is the same as having none, but the cause is the opposite - someone
        set encryption up and turned it off, which is a decision to revisit rather than work
        never done.

        NB THE DISABLED FLAG ARRIVES AS THE STRING 'true' OR 'false'. In PowerShell the string
        'false' is TRUTHY, so a plain truthiness test on it reports every action as disabled.
        This compares the text explicitly; anything writing new checks against LabelActions has
        to do the same.

        A LABEL NOBODY PUBLISHES CANNOT BE APPLIED. PublishedBy lists the label policies that
        offer it to users, and IsPublished is false when none do - a label that exists but
        reaches nobody is a common leftover from a pilot and is invisible in the label list.

    .PARAMETER Name
        Limit to labels whose name or display name matches. Wildcards allowed.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecPurviewSensitivityLabel |
            Format-Table Priority, DisplayName, EncryptionConfigured, EncryptionEnabled, IsPublished

    .EXAMPLE
        # Labels where protection was set up and then switched off.
        Get-MsecPurviewSensitivityLabel |
            Where-Object { $_.EncryptionConfigured -and -not $_.EncryptionEnabled }

    .EXAMPLE
        # Labels that exist but reach nobody.
        Get-MsecPurviewSensitivityLabel | Where-Object { -not $_.IsPublished }

    .OUTPUTS
        One PSCustomObject per label, PSTypeName 'MsecPurviewSensitivityLabel'.

    .NOTES
        Needs Connect-Msec. The compliance session is opened automatically on first use - that
        handshake takes a few seconds and imports a few hundred cmdlets, so it is reported rather
        than done silently. Call Connect-MsecPurview yourself to control -Organization, or to
        choose when those 102 cmdlet names land in your runspace.

        Read-only.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [string] $Name
    )

    Initialize-MsecExoSession -Endpoint Compliance
    Assert-MsecExoCmdlet -Name 'Get-Label' -Feature 'sensitivity labels'

    $labels = @(Get-Label -ErrorAction Stop)

    # Which policies publish which labels. A failure here must not silently become "published by
    # nothing", so it is tracked and the column goes null instead.
    $policies = $null
    try { $policies = @(Get-LabelPolicy -ErrorAction Stop) }
    catch {
        Write-Warning "Could not read label policies, so PublishedBy and IsPublished are null rather than empty: $($_.Exception.Message)"
    }

    $byDisplayName = @{}
    foreach ($label in $labels) { $byDisplayName[[string] $label.Guid] = [string] $label.DisplayName }

    $filtered = $labels
    if ($Name) {
        $filtered = @($labels | Where-Object { $_.Name -like $Name -or $_.DisplayName -like $Name })
    }

    foreach ($label in $filtered) {
        # Each entry is a JSON document describing one action and its settings.
        $actions = @()
        foreach ($raw in @($label.LabelActions)) {
            if (-not $raw) { continue }
            try { $actions += ($raw | ConvertFrom-Json -ErrorAction Stop) }
            catch { Write-Warning "Label '$($label.DisplayName)' has a LabelActions entry that is not valid JSON; it is ignored." }
        }

        # 'disabled' comes back as the STRING 'true'/'false'. Comparing the text is deliberate:
        # [bool]'false' is $true, which would mark every configured action as switched off.
        $isEnabled = {
            param($action)
            $flag = @($action.Settings | Where-Object { $_.Key -eq 'disabled' })[0]
            if (-not $flag) { return $true }          # no flag at all means active
            ([string] $flag.Value) -ne 'true'
        }

        $encrypt  = @($actions | Where-Object { $_.Type -eq 'encrypt' })[0]
        $marking  = @($actions | Where-Object { $_.Type -eq 'applycontentmarking' })[0]
        $watermark = @($actions | Where-Object { $_.Type -eq 'applywatermarking' })[0]

        $publishedBy = $null
        if ($null -ne $policies) {
            $publishedBy = @($policies | Where-Object {
                $labelNames = @($_.Labels | ForEach-Object { [string] $_ })
                ($labelNames -contains [string] $label.Name) -or ($labelNames -contains [string] $label.DisplayName)
            } | ForEach-Object { [string] $_.Name })
        }

        [PSCustomObject]@{
            PSTypeName              = 'MsecPurviewSensitivityLabel'
            DisplayName             = [string] $label.DisplayName
            Name                    = [string] $label.Name
            Priority                = $label.Priority
            Disabled                = [bool] $label.Disabled
            ParentLabel             = $(if ($label.ParentId) { $byDisplayName[[string] $label.ParentId] } else { $null })
            ContentType             = [string] $label.ContentType
            ActionTypes             = @($actions | ForEach-Object { [string] $_.Type })
            # Configured vs enabled, kept apart on purpose - see the help.
            EncryptionConfigured    = [bool] $encrypt
            EncryptionEnabled       = $(if ($encrypt) { [bool] (& $isEnabled $encrypt) } else { $false })
            EncryptionType          = $(if ($encrypt) { [string] @($encrypt.Settings | Where-Object { $_.Key -eq 'protectiontype' })[0].Value } else { $null })
            ContentMarkingConfigured = [bool] $marking
            ContentMarkingEnabled   = $(if ($marking) { [bool] (& $isEnabled $marking) } else { $false })
            WatermarkConfigured     = [bool] $watermark
            WatermarkEnabled        = $(if ($watermark) { [bool] (& $isEnabled $watermark) } else { $false })
            # $null when the policies could not be read - never an empty list, which would read
            # as "checked, published by nobody".
            PublishedBy             = $publishedBy
            IsPublished             = $(if ($null -eq $publishedBy) { $null } else { [bool] @($publishedBy).Count })
            Tooltip                 = [string] $label.Tooltip
        }
    }
}
