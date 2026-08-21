#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initializes this template into a concrete C# project.

.DESCRIPTION
    Replaces placeholder tokens only in the template-owned files listed by
    scripts/init-plan.tsv, moves the listed project files to their generated
    paths, and removes the listed template-only files. Unless -KeepScript is
    supplied, it also removes both initializers — this script and init.sh.

    The complete plan is validated before the first write. An existing target
    path causes initialization to stop without changing the repository.

    Run it once, right after creating a repository from the template:

        pwsh ./scripts/init.ps1 -ProjectName Acme.Widgets

    Omitted optional values fall back to sensible defaults so the result always
    builds; edit LICENSE / the .csproj afterwards if you need to refine them.

.PARAMETER ProjectName
    Project / namespace / assembly / NuGet package id. Required.
    Letters, digits, underscores; dot-separated segments allowed (e.g. Acme.Widgets).

.PARAMETER Author
    Single-line author for LICENSE, the .csproj, and the release commit. Defaults
    to `git config user.name`, else "Your Name".

.PARAMETER AuthorEmail
    Single-line author email for the release commit. Defaults to
    `git config user.email`, else "you@example.com".

.PARAMETER GitHubOwner
    GitHub owner/org used in repository URLs. Must be a 1-39 character GitHub
    account segment made of letters, digits, and non-edge hyphens. Defaults to
    "your-org".

.PARAMETER Description
    Single-line package description. Defaults to "TODO: project description".

.PARAMETER Year
    Copyright year. Defaults to the current year.

.PARAMETER KeepScript
    Keep this script after running (TEMPLATE.md is removed either way).

.EXAMPLE
    pwsh ./scripts/init.ps1 -ProjectName Acme.Widgets -Author "Jane Doe" -GitHubOwner acme -Description "Widget toolkit"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectName,
    [string]$Author,
    [string]$AuthorEmail,
    [string]$GitHubOwner,
    [string]$Description,
    [int]$Year = (Get-Date).Year,
    [switch]$KeepScript
)

$ErrorActionPreference = 'Stop'

if ($ProjectName -notmatch '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$') {
    throw "Invalid -ProjectName '$ProjectName'. Use letters, digits, underscores; dot-separated segments allowed (e.g. Acme.Widgets)."
}

function Get-GitConfigValue(
    [Management.Automation.ApplicationInfo]$gitCommand,
    [string]$key
) {
    if (-not $gitCommand) {
        return $null
    }

    $nativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        [string]$value = & $gitCommand.Source config --get $key 2>$null
        if ($LASTEXITCODE -eq 0 -and $value) {
            return $value
        }
    }
    catch {
        # Git-backed defaults are optional; an unavailable or broken executable falls back to placeholders.
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
    }

    return $null
}

$gitCommand = if (-not $Author -or -not $AuthorEmail) {
    @(Get-Command git -CommandType Application -ErrorAction SilentlyContinue)[0]
} else {
    $null
}
if (-not $Author) {
    $Author = Get-GitConfigValue $gitCommand 'user.name'
    if (-not $Author) { $Author = 'Your Name' }
}
if (-not $AuthorEmail) {
    $AuthorEmail = Get-GitConfigValue $gitCommand 'user.email'
    if (-not $AuthorEmail) { $AuthorEmail = 'you@example.com' }
}
if (-not $GitHubOwner) { $GitHubOwner = 'your-org' }
if (-not $Description) { $Description = 'TODO: project description' }

foreach ($field in @(
    @{ Name = 'Author'; Value = $Author },
    @{ Name = 'AuthorEmail'; Value = $AuthorEmail },
    @{ Name = 'Description'; Value = $Description }
)) {
    if ($field.Value.Contains("`r") -or $field.Value.Contains("`n")) {
        throw "Invalid -$($field.Name): line breaks are not allowed."
    }
}

if ($GitHubOwner -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$') {
    throw "Invalid -GitHubOwner '$GitHubOwner'. Use 1-39 letters, digits, or hyphens, with no leading or trailing hyphen."
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$selfPath = $PSCommandPath

$replacements = [ordered]@{
    '__ProjectName__'      = $ProjectName
    '__Author__'           = $Author
    '__AuthorEmail__'      = $AuthorEmail
    '__AuthorBase64__'     = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Author))
    '__AuthorEmailBase64__' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($AuthorEmail))
    '__GitHubOwner__'      = $GitHubOwner
    '__Description__'      = $Description
    '__Year__'             = "$Year"
}

# Values written into XML files (e.g. the .csproj <Authors>/<Description>) must be
# XML-escaped — a literal & or < in an author/description would break the project file.
$xmlReplacements = [ordered]@{}
foreach ($key in $replacements.Keys) {
    $xmlReplacements[$key] = $replacements[$key].Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}
