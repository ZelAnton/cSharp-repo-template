#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$workflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "release-autofill-tests-$([Guid]::NewGuid().ToString('N'))"
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
}

function Get-AutoFillPython([string]$workflow) {
    $pattern = "(?ms)^      - name: Auto-fill \[Unreleased\] from git log if empty\r?\n.*?^          python3 <<'PY'\r?\n(?<code>.*?)^          PY\s*$"
    $match = [regex]::Match($workflow, $pattern)
    Assert-True $match.Success 'Could not extract the auto-fill Python block from release.yml.'
    return [regex]::Replace($match.Groups['code'].Value, '(?m)^          ', '')
}

function Invoke-AutoFillCase(
    [string]$name,
    [bool]$firstRelease,
    [string]$previousTag,
    [string[]]$expectedArguments,
    [string]$expectedNotes,
    [switch]$ExpectFailure
) {
    $caseRoot = Join-Path $tempRoot $name
    $shimRoot = Join-Path $caseRoot 'python-shim'
    [IO.Directory]::CreateDirectory($shimRoot) | Out-Null
    $argumentsPath = Join-Path $caseRoot 'git-cliff-arguments.json'
    $scriptPath = Join-Path $caseRoot 'autofill.py'
    $changelogPath = Join-Path $caseRoot 'CHANGELOG.md'
    [IO.File]::WriteAllText($scriptPath, "$scriptUnderTest`n", $utf8NoBom)
    [IO.File]::WriteAllText(
        $changelogPath,
        "# Changelog`n`n## [Unreleased]`n`n### Added`n-`n`n### Changed`n-`n`n### Fixed`n-`n",
        $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $caseRoot 'payload.txt'), "initial`n", $utf8NoBom)

    $siteCustomize = @'
import json
import os
import pathlib
import subprocess

_real_run = subprocess.run

def _run(arguments, *args, **kwargs):
    if arguments and arguments[0] == "git-cliff":
        pathlib.Path(os.environ["FAKE_CLIFF_ARGS"]).write_text(
            json.dumps(arguments), encoding="utf-8"
        )
        git_arguments = ["git", "log", "--reverse", "--format=%s"]
        if len(arguments) > 5:
            git_arguments.append(arguments[-1])
        log = _real_run(git_arguments, check=True, capture_output=True, text=True)
        groups = {"Added": [], "Changed": [], "Fixed": [], "Removed": []}
        for subject in log.stdout.splitlines():
            prefix = subject.split(maxsplit=1)[0].lower() if subject else ""
            if prefix in {"doc", "docs", "chore", "test", "tests", "style", "release", "merge"}:
                continue
            if prefix in {"add", "feat"}:
                group = "Added"
            elif prefix in {"fix", "bug"}:
                group = "Fixed"
            elif prefix in {"remove", "delete", "drop"}:
                group = "Removed"
            else:
                group = "Changed"
            groups[group].append(subject)
        sections = []
        for group, subjects in groups.items():
            if subjects:
                sections.append("### " + group + "\n" + "\n".join("- " + subject for subject in subjects))
        stdout = "\n\n".join(sections) + ("\n" if sections else "")
        return subprocess.CompletedProcess(arguments, 0, stdout=stdout, stderr="")
    return _real_run(arguments, *args, **kwargs)

