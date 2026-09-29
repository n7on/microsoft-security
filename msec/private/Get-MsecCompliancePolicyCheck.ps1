function Get-MsecCompliancePolicyCheck {
    <#
    .SYNOPSIS
        Works out which compliance settings on a policy are actually enforcing something.

    .DESCRIPTION
        A compliance policy that checks NOTHING is indistinguishable from a healthy one by name,
        platform and assignment count - it reports every device as compliant, because there is
        nothing to fail. Measured live: a macOS baseline assigned to all licensed users since
        2021 had osMinimumVersion empty and password, encryption, firewall and system-integrity
        all False. Every device passed.

        DECIDING "CONFIGURED" IS A JUDGEMENT, SO IT IS WRITTEN DOWN RATHER THAN GUESSED AT:

          Boolean  - configured only when $true. False means "not required", not "required to be
                     false"; there is no compliance setting that enforces the absence of a
                     control.
          String   - configured when non-empty AND not a do-nothing sentinel. Graph uses
                     'deviceDefault' and 'unavailable' to mean "leave it alone" - measured, those
                     two account for nine of the fourteen string values across one tenant's
                     policies.
          Numeric  - configured when non-null and non-zero. A zero threshold (minimum length 0,
                     previous-passwords-blocked 0) enforces nothing.

        It is DELIBERATELY GENERIC rather than a per-platform list of known settings. Microsoft
        adds compliance settings regularly, and an allowlist would silently stop counting them -
        under-reporting on a control question is the failure mode this whole function exists to
        prevent.

    .PARAMETER Policy
        The raw compliance policy object from Graph.

    .OUTPUTS
        Hashtable: Names (configured setting names), Count, and Settings (every setting and its
        value, metadata removed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Policy
    )

    # Not settings: identity, timestamps, and the action rules that say what happens AFTER a
    # device fails - none of them decide whether anything is checked.
    $metadata = @(
        'id', 'displayName', 'description', 'version', 'createdDateTime', 'lastModifiedDateTime',
        'roleScopeTagIds', 'assignments', 'scheduledActionsForRule', 'deviceCompliancePolicyScript'
    )

    # Graph's "leave this alone" values. Present and meaning nothing.
    $inert = @('deviceDefault', 'unavailable', 'notConfigured', 'userDefined')

    $settings = [ordered]@{}
    $configured = @()

    foreach ($property in $Policy.PSObject.Properties) {
        $name = $property.Name
        if ($name -in $metadata -or $name -like '*@odata*') { continue }

        $value = $property.Value
        $settings[$name] = $value

        $isConfigured = if ($null -eq $value) { $false }
                        elseif ($value -is [bool]) { $value }
                        elseif ($value -is [string]) { $value -and $value -notin $inert }
                        elseif ($value -is [array]) { @($value).Count -gt 0 }
                        else {
                            # Numeric: a zero threshold enforces nothing.
                            try { [double] $value -ne 0 } catch { $true }
                        }

        if ($isConfigured) { $configured += $name }
    }

    @{
        Names    = $configured
        Count    = $configured.Count
        Settings = $settings
    }
}
