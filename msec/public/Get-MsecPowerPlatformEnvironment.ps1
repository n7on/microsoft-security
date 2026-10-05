function Get-MsecPowerPlatformEnvironment {
    <#
    .SYNOPSIS
        Power Platform environments and whether a connector DLP policy actually covers each
        one - the control that decides what a Power Automate flow is allowed to connect to.

    .DESCRIPTION
        A Power Automate flow runs as the person who built it, needs no approval, and can move
        data between any two connectors it is permitted to use. The only thing constraining
        that is a connector DLP policy, and a policy constrains an environment only if it is
        scoped to include it.

        AN ENVIRONMENT WITH NO DLP POLICY HAS NO CONNECTOR RESTRICTIONS AT ALL. Not weak ones -
        none. SharePoint to a personal Gmail is an ordinary afternoon's work for a maker in an
        uncovered environment, and nothing in Secure Score, DLP for Microsoft 365, or a
        Conditional Access review mentions it.

        RUNS AS THE SIGNED-IN USER, NOT AS THE msec APP. The Power Platform admin APIs return
        403 to the app certificate: app-only access requires the application to be registered
        as a Power Platform MANAGEMENT APPLICATION, which grants administrative - not read-only
        - access to the whole Power Platform estate. Taking that route would break the promise
        that the certificate in Key Vault cannot change the tenant, so this command follows the
        same pattern as Search-MsecAzureResourceGraph and runs on your Az context instead. One
        command, one identity.

        DLP SCOPE IS A FILTER TYPE, NOT A LIST. A policy carries environmentFilterType of
        'none' (every environment), 'include' (only the listed ones) or 'exclude' (all but the
        listed ones). Reading only the environment list would report a tenant-wide policy as
        covering nothing, which is the most dangerous possible way to be wrong here.

        UNREADABLE IS NOT UNCOVERED. If the policy list cannot be read, IsCoveredByDlp is
        $null on every row rather than $false - an environment nobody could check must not
        render as one that is definitely unprotected.

    .PARAMETER UncoveredOnly
        Only environments no DLP policy applies to.

    .EXAMPLE
        Get-MsecPowerPlatformEnvironment

        Every environment, with the policies covering it.

    .EXAMPLE
        Get-MsecPowerPlatformEnvironment -UncoveredOnly

        The environments where a maker may connect anything to anything.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [switch] $UncoveredOnly
    )

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'No Azure context. Run Connect-AzAccount first - this command runs as you, not as the msec app.'
    }

    # Get-AzAccessToken returns SecureString on Az.Accounts 5.x+ and a plain string before
    # that; both are handled, same as Get-MsecAzureSecureScore.
    $resource = 'https://api.bap.microsoft.com'
    $tokenResp = Get-AzAccessToken -ResourceUrl $resource -ErrorAction Stop
    $token = if ($tokenResp.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tokenResp.Token).Password
    }
    else { [string] $tokenResp.Token }
    $headers = @{ Authorization = "Bearer $token" }

    $environments = $null
    try {
        $environments = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Uri `
            "$resource/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=2020-10-01").value)
    }
    catch {
        $status = if ($_.Exception.Response) { [int] $_.Exception.Response.StatusCode } else { $null }
        if ($status -eq 403) {
            throw 'Power Platform returned 403. This command runs as the signed-in user and needs the Power Platform Administrator, Dynamics 365 Administrator or Global Administrator role.'
        }
        throw "Could not list Power Platform environments: $($_.Exception.Message)"
    }

    $policies = $null
    try {
        $policies = @((Invoke-RestMethod -Headers $headers -ErrorAction Stop -Uri `
            "$resource/providers/PowerPlatform.Governance/v2/policies?api-version=2020-10-01").value)
    }
    catch {
        Write-Warning "Could not read connector DLP policies, so IsCoveredByDlp is null rather than false on every environment - this is NOT the same as finding none. Power Platform said: $($_.Exception.Message)"
    }

    foreach ($environment in $environments) {
        $p = $environment.properties
        $name = [string] $environment.name

        $covering = $null
        if ($null -ne $policies) {
            $covering = @(foreach ($policy in $policies) {
                $filter = [string] $policy.environments.environmentFilterType
                $listed = @($policy.environments.environments | ForEach-Object { [string] $_.name })
                $applies = switch ($filter) {
                    'none'    { $true }                        # every environment in the tenant
                    'include' { $name -in $listed }
                    'exclude' { $name -notin $listed }
                    # An unrecognised filter type is not assumed harmless.
                    default   { $null }
                }
                if ($applies) { [string] $policy.displayName }
            })
        }

        $isCovered = if ($null -eq $policies) { $null } else { [bool] @($covering).Count }
        if ($UncoveredOnly -and $isCovered -ne $false) { continue }

        [PSCustomObject]@{
            PSTypeName      = 'MsecPowerPlatformEnvironment'
            DisplayName     = [string] $p.displayName
            EnvironmentName = $name
            Type            = [string] $p.environmentSku
            IsDefault       = [bool] $p.isDefault
            Region          = [string] $environment.location
            # A Dataverse database is where Power Platform keeps structured business data, so
            # an uncovered environment holding one is a different size of problem to one without.
            HasDataverse    = [bool] $p.linkedEnvironmentMetadata
            IsCoveredByDlp  = $isCovered
            DlpPolicyCount  = if ($null -eq $covering) { $null } else { @($covering).Count }
            DlpPolicies     = if ($null -eq $covering) { $null } else { (@($covering) -join '; ') }
            CreatedBy       = [string] $p.createdBy.displayName
            CreatedTime     = $p.createdTime
        }
    }
}
