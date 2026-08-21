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
$bashPath = if ([OperatingSystem]::IsWindows()) {
    $git = Get-Command git -CommandType Application -ErrorAction Stop
    $gitBashPath = [IO.Path]::GetFullPath((Join-Path (Split-Path $git.Source -Parent) '../bin/bash.exe'))
    (Get-Item -LiteralPath $gitBashPath -ErrorAction Stop).FullName
}
else {
    (Get-Command bash -CommandType Application -ErrorAction Stop).Source
}

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

function Get-WorkflowRunScript([string]$workflow, [string]$stepName) {
    $block = Get-WorkflowStepBlock $workflow $stepName
    $match = [regex]::Match($block, "(?ms)^        run: \|\r?\n(?<code>.*)$")
    Assert-True $match.Success "Could not extract the '$stepName' run script from release.yml."
    return [regex]::Replace($match.Groups['code'].Value, '(?m)^          ', '')
}

function Invoke-BashBlock(
    [string]$workingDirectory,
    [string]$scriptName,
    [string]$script,
    [hashtable]$environment,
    [switch]$ExpectFailure
) {
    $scriptPath = Join-Path $workingDirectory $scriptName
    [IO.File]::WriteAllText($scriptPath, "$script`n", $utf8NoBom)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $bashPath
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    [void]$startInfo.ArgumentList.Add($scriptName)
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

function Get-Sha256Hex([string]$path) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($path))).ToLowerInvariant()
}

function Read-KeyValueFile([string]$path) {
    $values = @{}
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $parts = $line.Split('=', 2)
        $values[$parts[0]] = $parts[1]
    }
    return $values
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

