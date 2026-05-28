function ConvertTo-MsecBase64Url {
    <#
    .SYNOPSIS
        Encodes bytes (or a UTF-8 string) as base64url (RFC 4648 §5) - used for JWT parts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        $InputObject
    )

    $bytes = if ($InputObject -is [byte[]]) {
        $InputObject
    }
    else {
        [System.Text.Encoding]::UTF8.GetBytes([string]$InputObject)
    }

    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
