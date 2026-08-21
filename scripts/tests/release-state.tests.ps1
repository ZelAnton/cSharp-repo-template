#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
$projectPath = Join-Path $repoRoot 'src/__ProjectName__/__ProjectName__.csproj'
$agentsPath = Join-Path $repoRoot 'AGENTS.md'
$claudePath = Join-Path $repoRoot 'CLAUDE.md'
$templatePath = Join-Path $repoRoot 'TEMPLATE.md'
$changelogGuidancePath = Join-Path $repoRoot 'CHANGELOG.md'
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

function Assert-False([bool]$condition, [string]$message) {
    if ($condition) {
        throw $message
    }
}

function Assert-BytesEqual([byte[]]$expected, [byte[]]$actual, [string]$message) {
    Assert-Equal $expected.Length $actual.Length "$message Byte lengths differ."
    for ($index = 0; $index -lt $expected.Length; $index++) {
        if ($actual[$index] -ne $expected[$index]) {
            throw "$message First differing byte: $index."
        }
    }
}

function Invoke-Git([string]$workingDirectory, [string[]]$arguments) {
    $output = @(& git -C $workingDirectory @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($arguments -join ' ') failed in $workingDirectory.`n$($output -join "`n")"
    }
    return $output
}

function Invoke-Dotnet([string]$workingDirectory, [string[]]$arguments) {
    $previousLocation = Get-Location
    try {
        Set-Location -LiteralPath $workingDirectory
        $output = @(& dotnet @arguments 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet $($arguments -join ' ') failed in $workingDirectory.`n$($output -join "`n")"
        }
        return $output
    }
    finally {
        Set-Location -LiteralPath $previousLocation
    }
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
    [string]$prelude = '',
    [switch]$ExpectFailure
) {
    $scriptPath = Join-Path $workingDirectory $scriptName
    [IO.File]::WriteAllText($scriptPath, "$prelude$script`n", $utf8NoBom)

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

function Read-GitHubOutputs([string]$path) {
    $outputs = @{}
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $parts = $line.Split('=', 2)
        $outputs[$parts[0]] = $parts[1]
    }
    return $outputs
}

