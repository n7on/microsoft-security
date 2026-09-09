#Requires -Module Pester
#
# Guards for the bundled Intune scripts.
#
# These CANNOT be executed here: they use SecurityIdentifier.Translate and the WinNT ADSI
# provider, both Windows-only, so a macOS or Linux runner cannot even construct a SID. What
# is testable is the set of invariants that do not need Windows - and the first of them is the
# exact hazard the scripts warn about:
#
#   A detect/remediate pair is TWO separate uploads to Intune and nothing enforces that they
#   agree. A $TargetAccount edited in one and not the other means detection fires on one
#   account while remediation removes a different one - on every device the pair is assigned
#   to, silently, because both scripts would still report success.
#
# Not every folder is a pair. Intune allows a remediation with detection ONLY, which is how a
# script becomes a fleet-wide inventory report read out of the detection output column, so a
# missing remediate.ps1 is a legitimate shape rather than a half-finished one.

BeforeAll {
    $script:IntuneRoot = Join-Path $PSScriptRoot '..' 'Scripts' 'Intune'
    $script:WindowsRoot = Join-Path $script:IntuneRoot 'Windows'

    $script:Pairs = @(Get-ChildItem -Path $script:WindowsRoot -Directory -ErrorAction SilentlyContinue)

    # Present halves only, so an inventory-only folder does not read as a broken pair.
    $script:Halves = @(
        foreach ($pair in $script:Pairs) {
            foreach ($half in 'detect.ps1', 'remediate.ps1') {
                $path = Join-Path $pair.FullName $half
                if (Test-Path $path) {
                    [pscustomobject]@{ Pair = $pair.Name; Half = $half; Path = $path }
                }
            }
        }
    )

    # Command invocations, from the AST - so a cmdlet NAMED in a comment explaining why it is
    # avoided does not read as a use of it. That distinction matters here: the scripts carry
    # long notes about Get-LocalGroupMember precisely because they do not call it.
    $script:CommandsIn = {
        param($Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $null)
        @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }
}

