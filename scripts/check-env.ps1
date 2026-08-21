#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Checks this machine can build and test a C# (.NET) project before you
    initialize the template.

.DESCRIPTION
    Asks the .NET host to resolve the SDK configuration pinned in global.json.
    Prints "Environment ready" and exits 0 on success; if a required tool is
    missing or the SDK configuration cannot be resolved, it prints per-OS install
    commands and exits 1 — install what it names, then re-run.

    Run it first, before scripts/init.ps1:

        pwsh ./scripts/check-env.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$problems = @()

Write-Host "==> Checking environment for C# (.NET) development" -ForegroundColor Cyan

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$globalJson = Join-Path $repoRoot 'global.json'

# Required: the .NET SDK (it bundles the C# compiler and `dotnet test`).
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    $problems += "the .NET SDK ('dotnet' is not on PATH)"
} else {
    Push-Location $repoRoot
    $nativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $sdkOutput = @(& dotnet --version 2>&1)
        $sdkExitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $nativeErrorPreference
        Pop-Location
    }

    if ($sdkExitCode -eq 0 -and $sdkOutput.Count -gt 0) {
        $resolvedSdk = [string]$sdkOutput[-1]
        Write-Host "    .NET SDK $resolvedSdk resolved from global.json" -ForegroundColor DarkGray
    }
    else {
        $problems += "the SDK configuration in '$globalJson' could not be resolved by dotnet"
        foreach ($line in $sdkOutput) {
            Write-Host "    $line" -ForegroundColor DarkGray
        }
    }
}

# Soft: git drives the init defaults (author/email) and the VCS workflow.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "    note: git is not on PATH — init falls back to placeholder author/email." -ForegroundColor Yellow
}

if ($problems.Count -eq 0) {
    Write-Host ""
    Write-Host "Environment ready. Next: pwsh ./scripts/init.ps1 -ProjectName ..." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Environment NOT ready. Missing:" -ForegroundColor Red
foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
Write-Host ""
Write-Host "Install an SDK compatible with $globalJson, then re-run this check:" -ForegroundColor Yellow
Write-Host "  Windows : winget install Microsoft.DotNet.SDK.10"
Write-Host "  macOS   : brew install --cask dotnet-sdk"
Write-Host "  Linux   : see https://learn.microsoft.com/dotnet/core/install/linux"
exit 1
