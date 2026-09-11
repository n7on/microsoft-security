function Get-MsecAzureDevOpsExtension {
    <#
    .SYNOPSIS
        Marketplace extensions installed in an Azure DevOps organization, with the access each
        one holds - one row per extension.

    .DESCRIPTION
        An extension is third-party code running inside your organization with delegated access
        to it. The scopes it was granted at install time are permanent until someone uninstalls
        it, they apply organization-wide, and nothing prompts anyone to review them again.

        A publisher with `vso.serviceendpoint_manage` can read and rewrite service connections;
        one with `vso.code_manage` can rewrite repositories. Those are not hypothetical
        permissions - they are what the extension already has.

        ACCESS IS DERIVED FROM THE SCOPE SUFFIXES, and that derivation is this command's
        judgement rather than something the API states:

            Manage   any *_manage scope - full control of that resource type
            Write    any *_write or *_execute scope - can change things or run code
            Read     read-only scopes
            None     no scopes declared

        The raw Scopes are always returned alongside it, because the grouping is a convenience
        and the scope list is the fact.

        MICROSOFT-PUBLISHED IS NOT THE SAME AS SAFE, but it is the line most reviews draw first,
        so IsMicrosoftPublisher is a column rather than a filter. Judging the publisher is the
        reader's job.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/.

    .PARAMETER ThirdPartyOnly
        Exclude extensions published by Microsoft. On a real organization 43 of 50 were
        Microsoft-published, and the remainder is where a review usually starts.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsExtension -Organization 'contoso' |
            Sort-Object Access, Publisher | Format-Table Publisher, ExtensionName, Access, Scopes

    .EXAMPLE
        # Third-party code that can rewrite service connections or repositories.
        Get-MsecAzureDevOpsExtension -Organization 'contoso' -ThirdPartyOnly |
            Where-Object { $_.Access -in 'Manage', 'Write' }

    .OUTPUTS
        PSCustomObject per extension, PSTypeName 'MsecAzureDevOpsExtension'.

    .NOTES
        Needs Connect-Msec and organization membership. No extra permission: the extension
        management API is readable by any member, unlike repositories and service connections.

        Extensions are installed per ORGANIZATION, so there is no project dimension here.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization,

        [switch] $ThirdPartyOnly
    )

    Assert-MsecSession

    # Extension management lives on its own host, not dev.azure.com.
    $extensions = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                        -HostName 'extmgmt.dev.azure.com' -ApiVersion '7.1-preview.1' `
                        -Path '_apis/extensionmanagement/installedextensions')

    if (-not $extensions.Count) {
        Write-Warning "No extensions returned for '$Organization'. That is 'nothing was read', not 'none installed' - every organization has at least the built-in ones."
        return
    }

    foreach ($extension in $extensions) {
        $scopes = @($extension.scopes)

        $access =
            if     (-not $scopes.Count)                       { 'None' }
            elseif ($scopes -match '_manage$')                { 'Manage' }
            elseif ($scopes -match '_(write|execute)$')       { 'Write' }
            else                                              { 'Read' }

        # installState.flags is a comma-separated string: 'none', 'disabled', 'trusted'.
        $flags = [string] $extension.installState.flags

        $row = [PSCustomObject]@{
            PSTypeName           = 'MsecAzureDevOpsExtension'
            Organization         = $Organization
            Publisher            = $extension.publisherName
            ExtensionName        = $extension.extensionName
            # Derived, not stated by the API - see the help.
            Access               = $access
            Scopes               = ($scopes | Sort-Object) -join ', '
            # Microsoft Devlabs is Microsoft-published but explicitly experimental, so it is
            # counted as Microsoft here and left visible in Publisher for the reader to weigh.
            IsMicrosoftPublisher = [bool] ($extension.publisherId -eq 'ms' -or $extension.publisherName -match '^Microsoft')
            # A disabled extension keeps its grants and can be re-enabled without re-consent.
            IsDisabled           = $flags -match 'disabled'
            Version              = $extension.version
            LastPublished        = $extension.lastPublished
            PublisherId          = $extension.publisherId
            ExtensionId          = $extension.extensionId
            InstallFlags         = $flags
        }

        if ($ThirdPartyOnly -and $row.IsMicrosoftPublisher) { continue }
        $row
    }
}
