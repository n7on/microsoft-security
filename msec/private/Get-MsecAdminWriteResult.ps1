function Get-MsecAdminWriteResult {
    <#
    .SYNOPSIS
        Re-reads an object after a write and reports which requested fields have not settled.

    .DESCRIPTION
        Defender XDR is eventually consistent. A GET issued immediately after a successful PATCH
        can return the PRE-WRITE values, and reporting that as "the change did not hold" is a
        false alarm - observed live: an alert PATCHed at 16:37:00 still read as unchanged
        moments later and was correct when read again. A verification step that cries wolf is
        worse than none, because people learn to ignore it.

        So this polls, briefly and with a bounded budget, and stops the moment every requested
        field matches. Mismatch is only returned when the values are STILL wrong after the last
        attempt, which makes it worth acting on.

        It never retries the write. Only the read is repeated - if the PATCH itself failed the
        caller has already handled that.

    .PARAMETER Path
        Path to re-read, e.g. /v1.0/security/alerts_v2/{id}.

    .PARAMETER Expected
        Key/value pairs that were sent. Compared against the re-read object by the same keys.

    .PARAMETER DelaySeconds
        Waits between attempts. The first read happens immediately, before any of these, so the
        common case costs nothing. Defaults to a ~10s total budget.

    .OUTPUTS
        Hashtable: Object (the last successful read, or $null), Mismatch (array of key names
        still wrong), Attempts, and Error (the last read failure, if every attempt failed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        $Expected,

        [Parameter()]
        [int[]] $DelaySeconds = @(2, 3, 5)
    )

    # Collections compare as a joined string so customTags behaves like any other field.
    $normalize = {
        param($value)
        if ($null -eq $value) { return '' }
        if ($value -is [string]) { return $value }
        if ($value -is [System.Collections.IEnumerable]) {
            return ((@($value) | ForEach-Object { [string] $_ }) -join '|')
        }
        [string] $value
    }

    $object   = $null
    $mismatch = @()
    $lastErr  = $null
    $attempt  = 0

    # One immediate read, then one per delay.
    foreach ($wait in @(0) + @($DelaySeconds)) {
        if ($wait -gt 0) { Start-Sleep -Seconds $wait }
        $attempt++

        try { $object = Invoke-MsecAdminGraphRequest -Path $Path }
        catch {
            $lastErr = $_
            continue
        }

        $mismatch = @()
        foreach ($key in $Expected.Keys) {
            if ((& $normalize $object.$key) -ne (& $normalize $Expected[$key])) { $mismatch += $key }
        }

        if (-not $mismatch.Count) { break }
        Write-Verbose "Re-read $attempt of $($DelaySeconds.Count + 1): $($mismatch -join ', ') not settled yet."
    }

    @{
        Object   = $object
        Mismatch = $mismatch
        Attempts = $attempt
        Error    = $lastErr
    }
}
