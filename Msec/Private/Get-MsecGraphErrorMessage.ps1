function Get-MsecGraphErrorMessage {
    <#
    .SYNOPSIS
        Pulls Microsoft Graph's own error message out of a terminating error record.

    .DESCRIPTION
        Graph puts the useful text in the RESPONSE BODY, which PowerShell surfaces on
        $_.ErrorDetails.Message. It is NOT in $_.Exception.Message, which carries only the
        bare status line - "Response status code does not indicate success: 403 (Forbidden)."

        That distinction matters whenever one status code has several causes. /auditLogs/signIns
        and /reports/authenticationMethods/userRegistrationDetails both return 403 either
        because the app lacks a permission OR because the tenant has no Entra ID premium
        licence, and those need opposite responses: grant-and-consent versus buy-a-licence or
        accept-not-applicable. Blaming the permission unconditionally sends people through a
        consent cycle that cannot help, so callers must read what Graph actually said.

        Falls back through: Graph's `error.message` -> the raw response body (when it isn't
        JSON) -> the exception message. Never throws, so it is safe to call from a catch block.

    .PARAMETER ErrorRecord
        The ErrorRecord caught from a failed Invoke-MsecGraphRequest / Invoke-RestMethod call.

    .EXAMPLE
        catch {
            $detail = Get-MsecGraphErrorMessage $_
            if ($detail -match 'premium|B2C') { throw "…licensing…" }
            throw "…permission…"
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        $ErrorRecord
    )

    $detail = $null

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        # A JSON body is the normal case; a proxy or gateway can return plain text instead.
        $detail = try { ($ErrorRecord.ErrorDetails.Message | ConvertFrom-Json).error.message }
                  catch { $ErrorRecord.ErrorDetails.Message }
    }

    if (-not $detail -and $ErrorRecord.Exception) { $detail = $ErrorRecord.Exception.Message }

    return [string]$detail
}
