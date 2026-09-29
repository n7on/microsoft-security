function Initialize-MsecExoSession {
    <#
    .SYNOPSIS
        Ensures a session to one ExchangeOnlineManagement endpoint exists, for the tenant the
        msec session is currently on.

    .DESCRIPTION
        One implementation for both Exchange Online and Security & Compliance, because they
        differ only in endpoint and connect cmdlet, and the part that is easy to get wrong - the
        tenant check - must not be written twice.

        IT MATCHES ON TENANT, NOT JUST ON "SOMETHING IS CONNECTED". A session outlives the
        Connect-Msec that prompted it, so after switching tenants a check that only asked "is
        there a compliance connection?" would reuse the PREVIOUS tenant's session and report its
        data under the new tenant's name. Nothing about that looks like an error. Get-Connection-
        Information carries TenantID, so the comparison is available and cheap.

        A STALE SESSION IS CLOSED RATHER THAN LEFT ALONGSIDE. Connecting again without
        disconnecting leaves two live sessions and the cmdlets pick between them in a way the
        caller cannot see, which turns a wrong-tenant read into an intermittent one.

        IT DOES NOT REQUIRE THE SESSION TO BE THE APP'S. A caller who signed in as themselves
        has rights the app lacks, and reconnecting as the app would quietly take those away -
        the same trap Get-MsecTeamsPolicy avoids with its -AsCurrentUser guard. Tenant is the
        correctness question; identity is the caller's business, and is only noted verbosely.

        The handshake takes seconds, so it is reported rather than done silently: an unexplained
        pause in a Get- command reads as a hang.

    .PARAMETER Endpoint
        Exchange or Compliance.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Exchange', 'Compliance')]
        [string] $Endpoint
    )

    $label = if ($Endpoint -eq 'Compliance') { 'Microsoft Purview' } else { 'Exchange Online' }
    $wantTenant = [string] $script:MsecSession.TenantId

    $existing = @(Get-MsecExoConnection -Endpoint $Endpoint)

    # Split on tenant. Anything on another tenant is not merely unhelpful, it is a trap.
    $usable = @($existing | Where-Object { -not $wantTenant -or "$($_.TenantID)" -eq $wantTenant })
    $stale  = @($existing | Where-Object { $wantTenant -and "$($_.TenantID)" -ne $wantTenant })

    foreach ($connection in $stale) {
        Write-Warning ("Closing a $label session on tenant $($connection.TenantID); the msec session is now on " +
                       "$wantTenant. Reusing it would have reported the wrong tenant's data under this one's name.")
        try { Disconnect-ExchangeOnline -ConnectionId $connection.ConnectionId -Confirm:$false -ErrorAction Stop }
        catch { Write-Warning "Could not close that session: $($_.Exception.Message)" }
    }

    if ($usable.Count) {
        $appId = [string] $script:MsecSession.ClientId
        $other = @($usable | Where-Object { $appId -and "$($_.AppId)" -and "$($_.AppId)" -ne $appId })
        if ($other.Count) {
            Write-Verbose "Reusing an existing $label session signed in as $($other[0].UserPrincipalName), not as the msec app."
        }
        return
    }

    if (-not $script:MsecSession) {
        throw "Not connected. Run Connect-Msec first - the $label commands then open their own session automatically."
    }

    $progressId = if ($Endpoint -eq 'Compliance') { 1731 } else { 1732 }
    Write-Progress -Id $progressId -Activity $label `
        -Status 'Opening a session (first call only - this takes a few seconds)'
    try {
        if ($Endpoint -eq 'Compliance') { Connect-MsecPurview } else { Connect-MsecExchangeOnline }
        Write-Verbose "$label session opened automatically."
    }
    finally {
        Write-Progress -Id $progressId -Activity $label -Completed
    }
}
