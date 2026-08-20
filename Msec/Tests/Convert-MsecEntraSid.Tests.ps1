#Requires -Module Pester
#
# Tests for Convert-MsecEntraSid. The arithmetic is the whole point of the command,
# so it is pinned against a known SID/objectId pair and round-tripped in both
# directions. The other half of the coverage is the boundary: an on-premises
# S-1-5-21 SID has no objectId in it, and must be refused rather than turned into
# a plausible-looking but meaningless GUID.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # Verified pair: little-endian uint32 packing of the objectId's 16 bytes.
    $script:KnownSid      = 'S-1-12-1-2640853384-1293864314-2707107988-2394433369'
    $script:KnownObjectId = '9d683988-cd7a-4d1e-9430-5ba15927b88e'

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'Convert-MsecEntraSid' {

    Context 'offline conversion' {
        It 'converts a known Entra SID to its objectId' {
            $row = Convert-MsecEntraSid -Sid $script:KnownSid

            $row.ObjectId  | Should -Be ([guid] $script:KnownObjectId)
            $row.Sid       | Should -Be $script:KnownSid
            $row.Direction | Should -Be 'SidToObjectId'
            $row.ObjectId  | Should -BeOfType [guid]
            $row.PSObject.TypeNames | Should -Contain 'MsecEntraSid'
        }

        It 'converts an objectId back to the same SID' {
            $row = Convert-MsecEntraSid -ObjectId $script:KnownObjectId

            $row.Sid       | Should -Be $script:KnownSid
            $row.ObjectId  | Should -Be ([guid] $script:KnownObjectId)
            $row.Direction | Should -Be 'ObjectIdToSid'
        }

        It 'round-trips an arbitrary GUID byte-exactly' {
            # A fixed GUID with a high bit set in every one of the four groups, so a
            # signed/unsigned or endianness slip cannot pass unnoticed.
            $guid = [guid] 'ffffffff-8000-8001-80ff-ffffffffffff'

            $sid = (Convert-MsecEntraSid -ObjectId $guid).Sid
            (Convert-MsecEntraSid -Sid $sid).ObjectId | Should -Be $guid
        }

        It 'accepts several SIDs from the pipeline and preserves order' {
            $second = (Convert-MsecEntraSid -ObjectId '00000000-0000-0000-0000-000000000001').Sid

            $rows = @($script:KnownSid, $second) | Convert-MsecEntraSid

            $rows.Count      | Should -Be 2
            $rows[0].ObjectId | Should -Be ([guid] $script:KnownObjectId)
            $rows[1].ObjectId | Should -Be ([guid] '00000000-0000-0000-0000-000000000001')
        }

        It 'accepts SIDs by property name, so rows from another command pipe in' {
            $rows = [pscustomobject]@{ Sid = $script:KnownSid } | Convert-MsecEntraSid
            $rows.ObjectId | Should -Be ([guid] $script:KnownObjectId)
        }

        It 'tolerates surrounding whitespace from a text file' {
            $row = Convert-MsecEntraSid -Sid "  $script:KnownSid`t"

            $row.Sid      | Should -Be $script:KnownSid
            $row.ObjectId | Should -Be ([guid] $script:KnownObjectId)
        }

        It 'does not need a session when -Resolve is not used' {
            InModuleScope msec { $script:MsecSession = $null }
            { Convert-MsecEntraSid -Sid $script:KnownSid } | Should -Not -Throw
        }
    }

    Context 'rejecting SIDs that carry no objectId' {
        It 'refuses an on-premises S-1-5-21 SID and says why' {
            { Convert-MsecEntraSid -Sid 'S-1-5-21-1004336348-1177238915-682003330-512' } |
                Should -Throw -ExpectedMessage '*onPremisesSecurityIdentifier*'
        }

        It 'refuses a well-known SID' {
            { Convert-MsecEntraSid -Sid 'S-1-5-32-544' } | Should -Throw -ExpectedMessage '*not an Entra ID SID*'
        }

        It 'refuses an S-1-12-1 SID with the wrong number of sub-authorities' {
            { Convert-MsecEntraSid -Sid 'S-1-12-1-2640853384-1293864314-2707107988' } |
                Should -Throw -ExpectedMessage '*S-1-12-1-<a>-<b>-<c>-<d>*'
        }

        It 'refuses a sub-authority that does not fit in 32 bits' {
            { Convert-MsecEntraSid -Sid 'S-1-12-1-4294967296-1293864314-2707107988-2394433369' } |
                Should -Throw -ExpectedMessage '*exceeds the 32-bit maximum*'
        }

        It 'refuses text that is not a SID at all' {
            { Convert-MsecEntraSid -Sid 'user@contoso.com' } | Should -Throw -ExpectedMessage '*not an Entra ID SID*'
        }
    }

    Context '-Resolve' {
        BeforeEach {
            InModuleScope msec -Parameters @{ Thumb = $script:TestThumbBytes } {
                param($Thumb)
                $script:MsecSession = @{
                    TenantId        = 'tenant'
                    ClientId        = 'client'
                    KeyVaultName    = 'kv-test'
                    KeyName         = 'msec-app'
                    ThumbprintBytes = $Thumb
                    Tokens          = @{}
                }
            }
        }

        It 'adds the display name, UPN and object type from Graph' {
            $row = InModuleScope msec -Parameters @{ Sid = $script:KnownSid } {
                param($Sid)
                Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryObjects/9d683988' } -MockWith {
                    [pscustomobject]@{
                        '@odata.type'     = '#microsoft.graph.user'
                        id                = '9d683988-cd7a-4d1e-9430-5ba15927b88e'
                        displayName       = 'Ada Lovelace'
                        userPrincipalName = 'ada@contoso.com'
                    }
                }

                Convert-MsecEntraSid -Sid $Sid -Resolve
            }

            $row.DisplayName       | Should -Be 'Ada Lovelace'
            $row.UserPrincipalName | Should -Be 'ada@contoso.com'
            # The '#microsoft.graph.' prefix is stripped so the value reads as a type.
            $row.ObjectType        | Should -Be 'user'
            $row.ObjectId          | Should -Be ([guid] $script:KnownObjectId)
            # Resolved rows get their own format view in front of the plain one.
            $row.PSObject.TypeNames[0] | Should -Be 'MsecEntraSidResolved'
            $row.PSObject.TypeNames    | Should -Contain 'MsecEntraSid'
        }

        It 'resolves a group, which has no UPN' {
            $row = InModuleScope msec -Parameters @{ Sid = $script:KnownSid } {
                param($Sid)
                Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryObjects/' } -MockWith {
                    [pscustomobject]@{
                        '@odata.type' = '#microsoft.graph.group'
                        displayName   = 'sg-admins'
                    }
                }

                Convert-MsecEntraSid -Sid $Sid -Resolve
            }

            $row.ObjectType        | Should -Be 'group'
            $row.DisplayName       | Should -Be 'sg-admins'
            $row.UserPrincipalName | Should -BeNullOrEmpty
        }

        It 'resolves a directory role and keeps roleTemplateId reachable via Raw' {
            # The common case for a SID scraped off an Entra-joined device: local admin
            # is granted to the ROLE, so the SID is a directoryRole, not a person. The
            # per-tenant instance id is useless for joining across tenants, so the
            # stable roleTemplateId must survive into the row.
            $row = InModuleScope msec -Parameters @{ Sid = $script:KnownSid } {
                param($Sid)
                Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryObjects/' } -MockWith {
                    [pscustomobject]@{
                        '@odata.type'  = '#microsoft.graph.directoryRole'
                        id             = '9d683988-cd7a-4d1e-9430-5ba15927b88e'
                        displayName    = 'Global Administrator'
                        roleTemplateId = '62e90394-69f5-4237-9190-012177145e10'
                    }
                }

                Convert-MsecEntraSid -Sid $Sid -Resolve
            }

            $row.ObjectType            | Should -Be 'directoryRole'
            $row.DisplayName           | Should -Be 'Global Administrator'
            $row.UserPrincipalName     | Should -BeNullOrEmpty
            $row.Raw.roleTemplateId    | Should -Be '62e90394-69f5-4237-9190-012177145e10'
        }

        It 'marks a deleted object NotFound instead of failing the batch' {
            $rows = InModuleScope msec -Parameters @{ Sid = $script:KnownSid } {
                param($Sid)
                Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
                }
                # First SID resolves, second is gone - the run must still produce both
                # rows. Pester tries the most recently defined mock first, so the catch-all
                # 404 goes in before the specific object that does exist.
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryObjects/' } -MockWith {
                    throw 'Response status code does not indicate success: 404 (Not Found).'
                }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryObjects/9d683988' } -MockWith {
                    [pscustomobject]@{ '@odata.type' = '#microsoft.graph.user'; displayName = 'Ada Lovelace' }
                }

                $gone = (Convert-MsecEntraSid -ObjectId '00000000-0000-0000-0000-000000000001').Sid
                @($Sid, $gone) | Convert-MsecEntraSid -Resolve
            }

            $rows.Count           | Should -Be 2
            $rows[0].ObjectType   | Should -Be 'user'
            $rows[1].ObjectType   | Should -Be 'NotFound'
            $rows[1].DisplayName  | Should -BeNullOrEmpty
        }

        It 'rewrites a 403 to mention the missing Directory.Read.All permission' {
            InModuleScope msec -Parameters @{ Sid = $script:KnownSid } {
                param($Sid)
                Mock Invoke-MsecKeyVaultSign -MockWith { [byte[]](1..10) }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match 'oauth2/v2.0/token' } -MockWith {
                    [pscustomobject]@{ access_token = 'mock'; expires_in = 3600 }
                }
                Mock Invoke-RestMethod -ParameterFilter { $Uri -match '/directoryObjects/' } -MockWith {
                    throw 'Response status code does not indicate success: 403 (Forbidden).'
                }

                { Convert-MsecEntraSid -Sid $Sid -Resolve } |
                    Should -Throw -ExpectedMessage '*Directory.Read.All*'
            }
        }

        It 'requires a session' {
            InModuleScope msec -Parameters @{ Sid = $script:KnownSid } {
                param($Sid)
                $script:MsecSession = $null
                { Convert-MsecEntraSid -Sid $Sid -Resolve } | Should -Throw -ExpectedMessage '*Connect-Msec*'
            }
        }
    }

    Context 'module surface' {
        It 'is exported by the module' {
            (Get-Command Convert-MsecEntraSid -Module msec) | Should -Not -BeNullOrEmpty
        }

        It 'is listed in FunctionsToExport' {
            $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot '..' 'msec.psd1')
            $manifest.FunctionsToExport | Should -Contain 'Convert-MsecEntraSid'
        }
    }
}
