#Requires -Module Pester
#
# Tests for Get-MsecDefenderDevice.
#
# The behaviour worth pinning down is the counting, because the obvious implementation is
# wrong in two directions:
#
#   * the assessment export is one row per (device, software, CVE), so the same CVE affecting
#     three installed versions of a product is THREE rows and ONE vulnerability. Counting rows
#     inflates every device by a factor that varies with how much software it has.
#   * severity must therefore be counted once per CVE too, or the severity columns stop
#     adding up to VulnerabilityCount.
#
# And the one that matters most: a tenant without Defender Vulnerability Management answers
# 403 on the export. Reporting 0 there would read as "no device has any vulnerability" - the
# most dangerous wrong answer this command can give - so the counts must be $null and the
# device rows must still come back.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'Msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:TestThumbBytes = [byte[]](1..20)
}

AfterAll {
    Remove-Module Msec -Force -ErrorAction SilentlyContinue
}

Describe 'Get-MsecDefenderDevice' {
    BeforeEach {
        InModuleScope Msec -Parameters @{ Thumb = $script:TestThumbBytes } {
            param($Thumb)
            $script:MsecSession = @{
                TenantId = 'tenant'; ClientId = 'client'; KeyVaultName = 'kv-test'
                KeyName = 'msec-app'; ThumbprintBytes = $Thumb; Tokens = @{}
                Endpoints = @{ DefenderResource = 'https://api.securitycenter.microsoft.com'
                               EnvironmentName  = 'AzureCloud' }
            }
        }
    }

    It 'counts distinct CVEs, not export rows' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01'; exposureLevel = 'High'; healthStatus = 'Active' }
            }
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith {
                # ONE CVE, three installed versions of the same product - three rows.
                [pscustomobject]@{ deviceId = 'd1'; cveId = 'CVE-2026-1111'; vulnerabilitySeverityLevel = 'Critical'; softwareName = 'openssl'; softwareVersion = '1.0' }
                [pscustomobject]@{ deviceId = 'd1'; cveId = 'CVE-2026-1111'; vulnerabilitySeverityLevel = 'Critical'; softwareName = 'openssl'; softwareVersion = '1.1' }
                [pscustomobject]@{ deviceId = 'd1'; cveId = 'CVE-2026-1111'; vulnerabilitySeverityLevel = 'Critical'; softwareName = 'openssl'; softwareVersion = '3.0' }
                # A genuinely different one.
                [pscustomobject]@{ deviceId = 'd1'; cveId = 'CVE-2026-2222'; vulnerabilitySeverityLevel = 'High'; softwareName = 'curl'; softwareVersion = '8.0' }
            }
            Get-MsecDefenderDevice
        }

        # Two vulnerabilities, four findings. Not four vulnerabilities.
        $rows.VulnerabilityCount | Should -Be 2
        $rows.FindingCount       | Should -Be 4

        # Severity counted once per CVE too, or these stop summing to VulnerabilityCount.
        $rows.CriticalCount | Should -Be 1
        $rows.HighCount     | Should -Be 1
        ($rows.CriticalCount + $rows.HighCount + $rows.MediumCount + $rows.LowCount) |
            Should -Be $rows.VulnerabilityCount
    }

    It 'attributes findings to the right device and leaves clean ones at zero' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01'; healthStatus = 'Active' }
                [pscustomobject]@{ id = 'd2'; computerDnsName = 'db01';  healthStatus = 'Active' }
                [pscustomobject]@{ id = 'd3'; computerDnsName = 'kiosk'; healthStatus = 'Inactive' }
            }
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith {
                [pscustomobject]@{ deviceId = 'd1'; cveId = 'CVE-1'; vulnerabilitySeverityLevel = 'Critical' }
                [pscustomobject]@{ deviceId = 'd1'; cveId = 'CVE-2'; vulnerabilitySeverityLevel = 'Low' }
                [pscustomobject]@{ deviceId = 'd2'; cveId = 'CVE-1'; vulnerabilitySeverityLevel = 'Critical' }
            }
            Get-MsecDefenderDevice
        }

        $byName = @{}; foreach ($r in $rows) { $byName[$r.DeviceName] = $r }
        $byName['web01'].VulnerabilityCount | Should -Be 2
        $byName['db01'].VulnerabilityCount  | Should -Be 1
        # The same CVE on two devices is one vulnerability EACH, not shared.
        $byName['db01'].CriticalCount       | Should -Be 1

        # Absent from the export means no findings recorded - a real 0, not a null.
        $byName['kiosk'].VulnerabilityCount | Should -Be 0
        $byName['kiosk'].CriticalCount      | Should -Be 0
        # ...but it is Inactive, which is what tells the reader nobody has looked recently.
        # The command reports both rather than deciding for them.
        $byName['kiosk'].HealthStatus       | Should -Be 'Inactive'
    }

    It 'reads the id and severity under both names Defender uses' {
        # The bug this exists for: the command called /api/vulnerabilities/machinesVulnerabilities
        # - which returns machineId and severity - while looking for deviceId and
        # vulnerabilitySeverityLevel, the names the OTHER bulk endpoint uses. Every row was
        # discarded for having no id, and against a live tenant the whole estate reported 0
        # vulnerabilities with no error at all.
        $withMachineId = InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01'; healthStatus = 'Active' }
            }
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith {
                # The shape /api/vulnerabilities/machinesVulnerabilities actually returns.
                [pscustomobject]@{ machineId = 'd1'; cveId = 'CVE-1'; severity = 'Critical'; productName = 'openssl' }
                [pscustomobject]@{ machineId = 'd1'; cveId = 'CVE-2'; severity = 'High';     productName = 'curl' }
            }
            Get-MsecDefenderDevice
        }
        $withMachineId.VulnerabilityCount | Should -Be 2
        $withMachineId.CriticalCount      | Should -Be 1
        $withMachineId.HighCount          | Should -Be 1

        $withDeviceId = InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01'; healthStatus = 'Active' }
            }
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith {
                # The shape the export endpoint returns, accepted so swapping endpoint cannot
                # reintroduce the silent zero.
                [pscustomobject]@{ deviceId = 'd1'; cveId = 'CVE-1'; vulnerabilitySeverityLevel = 'Critical' }
                [pscustomobject]@{ deviceId = 'd1'; cveId = 'CVE-2'; vulnerabilitySeverityLevel = 'High' }
            }
            Get-MsecDefenderDevice
        }
        $withDeviceId.VulnerabilityCount | Should -Be 2
        $withDeviceId.CriticalCount      | Should -Be 1
    }

    It 'refuses to report zero when rows came back it could not attribute' {
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01'; healthStatus = 'Active' }
                [pscustomobject]@{ id = 'd2'; computerDnsName = 'db01';  healthStatus = 'Active' }
            }
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith {
                # Findings arrive, but under a key nothing knows about - a schema this code
                # does not understand. Indistinguishable from a clean estate in the output
                # unless it is caught here.
                [pscustomobject]@{ someUnknownIdField = 'd1'; cveId = 'CVE-1'; severity = 'Critical' }
                [pscustomobject]@{ someUnknownIdField = 'd1'; cveId = 'CVE-2'; severity = 'High' }
            }
            Get-MsecDefenderDevice
        } -WarningVariable warnings -WarningAction SilentlyContinue

        # Null, not 0. A row of zeroes across the estate reads as good news, and this is the
        # opposite of news.
        foreach ($r in $rows) {
            $r.VulnerabilityCount | Should -BeNullOrEmpty
            $r.CriticalCount      | Should -BeNullOrEmpty
        }
        ($warnings -join ' ') | Should -Match 'not in the expected shape'
        ($warnings -join ' ') | Should -Match '2 row'
    }

    It 'still reports zero when the export genuinely returns nothing' {
        # The other side of the guard: an empty export is a real answer, and must not be
        # turned into nulls by the shape check.
        $warnings = @()
        $rows = InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01'; healthStatus = 'Active' }
            }
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith { @() }
            Get-MsecDefenderDevice
        } -WarningVariable warnings -WarningAction SilentlyContinue

        $rows.VulnerabilityCount | Should -Be 0
        $rows.CriticalCount      | Should -Be 0
        ($warnings -join ' ')    | Should -Not -Match 'not in the expected shape'
    }

    It 'reports null counts, not zero, when the vulnerability export cannot be read' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01'; exposureLevel = 'High'; healthStatus = 'Active' }
                [pscustomobject]@{ id = 'd2'; computerDnsName = 'db01';  exposureLevel = 'Low';  healthStatus = 'Active' }
            }
            # No Defender Vulnerability Management licence.
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            Get-MsecDefenderDevice -WarningAction SilentlyContinue
        }

        # The inventory survives - losing the counts must not lose the devices.
        @($rows).Count | Should -Be 2

        # And every count is null. A 0 here would read as "no device has any vulnerability",
        # which is the one conclusion a failed read must never support.
        foreach ($r in $rows) {
            $r.VulnerabilityCount | Should -BeNullOrEmpty
            $r.CriticalCount      | Should -BeNullOrEmpty
            $r.FindingCount       | Should -BeNullOrEmpty
            $r.VulnerabilityCount | Should -Not -Be 0
        }
        # What the API did answer is still there.
        ($rows | Where-Object DeviceName -eq 'web01').ExposureLevel | Should -Be 'High'
    }

    It 'warns and names the permission when the export is forbidden' {
        $warnings = @()
        InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01' }
            }
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith {
                throw 'Response status code does not indicate success: 403 (Forbidden).'
            }
            Get-MsecDefenderDevice
        } -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null

        ($warnings -join ' ') | Should -Match 'Vulnerability\.Read\.All'
        ($warnings -join ' ') | Should -Match 'null rather than 0'
    }

    It 'normalises timestamps to UTC rather than local' {
        $row = InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01'; lastSeen = '2026-09-01T08:00:00Z' }
            }
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith { @() }
            Get-MsecDefenderDevice
        }

        # A plain [datetime] cast returns Kind=Local - the right instant in local wall-clock -
        # which then compares wrongly against a UTC clock.
        $row.LastSeen.Kind | Should -Be 'Utc'
        $row.LastSeen      | Should -Be ([datetime]::new(2026, 9, 1, 8, 0, 0, [DateTimeKind]::Utc))
    }

    It 'filters on health and exposure without a second fetch' {
        $rows = InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -eq '/api/machines' } -MockWith {
                [pscustomobject]@{ id = 'd1'; computerDnsName = 'web01'; healthStatus = 'Active';   exposureLevel = 'High' }
                [pscustomobject]@{ id = 'd2'; computerDnsName = 'db01';  healthStatus = 'Active';   exposureLevel = 'Low' }
                [pscustomobject]@{ id = 'd3'; computerDnsName = 'old';   healthStatus = 'Inactive'; exposureLevel = 'High' }
            }
            Mock Invoke-MsecDefenderRequest -ParameterFilter { $Path -match 'machinesVulnerabilities' } -MockWith { @() }
            Get-MsecDefenderDevice -HealthStatus Active -ExposureLevel High
        }

        @($rows).Count      | Should -Be 1
        $rows.DeviceName    | Should -Be 'web01'
    }

    It 'names the missing permission when the device list itself is forbidden' {
        InModuleScope Msec {
            Mock Invoke-MsecDefenderRequest -MockWith { throw 'Response status code does not indicate success: 403 (Forbidden).' }
            { Get-MsecDefenderDevice } | Should -Throw '*Machine.Read.All*'
        }
    }

    It 'throws a clear error when not connected' {
        InModuleScope Msec {
            $script:MsecSession = $null
            { Get-MsecDefenderDevice } | Should -Throw '*Connect-Msec*'
        }
    }
}
