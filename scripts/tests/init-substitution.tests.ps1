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
$pwshCommand = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0]

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

function Invoke-WithEnvironment(
    [string]$filePath,
    [string[]]$arguments,
    [string]$workingDirectory,
    [hashtable]$environment,
    [switch]$ExpectFailure
) {
    $previous = @{}
    foreach ($name in $environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$environment[$name], 'Process')
    }

    try {
        return Invoke-Native $filePath $arguments $workingDirectory -ExpectFailure:$ExpectFailure
    }
    finally {
        foreach ($name in $environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
        }
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
    [switch]$ExpectFailure,
    [string]$PathPrefix
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
    $pathSetup = if ($PathPrefix) { "export PATH='$PathPrefix':`$PATH`n" } else { '' }
    $command = @"
#!/usr/bin/env bash
$pathSetup`nexec ./scripts/init.sh \
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

function Get-TreeSnapshot([string]$root) {
    $entries = @()
    foreach ($item in Get-ChildItem -LiteralPath $root -Force -Recurse) {
        $relative = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $target = @($item.Target) -join '|'
            $entries += "L:$relative`:$($item.LinkType):$target`:$([int64]$item.Attributes)"
        }
        elseif ($item.PSIsContainer) {
            $entries += "D:$relative`:$([int64]$item.Attributes)"
        }
        else {
            $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            $entries += "F:$relative`:$hash`:$([int64]$item.Attributes)"
        }
    }
    return @($entries | Sort-Object)
}

function Add-LocalData([string]$root) {
    [IO.File]::WriteAllText(
        (Join-Path $root 'local-__ProjectName__.txt'),
        "local __ProjectName__ __Author__`n",
        $utf8NoBom
    )
    [IO.File]::WriteAllBytes(
        (Join-Path $root 'local-asset.bin'),
        [byte[]](0, 255, 1, 95, 95, 80, 114, 111, 106, 101, 99, 116, 78, 97, 109, 101, 95, 95)
    )

    foreach ($relative in @('.work', '.cache/packages', 'cache-__ProjectName__', 'src/__ProjectName__/local-data')) {
        [IO.Directory]::CreateDirectory((Join-Path $root $relative)) | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $root '.work/state.json'), '{"project":"__ProjectName__"}', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $root '.cache/packages/entry.txt'), '__ProjectName__', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $root 'cache-__ProjectName__/entry.txt'), '__ProjectName__', $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $root 'src/__ProjectName__/local-data/note.txt'), '__ProjectName__', $utf8NoBom)
    [IO.File]::WriteAllBytes(
        (Join-Path $root 'src/__ProjectName__/local-data/payload.bin'),
        [byte[]](0, 16, 32, 127, 128, 254, 255)
    )
}

function Assert-LocalDataPreserved([string]$root, [string]$projectName) {
    Assert-Equal "local __ProjectName__ __Author__`n" ([IO.File]::ReadAllText((Join-Path $root 'local-__ProjectName__.txt'))) 'Unknown text file was renamed or rewritten.'
    Assert-Equal '00-FF-01-5F-5F-50-72-6F-6A-65-63-74-4E-61-6D-65-5F-5F' ([BitConverter]::ToString([IO.File]::ReadAllBytes((Join-Path $root 'local-asset.bin')))) 'Unknown binary file was changed.'
    Assert-Equal '{"project":"__ProjectName__"}' ([IO.File]::ReadAllText((Join-Path $root '.work/state.json'))) '.work content was changed.'
    Assert-Equal '__ProjectName__' ([IO.File]::ReadAllText((Join-Path $root '.cache/packages/entry.txt'))) 'Cache content was changed.'
    Assert-Equal '__ProjectName__' ([IO.File]::ReadAllText((Join-Path $root 'cache-__ProjectName__/entry.txt'))) 'Unknown token-named directory was renamed or rewritten.'
    Assert-Equal '__ProjectName__' ([IO.File]::ReadAllText((Join-Path $root 'src/__ProjectName__/local-data/note.txt'))) 'Unknown file inside the source template directory moved or changed.'
    Assert-Equal '00-10-20-7F-80-FE-FF' ([BitConverter]::ToString([IO.File]::ReadAllBytes((Join-Path $root 'src/__ProjectName__/local-data/payload.bin')))) 'Unknown binary data inside the source template directory moved or changed.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $root "src/$projectName/local-data"))) 'Unknown source-directory content moved into the generated project.'
}

