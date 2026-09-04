function ConvertTo-MsecDeviceOsRelease {
    <#
    .SYNOPSIS
        Turns a device's operating system and version into a stable RELEASE label -
        'Windows 11', 'iOS 17', 'macOS 14' - suitable for a column that persists across runs.

    .DESCRIPTION
        A posture sheet grows a column per distinct value, so the raw version is unusable:
        '10.0.22631.3155' becomes a different column on every patch Tuesday, the sheet reshapes
        every run, and the chart turns into a hundred one-point series. The major release is
        both stable enough to trend and the granularity the security question is actually
        asked at - "are we still running Windows 10" rather than "which build".

        WINDOWS 11 REPORTS ITSELF AS 10.0. The marketing name and the version number diverged
        at Windows 11, so the only thing separating them is the BUILD: 22000 and above is
        Windows 11, below it is Windows 10. Splitting on the version string alone - the obvious
        implementation - files every Windows 11 device as Windows 10, which is exactly backwards
        for the question people ask this to answer.

        WINDOWS SERVER CANNOT BE TOLD APART HERE, and is not guessed at. Server 2019 and
        Windows 10 1809 are both build 17763; Server 2022 is 20348, below the Windows 11 line.
        Intune's operatingSystem says 'Windows' for both, so a server would be labelled as a
        client. Intune-managed estates are overwhelmingly client devices, so this is a small
        error - but it is a real one, and pretending a build number resolves it would be worse.

        A missing version is labelled rather than dropped: a device Intune could not report a
        version for is still a device, and losing it would quietly shrink the total.

    .PARAMETER Os
        The device's operating system family - Intune's operatingSystem.

    .PARAMETER Version
        The device's version string - Intune's osVersion.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Os,
        [Parameter()] [AllowNull()] [AllowEmptyString()] [string] $Version
    )

    $family = if ([string]::IsNullOrWhiteSpace($Os)) { 'Unknown' } else { $Os.Trim() }
    if ([string]::IsNullOrWhiteSpace($Version)) { return "$family (unknown version)" }

    $parts = $Version.Trim().Split('.')

    if ($family -match '^Windows') {
        if ($Version -match '^10\.0(\.|$)') {
            $build = 0
            if ($parts.Count -ge 3 -and [int]::TryParse($parts[2], [ref] $build) -and $build -gt 0) {
                # See .DESCRIPTION: the build is the ONLY thing separating 10 from 11.
                return $(if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' })
            }
            # '10.0' with no build says which of the two it is not.
            return 'Windows 10/11 (unknown build)'
        }

        # Pre-10 Windows, rare under Intune. major.minor is the release there (6.1 = 7,
        # 6.3 = 8.1), and reporting it raw is honest rather than mapping a guess.
        $minor = if ($parts.Count -gt 1) { $parts[1] } else { '0' }
        return "Windows $($parts[0]).$minor"
    }

    # Everything else names its releases by major version: iOS 17, macOS 14, Android 14.
    return "$family $($parts[0])"
}
