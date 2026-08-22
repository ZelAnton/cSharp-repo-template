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

if ($IsWindows -and -not ('TemplateInitializerWindowsAccess' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class TemplateInitializerWindowsAccess
{
    private const uint TokenDuplicate = 0x0002;
    private const uint TokenQuery = 0x0008;
    private const int SecurityImpersonation = 2;
    private const int ErrorInsufficientBuffer = 122;

    [StructLayout(LayoutKind.Sequential)]
    private struct GenericMapping
    {
        internal uint GenericRead;
        internal uint GenericWrite;
        internal uint GenericExecute;
        internal uint GenericAll;
    }

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(
        IntPtr processHandle,
        uint desiredAccess,
        out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateToken(
        IntPtr existingTokenHandle,
        int impersonationLevel,
        out IntPtr duplicateTokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AccessCheck(
        [In] byte[] securityDescriptor,
        IntPtr clientToken,
        uint desiredAccess,
        ref GenericMapping genericMapping,
        IntPtr privilegeSet,
        ref uint privilegeSetLength,
        out uint grantedAccess,
        [MarshalAs(UnmanagedType.Bool)] out bool accessStatus);

    public static bool IsGranted(byte[] securityDescriptor, uint desiredAccess)
    {
        IntPtr primaryToken = IntPtr.Zero;
        IntPtr impersonationToken = IntPtr.Zero;
        IntPtr privilegeSet = IntPtr.Zero;
        try
        {
            if (!OpenProcessToken(GetCurrentProcess(), TokenQuery | TokenDuplicate, out primaryToken))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (!DuplicateToken(primaryToken, SecurityImpersonation, out impersonationToken))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            GenericMapping mapping = new GenericMapping
            {
                GenericRead = 0x00120089,
                GenericWrite = 0x00120116,
                GenericExecute = 0x001200A0,
                GenericAll = 0x001F01FF,
            };
            uint privilegeSetLength = 0;
            uint grantedAccess;
            bool accessStatus;
            if (AccessCheck(
                securityDescriptor,
                impersonationToken,
                desiredAccess,
                ref mapping,
                IntPtr.Zero,
                ref privilegeSetLength,
                out grantedAccess,
                out accessStatus))
            {
                return accessStatus && (grantedAccess & desiredAccess) == desiredAccess;
            }

            int error = Marshal.GetLastWin32Error();
            if (error != ErrorInsufficientBuffer)
            {
                throw new Win32Exception(error);
            }

            privilegeSet = Marshal.AllocHGlobal(checked((int)privilegeSetLength));
            if (!AccessCheck(
                securityDescriptor,
                impersonationToken,
                desiredAccess,
                ref mapping,
                privilegeSet,
                ref privilegeSetLength,
                out grantedAccess,
                out accessStatus))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return accessStatus && (grantedAccess & desiredAccess) == desiredAccess;
        }
        finally
        {
            if (privilegeSet != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(privilegeSet);
            }
            if (impersonationToken != IntPtr.Zero)
            {
                CloseHandle(impersonationToken);
            }
            if (primaryToken != IntPtr.Zero)
            {
                CloseHandle(primaryToken);
            }
        }
    }
}
'@
}

function Test-WindowsEffectiveAccess([string]$fullPath, [Security.AccessControl.FileSystemRights]$right) {
    $sections =
        [Security.AccessControl.AccessControlSections]::Owner -bor
        [Security.AccessControl.AccessControlSections]::Group -bor
        [Security.AccessControl.AccessControlSections]::Access
    $security = if (Test-Path -LiteralPath $fullPath -PathType Container) {
        [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($fullPath), $sections)
    }
    else {
        [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($fullPath), $sections)
    }
    return [TemplateInitializerWindowsAccess]::IsGranted(
        $security.GetSecurityDescriptorBinaryForm(),
        [uint32][int64]$right
    )
}

function Assert-ContentCanBeReplaced([pscustomobject]$path, [string]$role) {
    Assert-FileCanBeChanged $path $role
    $parent = [IO.Path]::GetDirectoryName($path.FullPath)
    if ($IsWindows) {
        try {
            $canCreateTemporary = Test-WindowsEffectiveAccess $parent ([Security.AccessControl.FileSystemRights]::CreateFiles)
            $canDeleteTarget = Test-WindowsEffectiveAccess $path.FullPath ([Security.AccessControl.FileSystemRights]::Delete)
            $canDeleteChild = Test-WindowsEffectiveAccess $parent ([Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles)
        }
        catch {
            throw "$role replacement permissions cannot be validated: $($path.Relative). No files were changed."
        }
        if (-not $canCreateTemporary) {
            throw "$role parent does not permit a sibling temporary file: $($path.Relative). No files were changed."
        }
        if (-not ($canDeleteTarget -or $canDeleteChild)) {
            throw "$role directory entry cannot be replaced: $($path.Relative). No files were changed."
        }
    }
    else {
        Assert-DirectoryCanBeChanged $parent $path.Relative "$role replacement"
    }
}

function Assert-NoReparsePoint([pscustomobject]$path, [string]$role) {
    $current = $repoRoot
    foreach ($segment in $path.Relative.Split('/')) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Unsafe reparse point in $role path '$($path.Relative)'. No files were changed."
        }
    }
}

function Assert-FileCanBeChanged([pscustomobject]$path, [string]$role) {
    $attributes = [IO.File]::GetAttributes($path.FullPath)
    if ($attributes -band [IO.FileAttributes]::ReadOnly) {
        throw "$role path is read-only: $($path.Relative). No files were changed."
    }

    $stream = $null
    try {
        $stream = [IO.File]::Open($path.FullPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    }
    catch {
        throw "$role path is not writable: $($path.Relative). No files were changed."
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Get-FileMetadata([string]$fullPath) {
    $item = Get-Item -LiteralPath $fullPath -Force
    $securityDescriptor = $null
    if ($IsWindows) {
        $sections =
            [Security.AccessControl.AccessControlSections]::Owner -bor
            [Security.AccessControl.AccessControlSections]::Group -bor
            [Security.AccessControl.AccessControlSections]::Access
        try {
            $security = [IO.FileSystemAclExtensions]::GetAccessControl(
                [IO.FileInfo]::new($fullPath),
                $sections
            )
            $securityDescriptor = $security.GetSecurityDescriptorSddlForm($sections)
        }
        catch {
            throw "File security metadata cannot be read: $fullPath. No files were changed."
        }
    }

    return [pscustomobject]@{
        Attributes = $item.Attributes
        CreationTimeUtc = if ($IsWindows) { $item.CreationTimeUtc } else { $null }
        LastAccessTimeUtc = $item.LastAccessTimeUtc
        LastWriteTimeUtc = $item.LastWriteTimeUtc
        UnixFileMode = if ($IsWindows) { $null } else { [IO.File]::GetUnixFileMode($fullPath) }
        SecurityDescriptor = $securityDescriptor
    }
}

function Set-FileMetadata([string]$fullPath, [pscustomobject]$metadata) {
    if ($IsWindows) {
        $sections =
            [Security.AccessControl.AccessControlSections]::Owner -bor
            [Security.AccessControl.AccessControlSections]::Group -bor
            [Security.AccessControl.AccessControlSections]::Access
        try {
            $security = [Security.AccessControl.FileSecurity]::new()
            $security.SetSecurityDescriptorSddlForm($metadata.SecurityDescriptor, $sections)
            [IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($fullPath), $security)
        }
        catch {
            throw "File security metadata cannot be preserved: $fullPath."
        }
        [IO.File]::SetCreationTimeUtc($fullPath, $metadata.CreationTimeUtc)
    }
    else {
        [IO.File]::SetUnixFileMode($fullPath, $metadata.UnixFileMode)
    }

    [IO.File]::SetLastAccessTimeUtc($fullPath, $metadata.LastAccessTimeUtc)
    [IO.File]::SetLastWriteTimeUtc($fullPath, $metadata.LastWriteTimeUtc)
    [IO.File]::SetAttributes($fullPath, $metadata.Attributes)
}

function Set-PostReplacementMetadata([string]$fullPath, [pscustomobject]$metadata) {
    if ($IsWindows) {
        # NTFS name tunneling can replace the prepared file's creation time during the move.
        [IO.File]::SetCreationTimeUtc($fullPath, $metadata.CreationTimeUtc)
    }
    [IO.File]::SetLastAccessTimeUtc($fullPath, $metadata.LastAccessTimeUtc)
    [IO.File]::SetLastWriteTimeUtc($fullPath, $metadata.LastWriteTimeUtc)
    [IO.File]::SetAttributes($fullPath, $metadata.Attributes)
}

function Set-FileContentSafely(
    [pscustomobject]$path,
    [string]$content,
    [Text.Encoding]$encoding,
    [pscustomobject]$backup,
    [Collections.Generic.List[object]]$mutatedBackups,
    [Collections.Generic.HashSet[string]]$mutatedBackupPaths
) {
    $metadata = Get-FileMetadata $path.FullPath
    $temporaryPath = Join-Path ([IO.Path]::GetDirectoryName($path.FullPath)) ".csharp-template-init-$([Guid]::NewGuid().ToString('N')).tmp"
    $stream = $null
    $writer = $null
    $swapped = $false
    try {
        $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $writer = [IO.StreamWriter]::new($stream, $encoding)
        $writer.Write($content)
        $writer.Dispose()
        $writer = $null
        $stream = $null

        Set-FileMetadata $temporaryPath $metadata

        # Replacing the directory entry prevents a hard-linked peer outside the repository from being truncated.
        [IO.File]::Move($temporaryPath, $path.FullPath, $true)
        $swapped = $true
        if ($mutatedBackupPaths.Add($backup.Original)) {
            $mutatedBackups.Add($backup)
        }
        Set-PostReplacementMetadata $path.FullPath $metadata
    }
    finally {
        try {
            if ($writer) {
                $writer.Dispose()
            }
            elseif ($stream) {
                $stream.Dispose()
            }
        }
        finally {
            if (Test-Path -LiteralPath $temporaryPath) {
                try {
                    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
                }
                catch {
                    $phase = if ($swapped) { 'after replacement' } else { 'before replacement' }
                    throw "Temporary content file could not be cleaned up ${phase}: $($path.Relative)."
                }
            }
        }
    }
}

function Restore-FileSafely([pscustomobject]$backup) {
    $temporaryPath = Join-Path ([IO.Path]::GetDirectoryName($backup.Original)) ".csharp-template-init-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::Copy($backup.Backup, $temporaryPath, $false)
        Set-FileMetadata $temporaryPath $backup.Metadata

        # Rollback also replaces the entry so a raced or original hard link is never written through.
        [IO.File]::Move($temporaryPath, $backup.Original, $true)
        Set-PostReplacementMetadata $backup.Original $backup.Metadata
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-DirectoryCanBeChanged([string]$fullPath, [string]$relative, [string]$role) {
    $current = $fullPath
    while (-not (Test-Path -LiteralPath $current)) {
        $parent = Split-Path -Parent $current
        if (-not $parent -or (Test-SamePlanPath $parent $current)) {
            throw "$role parent cannot be resolved: $relative. No files were changed."
        }
        $current = $parent
    }

    if (-not (Test-Path -LiteralPath $current -PathType Container)) {
        throw "$role parent is not a directory: $relative. No files were changed."
    }

    $item = Get-Item -LiteralPath $current -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) {
        throw "$role parent is read-only: $relative. No files were changed."
    }

    if ($IsWindows) {
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $identitySids = @($identity.User.Value) + @($identity.Groups | ForEach-Object Value)
            $rules = (Get-Acl -LiteralPath $current).GetAccessRules(
                $true,
                $true,
                [Security.Principal.SecurityIdentifier]
            )
            $mutationRights =
                [Security.AccessControl.FileSystemRights]::Write -bor
                [Security.AccessControl.FileSystemRights]::Modify -bor
                [Security.AccessControl.FileSystemRights]::FullControl -bor
                [Security.AccessControl.FileSystemRights]::Delete -bor
                [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles
            $allowed = $false
            foreach ($rule in $rules | Where-Object { $identitySids -contains $_.IdentityReference.Value }) {
                if (($rule.FileSystemRights -band $mutationRights) -eq 0) {
                    continue
                }
                if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Deny) {
                    throw "$role parent denies mutation access: $relative. No files were changed."
                }
                $allowed = $true
            }
            if (-not $allowed) {
                throw "$role parent does not grant mutation access: $relative. No files were changed."
            }
        }
        catch {
            if ($_.Exception.Message -match 'No files were changed\.$') {
                throw
            }
            throw "$role parent permissions cannot be validated: $relative. No files were changed."
        }
    }
    else {
        & /usr/bin/test -w $current
        $canWrite = $LASTEXITCODE -eq 0
        & /usr/bin/test -x $current
        $canTraverse = $LASTEXITCODE -eq 0
        if (-not $canWrite) {
            throw "$role parent is not writable: $relative. No files were changed."
        }
        if (-not $canTraverse) {
            throw "$role parent is not traversable: $relative. No files were changed."
        }
    }
}

Assert-NoReparsePoint ([pscustomobject]@{
    Relative = 'scripts/init-plan.tsv'
    FullPath = $planPath
}) 'plan'

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
    Assert-NoReparsePoint $operation.Source 'source'
    if ($operation.Destination) {
        Assert-NoReparsePoint $operation.Destination 'destination'
    }

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
                Assert-ContentCanBeReplaced $operation.Source 'Template content'
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
            Assert-DirectoryCanBeChanged (Split-Path -Parent $operation.Destination.FullPath) $operation.Destination.Relative 'Initialization target'
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
            Assert-DirectoryCanBeChanged $destinationParent $operation.Destination.Relative 'Initialization target'
            Assert-DirectoryCanBeChanged (Split-Path -Parent $operation.Source.FullPath) $operation.Source.Relative 'Template move source'
            $plannedDestinations[$operation.Destination.FullPath] = $operation.Source.Relative
        }
        'remove' {
            if ($sourceExists -and -not (Test-Path -LiteralPath $operation.Source.FullPath -PathType Leaf)) {
                throw "Template-only removal path is not a file: $($operation.Source.Relative). No files were changed."
            }
            if ($sourceExists) {
                Assert-FileCanBeChanged $operation.Source 'Template-only removal'
                Assert-DirectoryCanBeChanged (Split-Path -Parent $operation.Source.FullPath) $operation.Source.Relative 'Template-only removal'
            }
        }
    }
}

Write-Host "==> Initializing template as '$ProjectName'" -ForegroundColor Cyan
Write-Host "    Preflight validated $($plan.Count) template-owned operation(s)." -ForegroundColor DarkGray

$stagingRoot = Join-Path ([IO.Path]::GetTempPath()) "csharp-template-init-$([Guid]::NewGuid().ToString('N'))"
$backupRecords = @()
$completedMoves = @()
$createdDirectories = @()
$removedDirectories = @()
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$pathComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$backupByPath = [Collections.Generic.Dictionary[string, object]]::new($pathComparer)
$mutatedBackups = [Collections.Generic.List[object]]::new()
$mutatedBackupPaths = [Collections.Generic.HashSet[string]]::new($pathComparer)

try {
    [IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
    $backupPaths = [Collections.Generic.List[string]]::new()
    foreach ($write in $contentWrites) {
        $backupPaths.Add($write.Path.FullPath)
    }
    foreach ($operation in $plan | Where-Object Kind -eq 'remove') {
        if (Test-Path -LiteralPath $operation.Source.FullPath -PathType Leaf) {
            $backupPaths.Add($operation.Source.FullPath)
        }
    }
    if (-not $KeepScript) {
        foreach ($initializer in @((Join-Path $PSScriptRoot 'init.sh'), $selfPath)) {
            if (Test-Path -LiteralPath $initializer -PathType Leaf) {
                $backupPaths.Add($initializer)
            }
        }
    }

    $backedUp = [Collections.Generic.HashSet[string]]::new($pathComparer)
    foreach ($original in $backupPaths) {
        if (-not $backedUp.Add($original)) {
            continue
        }
        $metadata = Get-FileMetadata $original
        $backup = Join-Path $stagingRoot "$($backupRecords.Count).bak"
        [IO.File]::Copy($original, $backup, $false)
        $record = [pscustomobject]@{
            Original = $original
            Backup = $backup
            Metadata = $metadata
        }
        $backupRecords += $record
        $backupByPath.Add($original, $record)
    }

    foreach ($write in $contentWrites) {
        Assert-NoReparsePoint $write.Path 'content source'
        Set-FileContentSafely $write.Path $write.Content $utf8NoBom $backupByPath[$write.Path.FullPath] $mutatedBackups $mutatedBackupPaths
    }
    Write-Host "    Updated contents in $($contentWrites.Count) file(s)." -ForegroundColor DarkGray

    # Destination directories are created empty; only listed files move into them.
    # Unknown files inside token-named source directories stay at their original paths.
    foreach ($operation in $plan | Where-Object Kind -eq 'directory') {
        if (
            (Test-Path -LiteralPath $operation.Source.FullPath -PathType Container) -and
            -not (Test-SamePlanPath $operation.Source.FullPath $operation.Destination.FullPath)
        ) {
            Assert-NoReparsePoint $operation.Source 'directory source'
            Assert-NoReparsePoint $operation.Destination 'directory destination'
            [IO.Directory]::CreateDirectory($operation.Destination.FullPath) | Out-Null
            $createdDirectories += $operation.Destination.FullPath
        }
    }

    foreach ($operation in $plan | Where-Object Kind -in @('move', 'activate')) {
        if (
            (Test-Path -LiteralPath $operation.Source.FullPath -PathType Leaf) -and
            -not (Test-SamePlanPath $operation.Source.FullPath $operation.Destination.FullPath)
        ) {
            Assert-NoReparsePoint $operation.Source 'move source'
            Assert-NoReparsePoint $operation.Destination 'move destination'
            Move-Item -LiteralPath $operation.Source.FullPath -Destination $operation.Destination.FullPath
            $completedMoves += $operation
            Write-Host "    Moved $($operation.Source.Relative) -> $($operation.Destination.Relative)" -ForegroundColor DarkGray
        }
    }

    foreach ($operation in $plan | Where-Object Kind -eq 'remove') {
        if (Test-Path -LiteralPath $operation.Source.FullPath -PathType Leaf) {
            Assert-NoReparsePoint $operation.Source 'removal source'
            Remove-Item -LiteralPath $operation.Source.FullPath -Force
            $backup = $backupByPath[$operation.Source.FullPath]
            if ($mutatedBackupPaths.Add($backup.Original)) {
                $mutatedBackups.Add($backup)
            }
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
            Assert-NoReparsePoint $operation.Source 'directory cleanup source'
            $removedDirectories += $operation.Source.FullPath
            Remove-Item -LiteralPath $operation.Source.FullPath -Force
        }
    }

    foreach ($relativeDirectory in @('docs', 'scripts/tests')) {
        $directory = Join-Path $repoRoot $relativeDirectory
        if ((Test-Path -LiteralPath $directory -PathType Container) -and -not (Get-ChildItem -LiteralPath $directory -Force)) {
            Assert-NoReparsePoint ([pscustomobject]@{ Relative = $relativeDirectory; FullPath = $directory }) 'directory cleanup source'
            $removedDirectories += $directory
            Remove-Item -LiteralPath $directory -Force
        }
    }

    if (-not $KeepScript) {
        foreach ($initializer in @((Join-Path $PSScriptRoot 'init.sh'), $selfPath)) {
            if (Test-Path -LiteralPath $initializer -PathType Leaf) {
                Remove-Item -LiteralPath $initializer -Force
                $backup = $backupByPath[$initializer]
                if ($mutatedBackupPaths.Add($backup.Original)) {
                    $mutatedBackups.Add($backup)
                }
            }
        }
    }
}
catch {
    $mutationError = $_
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    foreach ($directory in $removedDirectories) {
        try {
            [IO.Directory]::CreateDirectory($directory) | Out-Null
        }
        catch {
            $rollbackErrors.Add($_.Exception.Message)
        }
    }
    [array]::Reverse($completedMoves)
    foreach ($operation in $completedMoves) {
        try {
            if ((Test-Path -LiteralPath $operation.Destination.FullPath) -and -not (Test-Path -LiteralPath $operation.Source.FullPath)) {
                Move-Item -LiteralPath $operation.Destination.FullPath -Destination $operation.Source.FullPath
            }
        }
        catch {
            $rollbackErrors.Add($_.Exception.Message)
        }
    }
    foreach ($backup in $mutatedBackups) {
        try {
            Restore-FileSafely $backup
        }
        catch {
            $rollbackErrors.Add($_.Exception.Message)
        }
    }
    [array]::Reverse($createdDirectories)
    foreach ($directory in $createdDirectories) {
        try {
            if ((Test-Path -LiteralPath $directory -PathType Container) -and -not (Get-ChildItem -LiteralPath $directory -Force)) {
                Remove-Item -LiteralPath $directory -Force
            }
        }
        catch {
            $rollbackErrors.Add($_.Exception.Message)
        }
    }
    if ($rollbackErrors.Count -gt 0) {
        throw "Initialization failed and rollback was incomplete: $($mutationError.Exception.Message) Rollback errors: $($rollbackErrors -join '; ')"
    }
    throw "Initialization failed; all changes were rolled back: $($mutationError.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
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