function Test-PreflightCollision([string]$initializer, [string]$collision) {
    $projectName = 'Acme.Collision'
    $root = Join-Path $tempRoot "collision-$initializer-$collision"
    Copy-Template $root
    if ($collision -eq 'settings') {
        [IO.File]::WriteAllText((Join-Path $root '.claude/settings.json'), '{"local":true}', $utf8NoBom)
    }
    else {
        [IO.File]::WriteAllText((Join-Path $root "$projectName.slnx"), 'local solution', $utf8NoBom)
    }
    Add-LocalData $root
    $before = Get-TreeSnapshot $root

    if ($initializer -eq 'pwsh') {
        $result = Invoke-Native 'pwsh' @(
            '-NoProfile',
            '-File', './scripts/init.ps1',
            '-ProjectName', $projectName,
            '-Author', 'Collision Author',
            '-AuthorEmail', 'collision@example.invalid',
            '-GitHubOwner', 'safe-owner',
            '-Description', 'Collision preflight regression',
            '-Year', '2042',
            '-KeepScript'
        ) $root -ExpectFailure
    }
    else {
        $result = Invoke-BashInitializer $root $projectName 'Collision Author' 'collision@example.invalid' 'safe-owner' 'Collision preflight regression' '2042' -ExpectFailure
    }

    $after = Get-TreeSnapshot $root
    Assert-True ($result.Output -match '(?i)collision') "$initializer did not report the $collision collision clearly."
    Assert-True ($result.Output -match 'No files were changed') "$initializer did not report the preflight as non-mutating."
    Assert-True (@(Compare-Object $before $after).Count -eq 0) "$initializer changed the tree after the $collision preflight failure."
    Assert-True (Test-Path -LiteralPath (Join-Path $root 'src/__ProjectName__/__ProjectName__.csproj')) "$initializer partially renamed the project after the $collision preflight failure."
    Assert-True (Test-Path -LiteralPath (Join-Path $root '.claude/settings.json.template')) "$initializer partially activated settings after the $collision preflight failure."
}

function Invoke-InitializerExpectingFailure([string]$initializer, [string]$root, [string]$projectName) {
    if ($initializer -eq 'pwsh') {
        return Invoke-Native 'pwsh' @(
            '-NoProfile',
            '-File', './scripts/init.ps1',
            '-ProjectName', $projectName,
            '-Author', 'Safety Author',
            '-AuthorEmail', 'safety@example.invalid',
            '-GitHubOwner', 'safe-owner',
            '-Description', 'Path safety regression',
            '-Year', '2042',
            '-KeepScript'
        ) $root -ExpectFailure
    }

    return Invoke-BashInitializer $root $projectName 'Safety Author' 'safety@example.invalid' 'safe-owner' 'Path safety regression' '2042' -ExpectFailure
}

function Test-LinkSafety([string]$initializer, [string]$linkKind) {
    $projectName = 'Acme.LinkSafety'
    $root = Join-Path $tempRoot "link-$initializer-$linkKind"
    Copy-Template $root

    if ($linkKind -eq 'file') {
        $externalRoot = Join-Path $tempRoot "external-file-$initializer"
        if ($IsWindows) {
            Move-Item -LiteralPath (Join-Path $root 'docs') -Destination $externalRoot
            New-Item -ItemType Junction -Path (Join-Path $root 'docs') -Target $externalRoot | Out-Null
        }
        else {
            [IO.Directory]::CreateDirectory($externalRoot) | Out-Null
            $externalPath = Join-Path $externalRoot 'README.md'
            [IO.File]::WriteAllText($externalPath, "external __ProjectName__`n", $utf8NoBom)
            Remove-Item -LiteralPath (Join-Path $root 'README.md') -Force
            New-Item -ItemType SymbolicLink -Path (Join-Path $root 'README.md') -Target $externalPath | Out-Null
        }
    }
    else {
        $externalRoot = Join-Path $tempRoot "external-directory-$initializer"
        Move-Item -LiteralPath (Join-Path $root 'src') -Destination $externalRoot
        $itemType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $itemType -Path (Join-Path $root 'src') -Target $externalRoot | Out-Null
    }

    $before = Get-TreeSnapshot $root
    $externalBefore = Get-TreeSnapshot $externalRoot
    $result = Invoke-InitializerExpectingFailure $initializer $root $projectName
    $after = Get-TreeSnapshot $root
    $externalAfter = Get-TreeSnapshot $externalRoot

    Assert-True ($result.Output -match '(?i)(symbolic link|reparse point)') "$initializer did not report the unsafe $linkKind link clearly."
    Assert-True ($result.Output -match 'No files were changed') "$initializer did not report the link rejection as non-mutating."
    Assert-True (@(Compare-Object $before $after).Count -eq 0) "$initializer changed the repository after rejecting the $linkKind link."
    Assert-True (@(Compare-Object $externalBefore $externalAfter).Count -eq 0) "$initializer changed the external $linkKind target."
}

