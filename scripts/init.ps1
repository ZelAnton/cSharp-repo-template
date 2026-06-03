#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Initializes this template into a concrete C# project.

.DESCRIPTION
    Replaces the placeholder tokens (__ProjectName__, __Author__, __AuthorEmail__,
    __GitHubOwner__, __Description__, __Year__) in file contents AND in file/folder names, then
    removes the template-only files (TEMPLATE.md, docs/AGENT-INIT-GUIDE.md, and,
    unless -KeepScript, both initializers — this script and init.sh).

    Run it once, right after creating a repository from the template:

        pwsh ./scripts/init.ps1 -ProjectName Acme.Widgets

    Omitted optional values fall back to sensible defaults so the result always
    builds; edit LICENSE / the .csproj afterwards if you need to refine them.

.PARAMETER ProjectName
    Project / namespace / assembly / NuGet package id. Required.
    Letters, digits, underscores; dot-separated segments allowed (e.g. Acme.Widgets).

.PARAMETER Author
    Author for LICENSE and the .csproj. Defaults to `git config user.name`, else "Your Name".

.PARAMETER AuthorEmail
    Author email for the release commit. Defaults to `git config user.email`, else "you@example.com".

.PARAMETER GitHubOwner
    GitHub owner/org used in repository URLs. Defaults to "your-org".

.PARAMETER Description
    Short package description. Defaults to "TODO: project description".

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

if (-not $Author) {
    $Author = (& git config user.name 2>$null)
    if (-not $Author) { $Author = 'Your Name' }
}
if (-not $AuthorEmail) {
    $AuthorEmail = (& git config user.email 2>$null)
    if (-not $AuthorEmail) { $AuthorEmail = 'you@example.com' }
}
if (-not $GitHubOwner) { $GitHubOwner = 'your-org' }
if (-not $Description) { $Description = 'TODO: project description' }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$selfPath = $PSCommandPath

$replacements = [ordered]@{
    '__ProjectName__' = $ProjectName
    '__Author__'      = $Author
    '__AuthorEmail__' = $AuthorEmail
    '__GitHubOwner__' = $GitHubOwner
    '__Description__' = $Description
    '__Year__'        = "$Year"
}

# Values written into XML files (e.g. the .csproj <Authors>/<Description>) must be
# XML-escaped — a literal & or < in an author/description would break the project file.
$xmlReplacements = [ordered]@{}
foreach ($key in $replacements.Keys) {
    $xmlReplacements[$key] = $replacements[$key].Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}
$xmlFileExtensions = @('.csproj', '.props', '.targets', '.slnx', '.config')

# Binary files carry no tokens; reading/rewriting them as text would corrupt them.
# The template ships none, but a downstream user may add e.g. a strong-name key or
# a NuGet package icon before running init, so skip them by extension.
$binaryExtensions = @('.snk', '.pfx', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.zip')

$excludedDirs = @('.git', '.jj', 'bin', 'obj')

function Test-Excluded([string]$fullPath) {
    $rel = $fullPath.Substring($repoRoot.Length).TrimStart('\', '/')
    foreach ($seg in ($rel -split '[\\/]')) {
        if ($excludedDirs -contains $seg) { return $true }
    }
    return $false
}

Write-Host "==> Initializing template as '$ProjectName'" -ForegroundColor Cyan

# 1) Replace tokens in file contents. Both initializers are skipped: they carry
#    the placeholder search-keys as literals, so substituting them would corrupt
#    the sibling script (which -KeepScript leaves on disk).
$siblingShPath = Join-Path $PSScriptRoot 'init.sh'
$files = Get-ChildItem -Path $repoRoot -File -Recurse | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.FullName -ne $selfPath -and $_.FullName -ne $siblingShPath
}
$contentChanged = 0
foreach ($file in $files) {
    if ($binaryExtensions -contains $file.Extension) { continue }
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $new = $text
    $map = if ($xmlFileExtensions -contains $file.Extension) { $xmlReplacements } else { $replacements }
    foreach ($key in $map.Keys) {
        $new = $new.Replace($key, $map[$key])
    }
    if ($new -ne $text) {
        [System.IO.File]::WriteAllText($file.FullName, $new, (New-Object System.Text.UTF8Encoding($false)))
        $contentChanged++
    }
}
Write-Host "    Updated contents in $contentChanged file(s)." -ForegroundColor DarkGray

# 2) Rename files and folders whose name contains the project-name token.
#    Deepest paths first so child renames don't invalidate parent paths.
$named = Get-ChildItem -Path $repoRoot -Recurse | Where-Object {
    -not (Test-Excluded $_.FullName) -and $_.Name -like '*__ProjectName__*'
} | Sort-Object { $_.FullName.Length } -Descending
foreach ($item in $named) {
    $newName = $item.Name.Replace('__ProjectName__', $ProjectName)
    Rename-Item -LiteralPath $item.FullName -NewName $newName
    Write-Host "    Renamed $($item.Name) -> $newName" -ForegroundColor DarkGray
}

# 3) Activate the Claude Code shared settings. Shipped inert as a .template file
#    so the template repository itself does not auto-grant any permissions.
$claudeTemplate = Join-Path $repoRoot '.claude/settings.json.template'
if (Test-Path $claudeTemplate) {
    Move-Item -LiteralPath $claudeTemplate -Destination (Join-Path $repoRoot '.claude/settings.json') -Force
    Write-Host "    Activated .claude/settings.json" -ForegroundColor DarkGray
}

# 4) Remove template-only files — documentation that only applies while this is a
#    template, not after it has been stamped into a concrete project.
$templateOnly = @(
    (Join-Path $repoRoot 'TEMPLATE.md'),
    (Join-Path $repoRoot 'docs/AGENT-INIT-GUIDE.md')
)
foreach ($path in $templateOnly) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "    Removed $($path.Substring($repoRoot.Length).TrimStart('\','/'))" -ForegroundColor DarkGray
    }
}

# Drop docs/ if it's now empty (it usually isn't — linux-testing.md also lives here).
$docsDir = Join-Path $repoRoot 'docs'
if ((Test-Path -LiteralPath $docsDir) -and -not (Get-ChildItem -LiteralPath $docsDir -Force)) {
    Remove-Item -LiteralPath $docsDir -Force
    Write-Host "    Removed docs" -ForegroundColor DarkGray
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