function Assert-RecoveryGuard(
    [string]$jobOutcome,
    [hashtable]$publishOutputs,
    [string]$markerPath,
    [bool]$expected,
    [string]$message
) {
    $terminalFailure = $jobOutcome -in @('failure', 'cancelled')
    $recoveryRequired = $publishOutputs['recovery_required'] -ceq 'true' -or `
        (Test-Path -LiteralPath $markerPath -PathType Leaf)
    Assert-Equal $expected ($terminalFailure -and $recoveryRequired) $message
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

    return [pscustomobject]@{
        Root = $caseRoot
        Changelog = $releaseState
        Notes = $notes
        ExpectedNotes = $expectedNotes
    }
}

function Test-PackedReleaseState([pscustomobject]$releaseCase, [string]$version, [string]$tag) {
    $caseRoot = $releaseCase.Root
    [IO.File]::WriteAllText((Join-Path $caseRoot 'README.md'), "# Package identity test`n", $utf8NoBom)
    [void](Invoke-Git $caseRoot @('init', '--initial-branch=main'))
    [void](Invoke-Git $caseRoot @('config', 'user.name', 'Release Test'))
    [void](Invoke-Git $caseRoot @('config', 'user.email', 'release-test@example.invalid'))
    [void](Invoke-Git $caseRoot @('add', 'CHANGELOG.md', 'README.md'))
    [void](Invoke-Git $caseRoot @('commit', '-m', "Release $tag"))
    [void](Invoke-Git $caseRoot @('tag', $tag))

    $workingChangelogObject = @(Invoke-Git $caseRoot @('hash-object', 'CHANGELOG.md'))[-1]
    $taggedChangelogObject = @(Invoke-Git $caseRoot @('rev-parse', "${tag}:CHANGELOG.md"))[-1]
    Assert-Equal $taggedChangelogObject $workingChangelogObject 'The pack input CHANGELOG.md does not match the tagged release state.'

    $artifactRoot = Join-Path $caseRoot 'artifacts'
    [IO.Directory]::CreateDirectory($artifactRoot) | Out-Null
    $packRepoRoot = "$caseRoot$([IO.Path]::DirectorySeparatorChar)"
    [void](Invoke-Dotnet $repoRoot @(
        'pack',
        $projectPath,
        '--configuration', 'Release',
        '--output', $artifactRoot,
        "/p:Version=$version",
        "/p:RepoRoot=$packRepoRoot"
    ))

    $packages = @(Get-ChildItem -LiteralPath $artifactRoot -Filter '*.nupkg' -File |
        Where-Object { -not $_.Name.EndsWith('.snupkg', [StringComparison]::OrdinalIgnoreCase) })
    Assert-Equal 1 $packages.Count 'The pack regression must produce exactly one .nupkg.'

    $archive = [IO.Compression.ZipFile]::OpenRead($packages[0].FullName)
    try {
        $changelogEntry = $archive.Entries | Where-Object { $_.FullName -ceq 'CHANGELOG.md' }
        Assert-True ($null -ne $changelogEntry) 'The packed artifact does not contain root CHANGELOG.md.'
        $changelogStream = $changelogEntry.Open()
        try {
            $memory = [IO.MemoryStream]::new()
            $changelogStream.CopyTo($memory)
            $packedChangelog = $memory.ToArray()
        }
        finally {
            $changelogStream.Dispose()
        }
        Assert-BytesEqual ([IO.File]::ReadAllBytes((Join-Path $caseRoot 'CHANGELOG.md'))) $packedChangelog 'Packed CHANGELOG.md differs from the tagged release state.'

        $nuspecEntry = $archive.Entries | Where-Object { $_.FullName.EndsWith('.nuspec', [StringComparison]::OrdinalIgnoreCase) }
        Assert-True ($null -ne $nuspecEntry) 'The packed artifact does not contain a nuspec.'
        $nuspecStream = $nuspecEntry.Open()
        try {
            $nuspec = [xml]::new()
            $nuspec.Load($nuspecStream)
        }
        finally {
            $nuspecStream.Dispose()
        }
        $releaseNotesNode = $nuspec.SelectSingleNode('/*[local-name()="package"]/*[local-name()="metadata"]/*[local-name()="releaseNotes"]')
        Assert-True ($null -ne $releaseNotesNode) 'The packed nuspec does not contain release notes.'
        $packedNotes = $releaseNotesNode.InnerText.Replace("`r`n", "`n").TrimEnd("`r", "`n")
        $expectedNotes = $releaseCase.ExpectedNotes.TrimEnd("`r", "`n")
        $extractedNotes = $releaseCase.Notes.TrimEnd("`r", "`n")
        Assert-Equal $expectedNotes $packedNotes 'Packed release notes differ from the versioned changelog section.'
        Assert-Equal $extractedNotes $packedNotes 'Packed release notes differ from the exact notes derived for this tag.'
    }
    finally {
        $archive.Dispose()
    }

    Write-Host 'PASS packed-release-state'
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $workflow = [IO.File]::ReadAllText($workflowPath)
    $project = [IO.File]::ReadAllText($projectPath)
    $agents = [IO.File]::ReadAllText($agentsPath)
    $claude = [IO.File]::ReadAllText($claudePath)
    $template = [IO.File]::ReadAllText($templatePath)
    $changelogGuidance = [IO.File]::ReadAllText($changelogGuidancePath)
    $promoteScript = Get-WorkflowPython $workflow 'Promote Unreleased section in CHANGELOG.md'
    $extractScript = Get-WorkflowPython $workflow 'Extract release notes from release section'
    $publishScript = Get-WorkflowPython $workflow 'Push to NuGet.org (irreversible pivot)'
    $publishStep = Get-WorkflowStepBlock $workflow 'Push to NuGet.org (irreversible pivot)'
    $pushStep = Get-WorkflowStepBlock $workflow 'Push the release commit + tag (atomic)'
    $releaseStep = Get-WorkflowStepBlock $workflow 'Create or update the GitHub Release (idempotent)'
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
    Assert-False $publishStep.Contains('continue-on-error: true') 'An ambiguous NuGet outcome must stop VCS and GitHub Release publication.'
    Assert-True $publishScript.Contains('write_output("acceptance", "not-attempted")') 'The NuGet pivot no longer distinguishes a skipped attempt from an ambiguous response.'
    Assert-True $publishScript.Contains('write_output("acceptance", "ambiguous")') 'The NuGet pivot no longer fails safe before its first network attempt.'
    Assert-True $publishScript.Contains('write_output("acceptance", "accepted")') 'The NuGet pivot no longer records confirmed client success.'
    Assert-True $publishScript.Contains('write_output("acceptance", "rejected")') 'The NuGet pivot no longer records a confirmed terminal rejection.'
    Assert-True $publishScript.Contains('write_output("acceptance", "pre-existing")') 'The NuGet pivot no longer distinguishes a first-attempt duplicate from this run''s accepted package.'
    Assert-True $publishScript.Contains('if attempt > 1:') 'Duplicate idempotence is no longer limited to retries after this process has attempted the package.'
    Assert-True $publishScript.Contains('timeout=300') 'The NuGet client attempt is no longer bounded before the job-level timeout.'
    Assert-True $publishScript.Contains('"./artifacts/*.nupkg"') 'The NuGet pivot no longer publishes the main package explicitly.'
    Assert-True $publishScript.Contains('"./artifacts/*.snupkg"') 'The NuGet pivot no longer publishes the symbol package explicitly.'
    Assert-True $publishScript.Contains('"--no-symbols"') 'The main-package acceptance decision is no longer isolated from symbol publication.'
    Assert-True $recoveryStep.Contains('always() && (failure() || cancelled()) &&') 'The recovery upload no longer covers both failed and cancelled NuGet client steps.'
    Assert-True $recoveryStep.Contains('steps.nuget_publish.outputs.recovery_required == ''true''') 'The recovery upload is not guarded by the publish attempt state.'
    Assert-True $recoveryStep.Contains('hashFiles(''artifacts/.nuget-recovery-required'') != ''''') 'The recovery upload no longer has a cancellation-safe local marker guard.'
    Assert-False ([regex]::IsMatch($pushStep, '(?m)^        if:')) 'The VCS push must retain the default success guard after the NuGet pivot.'
    Assert-False ([regex]::IsMatch($releaseStep, '(?m)^        if:')) 'The GitHub Release must retain the default success guard after the NuGet pivot.'
    Assert-True $recoveryStep.Contains('artifacts/release-recovery.bundle') 'The recovery artifact no longer contains the local release commit and tag.'
    Assert-True $recoveryStep.Contains('artifacts/*.nupkg') 'The recovery artifact no longer contains the exact published package.'
    Assert-True $recoveryStep.Contains('artifacts/*.snupkg') 'The recovery artifact no longer contains the exact symbol package.'
    Assert-True $recoveryStep.Contains('artifacts/SHA256SUMS') 'The recovery artifact no longer contains the package checksums.'
    Assert-True $recoveryStep.Contains('release-notes.md') 'The recovery artifact no longer contains the exact release notes.'
    $allGuidance = "$workflow`n$agents`n$claude`n$template`n$changelogGuidance"
    Assert-False ([regex]::IsMatch($allGuidance, 'A failure after the pivot is recoverable\s+by re-run', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) 'Shipped guidance still permits rebuilding after the publish pivot.'
    Assert-False ([regex]::IsMatch($allGuidance, 'after the publish but before the tag is pushed is also safe to re-run', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) 'Shipped guidance still permits rebuilding after publish when the tag push failed.'
    Assert-False ([regex]::IsMatch($allGuidance, 'failure (?:before or at|up to and including) the publish[^\n]*safe to re-run', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) 'Shipped guidance still treats every publish-step failure as safe to rerun without checking acceptance.'
    Assert-False ([regex]::IsMatch($allGuidance, 'NuGet push failed[^\n]*safe to re-run', [Text.RegularExpressions.RegexOptions]::IgnoreCase)) 'Publish failure guidance must require confirming that NuGet did not accept the package.'
    foreach ($guidance in @($agents, $claude, $template)) {
        Assert-True $guidance.Contains('release-recovery-vX.Y.Z') 'Shipped release guidance must direct post-pivot recovery to the immutable recovery artifact.'
    }
    Assert-True $workflow.Contains('Once NuGet accepts the package,') 'The workflow header must prohibit rebuilding as soon as the package is accepted.'

    $rejectedCase = Join-Path $tempRoot 'confirmed-rejection'
    [IO.Directory]::CreateDirectory((Join-Path $rejectedCase 'artifacts')) | Out-Null
    $rejectedOutputPath = Join-Path $rejectedCase 'github-output.txt'
    $rejectedAttemptPath = Join-Path $rejectedCase 'attempted.txt'
    $rejectedRecoveryMarker = Join-Path $rejectedCase 'artifacts/.nuget-recovery-required'
    $rejectedPrelude = @'
import os
import subprocess
import time

def confirmed_rejection(command, **kwargs):
    with open(os.environ["ATTEMPT_MARKER"], "a", encoding="utf-8") as marker:
        marker.write("attempted\n")
    return subprocess.CompletedProcess(
        command,
        1,
        stdout="",
        stderr="error: Response status code does not indicate success: 403 (Forbidden).\n",
    )

subprocess.run = confirmed_rejection
time.sleep = lambda seconds: None
'@
    $rejectedFailure = Invoke-PythonBlock `
        -WorkingDirectory $rejectedCase `
        -ScriptName 'publish-rejected.py' `
        -Script $publishScript `
        -Prelude "$rejectedPrelude`n" `
        -Environment @{
            ATTEMPT_MARKER = $rejectedAttemptPath
            GITHUB_OUTPUT = $rejectedOutputPath
            NUGET_API_KEY = 'test-key-not-a-secret'
        } `
        -ExpectFailure
    $rejectedOutputs = Read-GitHubOutputs $rejectedOutputPath
    Assert-Equal 'rejected' $rejectedOutputs['acceptance'] 'A structured terminal rejection was not classified as rejected.'
    Assert-Equal 'false' $rejectedOutputs['recovery_required'] 'A confirmed rejection incorrectly requested a remote recovery artifact.'
    Assert-Equal 1 ([IO.File]::ReadAllLines($rejectedAttemptPath).Length) 'A confirmed rejection should not be retried.'
    Assert-False (Test-Path -LiteralPath $rejectedRecoveryMarker) 'A confirmed rejection left the recovery marker behind.'
    Assert-RecoveryGuard 'failure' $rejectedOutputs $rejectedRecoveryMarker $false 'A confirmed rejection would create a remote recovery trace.'
    Assert-True $rejectedFailure.Contains('NuGet conclusively rejected the package') 'Confirmed rejection omitted the no-trace operator diagnostic.'
    Write-Host 'PASS confirmed-rejection-leaves-no-recovery-trace'

    $preExistingCase = Join-Path $tempRoot 'first-attempt-duplicate'
    [IO.Directory]::CreateDirectory((Join-Path $preExistingCase 'artifacts')) | Out-Null
    $preExistingOutputPath = Join-Path $preExistingCase 'github-output.txt'
    $preExistingAttemptPath = Join-Path $preExistingCase 'attempted.txt'
    $preExistingRecoveryMarker = Join-Path $preExistingCase 'artifacts/.nuget-recovery-required'
    $preExistingPrelude = @'
import os
import subprocess
import time

def first_attempt_duplicate(command, **kwargs):
    with open(os.environ["ATTEMPT_MARKER"], "a", encoding="utf-8") as marker:
        marker.write(f"skip-duplicate={'--skip-duplicate' in command}\n")
    return subprocess.CompletedProcess(
        command,
        1,
        stdout="",
        stderr="error: Response status code does not indicate success: 409 (Conflict).\n",
    )

subprocess.run = first_attempt_duplicate
time.sleep = lambda seconds: None
'@
    $preExistingFailure = Invoke-PythonBlock `
        -WorkingDirectory $preExistingCase `
        -ScriptName 'publish-first-attempt-duplicate.py' `
        -Script $publishScript `
        -Prelude "$preExistingPrelude`n" `
        -Environment @{
            ATTEMPT_MARKER = $preExistingAttemptPath
            GITHUB_OUTPUT = $preExistingOutputPath
            NUGET_API_KEY = 'test-key-not-a-secret'
        } `
        -ExpectFailure
    $preExistingOutputs = Read-GitHubOutputs $preExistingOutputPath
    Assert-Equal 'pre-existing' $preExistingOutputs['acceptance'] 'A first-attempt duplicate was falsely accepted as this run''s package.'
    Assert-Equal 'false' $preExistingOutputs['recovery_required'] 'A first-attempt duplicate falsely marked this run''s recovery bundle as exact.'
    Assert-Equal 'skip-duplicate=False' (([IO.File]::ReadAllLines($preExistingAttemptPath)) -join '|') 'The first package attempt used duplicate-skipping or was retried.'
    Assert-False (Test-Path -LiteralPath $preExistingRecoveryMarker) 'A first-attempt duplicate left an exact-recovery marker behind.'
    Assert-RecoveryGuard 'failure' $preExistingOutputs $preExistingRecoveryMarker $false 'A first-attempt duplicate would upload mismatched release state.'
    Assert-True $preExistingFailure.Contains('existed before the current run') 'First-attempt duplicate omitted its fail-closed operator diagnostic.'
    Write-Host 'PASS first-attempt-duplicate-fails-closed'

    $retryDuplicateCase = Join-Path $tempRoot 'duplicate-after-ambiguous-attempt'
    [IO.Directory]::CreateDirectory((Join-Path $retryDuplicateCase 'artifacts')) | Out-Null
    $retryDuplicateOutputPath = Join-Path $retryDuplicateCase 'github-output.txt'
    $retryDuplicateAttemptPath = Join-Path $retryDuplicateCase 'attempted.txt'
    $retryDuplicatePrelude = @'
import os
import subprocess
import time

call_count = 0

def duplicate_after_ambiguous_attempt(command, **kwargs):
    global call_count
    target = command[3]
    if target == "./artifacts/*.snupkg":
        return subprocess.CompletedProcess(command, 0, stdout="symbols accepted\n", stderr="")
    call_count += 1
    with open(os.environ["ATTEMPT_MARKER"], "a", encoding="utf-8") as marker:
        marker.write(f"attempt={call_count};skip-duplicate={'--skip-duplicate' in command}\n")
    if call_count == 1:
        return subprocess.CompletedProcess(command, 1, stdout="", stderr="connection reset\n")
    return subprocess.CompletedProcess(command, 0, stdout="already exists; skipping duplicate\n", stderr="")

subprocess.run = duplicate_after_ambiguous_attempt
time.sleep = lambda seconds: None
'@
    [void](Invoke-PythonBlock `
        -WorkingDirectory $retryDuplicateCase `
        -ScriptName 'publish-retry-duplicate.py' `
        -Script $publishScript `
        -Prelude "$retryDuplicatePrelude`n" `
        -Environment @{
            ATTEMPT_MARKER = $retryDuplicateAttemptPath
            GITHUB_OUTPUT = $retryDuplicateOutputPath
            NUGET_API_KEY = 'test-key-not-a-secret'
        })
    $retryDuplicateOutputs = Read-GitHubOutputs $retryDuplicateOutputPath
    Assert-Equal 'accepted' $retryDuplicateOutputs['acceptance'] 'A duplicate linked to this process''s ambiguous attempt did not preserve retry idempotence.'
    Assert-Equal 'true' $retryDuplicateOutputs['recovery_required'] 'A successful post-attempt duplicate lost the post-pivot recovery state.'
    Assert-Equal 'attempt=1;skip-duplicate=False|attempt=2;skip-duplicate=True' (([IO.File]::ReadAllLines($retryDuplicateAttemptPath)) -join '|') 'Duplicate-skipping was not confined to the retry after an ambiguous attempt.'
    Write-Host 'PASS duplicate-after-ambiguous-attempt-is-idempotent'

    $partialCase = Join-Path $tempRoot 'package-accepted-symbol-rejected'
    [IO.Directory]::CreateDirectory((Join-Path $partialCase 'artifacts')) | Out-Null
    $partialOutputPath = Join-Path $partialCase 'github-output.txt'
    $partialAttemptPath = Join-Path $partialCase 'attempted.txt'
    $partialRecoveryMarker = Join-Path $partialCase 'artifacts/.nuget-recovery-required'
    $partialPrelude = @'
import os
import subprocess
import time

def package_accepted_symbol_rejected(command, **kwargs):
    target = command[3]
    with open(os.environ["ATTEMPT_MARKER"], "a", encoding="utf-8") as marker:
        marker.write(f"{target}\n")
    if target == "./artifacts/*.nupkg":
        return subprocess.CompletedProcess(command, 0, stdout="package accepted\n", stderr="")
    return subprocess.CompletedProcess(
        command,
        1,
        stdout="",
        stderr="error: Response status code does not indicate success: 403 (Forbidden).\n",
    )

subprocess.run = package_accepted_symbol_rejected
time.sleep = lambda seconds: None
'@
    $partialFailure = Invoke-PythonBlock `
        -WorkingDirectory $partialCase `
        -ScriptName 'publish-partial.py' `
        -Script $publishScript `
        -Prelude "$partialPrelude`n" `
        -Environment @{
            ATTEMPT_MARKER = $partialAttemptPath
            GITHUB_OUTPUT = $partialOutputPath
            NUGET_API_KEY = 'test-key-not-a-secret'
        } `
        -ExpectFailure
    $partialOutputs = Read-GitHubOutputs $partialOutputPath
    $partialAttempts = [IO.File]::ReadAllLines($partialAttemptPath)
    Assert-Equal 'accepted' $partialOutputs['acceptance'] 'A symbol rejection incorrectly erased confirmed main-package acceptance.'
    Assert-Equal 'true' $partialOutputs['recovery_required'] 'A post-pivot symbol rejection did not preserve exact recovery state.'
    Assert-Equal 1 @($partialAttempts | Where-Object { $_ -ceq './artifacts/*.nupkg' }).Count 'The main package was not accepted exactly once.'
    Assert-Equal 3 @($partialAttempts | Where-Object { $_ -ceq './artifacts/*.snupkg' }).Count 'The symbol package did not execute all retry attempts.'
    Assert-RecoveryGuard 'failure' $partialOutputs $partialRecoveryMarker $true 'A post-pivot symbol rejection would not upload exact recovery state.'
    Assert-True $partialFailure.Contains('package is ALREADY on nuget.org') 'Post-pivot symbol rejection omitted the immutable-package diagnostic.'
    Write-Host 'PASS symbol-rejection-remains-post-pivot'

    $ambiguousCase = Join-Path $tempRoot 'ambiguous-publish'
    [IO.Directory]::CreateDirectory((Join-Path $ambiguousCase 'artifacts')) | Out-Null
    $ambiguousOutputPath = Join-Path $ambiguousCase 'github-output.txt'
    $acceptedMarkerPath = Join-Path $ambiguousCase 'server-accepted.txt'
    $ambiguousRecoveryMarker = Join-Path $ambiguousCase 'artifacts/.nuget-recovery-required'
    $ambiguousPrelude = @'
import os
import subprocess
import time

def accepted_but_client_failed(command, **kwargs):
    with open(os.environ["ACCEPTED_MARKER"], "a", encoding="utf-8") as marker:
        marker.write("accepted\n")
    return subprocess.CompletedProcess(command, 1, stdout="", stderr="connection reset\n")

subprocess.run = accepted_but_client_failed
time.sleep = lambda seconds: None
'@
    $ambiguousFailure = Invoke-PythonBlock `
        -WorkingDirectory $ambiguousCase `
        -ScriptName 'publish-ambiguous.py' `
        -Script $publishScript `
        -Prelude "$ambiguousPrelude`n" `
        -Environment @{
            ACCEPTED_MARKER = $acceptedMarkerPath
            GITHUB_OUTPUT = $ambiguousOutputPath
            NUGET_API_KEY = 'test-key-not-a-secret'
        } `
        -ExpectFailure
    $ambiguousOutputs = Read-GitHubOutputs $ambiguousOutputPath
    Assert-Equal 'ambiguous' $ambiguousOutputs['acceptance'] 'A terminal client failure after server acceptance was not classified as ambiguous.'
    Assert-Equal 'true' $ambiguousOutputs['recovery_required'] 'An ambiguous accepted publish did not require preservation of the exact recovery state.'
    Assert-Equal 3 ([IO.File]::ReadAllLines($acceptedMarkerPath).Length) 'The ambiguous publish regression did not execute all retry attempts.'
    Assert-True (Test-Path -LiteralPath $ambiguousRecoveryMarker -PathType Leaf) 'An ambiguous publish did not preserve the cancellation-safe recovery marker.'
    Assert-RecoveryGuard 'failure' $ambiguousOutputs $ambiguousRecoveryMarker $true 'An ambiguous accepted publish would not upload exact recovery state.'
    Assert-True $ambiguousFailure.Contains('NuGet acceptance is ambiguous') 'The ambiguous publish failure omitted the fail-safe operator diagnostic.'
    Write-Host 'PASS ambiguous-publish-preserves-recovery'

    $timeoutCase = Join-Path $tempRoot 'timed-out-publish'
    [IO.Directory]::CreateDirectory((Join-Path $timeoutCase 'artifacts')) | Out-Null
    $timeoutOutputPath = Join-Path $timeoutCase 'github-output.txt'
    $timeoutAttemptPath = Join-Path $timeoutCase 'attempted.txt'
    $timeoutRecoveryMarker = Join-Path $timeoutCase 'artifacts/.nuget-recovery-required'
    $timeoutPrelude = @'
import os
import subprocess
import time

def timed_out_after_attempt(command, **kwargs):
    with open(os.environ["ATTEMPT_MARKER"], "a", encoding="utf-8") as marker:
        marker.write("attempted\n")
    raise subprocess.TimeoutExpired(command, kwargs["timeout"])

subprocess.run = timed_out_after_attempt
time.sleep = lambda seconds: None
'@
    $timeoutFailure = Invoke-PythonBlock `
        -WorkingDirectory $timeoutCase `
        -ScriptName 'publish-timeout.py' `
        -Script $publishScript `
        -Prelude "$timeoutPrelude`n" `
        -Environment @{
            ATTEMPT_MARKER = $timeoutAttemptPath
            GITHUB_OUTPUT = $timeoutOutputPath
            NUGET_API_KEY = 'test-key-not-a-secret'
        } `
        -ExpectFailure
    $timeoutOutputs = Read-GitHubOutputs $timeoutOutputPath
    Assert-Equal 'ambiguous' $timeoutOutputs['acceptance'] 'A timed-out publish was not classified as ambiguous.'
    Assert-Equal 3 ([IO.File]::ReadAllLines($timeoutAttemptPath).Length) 'The timed-out publish regression did not execute all bounded attempts.'
    Assert-RecoveryGuard 'failure' $timeoutOutputs $timeoutRecoveryMarker $true 'A timed-out publish would not upload exact recovery state.'
    Assert-True $timeoutFailure.Contains('timed out; acceptance remains ambiguous') 'The timeout path omitted its ambiguous-acceptance diagnostic.'
    Write-Host 'PASS timed-out-publish-preserves-recovery'

    $cancelledCase = Join-Path $tempRoot 'cancelled-publish'
    [IO.Directory]::CreateDirectory((Join-Path $cancelledCase 'artifacts')) | Out-Null
    $cancelledOutputPath = Join-Path $cancelledCase 'github-output.txt'
    $cancelledAttemptPath = Join-Path $cancelledCase 'attempted.txt'
    $cancelledRecoveryMarker = Join-Path $cancelledCase 'artifacts/.nuget-recovery-required'
    $cancelledPrelude = @'
import os
import subprocess

def cancelled_after_attempt(command, **kwargs):
    with open(os.environ["ATTEMPT_MARKER"], "a", encoding="utf-8") as marker:
        marker.write("attempted\n")
    raise KeyboardInterrupt()

subprocess.run = cancelled_after_attempt
'@
    [void](Invoke-PythonBlock `
        -WorkingDirectory $cancelledCase `
        -ScriptName 'publish-cancelled.py' `
        -Script $publishScript `
        -Prelude "$cancelledPrelude`n" `
        -Environment @{
            ATTEMPT_MARKER = $cancelledAttemptPath
            GITHUB_OUTPUT = $cancelledOutputPath
            NUGET_API_KEY = 'test-key-not-a-secret'
        } `
        -ExpectFailure)
    $cancelledOutputs = Read-GitHubOutputs $cancelledOutputPath
    Assert-Equal 'ambiguous' $cancelledOutputs['acceptance'] 'A cancelled publish did not retain ambiguous acceptance.'
    Assert-Equal 1 ([IO.File]::ReadAllLines($cancelledAttemptPath).Length) 'The cancellation regression did not reach the network-attempt boundary exactly once.'
    Assert-True (Test-Path -LiteralPath $cancelledRecoveryMarker -PathType Leaf) 'Cancellation removed the durable recovery marker.'
    Assert-RecoveryGuard 'cancelled' $cancelledOutputs $cancelledRecoveryMarker $true 'A cancelled publish would not upload exact recovery state.'
    Write-Host 'PASS cancelled-publish-preserves-recovery'

    $firstRelease = Invoke-ReleaseStateCase `
        -Name 'first-release' `
        -Version '0.1.0' `
        -Tag 'v0.1.0' `
        -PreviousTag 'v0.0.0'
    $subsequentRelease = Invoke-ReleaseStateCase `
        -Name 'subsequent-release' `
        -Version '1.2.4' `
        -Tag 'v1.2.4' `
        -PreviousTag 'v1.2.3'
    Test-PackedReleaseState $subsequentRelease '1.2.4' 'v1.2.4'

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