function Test-LateFailureRollback([string]$initializer) {
    $projectName = 'Acme.Rollback'
    $root = Join-Path $tempRoot "rollback-$initializer"
    Copy-Template $root

    if ($initializer -eq 'pwsh') {
        $wrapper = Join-Path $tempRoot 'late-failure-wrapper.ps1'
        $wrapperText = @'
param([string]$Root)
$ErrorActionPreference = 'Stop'
$script:moveCount = 0
function Move-Item {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )
    $script:moveCount++
    if ($script:moveCount -eq 2) {
        throw 'Injected late move I/O failure.'
    }
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination
}
Set-Location $Root
& ./scripts/init.ps1 `
    -ProjectName Acme.Rollback `
    -Author 'Rollback Author' `
    -AuthorEmail rollback@example.invalid `
    -GitHubOwner safe-owner `
    -Description 'Rollback regression' `
    -Year 2042 `
    -KeepScript
'@
        [IO.File]::WriteAllText($wrapper, $wrapperText.Replace("`r`n", "`n"), $utf8NoBom)
        $before = Get-TreeSnapshot $root
        $result = Invoke-Native 'pwsh' @('-NoProfile', '-File', $wrapper, '-Root', $root) $root -ExpectFailure
    }
    else {
        $shimDirectory = Join-Path $root '.test-shim'
        [IO.Directory]::CreateDirectory($shimDirectory) | Out-Null
        $stateName = "csharp-init-mv-$([Guid]::NewGuid().ToString('N'))"
        $realMove = (Invoke-Native 'bash' @('-c', 'command -v mv') $root).Output.Trim()
        $shim = @"
#!/usr/bin/env bash
state='/tmp/$stateName'
count=0
[ ! -f "`$state" ] || count="`$(cat "`$state")"
count=`$((count + 1))
printf '%s' "`$count" > "`$state"
if [ "`$count" -eq 2 ]; then
  echo 'injected late move I/O failure' >&2
  exit 73
fi
exec '$realMove' "`$@"
"@
        [IO.File]::WriteAllText((Join-Path $shimDirectory 'mv'), $shim.Replace("`r`n", "`n"), $utf8NoBom)
        $null = Invoke-Native 'bash' @('-c', 'chmod +x ./.test-shim/mv') $root
        $before = Get-TreeSnapshot $root
        $result = Invoke-BashInitializer $root $projectName 'Rollback Author' 'rollback@example.invalid' 'safe-owner' 'Rollback regression' '2042' -ExpectFailure -PathPrefix './.test-shim'
        $null = Invoke-Native 'bash' @('-c', "rm -f '/tmp/$stateName'") $root
    }

    $after = Get-TreeSnapshot $root
    Assert-True ($result.Output -match '(?i)(rolled back|rollback)') "$initializer did not report rollback after the late failure."
    Assert-True (@(Compare-Object $before $after).Count -eq 0) "$initializer did not restore the complete tree after the late failure."
}

function Get-WorkflowIdentityEnvironment([string]$root) {
    $python = (Get-Command python -ErrorAction SilentlyContinue) ?? (Get-Command python3 -ErrorAction Stop)
    $script = @'
import json
import pathlib

import yaml

workflow = yaml.safe_load(pathlib.Path(".github/workflows/release.yml").read_text(encoding="utf-8"))
release_step = next(
    step
    for step in workflow["jobs"]["release"]["steps"]
    if step.get("name") == "Commit and tag the release (local only)"
)
environment = release_step["env"]
print(json.dumps({
    "RELEASE_AUTHOR_B64": environment["RELEASE_AUTHOR_B64"],
    "RELEASE_AUTHOR_EMAIL_B64": environment["RELEASE_AUTHOR_EMAIL_B64"],
}))
'@
    $result = Invoke-Native $python.Source @('-c', $script) $root
    return $result.Output | ConvertFrom-Json
}

