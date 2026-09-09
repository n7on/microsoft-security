function Get-MsecAzureRoleAssignment {
    <#
    .SYNOPSIS
        Azure RBAC role assignments across every accessible subscription, with role and
        principal names resolved - who has what, where.

    .DESCRIPTION
        Combines three sources, and keeping them apart is the point:

          assignments  Resource Graph, through your Az context. One query for the whole
                       estate rather than a Set-AzContext loop that mutates the caller's
                       context - 2415 assignments in one request on a real tenant, against
                       400 from Get-AzRoleAssignment in one subscription.
          role names   ARM REST, also your Az context. No Graph involved.
          principals   Microsoft Graph, through the msec app session.

        THIS IS WHY THE TWO IDENTITIES STAY SEPARATE. Get-AzRoleAssignment resolves principal
        names by calling Graph ITSELF, using whatever identity holds the Az context. That works
        for a person - who has directory read by default - and silently returns blank names for
        a service principal without Graph permissions. So a pipeline that ran the same code as
        a human would quietly produce a report full of GUIDs. Splitting the lookups means the
        ARM identity needs no directory access at all, and the answer is the same in a pipeline
        as it is on a laptop.

        PRINCIPALS ARE RESOLVED IN BULK, up to 1000 ids per call, through
        /directoryObjects/getByIds. The obvious implementation is one Graph call per assignment,
        which on this tenant would be 2415 round trips.

        A PRINCIPAL GRAPH CANNOT NAME IS STILL AN ASSIGNMENT. Deleted users and service
        principals leave their role assignments behind - that is the finding, not an error - so
        those rows come back with IsResolved = $false and the raw id rather than being dropped.

    .PARAMETER Subscription
        Limit to these subscriptions, by name or id. Omit for everything the Az context sees.

    .PARAMETER ScopeLevel
        Limit to assignments made at these scopes - ManagementGroup, Subscription,
        ResourceGroup, Resource. A Contributor at subscription scope is a very different
        finding from one on a single storage account.

    .PARAMETER PrincipalType
        Limit to User, Group or ServicePrincipal.

    .EXAMPLE
        Connect-AzAccount
        Connect-Msec -KeyVaultName kv-msec -TenantId <guid> -ClientId <guid>
        Get-MsecAzureRoleAssignment | Format-Table PrincipalName, RoleName, ScopeLevel, ScopeName

    .EXAMPLE
        # The findings worth chasing: broad rights held high up.
        Get-MsecAzureRoleAssignment -ScopeLevel Subscription, ManagementGroup |
            Where-Object RoleName -in 'Owner', 'Contributor', 'User Access Administrator' |
            Sort-Object RoleName, PrincipalName

    .EXAMPLE
        # Assignments left behind by principals that no longer exist.
        Get-MsecAzureRoleAssignment | Where-Object { -not $_.IsResolved }

    .OUTPUTS
        PSCustomObject per assignment, PSTypeName 'MsecAzureRoleAssignment'.

    .NOTES
        Needs BOTH an Az context (Reader on the subscriptions) and an msec session
        (Directory.Read.All, or User/Group/Application.Read.All) - they do different halves of
        the job. Without the msec session the assignments still come back, with names
        unresolved and a warning.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Alias('SubscriptionId')]
        [string[]] $Subscription,

        [ValidateSet('ManagementGroup', 'Subscription', 'ResourceGroup', 'Resource', 'Root')]
        [string[]] $ScopeLevel,

        [ValidateSet('User', 'Group', 'ServicePrincipal')]
        [string[]] $PrincipalType
    )

    $query = @{ ResourceType = 'Authorization'; Name = 'RoleAssignments' }
    if ($Subscription) { $query['Subscription'] = $Subscription }

    $assignments = @(Search-MsecAzureResourceGraph @query)
    if (-not $assignments.Count) { return }

    if ($ScopeLevel)    { $assignments = @($assignments | Where-Object { $_.ScopeLevel -in $ScopeLevel }) }
    if ($PrincipalType) { $assignments = @($assignments | Where-Object { $_.PrincipalType -in $PrincipalType }) }
    if (-not $assignments.Count) { return }

    # ---- role names, via ARM ------------------------------------------------------------------
    #
    # Cached per role: an estate has thousands of assignments and a few dozen distinct roles.
    # Through ARM REST rather than Get-AzRoleDefinition, which lives in Az.Resources - NOT one
    # of this module's dependencies. Using it would work on a developer's machine, where
    # Az.Resources is usually loaded, and fail on a clean agent that installed only msec and
    # what msec declares. Invoke-AzRestMethod is in Az.Accounts, which is a dependency.
    #
    # Tenant scope, so a role defined anywhere resolves without knowing which subscription to
    # ask - built-in roles are tenant-wide and custom ones are still readable from here.
    $roleName = @{}
    foreach ($guid in @($assignments.RoleDefinitionGuid | Sort-Object -Unique)) {
        if (-not $guid) { continue }
        try {
            $response = Invoke-AzRestMethod -Method GET `
                -Path "/providers/Microsoft.Authorization/roleDefinitions/$guid`?api-version=2022-04-01" `
                -ErrorAction Stop
            if ($response.StatusCode -eq 200) {
                $roleName[$guid] = ($response.Content | ConvertFrom-Json).properties.roleName
            }
            else {
                Write-Verbose "Role definition $guid returned HTTP $($response.StatusCode); the row will carry the id."
            }
        }
        catch {
            Write-Verbose "Could not resolve role definition $guid : $($_.Exception.Message)"
        }
    }

    # ---- principals, via Graph ----------------------------------------------------------------
    $principal = @{}
    $canResolve = $null -ne $script:MsecSession

    if (-not $canResolve) {
        # Loud, because a report full of GUIDs looks like a data problem rather than a missing
        # connection - and that is exactly how Get-AzRoleAssignment fails in a pipeline.
        Write-Warning 'No msec session, so principal names cannot be resolved - every row will carry an id and IsResolved = $false. Run Connect-Msec as well as Connect-AzAccount.'
    }
    else {
        $ids = @($assignments.PrincipalId | Where-Object { $_ } | Sort-Object -Unique)

        # getByIds takes up to 1000 per call. One call per assignment would be 2415 round trips
        # on a tenant this size.
        for ($i = 0; $i -lt $ids.Count; $i += 1000) {
            $batch = @($ids[$i..([Math]::Min($i + 999, $ids.Count - 1))])
            try {
                $response = Invoke-MsecGraphRequest -Method POST -Path '/v1.0/directoryObjects/getByIds' `
                                -Body @{ ids = $batch }
                foreach ($object in @($response.value)) {
                    $principal[[string] $object.id] = $object
                }
            }
            catch {
                Write-Warning "Could not resolve a batch of $($batch.Count) principal(s); those rows will carry ids rather than names: $($_.Exception.Message)"
            }
        }
    }

    foreach ($assignment in $assignments) {
        $object = $principal[[string] $assignment.PrincipalId]

        [PSCustomObject]@{
            PSTypeName        = 'MsecAzureRoleAssignment'
            PrincipalName     = $(if ($object) { $object.displayName } else { $null })
            PrincipalUserPrincipalName = $(if ($object) { $object.userPrincipalName } else { $null })
            PrincipalType     = $assignment.PrincipalType
            RoleName          = $(if ($roleName.ContainsKey([string] $assignment.RoleDefinitionGuid)) { $roleName[[string] $assignment.RoleDefinitionGuid] } else { $null })
            ScopeLevel        = $assignment.ScopeLevel
            ScopeName         = $assignment.ScopeName
            Scope             = $assignment.Scope
            SubscriptionName  = $assignment.SubscriptionName
            # False for a principal Graph could not name - a deleted user or service principal
            # whose assignment outlived it. That is the finding, not an error.
            IsResolved        = [bool] $object
            PrincipalId       = $assignment.PrincipalId
            RoleDefinitionGuid = $assignment.RoleDefinitionGuid
            CreatedOn         = $assignment.CreatedOn
            SubscriptionId    = $assignment.SubscriptionId
            Id                = $assignment.Id
        }
    }
}