subprocess.run = _run
'@
    [IO.File]::WriteAllText(
        (Join-Path $shimRoot 'sitecustomize.py'),
        $siteCustomize.Replace("`r`n", "`n"),
        $utf8NoBom)

    Invoke-Git $caseRoot @('init', '--initial-branch=main')
    Invoke-Git $caseRoot @('config', 'user.name', 'Release Test')
    Invoke-Git $caseRoot @('config', 'user.email', 'release-test@example.invalid')
    Invoke-Git $caseRoot @('add', '.')
    Invoke-Git $caseRoot @('commit', '-m', 'Add initial API')
    if (-not $firstRelease -and $previousTag) {
        Invoke-Git $caseRoot @('tag', $previousTag)
        [IO.File]::WriteAllText((Join-Path $caseRoot 'payload.txt'), "later`n", $utf8NoBom)
        Invoke-Git $caseRoot @('add', 'payload.txt')
        Invoke-Git $caseRoot @('commit', '-m', 'Fix later behavior')
    }

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $python.Source
    $startInfo.WorkingDirectory = $caseRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add($scriptPath)
    $startInfo.Environment['FIRST_RELEASE'] = $firstRelease.ToString().ToLowerInvariant()
    $startInfo.Environment['PREV_TAG'] = $previousTag
    $startInfo.Environment['PYTHONPATH'] = $shimRoot
    $startInfo.Environment['FAKE_CLIFF_ARGS'] = $argumentsPath

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $output = "$stdout$stderr"

    if ($ExpectFailure) {
        Assert-True ($process.ExitCode -ne 0) "$name should fail closed. Output: $output"
        Assert-True (-not (Test-Path -LiteralPath $argumentsPath)) "$name unexpectedly invoked git-cliff."
        Write-Host "PASS $name"
        return
    }

    Assert-Equal 0 $process.ExitCode "$name failed. Output: $output"
    $actualArguments = @([IO.File]::ReadAllText($argumentsPath) | ConvertFrom-Json)
    Assert-Equal $expectedArguments.Count $actualArguments.Count "$name changed the git-cliff argument count."
    for ($index = 0; $index -lt $expectedArguments.Count; $index++) {
        Assert-Equal $expectedArguments[$index] $actualArguments[$index] "$name changed git-cliff argument $index."
    }

    $changelog = [IO.File]::ReadAllText($changelogPath).Replace("`r`n", "`n")
    $normalizedExpectedNotes = $expectedNotes.Replace("`r`n", "`n").Trim()
    Assert-True $changelog.Contains($normalizedExpectedNotes) "$name did not write generated notes into [Unreleased]."
    Write-Host "PASS $name"
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $workflow = [IO.File]::ReadAllText($workflowPath)
    $scriptUnderTest = Get-AutoFillPython $workflow

    Assert-True (-not $workflow.Contains('Ensure previous tag exists')) 'The workflow still creates a synthetic previous tag.'
    Assert-True (-not $workflow.Contains('git tag "$PREV_TAG"')) 'The workflow still tags the root commit as a range boundary.'
    Assert-True ($workflow.Contains('first_release=$FIRST_RELEASE')) 'Determine next version does not expose first-release mode.'
    Assert-True ($workflow.Contains('previous_tag=$PREVIOUS_TAG')) 'Determine next version does not expose the real previous tag.'

    $sourceCaptureIndex = $workflow.IndexOf('      - name: Capture immutable release source')
    $autoFillIndex = $workflow.IndexOf('      - name: Auto-fill [Unreleased] from git log if empty')
    $localCommitIndex = $workflow.IndexOf('      - name: Commit and tag the release (local only)')
    $remoteGuardIndex = $workflow.IndexOf('      - name: Guard — remote main unchanged before NuGet pivot')
    $publishIndex = $workflow.IndexOf('      - name: Push to NuGet.org (irreversible pivot)')
    $pushIndex = $workflow.IndexOf('      - name: Push the release commit + tag (atomic)')
    Assert-True ($sourceCaptureIndex -ge 0 -and $sourceCaptureIndex -lt $autoFillIndex) 'The immutable release source is not captured before version/changelog derivation.'
    Assert-True ($autoFillIndex -ge 0 -and $autoFillIndex -lt $localCommitIndex) 'Auto-fill moved after the local release commit.'
    Assert-True ($localCommitIndex -lt $remoteGuardIndex -and $remoteGuardIndex -lt $publishIndex) 'The exact remote-main guard must run after the local release commit and immediately before the NuGet pivot.'
    Assert-True ($publishIndex -lt $pushIndex) 'The remote push moved before the NuGet publish pivot.'

    $baseArguments = @('git-cliff', '--config', 'cliff.toml', '--strip', 'all')
    Invoke-AutoFillCase `
        -Name 'single-root-first-release' `
        -FirstRelease $true `
        -PreviousTag '' `
        -ExpectedArguments $baseArguments `
        -ExpectedNotes "### Added`n- Add initial API`n"
    Invoke-AutoFillCase `
        -Name 'subsequent-release' `
        -FirstRelease $false `
        -PreviousTag 'v1.2.3' `
        -ExpectedArguments ($baseArguments + 'v1.2.3..HEAD') `
        -ExpectedNotes "### Fixed`n- Fix later behavior`n"
    Invoke-AutoFillCase `
        -Name 'subsequent-release-without-tag' `
        -FirstRelease $false `
        -PreviousTag '' `
        -ExpectedArguments @() `
        -ExpectedNotes '' `
        -ExpectFailure

    Write-Host 'All release auto-fill regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
