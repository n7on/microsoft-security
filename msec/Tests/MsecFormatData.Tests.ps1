#Requires -Module Pester
#
# Tests for msec.format.ps1xml. A malformed or unloaded format file does not fail loudly -
# it silently falls back to the default rendering, which is exactly the '{a, b}' output the
# file exists to fix. So the checks here are that it is registered at all, that it renders
# collections flattened, and - most importantly - that flattening the DISPLAY did not
# flatten the DATA, because the arrays are what make -contains an exact test.

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'msec.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop
    $script:FormatFile = (Resolve-Path (Join-Path $PSScriptRoot '..' 'msec.format.ps1xml')).Path
}

AfterAll {
    Remove-Module msec -Force -ErrorAction SilentlyContinue
}

Describe 'msec format data' {

    It 'is well-formed XML' {
        # A parse error takes out every table in the session, not just this view.
        { [xml](Get-Content -Raw -LiteralPath $script:FormatFile) } | Should -Not -Throw
    }

    It 'is registered by importing the module directly, not only via the manifest' {
        # The suite imports msec.psm1, so a FormatsToProcess key in msec.psd1 would be
        # skipped and these views would not apply where they are verified.
        $view = Get-FormatData -TypeName 'MsecIntuneConfigurationProfile' -ErrorAction SilentlyContinue
        $view | Should -Not -BeNullOrEmpty
        $view.FormatViewDefinition.Control | Should -Not -BeNullOrEmpty
    }

    It 'renders collection columns flattened, with no PowerShell collection braces' {
        $row = [PSCustomObject]@{
            PSTypeName              = 'MsecIntuneConfigurationProfile'
            DisplayName             = 'Ring Rollout'
            Source                  = 'SettingsCatalog'
            Platform                = 'windows10'
            AssignmentCount         = 2
            AssignmentType          = @('Group')
            AssignmentGroup         = @('sg-pilot-ring', 'sg-broad-ring')
            AssignmentExcludedGroup = @()
            HasAssignmentFilter     = $false
            AssignmentDetail        = @()
            Raw                     = $null
        }

        $text = $row | Format-Table | Out-String -Width 200

        $text | Should -Match 'sg-pilot-ring, sg-broad-ring'
        # The literal that started all this.
        $text | Should -Not -Match '\{sg-pilot-ring'
        $text | Should -Not -Match '\{Group\}'
    }

    It 'shows an exclusion-only assignment instead of leaving the group cell empty' {
        # An empty group cell beside an AssignmentType of 'ExclusionGroup' reads as a bug
        # rather than as "the only group here is a carve-out".
        $row = [PSCustomObject]@{
            PSTypeName              = 'MsecIntuneConfigurationProfile'
            DisplayName             = 'BitLocker'
            Source                  = 'SettingsCatalog'
            Platform                = 'windows10'
            AssignmentCount         = 2
            AssignmentType          = @('AllDevices', 'ExclusionGroup')
            AssignmentGroup         = @()
            AssignmentExcludedGroup = @('sg-executives')
            HasAssignmentFilter     = $false
            AssignmentDetail        = @()
            Raw                     = $null
        }

        $text = $row | Format-Table | Out-String -Width 200
        $text | Should -Match 'AllDevices, ExclusionGroup'
        $text | Should -Match 'excluding sg-executives'
    }

    It 'shows included and excluded groups together when a policy has both' {
        $row = [PSCustomObject]@{
            PSTypeName              = 'MsecIntuneConfigurationProfile'
            DisplayName             = 'Mixed'
            Source                  = 'SettingsCatalog'
            Platform                = 'windows10'
            AssignmentCount         = 2
            AssignmentType          = @('Group', 'ExclusionGroup')
            AssignmentGroup         = @('sg-pilot')
            AssignmentExcludedGroup = @('sg-vips')
            HasAssignmentFilter     = $false
            AssignmentDetail        = @()
            Raw                     = $null
        }

        ($row | Format-Table | Out-String -Width 200) | Should -Match 'sg-pilot, excluding sg-vips'
    }

    It 'leaves the DATA as arrays - the display is flattened, the property is not' {
        # The whole justification for a format file rather than joining at the source.
        # -contains is exact; -like on a joined string would report 'sg-pilot' as a hit
        # for 'sg-pilot-ring'.
        $row = [PSCustomObject]@{
            PSTypeName              = 'MsecIntuneConfigurationProfile'
            DisplayName             = 'Ring Rollout'
            AssignmentType          = @('Group')
            AssignmentGroup         = @('sg-pilot-ring', 'sg-broad-ring')
            AssignmentExcludedGroup = @()
        }

        $row.AssignmentGroup.Count        | Should -Be 2
        $row.AssignmentGroup -is [array]  | Should -BeTrue
        $row.AssignmentGroup -contains 'sg-pilot-ring' | Should -BeTrue
        $row.AssignmentGroup -contains 'sg-pilot'      | Should -BeFalse
        # And Format-Table must not have mutated the object it rendered.
        $row | Format-Table | Out-String | Out-Null
        $row.AssignmentGroup -is [array]  | Should -BeTrue
    }

    It 'ships the format file alongside the module so an installed copy gets it too' {
        # Update-FormatData resolves it relative to $PSScriptRoot, so it has to travel
        # with the module rather than being found on a dev machine only.
        Join-Path (Get-Module msec).ModuleBase 'msec.format.ps1xml' |
            Should -Exist
    }
}
