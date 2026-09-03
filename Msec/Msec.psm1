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

# Global Administrator's roleTemplateId - the same GUID in every tenant and every
# cloud. Named here because the role's DISPLAY name is not dependable: Graph returns
# it as the legacy 'Company Administrator' on many tenants, and a tenant may rename it
# outright, so any code comparing role names would silently report zero Global Admins.
# Anything asking "is this the Global Administrator role" compares against this.
$script:MsecGlobalAdministratorTemplateId = '62e90394-69f5-4237-9190-012177145e10'

# Table views for the types with COLLECTION columns, which a DefaultDisplayPropertySet
# cannot render properly - it chooses the columns but not their formatting, so a string[]
# comes out as '{a, b}'. See the header of Msec.format.ps1xml for why the data stays an
# array and only the display is flattened.
#
# Loaded here rather than declared as FormatsToProcess in Msec.psd1 because the test suite
# imports Msec.psm1 DIRECTLY - a manifest key would be skipped on that path, and the views
# would silently not apply in exactly the place they are verified. One mechanism, one code
# path, works for both import styles.
$msecFormatFile = Join-Path $PSScriptRoot 'Msec.format.ps1xml'
if (Test-Path -LiteralPath $msecFormatFile) {
    # -PrependPath so these win over anything already registered for the same type names,
    # which matters on a re-import during development.
    Update-FormatData -PrependPath $msecFormatFile
}

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

Update-TypeData -TypeName 'MsecEntraAppCredential' `
    -DefaultDisplayPropertySet 'DisplayName', 'CredentialType', 'CredentialName', 'EndDateTime', 'DaysUntilExpiry' `
    -Force

Update-TypeData -TypeName 'MsecEntraLicense' `
    -DefaultDisplayPropertySet 'SkuPartNumber', 'Enabled', 'Assigned', 'CapabilityStatus' `
    -Force

# The holder leads, because that is who an access review is about; the assignee
# trails, so a role inherited through a group shows the group it came from.
Update-TypeData -TypeName 'MsecEntraRoleHolder' `
    -DefaultDisplayPropertySet 'EffectiveName', 'EffectiveType', 'RoleName', 'AssignmentType', 'PrincipalName', 'PrincipalType' `
    -Force

# Two views for one row shape. Direction is deliberately out of both: it repeats
# what the caller already asked for, and only matters when rows from both
# directions are mixed. Convert-MsecEntraSid -Resolve pushes the ...Resolved type
# name in front so the resolved columns show up without a Format-Table; the plain
# name stays on the row either way, so a type check matches both.
Update-TypeData -TypeName 'MsecEntraSid' `
    -DefaultDisplayPropertySet 'Sid', 'ObjectId' `
    -Force

Update-TypeData -TypeName 'MsecEntraSidResolved' `
    -DefaultDisplayPropertySet 'Sid', 'ObjectId', 'DisplayName', 'ObjectType' `
    -Force

# NB: Msec.format.ps1xml defines the TABLE view for this type, and wins for Format-Table.
# This set still governs Format-List and Select-Object, keeping Raw and AssignmentDetail
# out of a list view - so both are needed, and both list the same columns on purpose.
#
# Output last: a script result can be long or multi-line, so it truncates gracefully at
# the end of the row instead of pushing the identifying columns off the terminal.
Update-TypeData -TypeName 'MsecIntuneScriptResult' `
    -DefaultDisplayPropertySet 'ScriptName', 'Source', 'DeviceName', 'State', 'Output' `
    -Force

# AssignmentType + AssignmentGroup rather than AssignmentCount: the count cannot tell 'All
# Users plus an exclusion group' from 'two unrelated groups', and which of those it is
# decides whether a row needs looking at. ExclusionGroup shows up in AssignmentType, so a
# carve-out is still visible here; AssignmentExcludedGroup names it. The count stays on the
# object, just out of the default view.
Update-TypeData -TypeName 'MsecIntuneConfigurationProfile' `
    -DefaultDisplayPropertySet 'DisplayName', 'Source', 'Platform', 'AssignmentType', 'AssignmentGroup', 'Status' `
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
        $module = Get-Module Msec
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
