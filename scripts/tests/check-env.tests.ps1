#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$bash = Get-Command bash -ErrorAction SilentlyContinue
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "check-env-tests-$([Guid]::NewGuid().ToString('N'))"
$fixtureRoot = Join-Path $tempRoot 'fixture'
$fakeBin = Join-Path $tempRoot 'bin'
$fakeLog = Join-Path $tempRoot 'dotnet.log'
$bashRunner = Join-Path $tempRoot 'run-checker.sh'

function Invoke-Process {
    param(
        [Parameter(Mandatory)] [string] $FileName,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [hashtable] $Environment
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $fixtureRoot
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.Environment[$entry.Key] = $entry.Value
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = "$stdout$stderr"
    }
}

function Convert-ToBashPath {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not [OperatingSystem]::IsWindows()) {
        return $Path
    }

    $drive = $Path.Substring(0, 1).ToLowerInvariant()
    $relativePath = $Path.Substring(2).Replace('\', '/')
    if ($bash.Source -like '*WindowsApps*') {
        return "/mnt/$drive$relativePath"
    }
    return "/$drive$relativePath"
}

function Assert-Case {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $GlobalJson,
        [Parameter(Mandatory)] [ValidateSet('success', 'failure')] [string] $HostResult,
        [Parameter(Mandatory)] [bool] $ShouldSucceed,
        [Parameter(Mandatory)] [string] $Runner,
        [Parameter(Mandatory)] [string] $FileName,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    Set-Content -LiteralPath (Join-Path $fixtureRoot 'global.json') -Value $GlobalJson -NoNewline
    Set-Content -LiteralPath $fakeLog -Value '' -NoNewline
    $pathSeparator = [System.IO.Path]::PathSeparator
    $effectivePath = "$fakeBin$pathSeparator$([Environment]::GetEnvironmentVariable('PATH'))"
    if ($Runner -eq 'Bash' -and [OperatingSystem]::IsWindows()) {
        $posixFakeBin = Convert-ToBashPath $fakeBin
        $effectivePath = "${posixFakeBin}:/usr/bin:/bin"
    }
    $environment = @{
        FAKE_DOTNET_LOG = $fakeLog
        FAKE_DOTNET_RESULT = $HostResult
        FAKE_DOTNET_VERSION = '10.0.303'
        PATH = $effectivePath
    }

    if ($Runner -eq 'Bash' -and [OperatingSystem]::IsWindows()) {
        $posixScript = Convert-ToBashPath (Join-Path $fixtureRoot 'scripts/check-env.sh')
        $posixLog = Convert-ToBashPath $fakeLog
        $Arguments = @(
            (Convert-ToBashPath $bashRunner),
            $posixFakeBin,
            $posixScript,
            $posixLog,
            $HostResult,
            '10.0.303'
        )
    }

    $result = Invoke-Process -FileName $FileName -Arguments $Arguments -Environment $environment
    $calls = Get-Content -LiteralPath $fakeLog -Raw
    if ($null -eq $calls) {
        $calls = ''
    }
    if ($calls.Trim() -notmatch '(?:^|[/\\])fixture\|--version$') {
        throw "$Runner/$Name called dotnet unexpectedly: '$($calls.Trim())'. Output: $($result.Output)"
    }

    if ($ShouldSucceed) {
        if ($result.ExitCode -ne 0 -or $result.Output -notmatch 'Environment ready' -or $result.Output -notmatch '10\.0\.303') {
            throw "$Runner/$Name should succeed through host resolution. Output: $($result.Output)"
        }
    }
    elseif ($result.ExitCode -eq 0 -or $result.Output -match 'Environment ready' -or $result.Output -notmatch 'global\.json') {
        throw "$Runner/$Name should fail and name global.json. Output: $($result.Output)"
    }

    Write-Host "PASS $Runner/$Name"
}

try {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'scripts'), $fakeBin -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/check-env.ps1') -Destination (Join-Path $fixtureRoot 'scripts/check-env.ps1')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/check-env.sh') -Destination (Join-Path $fixtureRoot 'scripts/check-env.sh')

    $fakeDotnetScript = @'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$FAKE_DOTNET_LOG"
if [ "${1:-}" = "--version" ]; then
  if [ "$FAKE_DOTNET_RESULT" = "success" ]; then
    printf '%s\n' "$FAKE_DOTNET_VERSION"
    exit 0
  fi
  echo "A compatible installed .NET SDK was not found." >&2
  exit 1
