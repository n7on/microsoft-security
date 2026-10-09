function New-MsecDefenderIndicator {
    <#
    .SYNOPSIS
        Creates a Defender for Endpoint indicator - allow, block or audit a certificate, file
        hash, IP, domain or URL. Runs as YOU, not as the msec app.

    .DESCRIPTION
        RUNS AS THE SIGNED-IN USER, DELIBERATELY AND UNAVOIDABLY. The indicator API has no
        read-only permission: listing indicators requires Ti.ReadWrite, the same scope that
        creates and deletes them. Granting that to the msec app would mean a certificate in Key
        Vault could allow-list arbitrary files and publishers across every onboarded device -
        which is the ability to turn blocking off for malware of someone's choosing. So this
        takes a delegated token from your Az context instead, the same way Get-MsecSentinelRule
        reads ARM, and the app keeps its read-only property.

        AN ALLOW INDICATOR IS A HOLE IN EVERY CONTROL THAT HONOURS IT, NOT JUST THE ONE YOU HAD
        IN MIND. 'Allowed' on a certificate exempts everything that certificate signs - now and
        in future - from Microsoft Defender Antivirus and from every attack surface reduction
        rule that honours certificate indicators, not only the rule that prompted it. That is
        usually the point, and it is still worth writing down: -Description is passed straight
        through to the indicator and is the only place the reason survives.

        CERTIFICATE INDICATORS MATCH LEAF CERTIFICATES ONLY. Parents and children are not
        included, so an indicator on a publisher's current signing certificate stops covering
        anything they sign after they renew - while continuing to cover everything already
        signed, because timestamped Authenticode signatures outlive the certificate. The failure
        is therefore silent and only affects new files. Get-MsecDefenderCertificateUsage
        -ExpiringWithinDays is how that is seen coming.

        THE THUMBPRINT IS WHAT THE API WANTS, NOT A FILE. The Defender portal's wizard asks for
        a .CER upload and derives the thumbprint from it; the API takes the thumbprint directly.
        Get-MsecDefenderCertificateUsage reports it as SignerHash, so the whole loop - notice a
        new signing certificate, allow it - needs nothing downloaded or extracted.

        IT REFUSES TO CREATE A DUPLICATE. An identical type-and-value pair already present is
        reported and left alone rather than added again, because the API accepts duplicates
        happily and a second indicator for the same certificate is indistinguishable from the
        first until somebody tries to remove one.

        CONFIRMIMPACT IS HIGH. This changes enforcement for every onboarded device in scope, so
        a bare call prompts, and -WhatIf describes exactly what would be created.

    .PARAMETER Type
        Indicator type. 'CertificateThumbprint' takes a SHA-1 thumbprint as -Value.

    .PARAMETER Value
        The indicator value - thumbprint, hash, IP, domain or URL. For CertificateThumbprint
        this is 40 hexadecimal characters and is validated before anything is sent, because the
        API accepts a malformed thumbprint without complaint and the indicator then silently
        matches nothing.

    .PARAMETER Action
        What Defender does on a match. 'Allowed' exempts; 'Block' and 'BlockAndRemediate'
        enforce; 'Audit' records without acting.

    .PARAMETER Title
        Short name, required by the API.

    .PARAMETER Description
        Why this indicator exists. Required here although the API treats it as optional - an
        allow indicator with no recorded reason is indistinguishable from a mistake six months
        later, and this is the only field that travels with it.

    .PARAMETER Severity
        Informational, Low, Medium or High. Defaults to Informational.

    .PARAMETER ExpirationTime
        When the indicator stops applying. Omit for no expiry.

    .PARAMETER DeviceGroup
        RBAC device group names to scope it to. Omit to apply to every device.

    .PARAMETER GenerateAlert
        Raise an alert on match. Meaningless for 'Allowed'.

    .EXAMPLE
        Get-MsecDefenderCertificateUsage -Signer anthropic -Issuer DigiCert |
            ForEach-Object {
                New-MsecDefenderIndicator -Type CertificateThumbprint -Value $_.SignerHash `
                    -Action Allowed -Title "Anthropic code signing" `
                    -Description "Claude is deployed on 95 devices across 8 install paths; ASR rules scid_2510 and scid_2517 block it. Work item 106897." -WhatIf
            }

        The rotation loop, as a dry run. Drop -WhatIf to create it.

    .EXAMPLE
        New-MsecDefenderIndicator -Type CertificateThumbprint `
            -Value 0d7581d2c51c59df686c3000c70bf543f9f6c6cb -Action Allowed `
            -Title 'Anthropic, PBC code signing' `
            -Description 'Allows Claude Desktop and Claude Code past ASR. Reviewed annually; see 106897.'

    .OUTPUTS
        PSCustomObject describing the created indicator, PSTypeName 'MsecDefenderIndicator'.

    .NOTES
        Needs Connect-AzAccount and the Ti.ReadWrite permission on YOUR account - Security
        Administrator or equivalent. The msec app cannot do this and is not asked to.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CertificateThumbprint', 'FileSha1', 'FileSha256', 'FileMd5', 'IpAddress', 'DomainName', 'Url')]
        [string] $Type,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Value,

        [Parameter(Mandatory)]
        [ValidateSet('Allowed', 'Audit', 'Block', 'BlockAndRemediate', 'Warn')]
        [string] $Action,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Title,

        # Mandatory here although the API allows it to be empty. See the help.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Description,

        [ValidateSet('Informational', 'Low', 'Medium', 'High')]
        [string] $Severity = 'Informational',

        [datetime] $ExpirationTime,

        [string[]] $DeviceGroup,

        [switch] $GenerateAlert
    )

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        throw 'No Azure context. Run Connect-AzAccount first - this command runs as you, not as the msec app, because the indicator API has no read-only scope and the app is deliberately read-only.'
    }

    # A thumbprint is 40 hex characters. The API takes a malformed one without complaint and the
    # indicator then matches nothing at all, which looks exactly like a correctly created
    # indicator that the product is ignoring. Checked here so the failure is loud.
    if ($Type -eq 'CertificateThumbprint') {
        $normalised = ($Value -replace '[\s:]', '')
        if ($normalised -notmatch '^[0-9a-fA-F]{40}$') {
            throw "'$Value' is not a SHA-1 certificate thumbprint. Expected 40 hexadecimal characters; got $($normalised.Length) after stripping spaces and colons. Get-MsecDefenderCertificateUsage reports the correct value as SignerHash."
        }
        $Value = $normalised.ToLowerInvariant()
    }

    $defender = (Get-MsecEnvironment).DefenderResource
    if (-not $defender) {
        throw "Microsoft Defender for Endpoint has no endpoint in this cloud, so indicators cannot be managed here."
    }

    $tokenResponse = Get-AzAccessToken -ResourceUrl $defender -ErrorAction Stop
    $token = if ($tokenResponse.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    }
    else { [string] $tokenResponse.Token }
    $headers = @{ Authorization = "Bearer $token" }

    # Duplicate check before the write. The API will happily create a second identical indicator.
    $existing = $null
    try {
        $all = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Uri "$defender/api/indicators").value)
        $existing = $all | Where-Object { $_.indicatorType -eq $Type -and "$($_.indicatorValue)" -eq "$Value" } | Select-Object -First 1
    }
    catch {
        $detail = $_.Exception.Message
        if ($detail -match '401|403|Unauthorized|Forbidden') {
            throw "Forbidden listing Defender indicators as $($context.Account.Id). This API has NO read-only permission - listing requires the Ti.ReadWrite scope, normally through the Security Administrator role. This is an authorization failure on YOUR account, not on the msec app. Original error: $detail"
        }
        # Not fatal on its own: a failed duplicate check must not stop a deliberate creation, but
        # the caller has to know the guard did not run.
        Write-Warning "Could not list existing indicators, so the duplicate check did NOT run and this may create a second indicator for the same value: $detail"
    }

    if ($existing) {
        Write-Warning "An indicator for $Type '$Value' already exists (id $($existing.id), action '$($existing.action)', created by $($existing.createdBy)). Nothing was created. Remove or edit the existing one if the action needs to change."
        return [PSCustomObject]@{
            PSTypeName     = 'MsecDefenderIndicator'
            Id             = [string] $existing.id
            IndicatorType  = [string] $existing.indicatorType
            IndicatorValue = [string] $existing.indicatorValue
            Action         = [string] $existing.action
            Title          = [string] $existing.title
            Description    = [string] $existing.description
            Severity       = [string] $existing.severity
            CreatedBy      = [string] $existing.createdBy
            CreatedUtc     = if ($existing.creationTimeDateTimeUtc) { [datetime] $existing.creationTimeDateTimeUtc } else { $null }
            ExpirationTime = if ($existing.expirationTime) { [datetime] $existing.expirationTime } else { $null }
            DeviceGroup    = @($existing.rbacGroupNames)
            AlreadyExisted = $true
            Raw            = $existing
        }
    }

    $body = @{
        indicatorValue = $Value
        indicatorType  = $Type
        action         = $Action
        title          = $Title
        description    = $Description
        severity       = $Severity
        generateAlert  = [bool] $GenerateAlert
    }
    if ($PSBoundParameters.ContainsKey('ExpirationTime')) { $body['expirationTime'] = $ExpirationTime.ToUniversalTime().ToString('o') }
    if ($DeviceGroup) { $body['rbacGroupNames'] = @($DeviceGroup) }

    $scope = if ($DeviceGroup) { "device group(s) $($DeviceGroup -join ', ')" } else { 'EVERY onboarded device' }
    $target = "$Type $Value"
    $operation = "Create '$Action' indicator on $scope"
    if (-not $PSCmdlet.ShouldProcess($target, $operation)) { return }

    try {
        $created = Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' `
            -Body ($body | ConvertTo-Json -Depth 5) -Uri "$defender/api/indicators" -ErrorAction Stop
    }
    catch {
        $detail = $_.Exception.Message
        $responseBody = $_.ErrorDetails.Message
        if ($responseBody) {
            $message = try { ($responseBody | ConvertFrom-Json).error.message } catch { $null }
            if ($message) { $detail = "$message ($detail)" }
        }
        if ($detail -match '401|403|Unauthorized|Forbidden') {
            throw "Forbidden creating the indicator as $($context.Account.Id). Creating indicators needs the Ti.ReadWrite scope on your account, normally through Security Administrator. Original error: $detail"
        }
        throw "Could not create the indicator: $detail"
    }

    if ($Action -eq 'Allowed') {
        Write-Verbose "Created an ALLOW indicator. It exempts the matching entity from Defender Antivirus and from every attack surface reduction rule that honours indicators of this type - not only the rule it was created for."
    }

    [PSCustomObject]@{
        PSTypeName     = 'MsecDefenderIndicator'
        Id             = [string] $created.id
        IndicatorType  = [string] $created.indicatorType
        IndicatorValue = [string] $created.indicatorValue
        Action         = [string] $created.action
        Title          = [string] $created.title
        Description    = [string] $created.description
        Severity       = [string] $created.severity
        CreatedBy      = [string] $created.createdBy
        CreatedUtc     = if ($created.creationTimeDateTimeUtc) { [datetime] $created.creationTimeDateTimeUtc } else { $null }
        ExpirationTime = if ($created.expirationTime) { [datetime] $created.expirationTime } else { $null }
        DeviceGroup    = @($created.rbacGroupNames)
        AlreadyExisted = $false
        Raw            = $created
    }
}
