function Get-MsecPrivilegedRoleTemplate {
    <#
    .SYNOPSIS
        The set of Entra directory roles msec treats as highly privileged, keyed by
        stable roleTemplateId.

    .DESCRIPTION
        Returns a hashtable of roleTemplateId -> canonical role name. The single
        definition of what msec means by "privileged", used by
        Get-MsecEntraRoleHolder's IsHighlyPrivileged flag and -HighlyPrivilegedOnly
        filter, and through it by every count in
        Get-MsecEntraTenantSecuritySetting - a second definition anywhere would
        make one report silently contradict another on the same tenant.

        Keyed by roleTemplateId rather than displayName because display names are
        localisable and, for some roles, editable: a tenant that renamed Global
        Administrator would otherwise drop out of every privileged-access report.
        Template ids are stable GUIDs, identical in every tenant and every cloud.

        The criterion for inclusion is escalation potential - the role can grant
        itself or others further access, reset another principal's credentials, or
        read/exfiltrate broadly. Read-only roles (Global Reader, Reports Reader,
        Security Reader) are deliberately absent.

        This is a curated list, not Microsoft's own "privileged" label. Microsoft
        flags a similar-but-not-identical set via isPrivileged on roleDefinitions;
        that flag is only on beta for some clouds, so it isn't relied on here.
    #>
    [CmdletBinding()]
    param()

    return @{
        '62e90394-69f5-4237-9190-012177145e10' = 'Global Administrator'
        'e8611ab8-c189-46e8-94e1-60213ab1f814' = 'Privileged Role Administrator'
        '7be44c8a-adaf-4e2a-84d6-ab2649e08a13' = 'Privileged Authentication Administrator'
        '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' = 'Application Administrator'
        '158c047a-c907-4556-b7ef-446551a6b5f7' = 'Cloud Application Administrator'
        'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9' = 'Conditional Access Administrator'
        '194ae4cb-b126-40b2-bd5b-6091b380977d' = 'Security Administrator'
        'fe930be7-5e62-47db-91af-98c3a49a38b1' = 'User Administrator'
        '29232cdf-9323-42fd-ade2-1d097af3e4de' = 'Exchange Administrator'
        '3a2c62db-5318-420d-8d74-23affee5d9d5' = 'Intune Administrator'
        'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' = 'SharePoint Administrator'
        '8ac3fc64-6eca-42ea-9e69-59f4c7b60eb2' = 'Hybrid Identity Administrator'
        '8329153b-31d0-4727-b945-745eb3bc5f31' = 'Domain Name Administrator'
        'e00e864a-17c5-4a4b-9c06-f5b95a8d5bd8' = 'Partner Tier2 Support'
    }
}
