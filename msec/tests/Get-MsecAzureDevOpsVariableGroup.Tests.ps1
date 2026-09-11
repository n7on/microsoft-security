#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsVariableGroup.
#
# The shape below was captured from a live organization: a variables object whose properties each
# carry isSecret, a type of Vsts or AzureKeyVault, and pipeline permissions on a separate call
# whose allPipelines field is OMITTED when the setting is off.
#
# The thing to protect is that values never reach the output. Secret values are not returned by
# the API at all; non-secret values ARE, and are dropped deliberately, because this output ends
# up in mailboxes and spreadsheets and pipeline variables carry connection strings. Names are
# kept - knowing a group holds AZURE_CLIENT_SECRET is the point.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsVariableGroup' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }

            function script:New-Group {
                param(
                    [int] $Id = 1, [string] $Name = 'Group', [string] $Type = 'Vsts',
                    [hashtable] $Variables = @{}, [string] $Vault, [int] $SharedWith = 1
                )
                $vars = [pscustomobject]@{}
                foreach ($k in $Variables.Keys) {
                    $vars | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]@{
                        value = $Variables[$k].value; isSecret = [bool] $Variables[$k].isSecret })
                }
                [pscustomobject]@{
                    id = $Id; name = $Name; type = $Type; variables = $vars
                    providerData = if ($Vault) { [pscustomobject]@{ vault = $Vault } } else { $null }
                    isShared = ($SharedWith -gt 1)
                    variableGroupProjectReferences = @(1..$SharedWith)
                    modifiedBy = [pscustomobject]@{ displayName = 'Ada' }
                    createdBy  = [pscustomobject]@{ displayName = 'Ada' }
                }
            }

            function script:Set-LibMock {
                param($Groups, $OpenGroupIds = @(), [switch] $GroupsFail)
                $script:MockGroups = $Groups
                $script:MockOpen   = @($OpenGroupIds)
                $script:MockFail   = [bool] $GroupsFail
                Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                    if ($Path -eq '_apis/projects') { return @([pscustomobject]@{ id = 'p1'; name = 'Platform' }) }
                    if ($Path -match '/variablegroups$') {
                        if ($script:MockFail) { throw 'Response status code does not indicate success: 403 (Forbidden).' }
                        return $script:MockGroups
                    }
                    if ($Path -match '/pipelinePermissions/variablegroup/(\d+)$') {
                        if ($script:MockOpen -contains [int] $Matches[1]) {
                            return [pscustomobject]@{
                                allPipelines = [pscustomobject]@{
                                    authorized   = $true
                                    authorizedBy = [pscustomobject]@{ displayName = 'Ada Lovelace' }
                                    authorizedOn = [datetime]'2022-11-15T17:30:23Z'
                                }
                                pipelines = @(1)
                            }
                        }
                        # Omitted when off.
                        return [pscustomobject]@{ pipelines = @() }
                    }
                    return @()
                }
            }
        }
    }

    It 'never emits variable values, secret or not' {
        $rows = InModuleScope msec {
            . Set-LibMock -Groups @(New-Group -Name 'creds' -Variables @{
                AZURE_CLIENT_SECRET = @{ value = $null;               isSecret = $true }
                SQL_CONNECTION      = @{ value = 'Server=prod;Pwd=x'; isSecret = $false } })
            Get-MsecAzureDevOpsVariableGroup -Organization 'contoso'
        }

        # Non-secret values ARE returned by the API. They stay out of the report - a connection
        # string in a spreadsheet is the thing this module exists to find, not to create.
        ($rows | ConvertTo-Json -Depth 4) | Should -Not -Match 'Server=prod'
        # Names are the point.
        $rows.SecretNames   | Should -Be 'AZURE_CLIENT_SECRET'
        $rows.VariableNames | Should -Be 'AZURE_CLIENT_SECRET, SQL_CONNECTION'
        $rows.SecretCount   | Should -Be 1
        $rows.VariableCount | Should -Be 2
    }

    It 'flags a group any pipeline may use' {
        $rows = InModuleScope msec {
            . Set-LibMock -Groups @(
                (New-Group -Id 10 -Name 'open'   -Variables @{ S = @{ isSecret = $true } })
                (New-Group -Id 11 -Name 'closed' -Variables @{ S = @{ isSecret = $true } })
            ) -OpenGroupIds @(10)
            Get-MsecAzureDevOpsVariableGroup -Organization 'contoso'
        }

        # Secrets plus "any pipeline may reference this" is the combination worth finding: a
        # pipeline written this afternoon can read them.
        ($rows | Where-Object Name -eq 'open').OpenToAllPipelines   | Should -BeTrue
        ($rows | Where-Object Name -eq 'closed').OpenToAllPipelines | Should -BeFalse
    }

    It 'records who opened the group to all pipelines, and when' {
        $rows = InModuleScope msec {
            . Set-LibMock -Groups @(
                (New-Group -Id 10 -Name 'open'   -Variables @{ S = @{ isSecret = $true } })
                (New-Group -Id 11 -Name 'closed' -Variables @{ S = @{ isSecret = $true } })
            ) -OpenGroupIds @(10)
            Get-MsecAzureDevOpsVariableGroup -Organization 'contoso'
        }

        # The decision is usually old and the person who made it has often moved on. Measured
        # live: nine groups holding 5 to 21 production secrets, all opened by one person in 2022.
        # Neither the boolean nor the count says that.
        ($rows | Where-Object Name -eq 'open').OpenedBy | Should -Be 'Ada Lovelace'
        ($rows | Where-Object Name -eq 'open').OpenedOn | Should -Be ([datetime]'2022-11-15T17:30:23Z')
        # Nothing to record when it was never opened.
        ($rows | Where-Object Name -eq 'closed').OpenedBy | Should -BeNullOrEmpty
    }
    It 'names the vault for a Key Vault-backed group' {
        $rows = InModuleScope msec {
            . Set-LibMock -Groups @(New-Group -Name 'kv' -Type 'AzureKeyVault' -Vault 'prod-secrets')
            Get-MsecAzureDevOpsVariableGroup -Organization 'contoso'
        }

        # The secrets live in the vault, not here - which moves the question rather than removing
        # it, so the vault has to be named.
        $rows.Type     | Should -Be 'AzureKeyVault'
        $rows.KeyVault | Should -Be 'prod-secrets'
    }

    It 'treats a Key Vault group as holding secrets under -WithSecrets' {
        $rows = InModuleScope msec {
            . Set-LibMock -Groups @(
                (New-Group -Id 1 -Name 'plain' -Variables @{ A = @{ isSecret = $false } })
                (New-Group -Id 2 -Name 'kv' -Type 'AzureKeyVault' -Vault 'v'))
            Get-MsecAzureDevOpsVariableGroup -Organization 'contoso' -WithSecrets
        }

        # It declares no secret variables of its own, but everything it exposes is one.
        @($rows).Count | Should -Be 1
        $rows.Name     | Should -Be 'kv'
    }

    It 'reports a project whose library could not be read' {
        $warnings = @()
        $rows = InModuleScope msec {
            . Set-LibMock -Groups @() -GroupsFail
            Get-MsecAzureDevOpsVariableGroup -Organization 'contoso'
        } -WarningVariable warnings -WarningAction SilentlyContinue

        @($rows).Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'refused their variable groups'
        ($warnings -join ' ') | Should -Match 'unread'
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsVariableGroup -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
