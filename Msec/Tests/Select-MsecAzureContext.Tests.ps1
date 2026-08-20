#Requires -Module Pester
#
# Tests for Select-MsecAzureContext: selecting among ALREADY-signed-in Azure contexts
# (Get-AzContext -ListAvailable + Select-AzContext) by subscription name/id, disambiguated
# by -User (account, which implies the tenant). Covers the app-session drift warning,
# dependent tab-completion, and clear errors.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Select-MsecAzureContext' {

    # Saved contexts: 'shared' is signed in under two different accounts (one in another
    # tenant/cloud), so it needs -User to disambiguate; the rest are unique.
    BeforeAll {
        $script:Ctxs = @(
            [pscustomobject]@{ Name = 'ctx-dev';    Subscription = [pscustomobject]@{ Id = 'sub-1'; Name = 'dev' };      Tenant = [pscustomobject]@{ Id = 't1' }; Environment = 'AzureCloud';      Account = [pscustomobject]@{ Id = 'admin@contoso.com' } }
            [pscustomobject]@{ Name = 'ctx-prod';   Subscription = [pscustomobject]@{ Id = 'sub-2'; Name = 'prod app' }; Tenant = [pscustomobject]@{ Id = 't1' }; Environment = 'AzureCloud';      Account = [pscustomobject]@{ Id = 'admin@contoso.com' } }
            [pscustomobject]@{ Name = 'ctx-cn';     Subscription = [pscustomobject]@{ Id = 'sub-3'; Name = 'shared' };   Tenant = [pscustomobject]@{ Id = 't2' }; Environment = 'AzureChinaCloud'; Account = [pscustomobject]@{ Id = 'cn@partner.cn' } }
            [pscustomobject]@{ Name = 'ctx-shared'; Subscription = [pscustomobject]@{ Id = 'sub-4'; Name = 'shared' };   Tenant = [pscustomobject]@{ Id = 't1' }; Environment = 'AzureCloud';      Account = [pscustomobject]@{ Id = 'admin@contoso.com' } }
        )
    }

    It 'switches to a saved context matched by subscription id' {
        $captured = InModuleScope msec -Parameters @{ Ctxs = $script:Ctxs } {
            param($Ctxs)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { $Ctxs }
            $script:CapturedSub = $null
            Mock Select-AzContext -RemoveParameterType 'InputObject' -MockWith { $script:CapturedSub = $InputObject.Subscription.Id }
            $script:MsecSession = $null

            $r = Select-MsecAzureContext -Subscription 'sub-1'
            [pscustomobject]@{ Captured = $script:CapturedSub; Result = $r }
        }

        $captured.Captured              | Should -Be 'sub-1'
        $captured.Result.SubscriptionId | Should -Be 'sub-1'
        $captured.Result.Account        | Should -Be 'admin@contoso.com'
    }

    It 'switches to a saved context matched by subscription name when it is unique' {
        $sub = InModuleScope msec -Parameters @{ Ctxs = $script:Ctxs } {
            param($Ctxs)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { $Ctxs }
            $script:CapturedSub = $null
            Mock Select-AzContext -RemoveParameterType 'InputObject' -MockWith { $script:CapturedSub = $InputObject.Subscription.Id }
            $script:MsecSession = $null

            $null = Select-MsecAzureContext -Subscription 'prod app'
            $script:CapturedSub
        }
        $sub | Should -Be 'sub-2'
    }

    It 'disambiguates a shared subscription name by -User (which carries the tenant/cloud)' {
        $captured = InModuleScope msec -Parameters @{ Ctxs = $script:Ctxs } {
            param($Ctxs)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { $Ctxs }
            $script:CapturedSub = $null
            Mock Select-AzContext -RemoveParameterType 'InputObject' -MockWith { $script:CapturedSub = $InputObject.Subscription.Id }
            $script:MsecSession = $null

            $r = Select-MsecAzureContext -Subscription 'shared' -User 'cn@partner.cn'
            [pscustomobject]@{ Captured = $script:CapturedSub; Result = $r }
        }

        $captured.Captured           | Should -Be 'sub-3'        # the cn@partner.cn context
        $captured.Result.TenantId    | Should -Be 't2'
        $captured.Result.Environment | Should -Be 'AzureChinaCloud'
    }

    It 'throws, naming the accounts, when a shared subscription name has no -User' {
        InModuleScope msec -Parameters @{ Ctxs = $script:Ctxs } {
            param($Ctxs)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { $Ctxs }
            Mock Select-AzContext -RemoveParameterType 'InputObject' -MockWith { }

            { Select-MsecAzureContext -Subscription 'shared' } |
                Should -Throw -ExpectedMessage '*signed in under more than one account*'
        }
    }

    It 'throws a clear error when no saved context matches' {
        InModuleScope msec -Parameters @{ Ctxs = $script:Ctxs } {
            param($Ctxs)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { $Ctxs }
            Mock Select-AzContext -RemoveParameterType 'InputObject' -MockWith { }

            { Select-MsecAzureContext -Subscription 'nope' } |
                Should -Throw -ExpectedMessage "*No signed-in context matches subscription 'nope'*"
        }
    }

    It 'warns when the chosen context tenant/cloud differs from the msec app session' {
        $warnings = InModuleScope msec -Parameters @{ Ctxs = $script:Ctxs } {
            param($Ctxs)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { $Ctxs }
            Mock Select-AzContext -RemoveParameterType 'InputObject' -MockWith { }
            # App session pinned to commercial / t1; we switch into the t2 / China context.
            $script:MsecSession = @{ TenantId = 't1'; Endpoints = [pscustomobject]@{ EnvironmentName = 'AzureCloud' } }

            Select-MsecAzureContext -Subscription 'shared' -User 'cn@partner.cn' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }
        ($warnings -join ' ') | Should -Match 'Connect-Msec again'
    }

    It 'does NOT warn when the chosen context tenant and cloud still match the session' {
        $warnings = InModuleScope msec -Parameters @{ Ctxs = $script:Ctxs } {
            param($Ctxs)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { $Ctxs }
            Mock Select-AzContext -RemoveParameterType 'InputObject' -MockWith { }
            $script:MsecSession = @{ TenantId = 't1'; Endpoints = [pscustomobject]@{ EnvironmentName = 'AzureCloud' } }

            Select-MsecAzureContext -Subscription 'dev' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }
        $warnings | Should -BeNullOrEmpty
    }

    It 'does NOT warn when .Environment is an object equal to the session cloud (regression)' {
        # A real saved context exposes .Environment as a PSAzureEnvironment OBJECT, not a
        # string. Comparing the object directly to the session cloud string is always "not
        # equal", which fired a false drift warning even when tenant + cloud matched.
        $cloud = [pscustomobject]@{ Name = 'AzureCloud' }
        $cloud | Add-Member -MemberType ScriptMethod -Name ToString -Value { 'AzureCloud' } -Force
        $ctx = [pscustomobject]@{
            Name = 'ctx-x'; Subscription = [pscustomobject]@{ Id = 'sub-x'; Name = 'prod' }
            Tenant = [pscustomobject]@{ Id = 't1' }; Environment = $cloud
            Account = [pscustomobject]@{ Id = 'admin@contoso.com' }
        }

        $warnings = InModuleScope msec -Parameters @{ Ctx = $ctx } {
            param($Ctx)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { @($Ctx) }
            Mock Select-AzContext -RemoveParameterType 'InputObject' -MockWith { }
            $script:MsecSession = @{ TenantId = 't1'; Endpoints = [pscustomobject]@{ EnvironmentName = 'AzureCloud' } }

            Select-MsecAzureContext -Subscription 'prod' -WarningVariable w -WarningAction SilentlyContinue | Out-Null
            $w
        }
        $warnings | Should -BeNullOrEmpty
    }

    It 'throws when there are no saved contexts at all' {
        InModuleScope msec {
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { @() }
            { Select-MsecAzureContext -Subscription 'dev' } |
                Should -Throw -ExpectedMessage '*No saved Azure contexts*'
        }
    }

    It '-Subscription tab-completes DISTINCT subscription names, with accounts in the tooltip' {
        InModuleScope msec -Parameters @{ Ctxs = $script:Ctxs } {
            param($Ctxs)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { $Ctxs }

            $sb = (Get-Command Select-MsecAzureContext).Parameters['Subscription'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] } |
                Select-Object -ExpandProperty ScriptBlock

            $completions = & $sb $null 'Subscription' '' $null @{}

            $completions.ListItemText | Should -Contain 'dev'
            $completions.ListItemText | Should -Contain 'prod app'
            # 'shared' is two contexts but appears once (distinct names).
            @($completions | Where-Object ListItemText -eq 'shared').Count | Should -Be 1
            # Its tooltip lists both accounts so the user knows -User will be needed.
            (($completions | Where-Object ListItemText -eq 'shared').ToolTip) | Should -Match 'cn@partner.cn'
            (($completions | Where-Object ListItemText -eq 'shared').ToolTip) | Should -Match 'admin@contoso.com'
        }
    }

    It '-User tab-completes only the accounts available for the chosen -Subscription' {
        InModuleScope msec -Parameters @{ Ctxs = $script:Ctxs } {
            param($Ctxs)
            Mock Get-AzContext -ParameterFilter { $ListAvailable } -MockWith { $Ctxs }

            $sb = (Get-Command Select-MsecAzureContext).Parameters['User'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ArgumentCompleterAttribute] } |
                Select-Object -ExpandProperty ScriptBlock

            # Dependent on -Subscription 'shared': should offer both of its accounts...
            $shared = & $sb $null 'User' '' $null @{ Subscription = 'shared' }
            $shared.CompletionText | Should -Contain 'cn@partner.cn'
            $shared.CompletionText | Should -Contain 'admin@contoso.com'

            # ...but for 'dev' only that subscription's single account.
            $dev = & $sb $null 'User' '' $null @{ Subscription = 'dev' }
            $dev.CompletionText | Should -Be 'admin@contoso.com'
        }
    }
}
