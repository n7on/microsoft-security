# Contributing

## Layout

```
msec/
  msec.psd1              manifest - FunctionsToExport is the public surface
  msec.psm1              dot-sources Private/ then Public/, exports Public/ only
  msec.format.ps1xml     table views for types with collection columns
  Public/                one exported command per file, named after the command
  Private/               one helper per file, not exported
  Tests/                 one <Command>.Tests.ps1 per command
  Kql/                   bundled .kql queries, loaded by convention from disk
  Scripts/               bundled VM scripts for Invoke-MsecAzureVMScript
docs/commands/           generated command reference - see Generating documentation
tools/                   Update-MsecHelp.ps1, the docs generator
.github/workflows/       ci.yml (test + help audit), publish.yml (tag -> Gallery)
```

A new command is a file in `Public/`, a matching file in `Tests/`, and a name added to
`FunctionsToExport` in the manifest. `msec.psm1` picks up the file automatically; the
manifest is what makes it visible to a caller, and a test asserts the two agree.

## Running the tests

```powershell
Invoke-Pester -Path ./msec/Tests
```

No tenant, no network, no Azure context is needed - every test mocks
`Invoke-RestMethod` and `Invoke-MsecKeyVaultSign`. If a test needs a session it fabricates
one by assigning `$script:MsecSession` inside `InModuleScope`.

Tests that touch the completion cache redirect it first:

```powershell
$env:MSEC_CACHE_DIR = Join-Path ([System.IO.Path]::GetTempPath()) "msec-test-$([guid]::NewGuid())"
```

That override exists solely so the suite cannot overwrite a developer's warm cache. Set it
in `BeforeAll` and restore it in `AfterAll`.

## Generating documentation