fi
if [ "${1:-}" = "--list-sdks" ]; then
  echo "11.0.100 [/fake/sdk]"
  exit 0
fi
exit 2
'@
    [System.IO.File]::WriteAllText(
        (Join-Path $fakeBin 'dotnet'),
        $fakeDotnetScript.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
    $bashRunnerScript = @'
#!/usr/bin/env bash
set -euo pipefail
PATH="$1:/usr/bin:/bin"
FAKE_DOTNET_LOG="$3"
FAKE_DOTNET_RESULT="$4"
FAKE_DOTNET_VERSION="$5"
export PATH FAKE_DOTNET_LOG FAKE_DOTNET_RESULT FAKE_DOTNET_VERSION
bash "$2"
'@
    [System.IO.File]::WriteAllText(
        $bashRunner,
        $bashRunnerScript.Replace("`r`n", "`n"),
        [System.Text.UTF8Encoding]::new($false))
    Set-Content -LiteralPath (Join-Path $fakeBin 'dotnet.cmd') -NoNewline -Value @'
@echo off
echo %CD%^|%*>>"%FAKE_DOTNET_LOG%"
if "%1"=="--version" (
  if "%FAKE_DOTNET_RESULT%"=="success" (
    echo %FAKE_DOTNET_VERSION%
    exit /b 0
  )
  echo A compatible installed .NET SDK was not found. 1>&2
  exit /b 1
)
if "%1"=="--list-sdks" (
  echo 11.0.100 [/fake/sdk]
  exit /b 0
)
exit /b 2
'@

    if ([OperatingSystem]::IsWindows() -and $bash) {
        $posixFakeDotnet = Convert-ToBashPath (Join-Path $fakeBin 'dotnet')
        $chmod = Invoke-Process -FileName $bash.Source -Arguments @('-c', "chmod +x '$posixFakeDotnet'") -Environment @{}
        if ($chmod.ExitCode -ne 0) {
            throw "Could not make the fake dotnet executable: $($chmod.Output)"
        }
    }
    elseif (-not [OperatingSystem]::IsWindows()) {
        $executableMode = [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor `
            [System.IO.UnixFileMode]::UserExecute -bor [System.IO.UnixFileMode]::GroupRead -bor `
            [System.IO.UnixFileMode]::GroupExecute -bor [System.IO.UnixFileMode]::OtherRead -bor `
            [System.IO.UnixFileMode]::OtherExecute
        [System.IO.File]::SetUnixFileMode((Join-Path $fakeBin 'dotnet'), $executableMode)
    }

    $cases = @(
        @{
            Name = 'compatible-sdk'
            Json = '{"sdk":{"version":"10.0.100","rollForward":"latestFeature","allowPrerelease":false}}'
            Result = 'success'
            Success = $true
        },
        @{
            Name = 'next-major-rejected'
            Json = '{"sdk":{"version":"10.0.100","rollForward":"latestFeature","allowPrerelease":false}}'
            Result = 'failure'
            Success = $false
        },
        @{
            Name = 'prerelease-rejected'
            Json = '{"sdk":{"version":"10.0.100","rollForward":"latestFeature","allowPrerelease":false}}'
            Result = 'failure'
            Success = $false
        },
        @{
            Name = 'malformed-global-json'
            Json = '{"sdk":{"version":"10.0.100"'
            Result = 'failure'
            Success = $false
        }
    )

    foreach ($case in $cases) {
        Assert-Case -Name $case.Name -GlobalJson $case.Json -HostResult $case.Result -ShouldSucceed $case.Success `
            -Runner 'PowerShell' -FileName (Get-Command pwsh).Source `
            -Arguments @('-NoProfile', '-File', (Join-Path $fixtureRoot 'scripts/check-env.ps1'))
    }

    if (-not $bash) {
        throw 'bash is required to validate scripts/check-env.sh.'
    }
    $bashScript = Convert-ToBashPath (Join-Path $fixtureRoot 'scripts/check-env.sh')
    foreach ($case in $cases) {
        Assert-Case -Name $case.Name -GlobalJson $case.Json -HostResult $case.Result -ShouldSucceed $case.Success `
            -Runner 'Bash' -FileName $bash.Source -Arguments @($bashScript)
    }

    Write-Host 'All check-env regression tests passed.'
}
finally {
    if (Test-Path $tempRoot) {
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
        catch {
            Write-Warning "Could not remove temporary test directory '$tempRoot': $($_.Exception.Message)"
        }
    }
}
