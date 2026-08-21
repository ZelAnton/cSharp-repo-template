#!/usr/bin/env bash
#
# Checks this machine can build and test a C# (.NET) project before you
# initialize the template (POSIX counterpart of check-env.ps1 — use whichever
# matches your shell; both do the same thing).
#
# Asks the .NET host to resolve the SDK configuration pinned in global.json.
# Exits 0 when ready; if a required tool is missing or the SDK configuration
# cannot be resolved, it prints per-OS install commands and exits 1 — install
# what it names, then re-run.
#
# Usage: bash ./scripts/check-env.sh

set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,11p' "$0"; exit 0 ;; esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
global_json="$repo_root/global.json"

problems=()
echo "==> Checking environment for C# (.NET) development"

# Required: the .NET SDK (it bundles the C# compiler and `dotnet test`).
if ! command -v dotnet >/dev/null 2>&1; then
  problems+=("the .NET SDK ('dotnet' is not on PATH)")
elif resolved_sdk="$(cd "$repo_root" && dotnet --version 2>&1)"; then
  echo "    .NET SDK $resolved_sdk resolved from global.json"
else
  problems+=("the SDK configuration in '$global_json' could not be resolved by dotnet")
  while IFS= read -r line; do
    echo "    $line"
  done <<< "$resolved_sdk"
fi

# Soft: git drives the init defaults (author/email) and the VCS workflow.
command -v git >/dev/null 2>&1 || \
  echo "    note: git is not on PATH — init falls back to placeholder author/email."

if [ ${#problems[@]} -eq 0 ]; then
  echo
  echo "Environment ready. Next: bash ./scripts/init.sh --project-name ..."
  exit 0
fi

echo
echo "Environment NOT ready. Missing:"
for p in "${problems[@]}"; do echo "  - $p"; done
echo
echo "Install an SDK compatible with $global_json, then re-run this check:"
echo "  Windows : winget install Microsoft.DotNet.SDK.10"
echo "  macOS   : brew install --cask dotnet-sdk"
echo "  Linux   : see https://learn.microsoft.com/dotnet/core/install/linux"
exit 1
