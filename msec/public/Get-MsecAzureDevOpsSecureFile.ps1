function Get-MsecAzureDevOpsSecureFile {
    <#
    .SYNOPSIS
        Secure files stored in an Azure DevOps organization - certificates, keystores and signing
        material - and which pipelines may use them.

    .DESCRIPTION
        A secure file is a file a pipeline needs but nobody wants in source control: a signing
        certificate, a keystore, a provisioning profile, a private key. Azure DevOps stores it
        encrypted and hands it to authorised pipelines at run time.

        THE CONTENTS ARE NEVER FETCHED. There is a download endpoint and this command does not
        call it - the point is an inventory of what exists and who can reach it, and a report
        that downloads private keys to produce that inventory would be worse than no report.

        THE FILE NAME IS THE ONLY CLUE TO WHAT IT HOLDS, so Kind is derived from the extension
        and is a guess, clearly labelled as one. A .pfx is a certificate and probably carries a
        private key; a .key could be anything. The name is always returned so the guess can be
        checked.

        AGE MATTERS MORE HERE THAN ELSEWHERE. Signing certificates expire, and a secure file
        uploaded four years ago that no pipeline has been authorised against since is either
        expired or forgotten. Neither is visible from the file itself.

    .PARAMETER Organization
        Azure DevOps organization name: the path segment after dev.azure.com/.

    .PARAMETER Project
        Restrict to one project. All projects by default.

    .EXAMPLE
        Connect-Msec -KeyVaultName kv-msec
        Get-MsecAzureDevOpsSecureFile -Organization 'contoso'

    .EXAMPLE
        # Certificates and keystores any pipeline could use.
        Get-MsecAzureDevOpsSecureFile -Organization 'contoso' |
            Where-Object { $_.Kind -eq 'Certificate' -and $_.OpenToAllPipelines }

    .OUTPUTS
        PSCustomObject per secure file, PSTypeName 'MsecAzureDevOpsSecureFile'.

    .NOTES
        Needs Connect-Msec and organization membership. One call per project, plus one per file
        for the pipeline authorization.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Organization,

        [string] $Project
    )

    Assert-MsecSession

    $projects = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                      -HostName 'dev.azure.com' -ApiVersion '7.1' -Path '_apis/projects' -All)
    if ($Project) {
        $projects = @($projects | Where-Object { $_.name -eq $Project })
        if (-not $projects.Count) { throw "No project named '$Project' in '$Organization'." }
    }
    if (-not $projects.Count) {
        Write-Warning "No projects returned for '$Organization'. That is 'nothing was read', not 'no projects'."
        return
    }

    $unreadable = [System.Collections.Generic.List[string]]::new()

    foreach ($proj in $projects) {
        $files = @()
        try {
            $files = @(Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                           -HostName 'dev.azure.com' -ApiVersion '7.1-preview.1' `
                           -Path "$($proj.id)/_apis/distributedtask/securefiles")
        }
        catch {
            $unreadable.Add($proj.name)
            Write-Verbose "Could not read secure files in '$($proj.name)': $($_.Exception.Message)"
            continue
        }

        foreach ($file in $files) {
            # A GUESS from the extension, and labelled as one in the help. The name is returned
            # alongside so it can be checked rather than trusted.
            $kind = switch -Regex ([string] $file.name) {
                '\.(pfx|p12|cer|crt|pem)$'      { 'Certificate'; break }
                '\.(jks|keystore|bks)$'         { 'Keystore';    break }
                '\.(mobileprovision|provisionprofile)$' { 'ProvisioningProfile'; break }
                '\.(ppk|key|pk8)$'              { 'Key';         break }
                default                          { 'Other' }
            }

            $open = $null; $authorized = $null; $openedBy = $null; $openedOn = $null
            try {
                $perms = Invoke-MsecAzureDevOpsRequest -Organization $Organization `
                             -HostName 'dev.azure.com' -ApiVersion '7.1-preview.1' `
                             -Path "$($proj.id)/_apis/pipelines/pipelinePermissions/securefile/$($file.id)"
                $open       = [bool] $perms.allPipelines.authorized
                $authorized = @($perms.pipelines).Count
                $openedBy   = $perms.allPipelines.authorizedBy.displayName
                $openedOn   = $perms.allPipelines.authorizedOn
            }
            catch { Write-Verbose "Could not read pipeline permissions for '$($file.name)': $($_.Exception.Message)" }

            [PSCustomObject]@{
                PSTypeName   = 'MsecAzureDevOpsSecureFile'
                Organization = $Organization
                Project      = $proj.name
                Name         = $file.name
                Kind         = $kind
                # Signing material expires, and a file nothing has been authorised against for
                # years is either expired or forgotten.
                AgeDays      = if ($file.createdOn) { [int] ([datetime]::UtcNow - [datetime] $file.createdOn).TotalDays } else { $null }
                OpenToAllPipelines      = $open
                AuthorizedPipelineCount = $authorized
                OpenedBy                = $openedBy
                OpenedOn                = $openedOn
                CreatedBy    = $file.createdBy.displayName
                CreatedOn    = $file.createdOn
                ModifiedOn   = $file.modifiedOn
                Id           = $file.id
            }
        }
    }

    if ($unreadable.Count) {
        $shown = ($unreadable | Select-Object -First 5) -join ', '
        $more  = if ($unreadable.Count -gt 5) { " and $($unreadable.Count - 5) more" } else { '' }
        Write-Warning "$($unreadable.Count) project(s) refused their secure files: $shown$more. Those are NOT in this output - treat them as unread, not as projects storing none."
    }
}
