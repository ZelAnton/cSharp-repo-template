#!/usr/bin/env pwsh
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$scriptUnderTest = Join-Path $repoRoot 'scripts/test-linux.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "test-linux-tests-$([Guid]::NewGuid().ToString('N'))"
$runnerPath = Join-Path $tempRoot 'invoke-test-linux.ps1'
$dockerLog = Join-Path $tempRoot 'docker-arguments.jsonl'
$dotnetLog = Join-Path $tempRoot 'dotnet-arguments.bin'
$bashWrapper = Join-Path $tempRoot 'invoke-container-command.sh'
$dockerShimProject = Join-Path $tempRoot 'docker-shim'
$dockerShimOutput = Join-Path $tempRoot 'docker-shim-output'
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0]
$bash = @(Get-Command bash -CommandType Application -ErrorAction Stop)[0]
$dotnet = @(Get-Command dotnet -CommandType Application -ErrorAction Stop)[0]

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

function Assert-Sequence([string[]]$expected, [string[]]$actual, [string]$message) {
    Assert-Equal $expected.Count $actual.Count "$message (argument count)"
    for ($index = 0; $index -lt $expected.Count; $index++) {
        Assert-Equal $expected[$index] $actual[$index] "$message (argument $index)"
    }
}

function Invoke-Process(
    [string]$fileName,
    [string[]]$arguments,
    [string]$workingDirectory
) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $fileName
    $startInfo.WorkingDirectory = $workingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
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

function Convert-ToBashPath([string]$path) {
    if (-not [OperatingSystem]::IsWindows()) {
        return $path
    }

    $drive = $path.Substring(0, 1).ToLowerInvariant()
    $relativePath = $path.Substring(2).Replace('\', '/')
    if ($bash.Source -like '*WindowsApps*') {
        return "/mnt/$drive$relativePath"
    }

    return "/$drive$relativePath"
}

function Read-DotnetCalls([string]$path) {
    $tokens = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($path)).Split([char]0)
    $calls = [Collections.Generic.List[object]]::new()
    $index = 0
    while ($index -lt $tokens.Count -and $tokens[$index]) {
        Assert-Equal 'CALL' $tokens[$index] 'Malformed fake dotnet call header.'
        $index++
        $arguments = [Collections.Generic.List[string]]::new()
        while ($tokens[$index] -ne 'END') {
            Assert-Equal 'ARG' $tokens[$index] 'Malformed fake dotnet argument marker.'
            $arguments.Add($tokens[$index + 1])
            $index += 2
        }

        $calls.Add($arguments.ToArray())
        $index++
    }

    return [pscustomobject]@{
        Calls = $calls.ToArray()
    }
}