$xmlFileExtensions = @('.csproj', '.props', '.targets', '.slnx', '.config')
$escapedTokens = @(
    $replacements.Keys |
        Sort-Object { $_.Length } -Descending |
        ForEach-Object { [Text.RegularExpressions.Regex]::Escape($_) }
)
$tokenPattern = [Text.RegularExpressions.Regex]::new(
    ($escapedTokens -join '|'),
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
)

function Replace-Tokens([string]$text, [Collections.IDictionary]$map) {
    return $tokenPattern.Replace(
        $text,
        [Text.RegularExpressions.MatchEvaluator] {
            param($match)
            return [string]$map[$match.Value]
        }
    )
}

$planPath = Join-Path $PSScriptRoot 'init-plan.tsv'
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) {
    throw "Initialization plan is missing: scripts/init-plan.tsv. No files were changed."
}

function Resolve-PlanPath([string]$pathTemplate) {
    $relative = $pathTemplate.Replace('{ProjectName}', $ProjectName)
    if (
        -not $relative -or
        [IO.Path]::IsPathRooted($relative) -or
        $relative.Contains('\') -or
        @($relative.Split('/') | Where-Object { -not $_ -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0
    ) {
        throw "Unsafe path '$pathTemplate' in scripts/init-plan.tsv. No files were changed."
    }

    $fullPath = [IO.Path]::GetFullPath((Join-Path $repoRoot $relative))
    $rootPrefix = $repoRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $fullPath.StartsWith($rootPrefix, $comparison)) {
        throw "Path '$pathTemplate' escapes the repository in scripts/init-plan.tsv. No files were changed."
    }

    return [pscustomobject]@{
        Relative = $relative
        FullPath = $fullPath
    }
}

function Test-SamePlanPath([string]$left, [string]$right) {
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals($left, $right, $comparison)
}

$plan = @()
$lineNumber = 0
foreach ($line in [IO.File]::ReadAllLines($planPath)) {
    $lineNumber++
    if (-not $line -or $line.StartsWith('#')) {
        continue
    }

    $fields = $line.Split("`t")
    $expectedFields = if ($fields[0] -in @('content', 'remove')) { 2 } else { 3 }
    if ($fields.Count -ne $expectedFields -or $fields[0] -notin @('content', 'directory', 'move', 'activate', 'remove')) {
        throw "Invalid entry at scripts/init-plan.tsv:$lineNumber. No files were changed."
    }

    $source = Resolve-PlanPath $fields[1]
    $destination = if ($expectedFields -eq 3) { Resolve-PlanPath $fields[2] } else { $null }
    $plan += [pscustomobject]@{
        Kind = $fields[0]
        Source = $source
        Destination = $destination
    }
}

if (-not $plan) {
    throw "Initialization plan is empty: scripts/init-plan.tsv. No files were changed."
}

# Build the complete mutation set and every replacement in memory before the
# first write. Paths not listed in the plan are never inspected or modified.
$contentWrites = @()
$plannedDestinations = @{}
foreach ($operation in $plan) {
    $sourceExists = Test-Path -LiteralPath $operation.Source.FullPath
    switch ($operation.Kind) {
        'content' {
            if (-not $sourceExists) {
                continue
            }
            if (-not (Test-Path -LiteralPath $operation.Source.FullPath -PathType Leaf)) {
                throw "Template content path is not a file: $($operation.Source.Relative). No files were changed."
            }

            $text = [IO.File]::ReadAllText($operation.Source.FullPath)
            $extension = [IO.Path]::GetExtension($operation.Source.FullPath)
            $map = if ($xmlFileExtensions -contains $extension) { $xmlReplacements } else { $replacements }
            $newText = Replace-Tokens $text $map
            if ($newText -cne $text) {
                $contentWrites += [pscustomobject]@{
                    Path = $operation.Source
                    Content = $newText
                }
            }
        }
        'directory' {
            if (-not $sourceExists) {
                continue
            }
            if (-not (Test-Path -LiteralPath $operation.Source.FullPath -PathType Container)) {
                throw "Template directory path is not a directory: $($operation.Source.Relative). No files were changed."
            }
            if (Test-SamePlanPath $operation.Source.FullPath $operation.Destination.FullPath) {
                continue
            }
            if (Test-Path -LiteralPath $operation.Destination.FullPath) {
                throw "Initialization target collision: $($operation.Destination.Relative) already exists. No files were changed."
            }
            if ($plannedDestinations.ContainsKey($operation.Destination.FullPath)) {
                throw "Duplicate initialization target: $($operation.Destination.Relative). No files were changed."
            }
            $plannedDestinations[$operation.Destination.FullPath] = $operation.Source.Relative
        }
        { $_ -in @('move', 'activate') } {
            if (-not $sourceExists) {
                continue
            }
            if (-not (Test-Path -LiteralPath $operation.Source.FullPath -PathType Leaf)) {
                throw "Template move source is not a file: $($operation.Source.Relative). No files were changed."
            }
            if (Test-SamePlanPath $operation.Source.FullPath $operation.Destination.FullPath) {
                continue
            }
            if (Test-Path -LiteralPath $operation.Destination.FullPath) {
                throw "Initialization target collision: $($operation.Destination.Relative) already exists. No files were changed."
            }
            if ($plannedDestinations.ContainsKey($operation.Destination.FullPath)) {
                throw "Duplicate initialization target: $($operation.Destination.Relative). No files were changed."
            }

            $destinationParent = Split-Path -Parent $operation.Destination.FullPath
            if ((Test-Path -LiteralPath $destinationParent) -and -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
                throw "Initialization target parent is not a directory: $($operation.Destination.Relative). No files were changed."
            }
            $plannedDestinations[$operation.Destination.FullPath] = $operation.Source.Relative
        }
        'remove' {
            if ($sourceExists -and -not (Test-Path -LiteralPath $operation.Source.FullPath -PathType Leaf)) {
                throw "Template-only removal path is not a file: $($operation.Source.Relative). No files were changed."
            }
        }
    }
}

Write-Host "==> Initializing template as '$ProjectName'" -ForegroundColor Cyan
Write-Host "    Preflight validated $($plan.Count) template-owned operation(s)." -ForegroundColor DarkGray

$utf8NoBom = [Text.UTF8Encoding]::new($false)
foreach ($write in $contentWrites) {
    [IO.File]::WriteAllText($write.Path.FullPath, $write.Content, $utf8NoBom)
}
Write-Host "    Updated contents in $($contentWrites.Count) file(s)." -ForegroundColor DarkGray

# Destination directories are created empty; only listed files move into them.
# Unknown files inside token-named source directories stay at their original paths.
foreach ($operation in $plan | Where-Object Kind -eq 'directory') {
    if (
        (Test-Path -LiteralPath $operation.Source.FullPath -PathType Container) -and
        -not (Test-SamePlanPath $operation.Source.FullPath $operation.Destination.FullPath)
    ) {
        [IO.Directory]::CreateDirectory($operation.Destination.FullPath) | Out-Null
    }
}

foreach ($operation in $plan | Where-Object Kind -in @('move', 'activate')) {
    if (
        (Test-Path -LiteralPath $operation.Source.FullPath -PathType Leaf) -and
        -not (Test-SamePlanPath $operation.Source.FullPath $operation.Destination.FullPath)
    ) {
        Move-Item -LiteralPath $operation.Source.FullPath -Destination $operation.Destination.FullPath
        Write-Host "    Moved $($operation.Source.Relative) -> $($operation.Destination.Relative)" -ForegroundColor DarkGray
    }
}

foreach ($operation in $plan | Where-Object Kind -eq 'remove') {
    if (Test-Path -LiteralPath $operation.Source.FullPath -PathType Leaf) {
        Remove-Item -LiteralPath $operation.Source.FullPath -Force
        Write-Host "    Removed $($operation.Source.Relative)" -ForegroundColor DarkGray
    }
}

$directoryOperations = @($plan | Where-Object Kind -eq 'directory')
[array]::Reverse($directoryOperations)
foreach ($operation in $directoryOperations) {
    if (
        (Test-Path -LiteralPath $operation.Source.FullPath -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $operation.Source.FullPath -Force)
    ) {
        Remove-Item -LiteralPath $operation.Source.FullPath -Force
    }
}

foreach ($relativeDirectory in @('docs', 'scripts/tests')) {
    $directory = Join-Path $repoRoot $relativeDirectory
    if ((Test-Path -LiteralPath $directory -PathType Container) -and -not (Get-ChildItem -LiteralPath $directory -Force)) {
        Remove-Item -LiteralPath $directory -Force
    }
}

Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Green
Write-Host "  1. dotnet build $ProjectName.slnx"
Write-Host "  2. dotnet test  $ProjectName.slnx"
Write-Host "  3. Review LICENSE (author/year) and the .csproj package metadata."
Write-Host "  4. NuGet publishing: add the NUGET_API_KEY repo secret, or delete"
Write-Host "     .github/workflows/release.yml and the packaging properties in the .csproj."
Write-Host "  5. Commit the initialized project."

# Remove both initializers unless asked to keep them.
if (-not $KeepScript) {
    $siblingSh = Join-Path $PSScriptRoot 'init.sh'
    if (Test-Path -LiteralPath $siblingSh) {
        Remove-Item -LiteralPath $siblingSh -Force
    }
    Remove-Item -LiteralPath $selfPath -Force
}
