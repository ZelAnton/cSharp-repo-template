#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "csharp-template-init-$([Guid]::NewGuid().ToString('N'))"
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Assert-Equal([string]$expected, [string]$actual, [string]$message) {
    if ($actual -cne $expected) {
        throw "$message`nExpected: <$expected>`nActual:   <$actual>"
    }
}

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) {
        throw $message
    }
}

function Invoke-Native(
    [string]$filePath,
    [string[]]$arguments,
    [string]$workingDirectory,
    [switch]$ExpectFailure
) {
    Push-Location $workingDirectory
    try {
        $output = @(& $filePath @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $outputText = ($output | ForEach-Object { $_.ToString() }) -join "`n"
    if ($ExpectFailure) {
        if ($exitCode -eq 0) {
            throw "Expected '$filePath $($arguments -join ' ')' to fail."
        }
    }
    elseif ($exitCode -ne 0) {
        throw "'$filePath $($arguments -join ' ')' failed with exit code $exitCode.`n$outputText"
    }
    elseif ($outputText) {
        Write-Host $outputText
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $outputText
    }
}

function Invoke-BashInitializer(
    [string]$workingDirectory,
    [string]$projectName,
    [string]$author,
    [string]$authorEmail,
    [string]$githubOwner,
    [string]$description,
    [string]$year,
    [switch]$ExpectFailure
) {
    $encodedValues = @(
        $projectName,
        $author,
        $authorEmail,
        $githubOwner,
        $description,
        $year
    ) | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }
    $runnerFile = Join-Path $workingDirectory '.init-test-runner.sh'
    $command = @"
#!/usr/bin/env bash
exec ./scripts/init.sh \
  --project-name "`$(printf '%s' '$($encodedValues[0])' | base64 --decode)" \
  --author "`$(printf '%s' '$($encodedValues[1])' | base64 --decode)" \
  --author-email "`$(printf '%s' '$($encodedValues[2])' | base64 --decode)" \
  --github-owner "`$(printf '%s' '$($encodedValues[3])' | base64 --decode)" \
  --description "`$(printf '%s' '$($encodedValues[4])' | base64 --decode)" \
  --year "`$(printf '%s' '$($encodedValues[5])' | base64 --decode)" \
  --keep-script
"@
    [IO.File]::WriteAllText($runnerFile, $command.Replace("`r`n", "`n"), $utf8NoBom)
    try {
        return Invoke-Native 'bash' @('./.init-test-runner.sh') $workingDirectory -ExpectFailure:$ExpectFailure
    }
    finally {
        Remove-Item -LiteralPath $runnerFile -Force -ErrorAction SilentlyContinue
    }
}

function Copy-Template([string]$destination) {
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $excluded = @('.git', '.jj', '.work', 'bin', 'obj', 'artifacts')
    foreach ($file in Get-ChildItem -LiteralPath $repoRoot -File -Force -Recurse) {
        $relative = [IO.Path]::GetRelativePath($repoRoot, $file.FullName)
        $segments = $relative -split '[\\/]'
        if (@($segments | Where-Object { $excluded -contains $_ }).Count -gt 0) {
            continue
        }

        $target = Join-Path $destination $relative
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
        [IO.File]::Copy($file.FullName, $target, $true)
    }
}

function Get-RelativeFiles([string]$root) {
    return @(
        Get-ChildItem -LiteralPath $root -File -Force -Recurse |
            ForEach-Object { [IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') } |
            Sort-Object
    )
}

function Assert-TreesEqual([string]$left, [string]$right) {
    $leftFiles = Get-RelativeFiles $left
    $rightFiles = Get-RelativeFiles $right
    $pathDifference = @(Compare-Object $leftFiles $rightFiles)
    if ($pathDifference.Count -gt 0) {
        throw "Generated file sets differ:`n$($pathDifference | Out-String)"
    }

    foreach ($relative in $leftFiles) {
        $leftHash = (Get-FileHash -LiteralPath (Join-Path $left $relative) -Algorithm SHA256).Hash
        $rightHash = (Get-FileHash -LiteralPath (Join-Path $right $relative) -Algorithm SHA256).Hash
        Assert-Equal $leftHash $rightHash "Generated file differs: $relative"
    }
}

function Assert-GeneratedValues(
    [string]$root,
    [string]$projectName,
    [string]$author,
    [string]$authorEmail,
    [string]$githubOwner,
    [string]$description,
    [string]$year
) {
    $projectPath = Join-Path $root "src/$projectName/$projectName.csproj"
    $projectXml = [xml][IO.File]::ReadAllText($projectPath)
    Assert-Equal $author $projectXml.SelectSingleNode('//Authors').InnerText 'XML author was not preserved.'
    Assert-Equal $description $projectXml.SelectSingleNode('//Description').InnerText 'XML description was not preserved.'

    $readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
    Assert-True $readme.StartsWith("# $projectName`n`n$description`n") 'README description was not preserved.'
    Assert-True $readme.Contains('__Author__') 'Placeholder-like description input cascaded.'

    $license = [IO.File]::ReadAllText((Join-Path $root 'LICENSE'))
    Assert-True $license.Contains("Copyright (c) $year $author") 'LICENSE author was not preserved.'
    Assert-True $license.Contains('__GitHubOwner__') 'Placeholder-like author input cascaded.'

    $workflow = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/release.yml'))
    $authorMatch = [regex]::Match($workflow, '(?m)^\s*RELEASE_AUTHOR_B64:\s*(\S+)\s*$')
    $emailMatch = [regex]::Match($workflow, '(?m)^\s*RELEASE_AUTHOR_EMAIL_B64:\s*(\S+)\s*$')
    Assert-True $authorMatch.Success 'Release author base64 value is missing.'
    Assert-True $emailMatch.Success 'Release author-email base64 value is missing.'
    $decodedAuthor = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($authorMatch.Groups[1].Value))
    $decodedEmail = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($emailMatch.Groups[1].Value))
    Assert-Equal $author $decodedAuthor 'Release author serialization changed the value.'
    Assert-Equal $authorEmail $decodedEmail 'Release author-email serialization changed the value.'
    Assert-True $workflow.Contains("repo = `"https://github.com/$githubOwner/$projectName`"") 'Python repository URL was not generated safely.'
}

function Test-ScriptSyntax([string]$root) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root 'scripts/init.ps1'),
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count -gt 0) {
        throw "PowerShell initializer syntax errors:`n$($errors | Out-String)"
    }

    $null = Invoke-Native 'bash' @('-n', './scripts/init.sh') $root
}