function Invoke-TestCase(
    [string]$name,
    [string]$configuration,
    [bool]$rebuild,
    [bool]$hasFilter,
    [string]$filter
) {
    [IO.File]::WriteAllText($dockerLog, '', $utf8NoBom)
    [IO.File]::WriteAllBytes($dotnetLog, [byte[]]::new(0))
    $environment = @{
        TEST_LINUX_SCRIPT = $scriptUnderTest
        TEST_DOCKER_LOG = $dockerLog
        TEST_DOCKER_DIR = $dockerShimOutput
        TEST_CONFIGURATION = $configuration
        TEST_REBUILD = $(if ($rebuild) { '1' } else { '0' })
        TEST_HAS_FILTER = $(if ($hasFilter) { '1' } else { '0' })
        TEST_FILTER_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($filter))
    }
    $previous = @{}
    foreach ($entry in $environment.GetEnumerator()) {
        $previous[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }

    try {
        $output = @(& $pwsh.Source -NoProfile -File $runnerPath 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        foreach ($entry in $environment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $previous[$entry.Key], 'Process')
        }
    }

    if ($exitCode -ne 0) {
        throw "$name failed to invoke test-linux.ps1.`n$($output -join "`n")"
    }

    $dockerCalls = @(Get-Content -LiteralPath $dockerLog -Encoding UTF8 | ForEach-Object {
        , @($_ | ConvertFrom-Json)
    })
    Assert-Equal 2 $dockerCalls.Count "$name should invoke docker exactly twice."
    Assert-Sequence @('version', '--format', '{{.Server.Version}}') $dockerCalls[0] "$name docker version boundary changed."

    $runArguments = [string[]]$dockerCalls[1]
    Assert-Equal 'run' $runArguments[0] "$name did not invoke docker run."
    $imageIndex = [Array]::IndexOf($runArguments, 'test/image:latest')
    Assert-True ($imageIndex -ge 0) "$name did not pass the image as a Docker argument."
    $containerArguments = [string[]]$runArguments[($imageIndex + 1)..($runArguments.Count - 1)]
    $expectedFilterPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($filter))
    $expectedContainerArgumentCount = if ($expectedFilterPayload) { 8 } else { 7 }
    Assert-Equal $expectedContainerArgumentCount $containerArguments.Count "$name container command boundary changed."
    Assert-Equal 'bash' $containerArguments[0] "$name container command should use Bash."
    Assert-Equal '-c' $containerArguments[1] "$name container command should use a constant Bash program."

    $bootstrap = $containerArguments[2]
    $programPayload = $containerArguments[3]
    $program = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($programPayload))
    if ($filter) {
        Assert-True (-not $bootstrap.Contains($filter)) "$name embedded filter data into executable bootstrap text."
        Assert-True (-not $program.Contains($filter)) "$name embedded filter data into executable Bash text."
    }
    Assert-True (-not $bootstrap.Contains($configuration)) "$name embedded configuration data into executable bootstrap text."
    Assert-True (-not $program.Contains($configuration)) "$name embedded configuration data into executable Bash text."
    $expectedTail = [Collections.Generic.List[string]]::new()
    $expectedTail.AddRange([string[]]@(
        $programPayload,
        $configuration,
        $(if ($rebuild) { '1' } else { '0' }),
        $(if ($hasFilter -and $filter) { '1' } else { '0' })
    ))
    if ($expectedFilterPayload) {
        $expectedTail.Add($expectedFilterPayload)
    }
    Assert-Sequence $expectedTail.ToArray() $containerArguments[3..($containerArguments.Count - 1)] "$name changed positional container data."

    $wrapperContent = $wrapperTemplate
    $wrapperContent = $wrapperContent.Replace(
        '__DOTNET_LOG_B64__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Convert-ToBashPath $dotnetLog))))
    $wrapperContent = $wrapperContent.Replace(
        '__BOOTSTRAP_B64__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bootstrap)))
    $wrapperContent = $wrapperContent.Replace(
        '__PROGRAM_PAYLOAD_B64__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($programPayload)))
    $wrapperContent = $wrapperContent.Replace(
        '__CONFIGURATION_B64__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($containerArguments[4])))
    $wrapperContent = $wrapperContent.Replace(
        '__REBUILD_B64__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($containerArguments[5])))
    $wrapperContent = $wrapperContent.Replace(
        '__HAS_FILTER_B64__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($containerArguments[6])))
    $wrapperContent = $wrapperContent.Replace(
        '__FILTER_B64__',
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            $(if ($containerArguments.Count -gt 7) { $containerArguments[7] } else { '' }))))
    [IO.File]::WriteAllText($bashWrapper, $wrapperContent.Replace("`r`n", "`n"), $utf8NoBom)
    $bashResult = Invoke-Process $bash.Source @((Convert-ToBashPath $bashWrapper)) $repoRoot
    if ($bashResult.ExitCode -ne 0) {
        throw "$name failed at the captured Bash boundary.`n$($bashResult.Output)"
    }

    $dotnetCalls = @((Read-DotnetCalls $dotnetLog).Calls)
    $expectedCalls = [Collections.Generic.List[object]]::new()
    if ($rebuild) {
        $expectedCalls.Add([string[]]@('clean', '-c', $configuration))
    }
    $expectedCalls.Add([string[]]@('build', '-c', $configuration))
    $testArguments = [Collections.Generic.List[string]]::new()
    $testArguments.AddRange([string[]]@(
        'test', '--no-build', '-c', $configuration,
        'tests/__ProjectName__.Tests/__ProjectName__.Tests.csproj'
    ))
    if ($hasFilter -and $filter) {
        $testArguments.Add('--filter')
        $testArguments.Add($filter)
    }
    $expectedCalls.Add($testArguments.ToArray())

    Assert-Equal $expectedCalls.Count $dotnetCalls.Count "$name changed the dotnet call count."
    for ($index = 0; $index -lt $expectedCalls.Count; $index++) {
        Assert-Sequence $expectedCalls[$index] $dotnetCalls[$index] "$name changed dotnet call $index."
    }

    Write-Host "PASS $name"
    return $program
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    [IO.Directory]::CreateDirectory($dockerShimProject) | Out-Null
    $dockerShimCsproj = @'
<Project Sdk="Microsoft.NET.Sdk">
	<PropertyGroup>
		<OutputType>Exe</OutputType>
		<TargetFramework>net10.0</TargetFramework>
		<AssemblyName>docker</AssemblyName>
		<ImplicitUsings>enable</ImplicitUsings>
		<Nullable>enable</Nullable>
	</PropertyGroup>
</Project>
'@
    $dockerShimSource = @'
using System.Text;
using System.Text.Json;

var logPath = Environment.GetEnvironmentVariable("TEST_DOCKER_LOG")
	?? throw new InvalidOperationException("TEST_DOCKER_LOG is required.");
await File.AppendAllTextAsync(
	logPath,
	JsonSerializer.Serialize(args) + "\n",
	new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
'@
    [IO.File]::WriteAllText(
        (Join-Path $dockerShimProject 'docker.csproj'),
        $dockerShimCsproj.Replace("`r`n", "`n"),
        $utf8NoBom)
    [IO.File]::WriteAllText(
        (Join-Path $dockerShimProject 'Program.cs'),
        $dockerShimSource.Replace("`r`n", "`n"),
        $utf8NoBom)
    $publishResult = Invoke-Process $dotnet.Source @(
        'publish',
        (Join-Path $dockerShimProject 'docker.csproj'),
        '--configuration', 'Release',
        '--output', $dockerShimOutput,
        '--nologo',
        '--verbosity', 'quiet'
    ) $tempRoot
    if ($publishResult.ExitCode -ne 0) {
        throw "Failed to build the native Docker argument interceptor.`n$($publishResult.Output)"
    }

    $runner = @'
$ErrorActionPreference = 'Stop'
if (Get-Variable PSNativeCommandArgumentPassing -ErrorAction SilentlyContinue) {
    $PSNativeCommandArgumentPassing = 'Legacy'
}
$env:PATH = "$env:TEST_DOCKER_DIR$([IO.Path]::PathSeparator)$env:PATH"

$invokeParameters = @{
    Image = 'test/image:latest'
    Configuration = $env:TEST_CONFIGURATION
}
if ($env:TEST_HAS_FILTER -eq '1') {
    $filter = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:TEST_FILTER_B64))
    $invokeParameters.Filter = $filter
}
if ($env:TEST_REBUILD -eq '1') {
    $invokeParameters.Rebuild = $true
}

& $env:TEST_LINUX_SCRIPT @invokeParameters
'@
    [IO.File]::WriteAllText($runnerPath, $runner.Replace("`r`n", "`n"), $utf8NoBom)
    $wrapperTemplate = @'
#!/usr/bin/env bash
set -e
decode_into() {
    local name=$1
    local encoded=$2
    local value
    IFS= read -r -d '' value < <(printf '%s' "$encoded" | base64 --decode; printf '\0') || true
    printf -v "$name" '%s' "$value"
}
dotnet() {
    {
        printf 'CALL\0'
        for argument in "$@"; do
            printf 'ARG\0%s\0' "$argument"
        done
        printf 'END\0'
    } >> "$DOTNET_ARGUMENT_LOG"
}
export -f dotnet
decode_into DOTNET_ARGUMENT_LOG '__DOTNET_LOG_B64__'
export DOTNET_ARGUMENT_LOG
decode_into bootstrap '__BOOTSTRAP_B64__'
decode_into program_payload '__PROGRAM_PAYLOAD_B64__'
decode_into configuration '__CONFIGURATION_B64__'
decode_into rebuild '__REBUILD_B64__'
decode_into has_filter '__HAS_FILTER_B64__'
decode_into filter '__FILTER_B64__'
exec bash -c "$bootstrap" "$program_payload" "$configuration" "$rebuild" "$has_filter" "$filter"
'@

    $ordinaryProgram = Invoke-TestCase 'ordinary-filter' 'Release' $false $true 'FullyQualifiedName~Greeter'
    $marker = Join-Path $tempRoot 'FILTER_WAS_EXECUTED'
    $backtickMarker = Join-Path $tempRoot 'FILTER_BACKTICK_WAS_EXECUTED'
    $markerBash = Convert-ToBashPath $marker
    $backtickMarkerBash = Convert-ToBashPath $backtickMarker
    $hostileFilter = 'FullyQualifiedName~\"quoted\" & $(touch "{0}"); `touch "{1}"` \ path' -f $markerBash, $backtickMarkerBash
    $hostileFilter += "`nsecond line"
    $hostileProgram = Invoke-TestCase 'hostile-filter-with-rebuild' 'Debug' $true $true $hostileFilter
    $unfilteredProgram = Invoke-TestCase 'unfiltered' 'Release' $false $false ''

    Assert-Equal $ordinaryProgram $hostileProgram 'The Bash program changed with filter data.'
    Assert-Equal $ordinaryProgram $unfilteredProgram 'The Bash program changed when filtering was disabled.'
    Assert-True (-not (Test-Path -LiteralPath $marker)) 'Command substitution from the filter was executed.'
    Assert-True (-not (Test-Path -LiteralPath $backtickMarker)) 'Backtick substitution from the filter was executed.'
    Write-Host 'All Linux test transport regression tests passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