Documentation is generated from comment-based help using
[PlatyPS](https://github.com/PowerShell/platyPS). The markdown in `docs/commands/` is
committed and linked from README.md, so regenerate and commit it in the same change as any
help edit.

```powershell
Install-Module PlatyPS -Scope CurrentUser

./tools/Update-MsecHelp.ps1
```

The script wraps `New-MarkdownHelp` and adds two things the bare one-liner does not:

- It audits the help first and reports any command with no parsed synopsis, no
  description, or no examples - all three of which render as visible placeholders.
- It strips `-ProgressAction` from the generated markdown. That became a common parameter
  in PowerShell 7.4, after PlatyPS 0.14 was last updated, so PlatyPS documents it
  per-command with an unfilled placeholder. It belongs under `[<CommonParameters>]`.

If the script reports unfilled `{{ }}` placeholders afterwards, fix the source help and
run it again - never edit the generated markdown, it is overwritten on the next run.

## Continuous integration

`.github/workflows/ci.yml` runs on every push and pull request to `main`.

- **test** - the Pester suite on `ubuntu-latest`, `windows-latest` and `macos-latest`.
  All three run even when one fails: "broken on Windows only" is the useful signal, and
  `fail-fast` would hide it. The matrix is also what makes the platform badge in README.md
  a measured claim rather than an assertion.
- **help** - `./tools/Update-MsecHelp.ps1 -AuditOnly`, which fails the build on help that
  would render as a placeholder or lose its description.

The suite needs no tenant and no network, but it does need four Az modules **installed**:
`Az.Accounts`, `Az.ResourceGraph`, `Az.Compute` and `Az.OperationalInsights`. Pester's
`Mock` requires the target command to exist, so a missing module fails as
`Could not find Command Get-AzContext` rather than as anything pointing at the real cause.

Note that Pester 5 does not set a non-zero exit code by itself. Both workflows check
`FailedCount` explicitly - without that a red suite reports a green build.

## Releasing a new version

1. Bump `ModuleVersion` in `msec/msec.psd1`.
2. Update `PrivateData.PSData.ReleaseNotes` in the same file.
3. Regenerate the docs if any help changed: `./tools/Update-MsecHelp.ps1`.
4. Commit and push.
5. Tag and push the tag:

   ```bash
   git tag v0.2.0
   git push origin v0.2.0
   ```

The tag triggers `.github/workflows/publish.yml`, which resolves the version from the tag,
runs the tests, validates the manifest, publishes with `Publish-Module -Path ./msec`, and
opens a GitHub release with generated notes.

It needs one repository secret, `PSGALLERY_API_KEY`, from your PowerShell Gallery account's
API keys page. The workflow fails early and explicitly if it is not set.

To rehearse without publishing, run the workflow manually from the Actions tab with
**dryRun** ticked - it does everything except the push, ending in `Publish-Module -WhatIf`.

If you tag without bumping the manifest, the workflow patches the version for that build
and warns. That is deliberate: it lets an urgent release through, but the warning is there
because the committed manifest then no longer describes what is on the Gallery. A Gallery
version cannot be replaced, only superseded, so prefer bumping first.

## Things that will catch you out

**Import the `.psm1`, not the manifest.** The tests do
`Import-Module ./msec/msec.psm1 -Force`, which bypasses `msec.psd1` entirely. Anything the
manifest would do - `FormatsToProcess`, `RequiredModules` - does not happen on that path.
This is why `msec.psm1` loads `msec.format.ps1xml` itself with `Update-FormatData` rather
than relying on a manifest key.

**Mocks are matched most-recently-defined first.** With overlapping `-ParameterFilter`
blocks, define the catch-all first and the specific case last, or the broad mock wins and
your specific one never fires.

**A scriptblock invoked with `&` cannot assign to an outer scalar.** It runs in a child
scope, so `$flag = $true` creates a local and the outer value never changes. Keep mutable
state in a hashtable - `@{ Denied = $false }` - which is a reference. Both
`Get-MsecEntraRoleHolder` and `Get-MsecIntuneConfigurationProfile` do this deliberately.

**A scriptblock passed into `InModuleScope` stays bound to the test file's scope**, so
`Mock` inside it cannot resolve module-private commands. Pass the setup as a *string* and
rebuild it there with `[scriptblock]::Create($text)`.

**`Invoke-RestMethod -Uri` is typed `[System.Uri]`**, so .NET canonicalises the string you
built: `%20` comes back as a literal space while `%27` survives. A mock that matches the
bytes the command sent will never fire. Match
`[uri]::UnescapeDataString([string]$Uri)` instead.

**Never start a line inside comment-based help with `.word`.** PowerShell's help parser
reads it as a help keyword, and an unrecognised one silently truncates the whole block -
`Get-Help` then shows the syntax in place of the synopsis and no description at all. Wrap
the line so a `.kql` or `.docx` never lands at the start.

## Writing commands

**Never match a role, policy or group by display name.** Graph returns Global
Administrator as `Company Administrator` on many tenants, display names are localisable,
and a tenant may rename a role outright. Match `roleTemplateId`. The curated privileged set
lives in `Private/Get-MsecPrivilegedRoleTemplate.ps1` and is the single definition of what
msec calls privileged.

**Collection columns stay arrays.** A joined string forces callers onto
`-like '*name*'`, and substring matching reports `sg-pilot` as a hit for `sg-pilot-ring`.
Flatten for display in `msec.format.ps1xml` instead - the data stays exact, the table
still reads well.

**Distinguish "read it, found nothing" from "could not read it".** A failed call must not
report the same value as a successful one that found zero. `$null` for unmeasured, `0` or
`$false` for measured, and a reason recorded where the command has somewhere to put one.

**An empty result must never be reachable by a typo.** `-Role 'Globl Administrator'`
throws and lists the tenant's roles rather than returning nothing, because zero rows reads
as a clean bill of health.

**Warn once for a global failure, per item for a local one.** A 401 or 403 will be true of
every subsequent call, so it is reported once and the loop gives up. A 500 on one object
says nothing about the next, so it warns per object and carries on.

## Style

Match the file you are editing. Comments explain *why* - the constraint, the failure mode,
the thing that looks like a simplification but is not. Comment-based help carries the
reasoning behind the output shape, not just the parameter list; `.NOTES` is where the
projection and its edge cases are documented.