Describe 'Intune scripts' {

    It 'gives every remediation folder a detection half' {
        @($script:Pairs).Count | Should -BeGreaterThan 0

        foreach ($pair in $script:Pairs) {
            # Detection is always required; remediation is optional - see the header.
            Test-Path (Join-Path $pair.FullName 'detect.ps1') | Should -BeTrue -Because "$($pair.Name) needs detect.ps1"
        }
    }

    It 'parses on any platform, so a syntax error is caught before upload' {
        foreach ($half in $script:Halves) {
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($half.Path, [ref] $null, [ref] $errors) | Out-Null
            @($errors) -join '; ' | Should -BeNullOrEmpty -Because "$($half.Pair)/$($half.Half) must parse"
        }
    }

    It 'keeps $TargetAccount identical across a pair that uses one' {
        foreach ($pair in $script:Pairs) {
            $values = @(
                foreach ($half in @($script:Halves | Where-Object Pair -eq $pair.Name)) {
                    $content = Get-Content -Path $half.Path -Raw
                    # The assignment, not a mention in a comment.
                    $match = [regex]::Match($content, '(?m)^\s*\$TargetAccount\s*=\s*(?<v>.+?)\s*$')
                    if ($match.Success) { $match.Groups['v'].Value }
                }
            )

            # An inventory script targets nobody, so having none is fine. Having ONE where the
            # folder has two halves is not: that is exactly the drift this guards.
            if (-not $values.Count) { continue }

            $halfCount = @($script:Halves | Where-Object Pair -eq $pair.Name).Count
            @($values).Count | Should -Be $halfCount -Because "$($pair.Name): every half must name the account, or none"
            @($values | Select-Object -Unique).Count | Should -Be 1 -Because "$($pair.Name): detect.ps1 and remediate.ps1 must name the SAME account"
        }
    }

    It 'resolves the Administrators group by SID, never by name' {
        # 'Administrators' is renamed on localised Windows - Administratoren, Administratörer -
        # so a script hard-coding the English name silently finds no group at all there and
        # reports every such machine as clean.
        foreach ($half in $script:Halves) {
            (Get-Content -Path $half.Path -Raw) | Should -Match 'S-1-5-32-544' -Because "$($half.Pair)/$($half.Half) must bind the group by SID"
        }
    }

    It 'never calls Get-LocalGroupMember' {
        # It raises "A local account with the SID '<sid>' was not found" for any member it
        # cannot resolve - an Entra user who has never signed in here, or an object since
        # deleted. The membership is real; only the name lookup fails. The error is
        # NON-TERMINATING, but $ErrorActionPreference = 'Stop' promotes it, so ONE unresolvable
        # member aborts the enumeration and a machine full of Entra admins looks like a
        # collection failure.
        foreach ($half in $script:Halves) {
            $commands = & $script:CommandsIn $half.Path
            $commands | Should -Not -Contain 'Get-LocalGroupMember' -Because "$($half.Pair)/$($half.Half) must enumerate through ADSI instead"
        }
    }

    It 'resolves Entra members to their UPN, or matching by UPN cannot work' {
        # ADSI and LSA give an Entra member its SAM-COMPATIBLE name - 'AzureAD\JaneDoe' -
        # never the UPN. A target written as 'AzureAD\jane@contoso.com' therefore never
        # matches, the account stays an administrator, and the device reports clean. The
        # IdentityStore caches are the only way back to the UPN.
        foreach ($half in $script:Halves) {
            $content = Get-Content -Path $half.Path -Raw
            $content | Should -Match 'S-1-12-1-'   -Because "$($half.Pair)/$($half.Half) must recognise the Entra SID authority"
            $content | Should -Match 'IdentityStore' -Because "$($half.Pair)/$($half.Half) must recover the UPN from the IdentityStore caches"
            $content | Should -Match 'LogonCache'  -Because "$($half.Pair)/$($half.Half) must try LogonCache as well as IdentityCache"
        }
    }

    It 'keeps the duplicated helper functions byte-identical across a pair' {
        # The member enumeration is repeated in both halves, because Intune uploads each script
        # as one standalone file and there is nowhere shared to put it. Duplication that drifts
        # is worse than duplication: detection would match an account the remediation then
        # fails to find, and the device would report remediated forever while the account
        # stayed an administrator.
        #
        # Compared through the AST, so reformatting or moving a function is not a false failure.
        $functionsOf = {
            param($Path)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $null)
            $map = @{}
            foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                $map[$f.Name] = $f.Extent.Text
            }
            $map
        }

        foreach ($pair in $script:Pairs) {
            $detect    = Join-Path $pair.FullName 'detect.ps1'
            $remediate = Join-Path $pair.FullName 'remediate.ps1'
            if (-not (Test-Path $remediate)) { continue }

            $a = & $functionsOf $detect
            $b = & $functionsOf $remediate

            $shared = @($a.Keys | Where-Object { $b.ContainsKey($_) })
            @($shared).Count | Should -BeGreaterThan 0 -Because "$($pair.Name) should share its enumeration between the halves"

            foreach ($name in $shared) {
                $a[$name] | Should -Be $b[$name] -Because "$($pair.Name): $name has drifted between detect.ps1 and remediate.ps1"
            }
        }
    }

    It 'keeps the safety rails in the remediation half' {
        $remediate = Get-Content -Path (Join-Path $script:WindowsRoot 'remove-local-admin' 'remediate.ps1') -Raw

        # Removing the last administrator leaves a device that cannot be recovered locally,
        # and a fleet-wide assignment would do it everywhere at once.
        $remediate | Should -Match 'ProtectBuiltInAdministrator'
        $remediate | Should -Match '\-500\$'
        $remediate | Should -Match 'only member'

        # It must re-read the group rather than trust the Remove call: the WinNT provider
        # reports success for a removal that policy quietly undid, and 'fixed' while the
        # account is still an administrator is worse than 'failed'.
        $remediate | Should -Match 'Get-AdminGroupMember \| Where-Object'
    }

    It 'documents every script folder' {
        # These are uploaded by hand into a portal, and the settings they need - SYSTEM,
        # 64-bit, which Intune blade - live nowhere in the script itself.
        foreach ($folder in @(Get-ChildItem -Path $script:IntuneRoot -Directory -Recurse |
                                Where-Object { @(Get-ChildItem $_.FullName -File -Filter '*.ps1') -or
                                               @(Get-ChildItem $_.FullName -File -Filter '*.sh') })) {
            Test-Path (Join-Path $folder.FullName 'README.md') | Should -BeTrue -Because "$($folder.Name) needs a README"
        }
    }

    It 'is documented as writing, unlike every other bundled script' {
        $readme = Get-Content -Path (Join-Path $script:IntuneRoot '..' 'README.md') -Raw
        # Scripts/README.md tells authors bundled scripts are read-only and idempotent. This
        # channel is the exception, and an undocumented exception is how someone assigns a
        # destructive script fleet-wide expecting a report.
        $readme | Should -Match '(?s)Intune/.*(writes|WRITE)'
    }
}
