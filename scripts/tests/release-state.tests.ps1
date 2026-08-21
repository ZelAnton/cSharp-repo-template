#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
$projectPath = Join-Path $repoRoot 'src/__ProjectName__/__ProjectName__.csproj'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "release-state-tests-$([Guid]::NewGuid().ToString('N'))"
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$python = (Get-Command python3 -CommandType Application -ErrorAction SilentlyContinue) ?? `
    (Get-Command python -CommandType Application -ErrorAction Stop)

function Assert-Equal([object]$expected, [object]$actual, [string]$message) {
    if ($actual -cne $expected) {
        throw "$message`nExpected: <$expected>`nActual:   <$actual>"
    }
}

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) {
        throw $message
    }
}

function Invoke-Git([string]$workingDirectory, [string[]]$arguments) {
    $output = @(& git -C $workingDirectory @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($arguments -join ' ') failed in $workingDirectory.`n$($output -join "`n")"
    }
    return $output
}

function Get-WorkflowPython([string]$workflow, [string]$stepName) {
    $escapedName = [regex]::Escape($stepName)
    $pattern = "(?ms)^      - name: $escapedName\r?\n.*?^          python3 <<'PY'\r?\n(?<code>.*?)^          PY\s*$"
    $match = [regex]::Match($workflow, $pattern)
    Assert-True $match.Success "Could not extract the '$stepName' Python block from release.yml."
    return [regex]::Replace($match.Groups['code'].Value, '(?m)^          ', '')
}

function Get-WorkflowStepBlock([string]$workflow, [string]$stepName) {
    $escapedName = [regex]::Escape($stepName)
    $pattern = "(?ms)^      - name: $escapedName\r?\n(?<block>.*?)(?=^      - name:|\z)"
    $match = [regex]::Match($workflow, $pattern)
    Assert-True $match.Success "Could not extract the '$stepName' step from release.yml."
    return $match.Groups['block'].Value
}

