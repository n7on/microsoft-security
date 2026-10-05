function Get-MsecEntraPimPolicy {
    <#
    .SYNOPSIS
        The Privileged Identity Management rules for each directory role - what activation
        demands, and whether a permanent assignment is allowed at all - as one row per setting.

    .DESCRIPTION
        Get-MsecEntraRoleHolder says WHO holds a role and whether it is active or eligible.
        This says what the eligibility is actually worth: a role that can be activated for
        eight hours with no MFA, no approval and no ticket is barely different from a permanent
        assignment, and nothing in the holder list shows that.

        TWO SETS OF RULES, AND THEY ANSWER DIFFERENT QUESTIONS.
          Activation (EndUser) - what an eligible person must do to switch the role on: MFA,
                                 justification, a ticket, an approver, an authentication
                                 context, and for how long it stays on.
          Assignment (Admin)   - what an administrator may hand out in the first place. This is
                                 where PermanentActiveAllowed lives, and it is the setting that
                                 decides whether standing privilege is even possible.

        'ActivationRequiresMfa = False' DOES NOT MEAN ACTIVATION HAPPENS WITHOUT MFA. The
        person may already be covered by a Conditional Access policy that required MFA at
        sign-in. What this setting controls is whether PIM demands a FRESH authentication at
        the moment of activation - the thing that stops a stolen, already-authenticated session
        from quietly switching a role on. Read it as "no re-authentication", not "no MFA".

        A POLICY ON A ROLE NOBODY IS ELIGIBLE FOR GOVERNS NOTHING. There are around 150
        directory roles and a typical tenant has eligible holders for a handful, so
        HasEligibleHolder is on every row and -HighlyPrivilegedOnly narrows further. Rows are
        still returned for roles with no holders: a policy may be deliberately pre-configured
        ahead of an assignment, and hiding it would make that invisible.

        HIGHLY PRIVILEGED USES THE SAME LIST AS EVERY OTHER msec COMMAND, from
        Get-MsecPrivilegedRoleTemplate, so this report cannot silently disagree with
        Get-MsecEntraRoleHolder about which roles matter.

    .PARAMETER Role
        Role display names or roleTemplateIds. Omit for every role.

    .PARAMETER HighlyPrivilegedOnly
        Only the roles msec treats as highly privileged.

    .PARAMETER All
        One row per underlying PIM rule rather than the curated projection.

    .EXAMPLE
        Get-MsecEntraPimPolicy -HighlyPrivilegedOnly |
            Where-Object { $_.Setting -eq 'ActivationRequiresMfa' -and $_.Value -eq 'False' }

        Privileged roles that can be activated without re-authenticating.

    .EXAMPLE
        Get-MsecEntraPimPolicy |
            Where-Object { $_.Setting -eq 'PermanentActiveAllowed' -and $_.Value -eq 'True' -and $_.HasEligibleHolder }

        Roles where standing privilege is still permitted.

    .EXAMPLE
        Get-MsecEntraPimPolicy -Role 'Global Administrator'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [string[]] $Role,

        [switch] $HighlyPrivilegedOnly,

        [switch] $All
    )

    if (-not $script:MsecSession) { throw 'No msec session. Run Connect-Msec first.' }

    $privileged = Get-MsecPrivilegedRoleTemplate

    Write-Verbose 'Reading directory role definitions'
    $definitions = @{}
    try {
        foreach ($d in @(Invoke-MsecGraphRequest -All -Path '/v1.0/roleManagement/directory/roleDefinitions?$select=id,displayName,templateId')) {
            $definitions[[string] $d.id] = $d
        }
    }
    catch {
        throw "Could not read directory role definitions, so no policy could be named: $(Get-MsecGraphErrorMessage $_)"
    }

    # One call, so a policy that governs nobody can be told from one that governs a real
    # eligible holder. Unreadable leaves the flag null rather than claiming nobody is eligible.
    $eligibleRoles = $null
    try {
        $eligibleRoles = @{}
        foreach ($e in @(Invoke-MsecGraphRequest -All -Path '/v1.0/roleManagement/directory/roleEligibilityScheduleInstances?$select=roleDefinitionId&$top=999')) {
            $eligibleRoles[[string] $e.roleDefinitionId] = $true
        }
    }
    catch {
        $eligibleRoles = $null
        Write-Warning "Could not read role eligibility schedules, so HasEligibleHolder is null rather than false on every row: $(Get-MsecGraphErrorMessage $_)"
    }

    Write-Verbose 'Reading role management policies'
    $assignments = $null
    try {
        $assignments = @(Invoke-MsecGraphRequest -All -Path (
            "/v1.0/policies/roleManagementPolicyAssignments?`$filter=scopeId eq '/' and scopeType eq 'DirectoryRole'&`$expand=policy(`$expand=rules)"))
    }
    catch {
        throw "Could not read PIM role management policies. The app needs RoleManagementPolicy.Read.Directory or RoleManagement.Read.Directory: $(Get-MsecGraphErrorMessage $_)"
    }

    foreach ($assignment in $assignments) {
        $definitionId = [string] $assignment.roleDefinitionId
        $definition   = $definitions[$definitionId]
        $roleName     = if ($definition) { [string] $definition.displayName } else { $definitionId }
        $templateId   = if ($definition -and $definition.templateId) { [string] $definition.templateId } else { $definitionId }

        $isPrivileged = $privileged.ContainsKey($templateId)
        if ($HighlyPrivilegedOnly -and -not $isPrivileged) { continue }
        if ($Role -and -not (@($Role) | Where-Object { $_ -eq $roleName -or $_ -eq $templateId })) { continue }

        $rules = @{}
        foreach ($rule in @($assignment.policy.rules)) { $rules[[string] $rule.id] = $rule }

        $hasEligible = if ($null -eq $eligibleRoles) { $null } else { $eligibleRoles.ContainsKey($definitionId) }

        $emit = {
            param($Setting, $Value)
            [PSCustomObject]@{
                PSTypeName         = 'MsecEntraPimPolicy'
                RoleName           = $roleName
                RoleTemplateId     = $templateId
                IsHighlyPrivileged = $isPrivileged
                HasEligibleHolder  = $hasEligible
                Setting            = $Setting
                Value              = if ($null -eq $Value) { $null } else { [string] $Value }
            }
        }

        if ($All) {
            foreach ($id in ($rules.Keys | Sort-Object)) {
                $rule = $rules[$id]
                & $emit $id (($rule | ConvertTo-Json -Depth 6 -Compress))
            }
            continue
        }

        # enabledRules is the list of things PIM demands. An absent entry is a demand not made.
        $enabledOf = {
            param($RuleId)
            $rule = $rules[$RuleId]
            if (-not $rule) { return $null }
            ,@(@($rule.enabledRules) | ForEach-Object { [string] $_ })
        }

        $activation = & $enabledOf 'Enablement_EndUser_Assignment'
        $adminAssign = & $enabledOf 'Enablement_Admin_Assignment'

        $expEndUser    = $rules['Expiration_EndUser_Assignment']
        $expEligible   = $rules['Expiration_Admin_Eligibility']
        $expActive     = $rules['Expiration_Admin_Assignment']
        $approval      = $rules['Approval_EndUser_Assignment']
        $authContext   = $rules['AuthenticationContext_EndUser_Assignment']
        $notifyAdmin   = $rules['Notification_Admin_EndUser_Assignment']

        # --- what activation demands ---
        & $emit 'ActivationMaxDuration'            $(if ($expEndUser) { $expEndUser.maximumDuration })
        & $emit 'ActivationRequiresMfa'            $(if ($null -eq $activation) { $null } else { $activation -contains 'MultiFactorAuthentication' })
        & $emit 'ActivationRequiresJustification'  $(if ($null -eq $activation) { $null } else { $activation -contains 'Justification' })
        & $emit 'ActivationRequiresTicket'         $(if ($null -eq $activation) { $null } else { $activation -contains 'Ticketing' })
        & $emit 'ActivationRequiresApproval'       $(if ($approval) { [bool] $approval.setting.isApprovalRequired })

        $approvers = @()
        foreach ($stage in @($approval.setting.approvalStages)) {
            foreach ($a in @($stage.primaryApprovers)) {
                $name = if ($a.displayName) { [string] $a.displayName } else { [string] $a.id }
                if ($name) { $approvers += $name }
            }
        }
        & $emit 'ActivationApprovers'              $(if ($approvers.Count) { $approvers -join '; ' } else { $null })

        # A step-up Conditional Access context at activation - stronger than the MFA flag,
        # because it can demand a phishing-resistant method specifically.
        & $emit 'ActivationAuthenticationContext'  $(if ($authContext) {
            if ($authContext.isEnabled) { if ($authContext.claimValue) { [string] $authContext.claimValue } else { 'True' } } else { 'False' }
        })

        & $emit 'ActivationNotifiesAdmins'         $(if ($notifyAdmin) { [bool] $notifyAdmin.isDefaultRecipientsEnabled -or @($notifyAdmin.notificationRecipients).Count -gt 0 })

        # --- what an administrator may hand out ---
        # isExpirationRequired FALSE means a non-expiring assignment is permitted, so the
        # flag is inverted here to read the way the question is actually asked.
        & $emit 'PermanentEligibleAllowed'         $(if ($expEligible) { -not [bool] $expEligible.isExpirationRequired })
        & $emit 'MaxEligibleDuration'              $(if ($expEligible) { $expEligible.maximumDuration })
        & $emit 'PermanentActiveAllowed'           $(if ($expActive)   { -not [bool] $expActive.isExpirationRequired })
        & $emit 'MaxActiveDuration'                $(if ($expActive)   { $expActive.maximumDuration })
        & $emit 'ActiveAssignmentRequiresMfa'      $(if ($null -eq $adminAssign) { $null } else { $adminAssign -contains 'MultiFactorAuthentication' })
        & $emit 'ActiveAssignmentRequiresJustification' $(if ($null -eq $adminAssign) { $null } else { $adminAssign -contains 'Justification' })
    }
}