function Test-GeneratedSyntax([string]$root) {
    $yamlLint = Get-Command yamllint -ErrorAction SilentlyContinue
    if ($yamlLint) {
        $null = Invoke-Native $yamlLint.Source @('-c', '.yamllint.yml', '.github/workflows/release.yml') $root
    }
    else {
        $python = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction Stop)
        $null = Invoke-Native $python.Source @('-c', 'import pathlib, yaml; yaml.safe_load(pathlib.Path(".github/workflows/release.yml").read_text())') $root
    }

    $workflow = [IO.File]::ReadAllText((Join-Path $root '.github/workflows/release.yml'))
    $pythonBlocks = [regex]::Matches($workflow, "(?ms)^          python3 <<'PY'\r?\n(?<code>.*?)^          PY\s*$")
    Assert-True ($pythonBlocks.Count -gt 0) 'No embedded Python blocks were found in release.yml.'
    $pythonCommand = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction Stop)
    for ($index = 0; $index -lt $pythonBlocks.Count; $index++) {
        $lines = $pythonBlocks[$index].Groups['code'].Value -split "\r?\n"
        $dedented = ($lines | ForEach-Object { if ($_.StartsWith('          ')) { $_.Substring(10) } else { $_ } }) -join "`n"
        $path = Join-Path $root ".init-python-$index.py"
        [IO.File]::WriteAllText($path, "$dedented`n", $utf8NoBom)
        $null = Invoke-Native $pythonCommand.Source @('-m', 'py_compile', $path) $root
        Remove-Item -LiteralPath $path -Force
    }
}

function Test-WorkflowIdentity(
    [string]$root,
    [string]$author,
    [string]$authorEmail
) {
    $workflowLines = [IO.File]::ReadAllLines((Join-Path $root '.github/workflows/release.yml'))
    $start = [Array]::IndexOf($workflowLines, '          set -euo pipefail', 340)
    $end = [Array]::IndexOf($workflowLines, '          git config user.email "$release_author_email"', $start)
    Assert-True ($start -ge 0 -and $end -ge $start) 'Could not extract the release identity shell block.'
    $authorBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($author))
    $emailBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($authorEmail))
    $snippetLines = @(
        "export RELEASE_AUTHOR_B64='$authorBase64'"
        "export RELEASE_AUTHOR_EMAIL_B64='$emailBase64'"
    ) + @($workflowLines[$start..$end] | ForEach-Object { $_.Substring(10) })
    $snippetPath = Join-Path $root '.init-workflow-identity.sh'
    [IO.File]::WriteAllText($snippetPath, (($snippetLines -join "`n") + "`n"), $utf8NoBom)

    $null = Invoke-Native 'bash' @('-c', 'git init -q') $root
    $null = Invoke-Native 'bash' @('./.init-workflow-identity.sh') $root
    $configured = Invoke-Native 'bash' @('-c', 'git config user.name; git config user.email') $root

    $configuredLines = $configured.Output -split "\r?\n"
    Assert-Equal $author $configuredLines[0] 'Workflow shell changed the configured author.'
    Assert-Equal $authorEmail $configuredLines[1] 'Workflow shell changed the configured author email.'
    Assert-True (-not (Test-Path (Join-Path $root 'INIT_AUTHOR_INJECTED'))) 'Author input executed a shell command.'
    Assert-True (-not (Test-Path (Join-Path $root 'INIT_AUTHOR_BACKTICKED'))) 'Backtick author input executed a shell command.'
    Assert-True (-not (Test-Path (Join-Path $root 'INIT_EMAIL_INJECTED'))) 'Author-email input executed a shell command.'
    Remove-Item -LiteralPath $snippetPath -Force
    Remove-Item -LiteralPath (Join-Path $root '.git') -Recurse -Force
}

