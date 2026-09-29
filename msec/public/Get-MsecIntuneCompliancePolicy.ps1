function Get-MsecIntuneCompliancePolicy {
    <#
    .SYNOPSIS
        Lists Intune compliance policies - what defines whether a device is "compliant"
        (and therefore allowed through Conditional Access).

    .DESCRIPTION

        A POLICY THAT CHECKS NOTHING LOOKS EXACTLY LIKE A HEALTHY ONE. Name, platform and
        assignment count say nothing about whether the policy enforces anything, and a policy
        with no settings configured reports every device as compliant because there is nothing
        to fail. Measured live: a macOS baseline assigned to all licensed users since 2021 had
        osMinimumVersion empty and password, encryption, firewall and system-integrity all
        False - 17 of 19 devices "compliant", including two on an unsupported major version.

        So ConfiguredCheckCount and ChecksNothing are on every row, not behind a switch. The
        rules for deciding whether a setting counts are written down in
        Get-MsecCompliancePolicyCheck rather than guessed at per platform.

        OsMinimumVersion IS PROMOTED OUT OF THE SETTINGS because it is the one compliance
        setting that turns a device inventory into a patch-compliance answer. Empty means the
        policy does not care what version a device runs, which is a finding rather than a blank.        Compliance policies are *separate from* configuration policies in Intune:
          - Configurations enforce a state on a device (e.g. "BitLocker on").
          - Compliance policies measure whether a state is met (e.g. "Encryption required"),
            and report compliant/non-compliant per device. Conditional Access then gates
            access on that.

        Queries /v1.0/deviceManagement/deviceCompliancePolicies, including assignments via
        $expand (one call, no extra round trip). Per-policy device check-in counts are opt-in
        via -IncludeStatus (one extra Graph call per policy).

        Required Graph permission: DeviceManagementConfiguration.Read.All (Application) -
        the same permission Get-MsecIntuneConfigurationProfile uses.

    .PARAMETER IncludeSettings
        Attach every compliance setting and its value as a Settings property. Costs nothing
        extra - the list endpoint already returns them.

    .PARAMETER IncludeStatus
        Fetch the per-policy device check-in counts. Off by default to keep the call cheap
        on large tenants.

    .EXAMPLE
        # Assigned, reporting compliant, and enforcing nothing.
        Get-MsecIntuneCompliancePolicy |
            Where-Object { $_.AssignmentCount -gt 0 -and $_.ChecksNothing }

    .EXAMPLE
        # Which platforms have a minimum OS version, and which do not.
        Get-MsecIntuneCompliancePolicy |
            Format-Table DisplayName, Platform, AssignmentCount, OsMinimumVersion, ConfiguredCheckCount

    .EXAMPLE
        # Quick inventory:
        Get-MsecIntuneCompliancePolicy | Format-Table -AutoSize

    .EXAMPLE
        # Compliance policies with devices failing:
        Get-MsecIntuneCompliancePolicy -IncludeStatus |
            Where-Object SuccessPercent -lt 100 |
            Sort-Object SuccessPercent |
            Select-Object DisplayName, Platform, SuccessPercent, ErrorCount

    .OUTPUTS
        PSCustomObject: Id, DisplayName, Description, Platform, Type, AssignmentCount,
        CreatedDateTime, LastModifiedDateTime; with -IncludeStatus also Status, SuccessCount,
        ErrorCount, ConflictCount, NotApplicableCount, PendingCount, SuccessPercent.
        See Get-MsecIntuneConfigurationProfile for Status value semantics.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch] $IncludeStatus,

        [Parameter()]
        [switch] $IncludeSettings
    )

    Assert-MsecSession

    Write-Verbose 'Loading compliance policies (/v1.0/deviceManagement/deviceCompliancePolicies)'
    $path = '/v1.0/deviceManagement/deviceCompliancePolicies?$expand=assignments'
    foreach ($c in (Invoke-MsecGraphRequest -Path $path -All)) {
        $odataType = $c.'@odata.type'
        $typeShort = if ($odataType) { $odataType -replace '^#microsoft\.graph\.', '' } else { $null }

        # Platform derived from the type name, same pattern as classic device configurations.
        $platform = $null
        switch -Wildcard ($typeShort) {
            'windows10*'           { $platform = 'windows10';          break }
            'windows*'             { $platform = 'windows';            break }
            'macOS*'               { $platform = 'macOS';              break }
            'ios*'                 { $platform = 'iOS';                break }
            'androidWorkProfile*'  { $platform = 'androidWorkProfile'; break }
            'androidDeviceOwner*'  { $platform = 'androidDeviceOwner'; break }
            'androidForWork*'      { $platform = 'androidForWork';     break }
            'android*'             { $platform = 'android';            break }
        }

        $assignmentCount = @($c.assignments).Count

        # Free: the list endpoint already returns every setting, so this costs no extra call.
        $check = Get-MsecCompliancePolicyCheck -Policy $c

        $obj = [ordered]@{
            Id              = $c.id
            DisplayName     = $c.displayName
            Description     = $c.description
            Platform        = $platform
            Type            = $typeShort
            AssignmentCount = $assignmentCount
            # The minimum OS version, promoted out of the settings because it is the one
            # compliance setting that turns an inventory into a patch-compliance answer.
            # Empty means the policy does not care what version a device runs.
            OsMinimumVersion = $(if ($c.PSObject.Properties.Name -contains 'osMinimumVersion') { [string] $c.osMinimumVersion } else { $null })
            OsMaximumVersion = $(if ($c.PSObject.Properties.Name -contains 'osMaximumVersion') { [string] $c.osMaximumVersion } else { $null })
            # How many settings actually enforce something. A policy can be assigned, reporting
            # 100% compliant, and be checking nothing at all.
            ConfiguredCheckCount = $check.Count
            ChecksNothing        = ($check.Count -eq 0)
            ConfiguredChecks     = $check.Names
        }

        if ($IncludeStatus) {
            # Skip the per-policy status call when AssignmentCount=0 - the answer is
            # "all zeros / NotDeployed" regardless. Saves an API round-trip per row.
            $status = if ($assignmentCount -gt 0) {
                Get-MsecPolicyStatus -Id $c.id -Source 'CompliancePolicy'
            }
            else { $null }

            # Status rollup - see Get-MsecIntuneConfigurationProfile for the same semantics.
            $obj.Status = if ($assignmentCount -eq 0) {
                'NotDeployed'
            }
            elseif ($null -eq $status.SuccessPercent) {
                'NotReporting'
            }
            elseif ($status.SuccessPercent -eq 100 -and $status.ErrorCount -eq 0 -and $status.ConflictCount -eq 0) {
                'Healthy'
            }
            else {
                'Degraded'
            }
        }

        $obj.CreatedDateTime      = if ($c.createdDateTime)      { [datetime]$c.createdDateTime }      else { $null }
        $obj.LastModifiedDateTime = if ($c.lastModifiedDateTime) { [datetime]$c.lastModifiedDateTime } else { $null }

        if ($IncludeStatus) {
            # NotDeployed / NotReporting -> all counts 0 (see Get-MsecIntuneConfigurationProfile).
            if ($obj.Status -in 'NotDeployed', 'NotReporting') {
                $obj.SuccessCount       = 0
                $obj.ErrorCount         = 0
                $obj.ConflictCount      = 0
                $obj.NotApplicableCount = 0
                $obj.PendingCount       = 0
                $obj.SuccessPercent     = 0
            }
            else {
                $obj.SuccessCount       = $status.SuccessCount
                $obj.ErrorCount         = $status.ErrorCount
                $obj.ConflictCount      = $status.ConflictCount
                $obj.NotApplicableCount = $status.NotApplicableCount
                $obj.PendingCount       = $status.PendingCount
                $obj.SuccessPercent     = $status.SuccessPercent
            }
        }

        if ($IncludeSettings) { $obj.Settings = $check.Settings }

        [PSCustomObject]$obj
    }
}