function Test-ExplicitSymbolPush([IO.FileInfo]$symbolPackage, [string]$caseRoot) {
    $serverPath = Join-Path $caseRoot 'symbol-server.py'
    $portPath = Join-Path $caseRoot 'symbol-server-port.txt'
    $uploadPath = Join-Path $caseRoot 'published.snupkg'
    $serverScript = @'
import http.server
import json
import os
from email.parser import BytesParser
from email.policy import default
from pathlib import Path

port_path = Path(os.environ["PORT_PATH"])
upload_path = Path(os.environ["UPLOAD_PATH"])

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def send_body(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path != "/v3/index.json":
            self.send_body(404)
            return
        root = f"http://127.0.0.1:{self.server.server_port}"
        body = json.dumps({
            "version": "3.0.0",
            "resources": [
                {"@id": f"{root}/package", "@type": "PackagePublish/2.0.0"},
                {"@id": f"{root}/symbol", "@type": "SymbolPackagePublish/4.9.0"},
            ],
        }).encode("utf-8")
        self.send_body(200, body)

    def do_PUT(self):
        if self.path.rstrip("/") != "/symbol":
            self.send_body(404)
            return
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks = []
            while True:
                size_line = self.rfile.readline().strip()
                size = int(size_line.split(b";", 1)[0], 16)
                if size == 0:
                    self.rfile.readline()
                    break
                chunks.append(self.rfile.read(size))
                self.rfile.read(2)
            body = b"".join(chunks)
        else:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        if content_type.lower().startswith("multipart/"):
            message = BytesParser(policy=default).parsebytes(
                f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode("ascii") + body
            )
            parts = list(message.iter_parts())
            if len(parts) != 1:
                self.send_body(400)
                return
            body = parts[0].get_payload(decode=True)
        upload_path.write_bytes(body)
        self.send_body(201, b"")

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_path.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
'@
    [IO.File]::WriteAllText($serverPath, $serverScript, $utf8NoBom)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $python.Source
    $startInfo.WorkingDirectory = $caseRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment['PORT_PATH'] = $portPath
    $startInfo.Environment['UPLOAD_PATH'] = $uploadPath
    [void]$startInfo.ArgumentList.Add($serverPath)

    $server = [Diagnostics.Process]::new()
    $server.StartInfo = $startInfo
    [void]$server.Start()
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not (Test-Path -LiteralPath $portPath -PathType Leaf)) {
            if ($server.HasExited) {
                throw "The local NuGet server exited before startup: $($server.StandardError.ReadToEnd())"
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                throw 'The local NuGet server did not become ready within 10 seconds.'
            }
            Start-Sleep -Milliseconds 50
        }

        $serviceIndex = "http://127.0.0.1:$([IO.File]::ReadAllText($portPath))/v3/index.json"
        [void](Invoke-Dotnet $caseRoot @(
            'nuget', 'push', $symbolPackage.FullName,
            '--source', $serviceIndex,
            '--api-key', 'local-test-key',
            '--symbol-source', $serviceIndex,
            '--symbol-api-key', 'local-test-key',
            '--skip-duplicate',
            '--allow-insecure-connections',
            '--force-english-output'
        ))

        Assert-True (Test-Path -LiteralPath $uploadPath -PathType Leaf) 'The real NuGet CLI returned without sending the explicit .snupkg to the symbol endpoint.'
        Assert-BytesEqual ([IO.File]::ReadAllBytes($symbolPackage.FullName)) ([IO.File]::ReadAllBytes($uploadPath)) 'The explicit symbol publication did not preserve the packed .snupkg.'
    }
    finally {
        if (-not $server.HasExited) {
            $server.Kill($true)
            $server.WaitForExit()
        }
        $server.Dispose()
    }
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

    $symbolPackages = @(Get-ChildItem -LiteralPath $artifactRoot -Filter '*.snupkg' -File)
    Assert-Equal 1 $symbolPackages.Count 'The pack regression must produce exactly one .snupkg.'
    Test-ExplicitSymbolPush $symbolPackages[0] $caseRoot

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
    $bundleScript = Get-WorkflowRunScript $workflow 'Create local release recovery bundle'
    $sourceGuardScript = Get-WorkflowRunScript $workflow 'Guard — remote main unchanged before NuGet pivot'
    $publishStep = Get-WorkflowStepBlock $workflow 'Push to NuGet.org (irreversible pivot)'
    $pushStep = Get-WorkflowStepBlock $workflow 'Push the release commit + tag (atomic)'
    $releaseStep = Get-WorkflowStepBlock $workflow 'Create or update the GitHub Release (idempotent)'
    $recoveryStep = Get-WorkflowStepBlock $workflow 'Preserve exact post-pivot recovery state'

    $steps = [ordered]@{
        capture = '      - name: Capture immutable release source'
        checkout = '      - uses: actions/checkout@'
        checkout_guard = '      - name: Verify immutable release source checkout'
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
        source_guard = '      - name: Guard — remote main unchanged before NuGet pivot'
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
    Assert-True $workflow.Contains('ref: ${{ steps.release_source.outputs.sha }}') 'Checkout no longer uses the immutable dispatch source SHA.'
    Assert-True $workflow.Contains('SOURCE_SHA: ${{ steps.release_source.outputs.sha }}') 'Release steps no longer consume the captured source SHA.'
    Assert-True $workflow.Contains('dotnet pack src/__ProjectName__/__ProjectName__.csproj --no-build --configuration Release --output ./artifacts /p:Version=${{ steps.version.outputs.version }}') 'Pack no longer uses the computed release version.'
    Assert-True $project.Contains('<None Include="$(RepoRoot)CHANGELOG.md" Pack="true" PackagePath="\" />') 'The package no longer includes the root release-state CHANGELOG.md.'
    Assert-True $project.Contains('<PackageReleaseNotes Condition="Exists(''$(RepoRoot)release-notes.md'')">$([System.IO.File]::ReadAllText(''$(RepoRoot)release-notes.md''))</PackageReleaseNotes>') 'The package no longer consumes the extracted release notes.'
    Assert-True $workflow.Contains('git add src/__ProjectName__/__ProjectName__.csproj CHANGELOG.md') 'The local release commit no longer records both release-state inputs.'
    Assert-True $workflow.Contains('git bundle create ./artifacts/release-recovery.bundle HEAD "$TAG"') 'The workflow no longer preserves a cloneable exact release commit and tag for recovery.'
    Assert-True $workflow.Contains('"$(git rev-parse --verify HEAD^)" != "$SOURCE_SHA"') 'The workflow no longer verifies release ancestry against the immutable source.'
    Assert-True $workflow.Contains('--force-with-lease="refs/heads/main:$SOURCE_SHA"') 'The remote main update is no longer bound to the exact captured source SHA.'
    Assert-True $workflow.Contains('artifacts/release-recovery-manifest.txt') 'The exact recovery artifact no longer includes source, release, tag, and integrity metadata.'
    Assert-True $workflow.Contains('id: nuget_publish') 'The NuGet pivot no longer exposes its outcome to the recovery guard.'
    Assert-False $publishStep.Contains('continue-on-error: true') 'An ambiguous NuGet outcome must stop VCS and GitHub Release publication.'
    Assert-True $publishScript.Contains('write_output("acceptance", "not-attempted")') 'The NuGet pivot no longer distinguishes a skipped attempt from an ambiguous response.'
    Assert-True $publishScript.Contains('write_output("acceptance", "ambiguous")') 'The NuGet pivot no longer fails safe before its first network attempt.'
    Assert-True $publishScript.Contains('write_output("acceptance", "accepted")') 'The NuGet pivot no longer records confirmed client success.'
    Assert-True $publishScript.Contains('write_output("acceptance", "rejected")') 'The NuGet pivot no longer records a confirmed terminal rejection.'
    Assert-True $publishScript.Contains('write_output("acceptance", "pre-existing")') 'The NuGet pivot no longer distinguishes a first-attempt duplicate from this run''s accepted package.'
    Assert-True $publishScript.Contains('if attempt > 1:') 'Duplicate idempotence is no longer limited to retries after this process has attempted the package.'
    Assert-True $publishScript.Contains('if attempt > 1 and retry_duplicate.search(response):') 'A retry duplicate can again be mistaken for a direct upload by this run.'
    Assert-True $publishScript.Contains('if attempt > 1 and not direct_upload_success.search(response):') 'A retry success without direct-upload evidence can again advance the release.'
    Assert-True $publishScript.Contains('timeout=300') 'The NuGet client attempt is no longer bounded before the job-level timeout.'
    Assert-True $publishScript.Contains('"./artifacts/*.nupkg"') 'The NuGet pivot no longer publishes the main package explicitly.'
    Assert-True $publishScript.Contains('"./artifacts/*.snupkg"') 'The NuGet pivot no longer publishes the symbol package explicitly.'
    $packageCommandMatch = [regex]::Match($publishScript, '(?ms)^package_command = \[(?<command>.*?)^\]$')
    $symbolCommandMatch = [regex]::Match($publishScript, '(?ms)^symbol_command = \[(?<command>.*?)^\]$')
    Assert-True $packageCommandMatch.Success 'The main-package command could not be inspected.'
    Assert-True $symbolCommandMatch.Success 'The symbol-package command could not be inspected.'
    Assert-True $packageCommandMatch.Groups['command'].Value.Contains('"--no-symbols"') 'The main-package acceptance decision is no longer isolated from automatic symbol publication.'
    Assert-False $symbolCommandMatch.Groups['command'].Value.Contains('"--no-symbols"') 'The explicit .snupkg command must not disable its own symbol source.'
    Assert-True $symbolCommandMatch.Groups['command'].Value.Contains('"--symbol-source"') 'The explicit .snupkg command must provide a symbol source to the NuGet client.'
    Assert-True $symbolCommandMatch.Groups['command'].Value.Contains('"--symbol-api-key"') 'The explicit .snupkg command must authenticate against its symbol source.'
    Assert-True $recoveryStep.Contains('always() && (failure() || cancelled()) &&') 'The recovery upload no longer covers both failed and cancelled NuGet client steps.'
    Assert-True $recoveryStep.Contains('steps.nuget_publish.outputs.recovery_required == ''true''') 'The recovery upload is not guarded by the publish attempt state.'
    Assert-True $recoveryStep.Contains('hashFiles(''artifacts/.nuget-recovery-required'') != ''''') 'The recovery upload no longer has a cancellation-safe local marker guard.'
    Assert-False ([regex]::IsMatch($pushStep, '(?m)^        if:')) 'The VCS push must retain the default success guard after the NuGet pivot.'
    Assert-False ([regex]::IsMatch($releaseStep, '(?m)^        if:')) 'The GitHub Release must retain the default success guard after the NuGet pivot.'
    Assert-True $recoveryStep.Contains('artifacts/release-recovery.bundle') 'The recovery artifact no longer contains the local release commit and tag.'
    Assert-True $recoveryStep.Contains('artifacts/release-recovery-manifest.txt') 'The recovery artifact no longer contains its immutable source and integrity manifest.'
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
    $retryDuplicateFailure = Invoke-PythonBlock `
        -WorkingDirectory $retryDuplicateCase `
        -ScriptName 'publish-retry-duplicate.py' `
        -Script $publishScript `
        -Prelude "$retryDuplicatePrelude`n" `
        -Environment @{
            ATTEMPT_MARKER = $retryDuplicateAttemptPath
            GITHUB_OUTPUT = $retryDuplicateOutputPath
            NUGET_API_KEY = 'test-key-not-a-secret'
        } `
        -ExpectFailure
    $retryDuplicateOutputs = Read-GitHubOutputs $retryDuplicateOutputPath
    $retryDuplicateRecoveryMarker = Join-Path $retryDuplicateCase 'artifacts/.nuget-recovery-required'
    Assert-Equal 'ambiguous' $retryDuplicateOutputs['acceptance'] 'A retry duplicate was falsely accepted as a direct upload by this run.'
    Assert-Equal 'true' $retryDuplicateOutputs['recovery_required'] 'A retry duplicate lost the exact recovery state needed for an ambiguous outcome.'
    Assert-Equal 'attempt=1;skip-duplicate=False|attempt=2;skip-duplicate=True' (([IO.File]::ReadAllLines($retryDuplicateAttemptPath)) -join '|') 'Duplicate-skipping was not confined to the retry after an ambiguous attempt.'
    Assert-True (Test-Path -LiteralPath $retryDuplicateRecoveryMarker -PathType Leaf) 'A retry duplicate removed the exact-recovery marker.'
    Assert-RecoveryGuard 'failure' $retryDuplicateOutputs $retryDuplicateRecoveryMarker $true 'A retry duplicate would not preserve exact recovery state.'
    Assert-True $retryDuplicateFailure.Contains('cannot be attributed to this run') 'A retry duplicate omitted the fail-closed ownership diagnostic.'
    Assert-True $retryDuplicateFailure.Contains('No VCS push or GitHub Release was attempted') 'A retry duplicate did not terminate before tag and GitHub Release publication.'
    Write-Host 'PASS duplicate-after-ambiguous-attempt-remains-recovery-only'

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

    $bundleRoot = Join-Path $tempRoot 'immutable-release-source'
    $remoteRoot = Join-Path $tempRoot 'immutable-release-source.git'
    [IO.Directory]::CreateDirectory((Join-Path $bundleRoot 'artifacts')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $bundleRoot 'payload.txt'), "source state`n", $utf8NoBom)
    [void](Invoke-Git $bundleRoot @('init', '--initial-branch=main'))
    [void](Invoke-Git $bundleRoot @('config', 'user.name', 'Release Test'))
    [void](Invoke-Git $bundleRoot @('config', 'user.email', 'release-test@example.invalid'))
    [void](Invoke-Git $bundleRoot @('add', 'payload.txt'))
    [void](Invoke-Git $bundleRoot @('commit', '-m', 'Source state'))
    $sourceCommit = @(Invoke-Git $bundleRoot @('rev-parse', 'HEAD'))[-1]
    [void](Invoke-Git $tempRoot @('init', '--bare', '--initial-branch=main', $remoteRoot))
    [void](Invoke-Git $bundleRoot @('remote', 'add', 'origin', $remoteRoot))
    [void](Invoke-Git $bundleRoot @('push', 'origin', 'main:main'))

    [IO.File]::WriteAllText((Join-Path $bundleRoot 'payload.txt'), "release state`n", $utf8NoBom)
    [void](Invoke-Git $bundleRoot @('add', 'payload.txt'))
    [void](Invoke-Git $bundleRoot @('commit', '-m', 'Release v1.2.4'))
    $releaseCommit = @(Invoke-Git $bundleRoot @('rev-parse', 'HEAD'))[-1]
    [void](Invoke-Git $bundleRoot @('tag', 'v1.2.4', $releaseCommit))
    $packagePath = Join-Path $bundleRoot 'artifacts/package.1.2.4.nupkg'
    $symbolsPath = Join-Path $bundleRoot 'artifacts/package.1.2.4.snupkg'
    $checksumsPath = Join-Path $bundleRoot 'artifacts/SHA256SUMS'
    $notesPath = Join-Path $bundleRoot 'release-notes.md'
    [IO.File]::WriteAllText($packagePath, "package bytes`n", $utf8NoBom)
    [IO.File]::WriteAllText($symbolsPath, "symbol bytes`n", $utf8NoBom)
    [IO.File]::WriteAllText($notesPath, "### Fixed`n- Preserve exact release state.`n", $utf8NoBom)
    [IO.File]::WriteAllText(
        $checksumsPath,
        "$(Get-Sha256Hex $packagePath)  $([IO.Path]::GetFileName($packagePath))`n$(Get-Sha256Hex $symbolsPath)  $([IO.Path]::GetFileName($symbolsPath))`n",
        $utf8NoBom)

    [void](Invoke-BashBlock `
        -WorkingDirectory $bundleRoot `
        -ScriptName 'create-recovery.sh' `
        -Script $bundleScript `
        -Environment @{
            GITHUB_REPOSITORY = 'example/release-test'
            SOURCE_SHA = $sourceCommit
            RELEASE_SHA = $releaseCommit
            TAG = 'v1.2.4'
        })
    [void](Invoke-BashBlock `
        -WorkingDirectory $bundleRoot `
        -ScriptName 'guard-release.sh' `
        -Script $sourceGuardScript `
        -Environment @{
            SOURCE_SHA = $sourceCommit
            RELEASE_SHA = $releaseCommit
            TAG = 'v1.2.4'
        })
    Write-Host 'PASS immutable-source-normal-release'

    $manifestPath = Join-Path $bundleRoot 'artifacts/release-recovery-manifest.txt'
    $manifest = Read-KeyValueFile $manifestPath
    Assert-Equal 'release-recovery-v1' $manifest['schema'] 'The recovery manifest schema changed unexpectedly.'
    Assert-Equal $sourceCommit $manifest['source_sha'] 'The recovery manifest lost the immutable source SHA.'
    Assert-Equal $releaseCommit $manifest['release_sha'] 'The recovery manifest lost the exact release commit.'
    Assert-Equal 'v1.2.4' $manifest['tag'] 'The recovery manifest lost the exact release tag.'
    Assert-Equal (Get-Sha256Hex $checksumsPath) $manifest['package_checksums_sha256'] 'The recovery manifest does not authenticate the package checksums.'
    Assert-Equal (Get-Sha256Hex (Join-Path $bundleRoot 'artifacts/release-recovery.bundle')) $manifest['bundle_sha256'] 'The recovery manifest does not authenticate the exact bundle.'
    Assert-Equal (Get-Sha256Hex $notesPath) $manifest['release_notes_sha256'] 'The recovery manifest does not authenticate the exact release notes.'

    [void](Invoke-Git $bundleRoot @('clone', './artifacts/release-recovery.bundle', 'recovered'))
    $recoveredCommit = @(Invoke-Git (Join-Path $bundleRoot 'recovered') @('rev-parse', 'HEAD'))[-1]
    Assert-Equal $releaseCommit $recoveredCommit 'The recovery bundle clone did not restore the exact release commit.'
    Assert-Equal $sourceCommit (@(Invoke-Git (Join-Path $bundleRoot 'recovered') @('rev-parse', 'HEAD^'))[-1]) 'The recovery bundle release commit is not based on the immutable source.'
    Assert-Equal 'v1.2.4' (@(Invoke-Git (Join-Path $bundleRoot 'recovered') @('tag', '--points-at', 'HEAD'))[-1]) 'The recovery bundle clone did not restore the release tag.'
    Write-Host 'PASS exact-post-pivot-recovery-state'

    $moverRoot = Join-Path $tempRoot 'main-mover'
    [void](Invoke-Git $tempRoot @('clone', $remoteRoot, $moverRoot))
    [void](Invoke-Git $moverRoot @('config', 'user.name', 'Concurrent Test'))
    [void](Invoke-Git $moverRoot @('config', 'user.email', 'concurrent-test@example.invalid'))
    [IO.File]::WriteAllText((Join-Path $moverRoot 'concurrent.txt'), "remote movement`n", $utf8NoBom)
    [void](Invoke-Git $moverRoot @('add', 'concurrent.txt'))
    [void](Invoke-Git $moverRoot @('commit', '-m', 'Concurrent main movement'))
    [void](Invoke-Git $moverRoot @('push', 'origin', 'main:main'))
    $guardFailure = Invoke-BashBlock `
        -WorkingDirectory $bundleRoot `
        -ScriptName 'guard-moved-main.sh' `
        -Script $sourceGuardScript `
        -Environment @{
            SOURCE_SHA = $sourceCommit
            RELEASE_SHA = $releaseCommit
            TAG = 'v1.2.4'
        } `
        -ExpectFailure
    Assert-True $guardFailure.Contains('origin/main moved from immutable release source') 'Concurrent main movement did not fail closed before the NuGet pivot.'
    Assert-True $guardFailure.Contains('No package was published') 'Concurrent main movement omitted the no-publish recovery direction.'
    Write-Host 'PASS moved-main-blocks-pivot'

    Write-Host 'All release-state regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
