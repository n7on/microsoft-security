# Dot-source private helpers first, then public functions; export only public.
$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($function in @($private + $public)) {
    try {
        . $function.FullName
    }
    catch {
        Write-Error "Failed to import function $($function.FullName): $_"
    }
}

# Module root path - used by functions that need to find bundled assets such as
# the Scripts/Linux and Scripts/Windows folders.
$script:MsecModuleRoot = $PSScriptRoot

# Module-scoped session populated by Connect-Msec, used by all score functions.
# The private key NEVER leaves Key Vault - signing happens via Invoke-AzKeyVaultKeyOperation.
# Shape:
#   @{
#     TenantId        = '<guid>'
#     ClientId        = '<guid>'           # appId of the msec app registration
#     KeyVaultName    = '<name>'
#     KeyName         = '<name>'           # same as the cert name when KV created them together
#     ThumbprintBytes = [byte[]]           # SHA-1 thumbprint, used for the JWT x5t header
#     Endpoints       = [pscustomobject]   # cloud endpoints from Get-MsecEnvironment
#                                          # (AadAuthority, GraphResource, DefenderResource,
#                                          #  KeyVaultResource/DnsSuffix, ArmResource)
#     Tokens          = @{
#         '<resource>' = @{ Token = '<jwt>'; ExpiresOn = [DateTimeOffset] }
#     }
#   }
$script:MsecSession = $null

# Default display property sets for msec types. Each Get-Msec* row that embeds a
# `Raw` (or otherwise heavy nested) property gets a PowerShell type name so
# Format-Table only shows the curated columns by default. The Raw column is still
# fully accessible via $row.Raw or Format-List - this only affects the *default*
# table layout. -Force is required because Pester / repeated imports re-register.
Update-TypeData -TypeName 'MsecEntraConditionalAccessPolicy' `
    -DefaultDisplayPropertySet 'DisplayName', 'State', 'Requires', 'IncludedGroups' `
    -Force

Update-TypeData -TypeName 'MsecIntuneConfigurationProfile' `
    -DefaultDisplayPropertySet 'DisplayName', 'Source', 'Platform', 'AssignmentCount', 'Status' `
    -Force

Update-TypeData -TypeName 'MsecAdoServiceConnection' `
    -DefaultDisplayPropertySet 'Name', 'Type', 'AuthScheme', 'IsShared' `
    -Force

Export-ModuleMember -Function $public.BaseName
