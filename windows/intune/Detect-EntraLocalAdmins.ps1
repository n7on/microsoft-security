
$ErrorActionPreference = 'Stop'

try {
    $entraAdminUsers = Get-LocalGroupMember -SID 'S-1-5-32-544' |
        Where-Object {
            "$($_.PrincipalSource)" -eq 'AzureAD' -and
            "$($_.ObjectClass)" -eq 'User'
        } |
        Sort-Object Name

    if ($entraAdminUsers) {
        $output = $entraAdminUsers |
            ForEach-Object {
                if ([string]::IsNullOrWhiteSpace($_.Name)) {
                    $_.SID.Value
                }
                else {
                    $_.Name
                }
            }

        Write-Output ($output -join ';')
    }
    else {
        Write-Output 'None'
    }

    # Successful inventory collection
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"

    # Collection itself failed
    exit 1
}