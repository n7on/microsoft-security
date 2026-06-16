#Requires -Module Pester
#
# Tests for Invoke-MsecAzureVMScript - the runner that dispatches bundled scripts to
# Azure VMs via Invoke-AzVMRunCommand. Covers OS-specific dispatch (RunShellScript
# vs RunPowerShellScript), output extraction (StdOut/StdErr filtering + the
# Linux agent's "[stdout]/[stderr]" wrapper unwrap), the active-context subscription
# guard (graceful fail for out-of-context VMs), per-row Os binding, parameter
# validation, and tab completion.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Invoke-MsecAzureVMScript' {
    It '-Os Linux runs the bundled .sh via RunShellScript and projects the response' {
        $results = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            $script:CapturedScriptPath = $null
            $script:CapturedCommandId  = $null
            Mock Invoke-AzVMRunCommand -MockWith {
                $script:CapturedScriptPath = $ScriptPath
                $script:CapturedCommandId  = $CommandId
                [pscustomobject]@{
                    Status = 'Succeeded'
                    Value  = @(
                        [pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = "ran $ScriptPath" }
                        [pscustomobject]@{ Code = 'ComponentStatus/StdErr/succeeded'; Message = '' }
                    )
                }
            }

            # Includes Location in the input so we verify passthrough.
            $vm = [pscustomobject]@{ Name = 'lin-1'; ResourceGroupName = 'rg-a'; Location = 'westeu' }
            $out = $vm | Invoke-MsecAzureVMScript -Os Linux -ScriptName os-info -TimeoutSeconds 0
            [pscustomobject]@{ Out = $out; Path = $script:CapturedScriptPath; Cmd = $script:CapturedCommandId }
        }

        $results.Cmd          | Should -Be 'RunShellScript'
        $results.Path         | Should -Match '/Scripts/VM/Linux/os-info\.sh$'
        $results.Out.VmName   | Should -Be 'lin-1'
        $results.Out.Os       | Should -Be 'Linux'
        $results.Out.Location | Should -Be 'westeu'
        $results.Out.Status   | Should -Be 'Succeeded'
        $results.Out.Output   | Should -Match 'os-info\.sh'
    }

    It '-Os Windows runs the bundled .ps1 via RunPowerShellScript and projects the response' {
        $results = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            $script:CapturedScriptPath = $null
            $script:CapturedCommandId  = $null
            Mock Invoke-AzVMRunCommand -MockWith {
                $script:CapturedScriptPath = $ScriptPath
                $script:CapturedCommandId  = $CommandId
                [pscustomobject]@{
                    Status = 'Succeeded'
                    Value  = @(
                        [pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = "ran $ScriptPath" }
                        [pscustomobject]@{ Code = 'ComponentStatus/StdErr/succeeded'; Message = '' }
                    )
                }
            }

            $vm = [pscustomobject]@{ Name = 'win-1'; ResourceGroupName = 'rg-a' }
            $out = $vm | Invoke-MsecAzureVMScript -Os Windows -ScriptName os-info -TimeoutSeconds 0
            [pscustomobject]@{ Out = $out; Path = $script:CapturedScriptPath; Cmd = $script:CapturedCommandId }
        }

        $results.Cmd        | Should -Be 'RunPowerShellScript'
        $results.Path       | Should -Match '/Scripts/VM/Windows/os-info\.ps1$'
        $results.Out.VmName | Should -Be 'win-1'
        $results.Out.Os     | Should -Be 'Windows'
        $results.Out.Status | Should -Be 'Succeeded'
        $results.Out.Output | Should -Match 'os-info\.ps1'
    }

    It 'unwraps the Linux agent "[stdout]/[stderr]" wrapper so consumers see clean script output' {
        # Reproduces the user-reported case: Linux RunShellScript returns a single Value
        # entry whose Message is "Enable succeeded:\n[stdout]\n<actual>\n[stderr]\n<err>".
        # The runner must strip that wrapper so ConvertFrom-Json on $_.Output works.
        $result = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Invoke-AzVMRunCommand -MockWith {
                [pscustomobject]@{
                    Status = 'Succeeded'
                    Value  = @(
                        [pscustomobject]@{
                            Code = 'ComponentStatus/StdOut/succeeded'
                            Message = @"
Enable succeeded:
[stdout]
{
  "TimeZone": "UTC",
  "Synchronized": true
}

[stderr]

"@
                        }
                    )
                }
            }

            [pscustomobject]@{ Name='lin-1'; ResourceGroupName='rg-a'; Location='westeu' } |
                Invoke-MsecAzureVMScript -Os Linux -ScriptName os-info -TimeoutSeconds 0
        }

        # Wrapper artefacts must be gone, leaving only the real stdout.
        $result.Output | Should -Not -Match 'Enable succeeded'
        $result.Output | Should -Not -Match '\[stdout\]'
        $result.Output | Should -Not -Match '\[stderr\]'

        # And the resulting Output is now valid JSON.
        $j = $result.Output | ConvertFrom-Json
        $j.TimeZone     | Should -Be 'UTC'
        $j.Synchronized | Should -BeTrue
    }

    It 'falls back to concatenating Value[].Message when the StdOut/StdErr Code filter misses' {
        # Reproduces the user-reported case: script succeeded, took ~30s, but Output came
        # back blank because Az.Compute's Code field didn't contain 'StdOut'.
        $out = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Invoke-AzVMRunCommand -MockWith {
                [pscustomobject]@{
                    Status = 'Succeeded'
                    Value  = @(
                        # Code without StdOut/StdErr in it - the preferred filter would miss this.
                        [pscustomobject]@{ Code = 'ProvisioningState/succeeded'; Message = 'hostname: web-test' }
                    )
                }
            }

            [pscustomobject]@{ Name = 'lin-1'; ResourceGroupName = 'rg-a' } |
                Invoke-MsecAzureVMScript -Os Linux -ScriptName os-info -TimeoutSeconds 0
        }

        $out.Status | Should -Be 'Succeeded'
        $out.Output | Should -Be 'hostname: web-test'
    }

    It 'throws a clear "<Os> script not found" error at runtime when the script does not exist' {
        InModuleScope msec {
            Mock Get-AzContext         -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Invoke-AzVMRunCommand -MockWith { throw 'should not be called' }

            $vm = [pscustomobject]@{ Name = 'lin-1'; ResourceGroupName = 'rg-a' }
            { $vm | Invoke-MsecAzureVMScript -Os Linux -ScriptName does-not-exist } |
                Should -Throw -ExpectedMessage 'Linux script not found:*'

            { $vm | Invoke-MsecAzureVMScript -Os Windows -ScriptName does-not-exist } |
                Should -Throw -ExpectedMessage 'Windows script not found:*'
        }
    }

    It 'runs VMs in the active-context subscription and gracefully fails VMs in another sub' {
        # Single-context model: with the active context on sub-A, a VM in sub-A dispatches
        # normally; a VM in sub-B is NOT dispatched - it comes back as a Failed row
        # explaining the mismatch. No per-VM context switching, no -DefaultProfile.
        InModuleScope msec {
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-A' }; Name = 'ctx-A' }
            }
            Mock Invoke-AzVMRunCommand -MockWith {
                [pscustomobject]@{
                    Status = 'Succeeded'
                    Value  = @([pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = 'ok' })
                }
            }

            $out = @(
                [pscustomobject]@{ Name='a-vm'; ResourceGroupName='rg'; Os='Linux'; SubscriptionId='sub-A' }
                [pscustomobject]@{ Name='b-vm'; ResourceGroupName='rg'; Os='Linux'; SubscriptionId='sub-B' }
            ) | Invoke-MsecAzureVMScript -ScriptName os-info -TimeoutSeconds 0

            # a-vm (matches active context) ran; b-vm (other sub) was failed gracefully.
            ($out | Where-Object VmName -eq 'a-vm').Status | Should -Be 'Succeeded'
            ($out | Where-Object VmName -eq 'b-vm').Status | Should -Be 'Failed'
            ($out | Where-Object VmName -eq 'b-vm').Error  | Should -Match 'subscription sub-B'

            # Invoke-AzVMRunCommand was only ever called for the in-context VM.
            Should -Invoke Invoke-AzVMRunCommand -Exactly 1 -ParameterFilter { $Name -eq 'a-vm' }
            Should -Invoke Invoke-AzVMRunCommand -Exactly 0 -ParameterFilter { $Name -eq 'b-vm' }
        }
    }

    It 'returns a Failed row (rather than throwing or dispatching) when a VMs subscription differs from the active context' {
        # Surfacing the gap in the report - with the remedy - is more useful than silently
        # dropping the VM, dispatching to the wrong sub, or aborting the whole batch.
        $result = InModuleScope msec {
            # Active context is sub-A; the VM lives in sub-B.
            Mock Get-AzContext -MockWith {
                [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-A' }; Name = 'ctx-A' }
            }
            Mock Invoke-AzVMRunCommand -MockWith { throw 'should not be called - b-vm is in another sub' }

            [pscustomobject]@{ Name='b-vm'; ResourceGroupName='rg'; Os='Linux'; SubscriptionId='sub-B' } |
                Invoke-MsecAzureVMScript -ScriptName os-info -TimeoutSeconds 0
        }

        $result.VmName | Should -Be 'b-vm'
        $result.Status | Should -Be 'Failed'
        $result.Error  | Should -Match 'subscription sub-B'
        $result.Error  | Should -Match 'active Az context is sub-A'
        $result.Error  | Should -Match 'Set-AzContext'
    }

    It 'binds -Os per-row from the pipeline so mixed Linux/Windows VMs work in one call' {
        # The whole point: no upstream ForEach-Object or OS-split needed - the caller
        # pipes rows that carry their own Os, and each row is dispatched against the
        # right Scripts/<Os>/ folder.
        $out = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Invoke-AzVMRunCommand -MockWith {
                # Echo the CommandId so the test can prove the per-row dispatch picked
                # the right script flavour (RunShellScript vs RunPowerShellScript).
                [pscustomobject]@{
                    Status = 'Succeeded'
                    Value  = @(
                        [pscustomobject]@{
                            Code    = 'ComponentStatus/StdOut/succeeded'
                            Message = $PesterBoundParameters.CommandId
                        }
                    )
                }
            }

            @(
                [pscustomobject]@{ Name='lin-1'; ResourceGroupName='rg-a'; Os='Linux';   Location='westeu' }
                [pscustomobject]@{ Name='win-1'; ResourceGroupName='rg-a'; Os='Windows'; Location='westeu' }
                [pscustomobject]@{ Name='lin-2'; ResourceGroupName='rg-a'; Os='Linux';   Location='westeu' }
            ) | Invoke-MsecAzureVMScript -ScriptName os-info -TimeoutSeconds 0
        }

        $out.Count                    | Should -Be 3
        $out.VmName                   | Should -Be @('lin-1','win-1','lin-2')
        $out.Os                       | Should -Be @('Linux','Windows','Linux')
        # Per-row dispatch picked the right CommandId for each OS.
        ($out | Where-Object Os -eq 'Linux').Output   | Should -Be @('RunShellScript','RunShellScript')
        ($out | Where-Object Os -eq 'Windows').Output | Should -Be 'RunPowerShellScript'
    }

    It 'exposes -TimeoutSeconds with sensible bounds and a real default' {
        $param = (Get-Command Invoke-MsecAzureVMScript).Parameters['TimeoutSeconds']
        $param                        | Should -Not -BeNullOrEmpty
        $param.ParameterType.FullName | Should -Be 'System.Int32'

        $range = $param.Attributes |
            Where-Object { $_.TypeId.Name -eq 'ValidateRangeAttribute' } |
            Select-Object -First 1
        $range.MinRange | Should -Be 0
        $range.MaxRange | Should -Be 3600

        # The default must be a real positive number - opting OUT of timeout (=0)
        # should be an explicit decision, not the default. Catches accidental
        # regression to the original "0 = no protection" default.
        $sourceLine = (Get-Command Invoke-MsecAzureVMScript).Definition |
            Select-String -Pattern '\[int\]\s*\$TimeoutSeconds\s*=\s*(\d+)' |
            Select-Object -First 1
        [int]$sourceLine.Matches.Groups[1].Value | Should -BeGreaterThan 0
    }

    It 'exposes -ThrottleLimit for parallel dispatch' {
        # Smoke test that the parameter exists and its bounds are sensible. The actual
        # parallel dispatch can't be unit-tested against mocks (ForEach-Object -Parallel
        # runspaces don't see Pester mocks), but verifying the parameter is wired up
        # catches accidental removal.
        $param = (Get-Command Invoke-MsecAzureVMScript).Parameters['ThrottleLimit']
        $param                       | Should -Not -BeNullOrEmpty
        $param.ParameterType.FullName | Should -Be 'System.Int32'

        $range = $param.Attributes |
            Where-Object { $_.TypeId.Name -eq 'ValidateRangeAttribute' } |
            Select-Object -First 1
        $range.MinRange | Should -Be 1
        $range.MaxRange | Should -Be 32
    }

    It 'with -ThrottleLimit 1 (default) still streams results through the sequential path' {
        # The sequential path is what we can actually mock - this verifies the refactor
        # to a worker-scriptblock didn't change observable behaviour at ThrottleLimit=1.
        $out = InModuleScope msec {
            Mock Get-AzContext -MockWith { [pscustomobject]@{ Subscription = @{ Id = 'sub-1' } } }
            Mock Invoke-AzVMRunCommand -MockWith {
                [pscustomobject]@{
                    Status = 'Succeeded'
                    Value  = @(
                        [pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = 'hello' }
                        [pscustomobject]@{ Code = 'ComponentStatus/StdErr/succeeded'; Message = ''      }
                    )
                }
            }

            @(
                [pscustomobject]@{ Name='lin-1'; ResourceGroupName='rg-a'; Location='westeu' }
                [pscustomobject]@{ Name='lin-2'; ResourceGroupName='rg-a'; Location='westeu' }
            ) | Invoke-MsecAzureVMScript -Os Linux -ScriptName os-info -ThrottleLimit 1 -TimeoutSeconds 0
        }

        $out.Count            | Should -Be 2
        $out.VmName           | Should -Be @('lin-1','lin-2')
        $out.Status           | Should -Be @('Succeeded','Succeeded')
        $out.Output           | Should -Be @('hello','hello')
    }

    It 'tab completion for -ScriptName returns the right basenames based on -Os' {
        # With -Os Linux already in the command line, completion should look in Scripts/VM/Linux.
        $line = 'Invoke-MsecAzureVMScript -Os Linux -ScriptName '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'os-info'

        # And with -Os Windows, it should look in Scripts/VM/Windows.
        $line = 'Invoke-MsecAzureVMScript -Os Windows -ScriptName '
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Contain 'os-info'
    }
}
