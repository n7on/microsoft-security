#Requires -Module Pester
#
# Tests for Get-MsecAzureDevOpsEnvironment.
#
# The distinction to protect is 0 versus $null. An environment with no checks configured returns
# an empty list; an environment whose checks could not be read returns nothing either. Collapsing
# those would report a deployment target nobody LOOKED at as one nobody guards - and -Unchecked
# would then hand back a list padded with environments that might be perfectly protected.
#
# Measured on a live organization: 71 environments, 50 with no checks, and three of those open to
# every pipeline in their project - one of them named CN-PROD.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecAzureDevOpsEnvironment' {

    BeforeEach {
        InModuleScope msec {
            $script:MsecSession = @{ TenantId = 't'; ClientId = 'c'; Tokens = @{} }

            function script:Set-EnvMock {
                param($Environments, $Checks = @{}, $Open = @(), [switch] $ChecksFail)
                $script:MockEnvs   = $Environments
                $script:MockChecks = $Checks
                $script:MockOpen   = @($Open)
                $script:MockChecksFail = [bool] $ChecksFail
                Mock Invoke-MsecAzureDevOpsRequest -MockWith {
                    if ($Path -eq '_apis/projects') { return @([pscustomobject]@{ id = 'p1'; name = 'Viedoc4' }) }
                    if ($Path -match '/distributedtask/environments$') { return $script:MockEnvs }
                    if ($Path -match 'resourceId=(\d+)') {
                        if ($script:MockChecksFail) { throw 'Response status code does not indicate success: 403 (Forbidden).' }
                        $id = [int] $Matches[1]
                        return @($script:MockChecks[$id])
                    }
                    if ($Path -match '/pipelinePermissions/environment/(\d+)$') {
                        if ($script:MockOpen -contains [int] $Matches[1]) {
                            return [pscustomobject]@{
                                allPipelines = [pscustomobject]@{ authorized = $true; authorizedBy = [pscustomobject]@{ displayName = 'Ada' } }
                                pipelines = @() }
                        }
                        return [pscustomobject]@{ pipelines = @() }
                    }
                    return @()
                }
            }
            function script:New-Env { param([int] $Id, [string] $Name)
                [pscustomobject]@{ id = $Id; name = $Name
                                   createdBy = [pscustomobject]@{ displayName = 'Ada' }
                                   lastModifiedBy = [pscustomobject]@{ displayName = 'Ada' } } }
            function script:New-Approval { param([string[]] $Approvers)
                [pscustomobject]@{ type = [pscustomobject]@{ name = 'Approval' }
                                   settings = [pscustomobject]@{ approvers = @($Approvers | ForEach-Object { [pscustomobject]@{ displayName = $_ } }) } } }
        }
    }

    It 'separates no checks configured from checks not read' {
        $configured = InModuleScope msec {
            . Set-EnvMock -Environments @(New-Env -Id 1 -Name 'bare') -Checks @{ 1 = @() }
            Get-MsecAzureDevOpsEnvironment -Organization 'contoso'
        }
        $unread = InModuleScope msec {
            . Set-EnvMock -Environments @(New-Env -Id 1 -Name 'bare') -ChecksFail
            Get-MsecAzureDevOpsEnvironment -Organization 'contoso'
        }

        # 0 is a claim about the environment; $null is a claim about the read.
        $configured.CheckCount  | Should -Be 0
        $configured.HasApproval | Should -BeFalse
        $unread.CheckCount      | Should -BeNullOrEmpty
        $unread.HasApproval     | Should -BeNullOrEmpty
    }

    It 'excludes unread environments from -Unchecked' {
        $rows = InModuleScope msec {
            . Set-EnvMock -Environments @(New-Env -Id 1 -Name 'unknown') -ChecksFail
            Get-MsecAzureDevOpsEnvironment -Organization 'contoso' -Unchecked
        }

        # Otherwise the list of unguarded targets fills up with ones that may be fine.
        @($rows).Count | Should -Be 0
    }

    It 'names the approvers, including when they are a group' {
        $rows = InModuleScope msec {
            . Set-EnvMock -Environments @(New-Env -Id 5 -Name 'prod') `
                -Checks @{ 5 = @(New-Approval -Approvers @('ado-platform-env-approvers')) }
            Get-MsecAzureDevOpsEnvironment -Organization 'contoso'
        }

        # A group is the honest answer - who is in it is a separate question.
        $rows.HasApproval   | Should -BeTrue
        $rows.ApproverCount | Should -Be 1
        $rows.Approvers     | Should -Be 'ado-platform-env-approvers'
    }

    It 'flags an approval check with nobody on it' {
        $rows = InModuleScope msec {
            . Set-EnvMock -Environments @(New-Env -Id 6 -Name 'ghost') -Checks @{ 6 = @(New-Approval -Approvers @()) }
            Get-MsecAzureDevOpsEnvironment -Organization 'contoso'
        }

        # A gate with no approver named on it is not the protection the check count implies.
        $rows.HasApproval   | Should -BeTrue
        $rows.ApproverCount | Should -Be 0
    }

    It 'reports an environment any pipeline may deploy to' {
        $rows = InModuleScope msec {
            . Set-EnvMock -Environments @((New-Env -Id 7 -Name 'CN-PROD'), (New-Env -Id 8 -Name 'guarded')) `
                -Checks @{ 7 = @(); 8 = @(New-Approval -Approvers @('Ada')) } -Open @(7)
            Get-MsecAzureDevOpsEnvironment -Organization 'contoso'
        }

        # No check AND reachable by anything - a production target a pipeline written this
        # afternoon can deploy to.
        ($rows | Where-Object Environment -eq 'CN-PROD').OpenToAllPipelines | Should -BeTrue
        ($rows | Where-Object Environment -eq 'CN-PROD').OpenedBy           | Should -Be 'Ada'
        ($rows | Where-Object Environment -eq 'guarded').OpenToAllPipelines | Should -BeFalse
    }

    It 'throws a clear error when not connected' {
        InModuleScope msec {
            $script:MsecSession = $null
            { Get-MsecAzureDevOpsEnvironment -Organization 'contoso' } | Should -Throw '*Connect-Msec*'
        }
    }
}
