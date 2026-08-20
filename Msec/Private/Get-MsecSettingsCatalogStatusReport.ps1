function Get-MsecSettingsCatalogStatusReport {
    <#
    .SYNOPSIS
        Returns a hashtable keyed by PolicyId with device check-in status counts for ALL
        Settings Catalog configuration policies in the tenant, via the Intune Reports API.

    .DESCRIPTION
        Settings Catalog policies don't expose per-policy device status via a navigation
        property the way Templates and Compliance policies do. The Intune portal sources
        this data via the Reports API asynchronously.

        This function:
          1. POSTs to /beta/deviceManagement/reports/exportJobs with
             reportName=ConfigurationPolicyAggregate, format=json.
          2. Polls /reports/exportJobs('{id}') every $PollIntervalSeconds until
             status='completed' (typically 5-15s).
          3. Downloads the result zip from the presigned blob URL in job.url. No auth
             header is required for that URL - the SAS signature embedded in the URL
             grants short-lived access.
          4. Unzips and parses the single JSON file inside.
          5. Returns a hashtable keyed by PolicyId with SuccessCount / ErrorCount /
             ConflictCount / NotApplicableCount / PendingCount.

        Required Graph permission: DeviceManagementConfiguration.Read.All (the same
        permission already needed by Get-MsecIntuneConfigurationProfile).

    .PARAMETER TimeoutSeconds
        Maximum time to wait for the report job to complete. Default 120.

    .PARAMETER PollIntervalSeconds
        How often to poll job status. Default 2.

    .OUTPUTS
        Hashtable keyed by PolicyId (string), values are PSCustomObjects with
        SuccessCount / ErrorCount / ConflictCount / NotApplicableCount / PendingCount.
        Returns an empty hashtable on timeout or download failure (and writes a warning).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [int] $TimeoutSeconds = 120,

        [Parameter()]
        [int] $PollIntervalSeconds = 2
    )

    Assert-MsecSession

    Write-Verbose 'Creating Intune Reports exportJob (ConfigurationPolicyAggregate)'
    $job = Invoke-MsecGraphRequest -Method POST `
        -Path '/beta/deviceManagement/reports/exportJobs' `
        -Body @{ reportName = 'ConfigurationPolicyAggregate'; format = 'json' }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($job.status -ne 'completed' -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $job = Invoke-MsecGraphRequest -Path "/beta/deviceManagement/reports/exportJobs('$($job.id)')"
        Write-Verbose "  exportJob status=$($job.status)"
    }
    if ($job.status -ne 'completed') {
        Write-Warning "Intune Reports exportJob did not complete in ${TimeoutSeconds}s (last status: $($job.status))."
        return @{}
    }

    $tmpZip = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName() + '.zip')
    $tmpDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
    try {
        # The presigned URL has its own SAS - don't add our bearer token (would 400).
        Invoke-WebRequest -Uri $job.url -OutFile $tmpZip -ErrorAction Stop | Out-Null
        New-Item -ItemType Directory -Path $tmpDir | Out-Null
        Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -ErrorAction Stop

        $jsonFile = Get-ChildItem $tmpDir -Filter '*.json' -Recurse | Select-Object -First 1
        if (-not $jsonFile) {
            Write-Warning 'Reports export zip did not contain a JSON file.'
            return @{}
        }
        $data = Get-Content -LiteralPath $jsonFile.FullName -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Failed to download / parse Reports export: $_"
        return @{}
    }
    finally {
        if (Test-Path -LiteralPath $tmpZip) { Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # The downloaded JSON has shape { columns: [...], values: [ {col=val,...}, ... ] }.
    # Each entry in values is already a hydrated object - we don't need to index by columns.
    $byId = @{}
    foreach ($v in @($data.values)) {
        if (-not $v.PolicyId) { continue }
        $byId[$v.PolicyId] = [PSCustomObject]@{
            # Mapping notes:
            # - SC reports "Compliant" rather than "Success"; treat as the success bucket.
            # - SC reports "NonCompliant" for devices that haven't applied yet OR are out
            #   of state; closest equivalent in our schema is PendingCount.
            SuccessCount       = [int]$v.NumberOfCompliantDevices
            ErrorCount         = [int]$v.NumberOfErrorDevices
            ConflictCount      = [int]$v.NumberOfConflictDevices
            NotApplicableCount = [int]$v.NumberOfNotApplicableDevices
            PendingCount       = [int]$v.NumberOfNonCompliantDevices
        }
    }
    $byId
}