function Assert-WorkflowIdentitySerialization(
    [string]$root,
    [string]$author,
    [string]$authorEmail
) {
    $identityEnvironment = Get-WorkflowIdentityEnvironment $root
    Assert-True ($identityEnvironment.RELEASE_AUTHOR_B64 -is [string]) 'Parsed release author base64 value is not a YAML string.'
    Assert-True ($identityEnvironment.RELEASE_AUTHOR_EMAIL_B64 -is [string]) 'Parsed release author-email base64 value is not a YAML string.'
    $expectedAuthorBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($author))
    $expectedEmailBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($authorEmail))
    Assert-Equal $expectedAuthorBase64 $identityEnvironment.RELEASE_AUTHOR_B64 'YAML parsing changed the release author base64 value.'
    Assert-Equal $expectedEmailBase64 $identityEnvironment.RELEASE_AUTHOR_EMAIL_B64 'YAML parsing changed the release author-email base64 value.'
    $decodedAuthor = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($identityEnvironment.RELEASE_AUTHOR_B64))
    $decodedEmail = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($identityEnvironment.RELEASE_AUTHOR_EMAIL_B64))
    Assert-Equal $author $decodedAuthor 'Release author serialization changed the value.'
    Assert-Equal $authorEmail $decodedEmail 'Release author-email serialization changed the value.'
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
    Assert-WorkflowIdentitySerialization $root $author $authorEmail
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
    $commitStep = [Array]::IndexOf($workflowLines, '      - name: Commit and tag the release (local only)')
    $start = [Array]::IndexOf($workflowLines, '          release_author="$(printf ''%s'' "$RELEASE_AUTHOR_B64" | base64 --decode)"', $commitStep)
    $end = [Array]::IndexOf($workflowLines, '          git config user.email "$release_author_email"', $start)
    Assert-True ($commitStep -ge 0 -and $start -ge $commitStep -and $end -ge $start) 'Could not extract the release identity shell block.'
    $authorBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($author))
    $emailBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($authorEmail))
    $snippetLines = @(
        'set -euo pipefail'
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

function Test-NumericLookingBase64 {
    $projectName = 'Acme.NumericBase64'
    $author = 'Ӎ4'
    $authorEmail = 'numeric@example.invalid'
    $githubOwner = 'safe-owner'
    $description = 'Numeric-looking base64 YAML regression'
    $year = '2042'
    $pwshRoot = Join-Path $tempRoot 'numeric-base64-pwsh'
    $bashRoot = Join-Path $tempRoot 'numeric-base64-bash'
    Copy-Template $pwshRoot
    Copy-Template $bashRoot

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

    Assert-Equal '0400' ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($author))) 'Regression input no longer produces numeric-looking base64.'
    Assert-TreesEqual $pwshRoot $bashRoot
    Assert-WorkflowIdentitySerialization $pwshRoot $author $authorEmail
    Assert-WorkflowIdentitySerialization $bashRoot $author $authorEmail
    Test-GeneratedSyntax $pwshRoot
    Test-GeneratedSyntax $bashRoot
}

function Assert-PowerShellIdentity(
    [string]$root,
    [string]$projectName,
    [string]$author,
    [string]$authorEmail
) {
    $projectXml = [xml][IO.File]::ReadAllText((Join-Path $root "src/$projectName/$projectName.csproj"))
    Assert-Equal $author $projectXml.SelectSingleNode('//Authors').InnerText 'PowerShell initializer selected the wrong author.'
    Assert-WorkflowIdentitySerialization $root $author $authorEmail
}