function Invoke-PythonBlock(
    [string]$workingDirectory,
    [string]$scriptName,
    [string]$script,
    [hashtable]$environment,
    [switch]$ExpectFailure
) {
    $scriptPath = Join-Path $workingDirectory $scriptName
    [IO.File]::WriteAllText($scriptPath, "$script`n", $utf8NoBom)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $python.Source
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add($scriptPath)
    foreach ($entry in $environment.GetEnumerator()) {
        $startInfo.Environment[$entry.Key] = $entry.Value
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $output = "$stdout$stderr"

    if ($ExpectFailure) {
        Assert-True ($process.ExitCode -ne 0) "$scriptName should fail closed. Output: $output"
        return $output
    }

    Assert-Equal 0 $process.ExitCode "$scriptName failed. Output: $output"
    return $output
}

function Invoke-ReleaseStateCase(
    [string]$name,
    [string]$version,
    [string]$tag,
    [string]$previousTag
) {
    $caseRoot = Join-Path $tempRoot $name
    [IO.Directory]::CreateDirectory($caseRoot) | Out-Null
    $changelogPath = Join-Path $caseRoot 'CHANGELOG.md'
    $source = @"
# Changelog

## [Unreleased]

### Added
- Add one release-state source

### Changed
-

### Fixed
- Fix packed changelog drift

[Unreleased]: https://github.com/__GitHubOwner__/__ProjectName__/commits/main
"@.Replace("`r`n", "`n")
    [IO.File]::WriteAllText($changelogPath, $source, $utf8NoBom)

    [void](Invoke-PythonBlock `
        -WorkingDirectory $caseRoot `
        -ScriptName 'promote.py' `
        -Script $promoteScript `
        -Environment @{ VERSION = $version; TAG = $tag; PREV_TAG = $previousTag })

    $releaseState = [IO.File]::ReadAllText($changelogPath).Replace("`r`n", "`n")
    Assert-True $releaseState.Contains("## [$version] - ") "$name did not create the versioned release section."
    Assert-True $releaseState.Contains("[Unreleased]: https://github.com/__GitHubOwner__/__ProjectName__/compare/$tag...HEAD") "$name did not advance the Unreleased comparison link."
    Assert-True $releaseState.Contains("[$version]: https://github.com/__GitHubOwner__/__ProjectName__/compare/$previousTag...$tag") "$name did not create the release comparison link."

    [void](Invoke-PythonBlock `
        -WorkingDirectory $caseRoot `
        -ScriptName 'extract.py' `
        -Script $extractScript `
        -Environment @{ VERSION = $version })

    $afterExtraction = [IO.File]::ReadAllText($changelogPath).Replace("`r`n", "`n")
    Assert-Equal $releaseState $afterExtraction "$name changed the release-state changelog while extracting notes."
    $notes = [IO.File]::ReadAllText((Join-Path $caseRoot 'release-notes.md')).Replace("`r`n", "`n")
    $expectedNotes = "### Added`n- Add one release-state source`n`n### Fixed`n- Fix packed changelog drift`n"
    Assert-Equal $expectedNotes $notes "$name release notes do not match the versioned changelog content."
    Assert-True $releaseState.Contains("### Added`n- Add one release-state source") "$name Added note is not present in the release-state changelog."
    Assert-True $releaseState.Contains("### Fixed`n- Fix packed changelog drift") "$name Fixed note is not present in the release-state changelog."
    Write-Host "PASS $name"
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $workflow = [IO.File]::ReadAllText($workflowPath)
    $project = [IO.File]::ReadAllText($projectPath)
    $promoteScript = Get-WorkflowPython $workflow 'Promote Unreleased section in CHANGELOG.md'
    $extractScript = Get-WorkflowPython $workflow 'Extract release notes from release section'
    $recoveryStep = Get-WorkflowStepBlock $workflow 'Preserve exact post-pivot recovery state'

    $steps = [ordered]@{
        bump = '      - name: Bump version in csproj'
        promote = '      - name: Promote Unreleased section in CHANGELOG.md'
        extract = '      - name: Extract release notes from release section'
        restore = '      - name: Restore'
        build = '      - name: Build'
        test = '      - name: Test'
        pack = '      - name: Pack'
        checksums = '      - name: Generate SHA256SUMS'
        commit = '      - name: Commit and tag the release (local only)'
        bundle = '      - name: Create local release recovery bundle'
        publish = '      - name: Push to NuGet.org (irreversible pivot)'
        push = '      - name: Push the release commit + tag (atomic)'
        release = '      - name: Create or update the GitHub Release (idempotent)'
        recovery = '      - name: Preserve exact post-pivot recovery state'
    }
    $previousIndex = -1
    foreach ($entry in $steps.GetEnumerator()) {
        $index = $workflow.IndexOf($entry.Value, [StringComparison]::Ordinal)
        Assert-True ($index -ge 0) "Missing release step '$($entry.Key)'."
        Assert-True ($index -gt $previousIndex) "Release step '$($entry.Key)' is out of order."
        $previousIndex = $index
    }

    Assert-Equal 1 ([regex]::Matches($workflow, '(?m)^      - name: Promote Unreleased section in CHANGELOG\.md$').Count) 'The workflow must promote the changelog exactly once.'
    Assert-True $workflow.Contains('dotnet pack src/__ProjectName__/__ProjectName__.csproj --no-build --configuration Release --output ./artifacts /p:Version=${{ steps.version.outputs.version }}') 'Pack no longer uses the computed release version.'
    Assert-True $project.Contains('<None Include="$(RepoRoot)CHANGELOG.md" Pack="true" PackagePath="\" />') 'The package no longer includes the root release-state CHANGELOG.md.'
    Assert-True $project.Contains('<PackageReleaseNotes Condition="Exists(''$(RepoRoot)release-notes.md'')">$([System.IO.File]::ReadAllText(''$(RepoRoot)release-notes.md''))</PackageReleaseNotes>') 'The package no longer consumes the extracted release notes.'
    Assert-True $workflow.Contains('git add src/__ProjectName__/__ProjectName__.csproj CHANGELOG.md') 'The local release commit no longer records both release-state inputs.'
    Assert-True $workflow.Contains('git bundle create ./artifacts/release-recovery.bundle HEAD "$TAG"') 'The workflow no longer preserves the exact local release commit and tag for recovery.'
    Assert-True $workflow.Contains('id: nuget_publish') 'The NuGet pivot no longer exposes its outcome to the recovery guard.'
    Assert-True $recoveryStep.Contains('if: ${{ failure() && steps.nuget_publish.outcome == ''success'' }}') 'Recovery state is not restricted to failures after a successful NuGet publish.'
    Assert-True $recoveryStep.Contains('artifacts/release-recovery.bundle') 'The recovery artifact no longer contains the local release commit and tag.'
    Assert-True $recoveryStep.Contains('artifacts/*.nupkg') 'The recovery artifact no longer contains the exact published package.'
    Assert-True $recoveryStep.Contains('artifacts/*.snupkg') 'The recovery artifact no longer contains the exact symbol package.'
    Assert-True $recoveryStep.Contains('artifacts/SHA256SUMS') 'The recovery artifact no longer contains the package checksums.'
    Assert-True $recoveryStep.Contains('release-notes.md') 'The recovery artifact no longer contains the exact release notes.'

    Invoke-ReleaseStateCase `
        -Name 'first-release' `
        -Version '0.1.0' `
        -Tag 'v0.1.0' `
        -PreviousTag 'v0.0.0'
    Invoke-ReleaseStateCase `
        -Name 'subsequent-release' `
        -Version '1.2.4' `
        -Tag 'v1.2.4' `
        -PreviousTag 'v1.2.3'

    $missingCase = Join-Path $tempRoot 'missing-release-section'
    [IO.Directory]::CreateDirectory($missingCase) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $missingCase 'CHANGELOG.md'),
        "# Changelog`n`n## [Unreleased]`n`n### Added`n- Add pending behavior`n",
        $utf8NoBom)
    $failure = Invoke-PythonBlock `
        -WorkingDirectory $missingCase `
        -ScriptName 'extract-missing.py' `
        -Script $extractScript `
        -Environment @{ VERSION = '9.9.9' } `
        -ExpectFailure
    Assert-True $failure.Contains('Release section [9.9.9] in CHANGELOG.md is missing or empty.') 'Missing versioned release section did not produce the expected fail-closed diagnostic.'
    Write-Host 'PASS missing-release-section'

    $bundleRoot = Join-Path $tempRoot 'recovery-bundle'
    [IO.Directory]::CreateDirectory((Join-Path $bundleRoot 'artifacts')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $bundleRoot 'payload.txt'), "release state`n", $utf8NoBom)
    [void](Invoke-Git $bundleRoot @('init', '--initial-branch=main'))
    [void](Invoke-Git $bundleRoot @('config', 'user.name', 'Release Test'))
    [void](Invoke-Git $bundleRoot @('config', 'user.email', 'release-test@example.invalid'))
    [void](Invoke-Git $bundleRoot @('add', 'payload.txt'))
    [void](Invoke-Git $bundleRoot @('commit', '-m', 'Release v1.2.4'))
    [void](Invoke-Git $bundleRoot @('tag', 'v1.2.4'))
    [void](Invoke-Git $bundleRoot @('bundle', 'create', './artifacts/release-recovery.bundle', 'HEAD', 'v1.2.4'))
    [void](Invoke-Git $bundleRoot @('bundle', 'verify', './artifacts/release-recovery.bundle'))
    [void](Invoke-Git $bundleRoot @('clone', './artifacts/release-recovery.bundle', 'recovered'))
    $releaseCommit = @(Invoke-Git $bundleRoot @('rev-parse', 'v1.2.4^{}'))[-1]
    $recoveredCommit = @(Invoke-Git (Join-Path $bundleRoot 'recovered') @('rev-parse', 'HEAD'))[-1]
    Assert-Equal $releaseCommit $recoveredCommit 'The recovery bundle clone did not restore the exact release commit.'
    Assert-Equal 'v1.2.4' (@(Invoke-Git (Join-Path $bundleRoot 'recovered') @('tag', '--points-at', 'HEAD'))[-1]) 'The recovery bundle clone did not restore the release tag.'
    Write-Host 'PASS recovery-bundle'

    Write-Host 'All release-state regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
