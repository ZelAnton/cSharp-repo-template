#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('capture', 'apply', 'temp')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
if ($Action -eq 'temp') {
    [Console]::Out.Write([IO.Path]::GetTempPath())
    exit 0
}

$path = [Environment]::GetEnvironmentVariable('CSHARP_TEMPLATE_METADATA_PATH', 'Process')
if ([string]::IsNullOrWhiteSpace($path)) {
    throw 'CSHARP_TEMPLATE_METADATA_PATH is required.'
}

$sections =
    [Security.AccessControl.AccessControlSections]::Owner -bor
    [Security.AccessControl.AccessControlSections]::Group -bor
    [Security.AccessControl.AccessControlSections]::Access

if ($Action -eq 'capture') {
    $security = [IO.FileSystemAclExtensions]::GetAccessControl([IO.FileInfo]::new($path), $sections)
    $record = [ordered]@{
        SecurityDescriptor = $security.GetSecurityDescriptorSddlForm($sections)
        CreationTimeUtcTicks = [IO.File]::GetCreationTimeUtc($path).Ticks
        LastAccessTimeUtcTicks = [IO.File]::GetLastAccessTimeUtc($path).Ticks
        LastWriteTimeUtcTicks = [IO.File]::GetLastWriteTimeUtc($path).Ticks
        Attributes = [int64][IO.File]::GetAttributes($path)
        AccessRulesProtected = $security.AreAccessRulesProtected
    }
    $json = $record | ConvertTo-Json -Compress
    [Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
    exit 0
}

$encoded = [Environment]::GetEnvironmentVariable('CSHARP_TEMPLATE_METADATA_B64', 'Process')
if ([string]::IsNullOrWhiteSpace($encoded)) {
    throw 'CSHARP_TEMPLATE_METADATA_B64 is required for apply.'
}

$metadata = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
$security = [Security.AccessControl.FileSecurity]::new()
$security.SetSecurityDescriptorSddlForm($metadata.SecurityDescriptor, $sections)
if ([bool]$metadata.AccessRulesProtected) {
    $security.SetAccessRuleProtection($true, $false)
}
[IO.FileSystemAclExtensions]::SetAccessControl([IO.FileInfo]::new($path), $security)
[IO.File]::SetCreationTimeUtc($path, [datetime]::new([int64]$metadata.CreationTimeUtcTicks, [DateTimeKind]::Utc))
[IO.File]::SetLastAccessTimeUtc($path, [datetime]::new([int64]$metadata.LastAccessTimeUtcTicks, [DateTimeKind]::Utc))
[IO.File]::SetLastWriteTimeUtc($path, [datetime]::new([int64]$metadata.LastWriteTimeUtcTicks, [DateTimeKind]::Utc))
[IO.File]::SetAttributes($path, [IO.FileAttributes][int64]$metadata.Attributes)