function Test-RejectedInput([string]$initializer, [string]$field) {
    $root = Join-Path $tempRoot "reject-$initializer-$field"
    Copy-Template $root
    if ($initializer -eq 'pwsh') {
        $arguments = @('-NoProfile', '-File', './scripts/init.ps1', '-ProjectName', 'Acme.Rejected')
        if ($field -eq 'newline') {
            $arguments += @('-Description', "first`nsecond")
        }
        else {
            $arguments += @('-GitHubOwner', 'owner;touch-INJECTED')
        }
        $null = Invoke-Native 'pwsh' $arguments $root -ExpectFailure
    }
    else {
        $description = 'valid description'
        $githubOwner = 'valid-owner'
        if ($field -eq 'newline') {
            $description = "first`nsecond"
        }
        else {
            $githubOwner = 'owner;touch-INJECTED'
        }
        $null = Invoke-BashInitializer $root 'Acme.Rejected' 'Valid Author' 'valid@example.invalid' $githubOwner $description '2042' -ExpectFailure
    }

    Assert-True (Test-Path -LiteralPath (Join-Path $root 'src/__ProjectName__')) 'Rejected input modified the template before failing.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'INJECTED'))) 'Rejected input executed a command.'
}

function Test-BuildAndTests([string]$root, [string]$projectName) {
    $null = Invoke-Native 'dotnet' @('build', "$projectName.slnx") $root
    $test = Invoke-Native 'dotnet' @(
        'test',
        "tests/$projectName.Tests/$projectName.Tests.csproj",
        '--no-build',
        '--logger', 'console;verbosity=normal'
    ) $root
    Assert-True ($test.Output -match 'NUnit3TestExecutor discovered\s+[1-9][0-9]*\s+of\s+[1-9][0-9]*') 'NUnit discovery was not reported.'
    $hasMicrosoftTestingPlatformSummary = $test.Output -match 'Test summary:\s+total:\s+[1-9][0-9]*,\s+failed:\s+0,\s+succeeded:\s+[1-9][0-9]*'
    $hasVstestSummary = $test.Output -match '(?s)Test Run Successful\..*Total tests:\s+[1-9][0-9]*.*Passed:\s+[1-9][0-9]*'
    Assert-True ($hasMicrosoftTestingPlatformSummary -or $hasVstestSummary) 'A successful non-empty test summary was not reported.'
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $projectName = 'Acme.SafeInit'
    $author = 'A "quoted" \ $(touch INIT_AUTHOR_INJECTED); `touch INIT_AUTHOR_BACKTICKED` & <tag> __GitHubOwner__'
    $authorEmail = 'mail\"$(touch INIT_EMAIL_INJECTED);__Description__@example.invalid'
    $githubOwner = 'safe-owner'
    $description = 'Text "quoted" \ $() ; & <tag> # [link] __Author__'
    $year = '2042'
    $pwshRoot = Join-Path $tempRoot 'pwsh'
    $bashRoot = Join-Path $tempRoot 'bash'
    Copy-Template $pwshRoot
    Copy-Template $bashRoot

    Test-ScriptSyntax $pwshRoot
    $null = Invoke-Native 'pwsh' @(
        '-NoProfile',
        '-File', './scripts/init.ps1',
        '-ProjectName', $projectName,
        '-Author', $author,
        '-AuthorEmail', $authorEmail,
        '-GitHubOwner', $githubOwner,
        '-Description', $description,
        '-Year', $year,
        '-KeepScript'
    ) $pwshRoot
    $null = Invoke-BashInitializer $bashRoot $projectName $author $authorEmail $githubOwner $description $year

    Assert-TreesEqual $pwshRoot $bashRoot
    Assert-GeneratedValues $pwshRoot $projectName $author $authorEmail $githubOwner $description $year
    Test-GeneratedSyntax $pwshRoot
    Test-WorkflowIdentity $pwshRoot $author $authorEmail
    Test-RejectedInput 'pwsh' 'newline'
    Test-RejectedInput 'bash' 'newline'
    Test-RejectedInput 'pwsh' 'owner'
    Test-RejectedInput 'bash' 'owner'

    if (-not $SkipBuild) {
        Test-BuildAndTests $pwshRoot $projectName
        Test-BuildAndTests $bashRoot $projectName
    }

    Write-Host 'PASS: PowerShell and Bash initialization are non-cascading, equivalent, syntax-valid, and injection-safe.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
