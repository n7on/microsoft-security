#Requires -Module Pester
#
# Tests for Get-MsecEntraMfaEvidence. The behaviours that matter are the ones that would
# make an audit response WRONG while looking complete: a user with no sign-ins being
# reported as covered, a non-interactive token refresh counted as a single-factor
# sign-in, a group-based policy exclusion going unresolved, and a failed MFA challenge
# being mistaken for a sign-in that skipped MFA.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecEntraMfaEvidence' {

    It 'assigns each user the right evidence bucket and resolves group-based exclusions' {
        $result = InModuleScope msec {
            # The three underlying commands are mocked directly: this function's job is
            # the JOIN, and mocking Graph three times over would test their parsing again
            # rather than the logic under test here.
            Mock Assert-MsecSession -MockWith { }
            Mock Get-MsecEntraMfaRegistration -MockWith {
                @(
                    [pscustomobject]@{ UserId = 'u-ok';     UserPrincipalName = 'ok@example.com'
                                       DisplayName = 'Satisfied'; UserType = 'member'; IsAdmin = $true
                                       IsMfaCapable = $true;  IsMfaRegistered = $true;  DefaultMfaMethod = 'push' }
                    [pscustomobject]@{ UserId = 'u-single'; UserPrincipalName = 'single@example.com'
                                       DisplayName = 'Single factor'; UserType = 'member'; IsAdmin = $false
                                       IsMfaCapable = $true;  IsMfaRegistered = $true;  DefaultMfaMethod = 'sms' }
                    [pscustomobject]@{ UserId = 'u-quiet';  UserPrincipalName = 'quiet@example.com'
                                       DisplayName = 'Dormant admin'; UserType = 'member'; IsAdmin = $true
                                       IsMfaCapable = $false; IsMfaRegistered = $false; DefaultMfaMethod = 'none' }
                    [pscustomobject]@{ UserId = 'u-excl';   UserPrincipalName = 'breakglass@example.com'
                                       DisplayName = 'Break glass'; UserType = 'member'; IsAdmin = $true
                                       IsMfaCapable = $true;  IsMfaRegistered = $true;  DefaultMfaMethod = 'push' }
                    # Guests are excluded by default - their home tenant governs them.
                    [pscustomobject]@{ UserId = 'u-guest';  UserPrincipalName = 'guest@partner.test'
                                       DisplayName = 'Guest'; UserType = 'guest'; IsAdmin = $false
                                       IsMfaCapable = $false; IsMfaRegistered = $false; DefaultMfaMethod = 'none' }
                )
            }
            Mock Get-MsecEntraConditionalAccessPolicy -MockWith {
                @(
                    [pscustomobject]@{
                        DisplayName = 'Require MFA for all users'; State = 'enabled'
                        Requires = @('mfa'); IncludedUsers = @('All')
                        ExcludedUsers = @(); ExcludedGroups = @('g-breakglass'); ExcludedRoles = @()
                    }
                    # Narrower scope: reported, but scope deliberately NOT inferred.
                    [pscustomobject]@{
                        DisplayName = 'MFA for finance app'; State = 'enabled'
                        Requires = @('mfa'); IncludedUsers = @('u-single')
                        ExcludedUsers = @(); ExcludedGroups = @(); ExcludedRoles = @()
                    }
                    # Disabled policies must never count towards coverage.
                    [pscustomobject]@{
                        DisplayName = 'Old disabled MFA policy'; State = 'disabled'
                        Requires = @('mfa'); IncludedUsers = @('All')
                        ExcludedUsers = @(); ExcludedGroups = @(); ExcludedRoles = @()
                    }
                )
            }
            Mock Invoke-MsecGraphRequest -ParameterFilter { $Path -match 'groups/g-breakglass/transitiveMembers' } -MockWith {
                @([pscustomobject]@{ id = 'u-excl' })
            }
            Mock Get-MsecEntraConditionalAccessSignInLog -MockWith {
                @(
                    [pscustomobject]@{ UserId = 'u-ok'; IsInteractive = $true
                                       CreatedDateTime = [datetime]'2026-08-01T09:00:00Z'
                                       MfaSatisfied = $true; MfaFailed = $false
                                       MfaRequiredByPolicies = @('Require MFA for all users') }
                    [pscustomobject]@{ UserId = 'u-ok'; IsInteractive = $true
                                       CreatedDateTime = [datetime]'2026-08-05T09:00:00Z'
                                       MfaSatisfied = $true; MfaFailed = $false
                                       MfaRequiredByPolicies = @('Require MFA for all users') }
                    # No MFA policy fired: one factor was enough.
                    [pscustomobject]@{ UserId = 'u-single'; IsInteractive = $true
                                       CreatedDateTime = [datetime]'2026-08-04T09:00:00Z'
                                       MfaSatisfied = $false; MfaFailed = $false
                                       MfaRequiredByPolicies = @() }
                    # NON-interactive: a token refresh. Counting it as single-factor would
                    # invent a finding for a user who never had a prompt to answer.
                    [pscustomobject]@{ UserId = 'u-quiet'; IsInteractive = $false
                                       CreatedDateTime = [datetime]'2026-08-06T09:00:00Z'
                                       MfaSatisfied = $false; MfaFailed = $false
                                       MfaRequiredByPolicies = @() }
                )
            }

            @(Get-MsecEntraMfaEvidence -Days 30 -WarningAction SilentlyContinue)
        }

        # Guests excluded by default.
        $result.Count | Should -Be 4
        $result | Where-Object UserId -eq 'u-guest' | Should -BeNullOrEmpty

        # Evidence of the control OPERATING - two satisfied sign-ins, most recent kept.
        $ok = $result | Where-Object UserId -eq 'u-ok'
        $ok.EvidenceStatus      | Should -Be 'MfaSatisfied'
        $ok.MfaSatisfiedSignIns | Should -Be 2
        $ok.SingleFactorSignIns | Should -Be 0
        $ok.LastMfaSatisfiedUtc | Should -Be ([datetime]'2026-08-05T09:00:00Z')
        $ok.EnforcingPolicies   | Should -Contain 'Require MFA for all users'
        $ok.InScopeOfMfaPolicies | Should -Contain 'Require MFA for all users'

        # A finding: an interactive sign-in completed with no MFA policy applied.
        $single = $result | Where-Object UserId -eq 'u-single'
        $single.EvidenceStatus      | Should -Be 'SingleFactorObserved'
        $single.SingleFactorSignIns | Should -Be 1

        # The dormant admin had ONLY a non-interactive sign-in, so nothing is evidenced.
        # This must never read as a pass - it is where unused admin accounts hide.
        $quiet = $result | Where-Object UserId -eq 'u-quiet'
        $quiet.EvidenceStatus     | Should -Be 'NoSignInInWindow'
        $quiet.InteractiveSignIns | Should -Be 0
        $quiet.IsMfaCapable       | Should -BeFalse

        # The break-glass account is excluded via a GROUP - an indirection a policy
        # listing shows only as a GUID - and the reason is named.
        $excl = $result | Where-Object UserId -eq 'u-excl'
        $excl.ExcludedFromMfaPolicies.Count | Should -Be 1
        $excl.ExcludedFromMfaPolicies[0]    | Should -Match 'Require MFA for all users'
        $excl.ExcludedFromMfaPolicies[0]    | Should -Match 'group g-breakglass'
        $excl.InScopeOfMfaPolicies          | Should -BeNullOrEmpty

        # A disabled policy never counts, and a narrower one is reported without having
        # its scope guessed at.
        $ok.InScopeOfMfaPolicies    | Should -Not -Contain 'Old disabled MFA policy'
        $ok.OtherMfaPolicies        | Should -Contain 'MFA for finance app'

        # The window has to be on the row: evidence is only as good as its period.
        $ok.WindowDays | Should -Be 30
        $ok.PSObject.TypeNames | Should -Contain 'MsecEntraMfaEvidence'
    }

    It 'does not mistake a FAILED MFA challenge for a sign-in that skipped MFA' {
        $result = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Get-MsecEntraMfaRegistration -MockWith {
                @([pscustomobject]@{ UserId = 'u1'; UserPrincipalName = 'u1@example.com'
                                     UserType = 'member'; IsAdmin = $false
                                     IsMfaCapable = $true; IsMfaRegistered = $true; DefaultMfaMethod = 'push' })
            }
            Mock Get-MsecEntraConditionalAccessPolicy -MockWith {
                @([pscustomobject]@{ DisplayName = 'Require MFA'; State = 'enabled'; Requires = @('mfa')
                                     IncludedUsers = @('All'); ExcludedUsers = @(); ExcludedGroups = @(); ExcludedRoles = @() })
            }
            Mock Get-MsecEntraConditionalAccessSignInLog -MockWith {
                # The policy demanded MFA and the challenge FAILED. That is the control
                # working, not a bypass - counting it as single-factor would turn every
                # blocked sign-in into an audit finding.
                @([pscustomobject]@{ UserId = 'u1'; IsInteractive = $true
                                     CreatedDateTime = [datetime]'2026-08-04T09:00:00Z'
                                     MfaSatisfied = $false; MfaFailed = $true
                                     MfaRequiredByPolicies = @('Require MFA') })
            }

            @(Get-MsecEntraMfaEvidence -WarningAction SilentlyContinue)
        }

        $result[0].SingleFactorSignIns | Should -Be 0
        $result[0].MfaSatisfiedSignIns | Should -Be 0
        # Not satisfied, but emphatically not a bypass either - the policy challenged
        # them and they failed it. Calling that 'SingleFactorObserved' would report the
        # control working as if it had been circumvented.
        $result[0].EvidenceStatus      | Should -Be 'NoSuccessfulSignIn'
    }

    It 'does not count a FAILED sign-in as single-factor access, and surfaces legacy auth' {
        $result = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Get-MsecEntraMfaRegistration -MockWith {
                @(
                    [pscustomobject]@{ UserId = 'u-fail'; UserPrincipalName = 'typo@example.com'; UserType = 'member'
                                       IsAdmin = $false; IsMfaCapable = $true; IsMfaRegistered = $true; DefaultMfaMethod = 'push' }
                    [pscustomobject]@{ UserId = 'u-legacy'; UserPrincipalName = 'legacy@example.com'; UserType = 'member'
                                       IsAdmin = $true; IsMfaCapable = $true; IsMfaRegistered = $true; DefaultMfaMethod = 'push' }
                )
            }
            Mock Get-MsecEntraConditionalAccessPolicy -MockWith { @() }
            Mock Get-MsecEntraConditionalAccessSignInLog -MockWith {
                @(
                    # Wrong password. No MFA policy fired because the sign-in never got
                    # that far - counting this would make every mistyped credential a
                    # finding, and would flag a user who did not get in at all.
                    [pscustomobject]@{ UserId = 'u-fail'; IsInteractive = $true
                                       CreatedDateTime = [datetime]'2026-08-04T09:00:00Z'
                                       MfaSatisfied = $false; MfaFailed = $false
                                       MfaRequiredByPolicies = @(); ResultCode = 50126
                                       AppDisplayName = 'Office 365'; ClientAppUsed = 'Browser' }
                    # Succeeded on one factor over a LEGACY protocol. Conditional Access
                    # cannot challenge basic auth, only block it, so no MFA policy is in
                    # the path at all - the serious version of this finding.
                    [pscustomobject]@{ UserId = 'u-legacy'; IsInteractive = $true
                                       CreatedDateTime = [datetime]'2026-08-06T09:00:00Z'
                                       MfaSatisfied = $false; MfaFailed = $false
                                       MfaRequiredByPolicies = @(); ResultCode = 0
                                       AppDisplayName = 'Office 365 Exchange Online'
                                       ClientAppUsed = 'IMAP4' }
                )
            }

            @(Get-MsecEntraMfaEvidence -WarningAction SilentlyContinue)
        }

        # A rejected sign-in is not access, so this user has nothing to evidence either
        # way - not a finding, and not a pass.
        $failed = $result | Where-Object UserId -eq 'u-fail'
        $failed.SingleFactorSignIns | Should -Be 0
        # They attempted and were rejected: distinct from never having signed in, and
        # distinct from getting in on one factor.
        $failed.EvidenceStatus      | Should -Be 'NoSuccessfulSignIn'
        $failed.InteractiveSignIns  | Should -Be 1

        # The real finding, with the detail needed to act on it.
        $legacy = $result | Where-Object UserId -eq 'u-legacy'
        $legacy.EvidenceStatus         | Should -Be 'SingleFactorObserved'
        $legacy.SingleFactorSignIns    | Should -Be 1
        $legacy.SingleFactorLegacyAuth | Should -Be 1
        $legacy.SingleFactorClientApps | Should -Contain 'IMAP4'
        $legacy.SingleFactorApps       | Should -Contain 'Office 365 Exchange Online'
        $legacy.LastSingleFactorUtc    | Should -Be ([datetime]'2026-08-06T09:00:00Z')
    }

    It 'filters sign-ins server-side for a small population instead of paging the tenant' {
        # The reason a tenant-wide run looks like a hang: without a userId filter this
        # pages every sign-in in the window. For a handful of users Graph can do the
        # filtering, so the query must actually ask it to.
        $passed = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Get-MsecEntraMfaRegistration -MockWith {
                @(
                    [pscustomobject]@{ UserId = 'u1'; UserPrincipalName = 'a@example.com'; UserType = 'member'
                                       IsAdmin = $true; IsMfaCapable = $true; IsMfaRegistered = $true; DefaultMfaMethod = 'push' }
                    [pscustomobject]@{ UserId = 'u2'; UserPrincipalName = 'b@example.com'; UserType = 'member'
                                       IsAdmin = $true; IsMfaCapable = $true; IsMfaRegistered = $true; DefaultMfaMethod = 'push' }
                )
            }
            Mock Get-MsecEntraConditionalAccessPolicy -MockWith { @() }
            Mock Get-MsecEntraConditionalAccessSignInLog -MockWith { @() }

            $null = Get-MsecEntraMfaEvidence -AdminsOnly -WarningAction SilentlyContinue

            # -UserId must be passed, and must carry both ids.
            Should -Invoke Get-MsecEntraConditionalAccessSignInLog -Times 1 -Exactly -ParameterFilter {
                $null -ne $UserId -and @($UserId).Count -eq 2 -and @($UserId) -contains 'u1'
            }
            $true
        }
        $passed | Should -BeTrue
    }

    It 'warns when the window contains no interactive sign-ins at all' {
        # Every row reading NoSignInInWindow is indistinguishable from a broken query,
        # so an empty window says so rather than presenting itself as a finding.
        $result = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Get-MsecEntraMfaRegistration -MockWith {
                @([pscustomobject]@{ UserId = 'u1'; UserPrincipalName = 'a@example.com'; UserType = 'member'
                                     IsAdmin = $false; IsMfaCapable = $true; IsMfaRegistered = $true; DefaultMfaMethod = 'push' })
            }
            Mock Get-MsecEntraConditionalAccessPolicy -MockWith { @() }
            # Only a non-interactive sign-in: present in the log, useless as evidence.
            Mock Get-MsecEntraConditionalAccessSignInLog -MockWith {
                @([pscustomobject]@{ UserId = 'u1'; IsInteractive = $false
                                     CreatedDateTime = [datetime]'2026-08-04T09:00:00Z'
                                     MfaSatisfied = $false; MfaFailed = $false; MfaRequiredByPolicies = @() })
            }

            $warnings = @()
            $rows = @(Get-MsecEntraMfaEvidence -WarningVariable warnings -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $rows; Warnings = @($warnings) }
        }

        $result.Rows[0].EvidenceStatus | Should -Be 'NoSignInInWindow'
        ($result.Warnings -join ' ')   | Should -Match 'No INTERACTIVE sign-ins'
    }

    It 'warns and reports every user as unevidenced when sign-in logs cannot be read' {
        $result = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Get-MsecEntraMfaRegistration -MockWith {
                @([pscustomobject]@{ UserId = 'u1'; UserPrincipalName = 'u1@example.com'
                                     UserType = 'member'; IsAdmin = $true
                                     IsMfaCapable = $true; IsMfaRegistered = $true; DefaultMfaMethod = 'push' })
            }
            Mock Get-MsecEntraConditionalAccessPolicy -MockWith { @() }
            Mock Get-MsecEntraConditionalAccessSignInLog -MockWith {
                throw 'Sign-in logs are not available in this tenant.'
            }

            $warnings = @()
            $rows = @(Get-MsecEntraMfaEvidence -WarningVariable warnings -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $rows; Warnings = @($warnings) }
        }

        # Capability is still reported, but nothing is claimed about enforcement.
        $result.Rows[0].EvidenceStatus | Should -Be 'NoEvidenceAvailable'
        $result.Rows[0].IsMfaCapable   | Should -BeTrue

        $joined = $result.Warnings -join ' '
        $joined | Should -Match 'NoEvidenceAvailable'
        # And the missing MFA policy is called out as the finding it is.
        $joined | Should -Match 'No ENABLED Conditional Access policy requires MFA'
    }

    It 'warns rather than overstating coverage when an exclusion group cannot be expanded' {
        $result = InModuleScope msec {
            Mock Assert-MsecSession -MockWith { }
            Mock Get-MsecEntraMfaRegistration -MockWith {
                @([pscustomobject]@{ UserId = 'u1'; UserPrincipalName = 'u1@example.com'
                                     UserType = 'member'; IsAdmin = $false
                                     IsMfaCapable = $true; IsMfaRegistered = $true; DefaultMfaMethod = 'push' })
            }
            Mock Get-MsecEntraConditionalAccessPolicy -MockWith {
                @([pscustomobject]@{ DisplayName = 'Require MFA'; State = 'enabled'; Requires = @('mfa')
                                     IncludedUsers = @('All'); ExcludedUsers = @()
                                     ExcludedGroups = @('g-unreadable'); ExcludedRoles = @() })
            }
            Mock Invoke-MsecGraphRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            Mock Get-MsecEntraConditionalAccessSignInLog -MockWith { @() }

            $warnings = @()
            $rows = @(Get-MsecEntraMfaEvidence -WarningVariable warnings -WarningAction SilentlyContinue)
            [pscustomobject]@{ Rows = $rows; Warnings = @($warnings) }
        }

        # An unreadable exclusion group means anyone inside it is wrongly shown as in
        # scope, which OVERSTATES coverage - the one direction an audit report must not
        # fail in silently.
        ($result.Warnings -join ' ') | Should -Match 'overstates coverage'
        $result.Rows[0].InScopeOfMfaPolicies | Should -Contain 'Require MFA'
    }
}
