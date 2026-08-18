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

Update-TypeData -TypeName 'MsecEntraTenantSecuritySetting' `
    -DefaultDisplayPropertySet 'SecurityDefaultsEnabled', 'ConditionalAccessAvailable', 'GlobalAdministratorCount', 'EntraIdPremium' `
    -Force

Update-TypeData -TypeName 'MsecEntraMfaRegistration' `
    -DefaultDisplayPropertySet 'UserPrincipalName', 'IsAdmin', 'IsMfaCapable', 'DefaultMfaMethod' `
    -Force

Update-TypeData -TypeName 'MsecEntraMfaEvidence' `
    -DefaultDisplayPropertySet 'UserPrincipalName', 'EvidenceStatus', 'IsMfaCapable', 'DefaultMfaMethod', 'IsAdmin' `
    -Force

Update-TypeData -TypeName 'MsecEntraLicense' `
    -DefaultDisplayPropertySet 'SkuPartNumber', 'Enabled', 'Assigned', 'CapabilityStatus' `
    -Force

Update-TypeData -TypeName 'MsecEntraDirectoryRoleMember' `
    -DefaultDisplayPropertySet 'RoleName', 'UserPrincipalName', 'MemberType', 'AccountEnabled' `
    -Force

Update-TypeData -TypeName 'MsecEntraPrivilegedPrincipal' `
    -DefaultDisplayPropertySet 'EffectiveName', 'EffectiveType', 'RoleName', 'AssignmentType', 'PrincipalName', 'PrincipalType' `
    -Force

Update-TypeData -TypeName 'MsecIntuneConfigurationProfile' `
    -DefaultDisplayPropertySet 'DisplayName', 'Source', 'Platform', 'AssignmentCount', 'Status' `
    -Force

Update-TypeData -TypeName 'MsecAdoServiceConnection' `
    -DefaultDisplayPropertySet 'Name', 'Type', 'AuthScheme', 'IsShared' `
    -Force

# How long a cached Resource Graph result is reused before Search-MsecAzureResourceGraph goes
# back to Azure. Deliberately short. Resource inventory changes on the timescale of deployments,
# so a few minutes buys most of the benefit across a working session - while an hour is long
# enough that a vault opened to the internet this morning could still read as sealed, and these
# queries exist to catch exactly that. -NoCache forces a live query when you need one.
$script:MsecGraphCacheMaxAge = [timespan]::FromMinutes(15)

# Cache-backed -SubscriptionId completion, shared by every command that takes one.
#
# Registered here rather than as a per-parameter [ArgumentCompleter()] attribute because four
# commands need the identical completer and an attribute cannot be shared between them. The
# per-command completers (-ResourceType, -Name, -Subject, -WorkspaceName) stay as attributes:
# they belong to one command each, and living next to the parameter is more discoverable.
#
# Reads the local cache and NEVER calls Azure. A completer that queries ARM blocks the prompt on
# every Tab, and when ARM is unhealthy it does not fail fast, it hangs. The cache is refreshed by
# any estate-wide call, which already enumerates subscriptions, so it stays warm for free.
#
# Deliberately not Get-AzContext -ListAvailable, which is local and instant but answers a
# different question - see Get-MsecSubscriptionList for why that list is not the same set.
$msecSubscriptionCompleter = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    try {
        $module = Get-Module msec
        if (-not $module) { return }
        # Read-MsecCache is private, and completers run outside module scope; invoking the
        # scriptblock against the module object runs it where private functions resolve.
        $subs = @(& $module { Read-MsecCache -Name 'subscriptions' })
        $word = ([string]$wordToComplete).Trim("'`"")

        $subs | Where-Object { $_.Name -like "$word*" -or $_.Id -like "$word*" } | Sort-Object Name |
            ForEach-Object {
                # -Subscription takes a name; -SubscriptionId (the older cmdlets, and the alias)
                # takes a GUID. Same cache, same list, different thing inserted.
                #
                # A name shared by several subscriptions is completed as the ID instead: the name
                # would bind and then fail as ambiguous, so completing it would be handing over a
                # value known not to work. This estate has three called 'Cloud Subscription'.
                $duplicated = @($subs | Where-Object Name -eq $_.Name).Count -gt 1
                $insert = if ($parameterName -eq 'Subscription' -and -not $duplicated) { $_.Name } else { $_.Id }
                if ($insert -match "[\s']") { $insert = "'" + ($insert -replace "'", "''") + "'" }

                [System.Management.Automation.CompletionResult]::new(
                    $insert, "$($_.Name)  $($_.Id)", 'ParameterValue',
                    "$($_.Name) - $($_.Id) (tenant $($_.TenantId))")
            }
    }
    catch {
        # A completer must never throw or the prompt breaks.
    }
}

Register-ArgumentCompleter -ParameterName 'Subscription' -ScriptBlock $msecSubscriptionCompleter -CommandName @(
    'Search-MsecAzureResourceGraph'
)

# The two older cmdlets still take a GUID: Invoke-MsecAzureVMScript's -SubscriptionId is not a
# filter at all, it is pipeline data carrying the VM's subscription from Search-MsecAzureResource-
# Graph rows, so renaming it would break that binding.
Register-ArgumentCompleter -ParameterName 'SubscriptionId' -ScriptBlock $msecSubscriptionCompleter -CommandName @(
    'Get-MsecAzureSecureScore',
    'Invoke-MsecAzureVMScript'
)

Export-ModuleMember -Function $public.BaseName