function Test-PowerShellGitFallbacks {
    $emptyPath = Join-Path $tempRoot 'empty-path'
    [IO.Directory]::CreateDirectory($emptyPath) | Out-Null

    $withoutGitRoot = Join-Path $tempRoot 'pwsh-without-git'
    $withoutGitHome = Join-Path $withoutGitRoot '.isolated-home'
    Copy-Template $withoutGitRoot
    [IO.Directory]::CreateDirectory($withoutGitHome) | Out-Null
    $withoutGitEnvironment = @{
        PATH = $emptyPath
        HOME = $withoutGitHome
        USERPROFILE = $withoutGitHome
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = (Join-Path $withoutGitHome '.gitconfig')
    }
    $null = Invoke-WithEnvironment $pwshCommand.Source @(
        '-NoProfile',
        '-File', './scripts/init.ps1',
        '-ProjectName', 'Acme.NoGit',
        '-GitHubOwner', 'safe-owner',
        '-Description', 'No Git fallback regression',
        '-Year', '2042',
        '-KeepScript'
    ) $withoutGitRoot $withoutGitEnvironment
    Assert-PowerShellIdentity $withoutGitRoot 'Acme.NoGit' 'Your Name' 'you@example.com'

    $null = Get-Command git -CommandType Application -ErrorAction Stop
    $withGitRoot = Join-Path $tempRoot 'pwsh-with-git'
    $withGitHome = Join-Path $withGitRoot '.isolated-home'
    $isolatedConfig = Join-Path $withGitHome '.gitconfig'
    Copy-Template $withGitRoot
    [IO.Directory]::CreateDirectory($withGitHome) | Out-Null
    [IO.File]::WriteAllText(
        $isolatedConfig,
        "[user]`n`tname = Isolated Config Author`n`temail = isolated@example.invalid`n",
        $utf8NoBom
    )
    $withGitEnvironment = @{
        PATH = [Environment]::GetEnvironmentVariable('PATH', 'Process')
        HOME = $withGitHome
        USERPROFILE = $withGitHome
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = $isolatedConfig
    }
    $null = Invoke-WithEnvironment $pwshCommand.Source @(
        '-NoProfile',
        '-File', './scripts/init.ps1',
        '-ProjectName', 'Acme.WithGit',
        '-GitHubOwner', 'safe-owner',
        '-Description', 'Git config regression',
        '-Year', '2042',
        '-KeepScript'
    ) $withGitRoot $withGitEnvironment
    Assert-PowerShellIdentity $withGitRoot 'Acme.WithGit' 'Isolated Config Author' 'isolated@example.invalid'

    $emptyConfigRoot = Join-Path $tempRoot 'pwsh-with-empty-git-config'
    $emptyConfigHome = Join-Path $emptyConfigRoot '.isolated-home'
    $emptyConfig = Join-Path $emptyConfigHome '.gitconfig'
    Copy-Template $emptyConfigRoot
    [IO.Directory]::CreateDirectory($emptyConfigHome) | Out-Null
    [IO.File]::WriteAllText($emptyConfig, '', $utf8NoBom)
    $emptyConfigEnvironment = @{
        PATH = [Environment]::GetEnvironmentVariable('PATH', 'Process')
        HOME = $emptyConfigHome
        USERPROFILE = $emptyConfigHome
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = $emptyConfig
    }
    $null = Invoke-WithEnvironment $pwshCommand.Source @(
        '-NoProfile',
        '-File', './scripts/init.ps1',
        '-ProjectName', 'Acme.EmptyGitConfig',
        '-GitHubOwner', 'safe-owner',
        '-Description', 'Empty Git config regression',
        '-Year', '2042',
        '-KeepScript'
    ) $emptyConfigRoot $emptyConfigEnvironment
    Assert-PowerShellIdentity $emptyConfigRoot 'Acme.EmptyGitConfig' 'Your Name' 'you@example.com'

    $explicitRoot = Join-Path $tempRoot 'pwsh-explicit-without-git'
    $explicitHome = Join-Path $explicitRoot '.isolated-home'
    Copy-Template $explicitRoot
    [IO.Directory]::CreateDirectory($explicitHome) | Out-Null
    $explicitEnvironment = @{
        PATH = $emptyPath
        HOME = $explicitHome
        USERPROFILE = $explicitHome
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = (Join-Path $explicitHome '.gitconfig')
    }
    $null = Invoke-WithEnvironment $pwshCommand.Source @(
        '-NoProfile',
        '-File', './scripts/init.ps1',
        '-ProjectName', 'Acme.Explicit',
        '-Author', 'Explicit Author',
        '-AuthorEmail', 'explicit@example.invalid',
        '-GitHubOwner', 'safe-owner',
        '-Description', 'Explicit identity regression',
        '-Year', '2042',
        '-KeepScript'
    ) $explicitRoot $explicitEnvironment
    Assert-PowerShellIdentity $explicitRoot 'Acme.Explicit' 'Explicit Author' 'explicit@example.invalid'

    $traceRoot = Join-Path $tempRoot 'pwsh-explicit-git-trace'
    $traceHome = Join-Path $traceRoot '.isolated-home'
    $traceFile = Join-Path $traceRoot 'git-trace.json'
    Copy-Template $traceRoot
    [IO.Directory]::CreateDirectory($traceHome) | Out-Null
    $traceEnvironment = @{
        PATH = [Environment]::GetEnvironmentVariable('PATH', 'Process')
        HOME = $traceHome
        USERPROFILE = $traceHome
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_CONFIG_GLOBAL = (Join-Path $traceHome '.gitconfig')
        GIT_TRACE2_EVENT = $traceFile
    }
    $null = Invoke-WithEnvironment $pwshCommand.Source @(
        '-NoProfile',
        '-File', './scripts/init.ps1',
        '-ProjectName', 'Acme.ExplicitTrace',
        '-Author', 'Explicit Author',
        '-AuthorEmail', 'explicit@example.invalid',
        '-GitHubOwner', 'safe-owner',
        '-Description', 'No Git invocation regression',
        '-Year', '2042',
        '-KeepScript'
    ) $traceRoot $traceEnvironment
    Assert-True (-not (Test-Path -LiteralPath $traceFile)) 'Explicit author values unexpectedly launched git.'
    Assert-PowerShellIdentity $traceRoot 'Acme.ExplicitTrace' 'Explicit Author' 'explicit@example.invalid'
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
    Add-LocalData $pwshRoot
    Add-LocalData $bashRoot

    Test-ScriptSyntax $pwshRoot
    Test-PowerShellGitFallbacks
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
    Assert-LocalDataPreserved $pwshRoot $projectName
    Assert-LocalDataPreserved $bashRoot $projectName
    Assert-GeneratedValues $pwshRoot $projectName $author $authorEmail $githubOwner $description $year
    Test-GeneratedSyntax $pwshRoot
    Test-WorkflowIdentity $pwshRoot $author $authorEmail
    Test-NumericLookingBase64
    Test-RejectedInput 'pwsh' 'newline'
    Test-RejectedInput 'bash' 'newline'
    Test-RejectedInput 'pwsh' 'owner'
    Test-RejectedInput 'bash' 'owner'
    Test-PreflightCollision 'pwsh' 'rename'
    Test-PreflightCollision 'bash' 'rename'
    Test-PreflightCollision 'pwsh' 'settings'
    Test-PreflightCollision 'bash' 'settings'
    Test-LinkSafety 'pwsh' 'file'
    Test-LinkSafety 'bash' 'file'
    Test-LinkSafety 'pwsh' 'directory'
    Test-LinkSafety 'bash' 'directory'
    Test-LateFailureRollback 'pwsh'
    Test-LateFailureRollback 'bash'

    if (-not $SkipBuild) {
        $cleanProjectName = 'Acme.CleanInit'
        $cleanPwshRoot = Join-Path $tempRoot 'clean-pwsh'
        $cleanBashRoot = Join-Path $tempRoot 'clean-bash'
        Copy-Template $cleanPwshRoot
        Copy-Template $cleanBashRoot
        $null = Invoke-Native 'pwsh' @(
            '-NoProfile',
            '-File', './scripts/init.ps1',
            '-ProjectName', $cleanProjectName,
            '-Author', 'Clean Build Author',
            '-AuthorEmail', 'clean@example.invalid',
            '-GitHubOwner', 'safe-owner',
            '-Description', 'Clean build regression',
            '-Year', '2042',
            '-KeepScript'
        ) $cleanPwshRoot
        $null = Invoke-BashInitializer $cleanBashRoot $cleanProjectName 'Clean Build Author' 'clean@example.invalid' 'safe-owner' 'Clean build regression' '2042'
        Assert-TreesEqual $cleanPwshRoot $cleanBashRoot
        Test-GeneratedSyntax $cleanPwshRoot
        Test-GeneratedSyntax $cleanBashRoot
        Test-BuildAndTests $cleanPwshRoot $cleanProjectName
        Test-BuildAndTests $cleanBashRoot $cleanProjectName
    }

    Write-Host 'PASS: PowerShell and Bash initialization are scoped, link-safe, transactional, collision-safe, non-cascading, equivalent, syntax-valid, and injection-safe.' -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
