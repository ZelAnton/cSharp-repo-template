# Changelog

All notable changes to **__ProjectName__** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `SECURITY.md`, `CONTRIBUTING.md`, `.github/PULL_REQUEST_TEMPLATE.md`, and `.github/CODEOWNERS` community-health files.
- NuGet dependency auditing (`NuGetAudit`/`NuGetAuditMode=all`) in `Directory.Build.props`; vulnerability findings are warnings, not build-breaking errors.
- CI now caches NuGet packages, uploads test results (`.trx`) as artifacts, and supports manual `workflow_dispatch` runs.
- `.yamllint.yml` config (tuned for GitHub Actions) and a CI `yaml-lint` job that lints workflow YAML.

### Changed
- Release workflow makes NuGet publication the irreversible pivot: confirmed terminal rejections leave no remote trace, while ambiguous failures, timeouts, and cancellations preserve the exact immutable recovery state.
- Releases now pin the dispatch source commit, stop before NuGet if `main` moves, and bind post-pivot recovery and trunk advancement to that exact source and release state.
- All GitHub Actions are pinned to a commit SHA (with a version comment) instead of a moving tag; Dependabot now groups action bumps into a single weekly PR.

### Fixed
- Bash template initialization now rejects missing option values, following options used as values, and years outside the signed decimal `Int32` contract before changing files.
- Template initialization now rejects project names incompatible with generated C# namespaces, portable paths, NuGet package IDs, or Docker volumes before changing the tree.
- Template initialization now changes only an explicit template-owned inventory, rejects local collisions and symbolic path escapes, preserves external hard-linked peers, and rolls back late I/O failures.
- Template initialization now rejects a missing or mistyped required inventory source before changing any files.
- Git Bash initialization on Windows now preserves exact file security metadata across content replacement and rollback.
- Release versioning now selects the highest exact stable SemVer tag reachable from the pinned source and checks tag existence through unambiguous tag refs.
- First-release changelog auto-fill now includes release-worthy changes from the repository's root commit.
- NuGet packages now contain the same versioned changelog state used for release notes and the release tag.
- Template initialization now rejects unsafe multiline or repository-owner metadata and preserves quoted, metacharacter-rich, or placeholder-like values without cascading replacements or release-workflow injection.
- Linux container tests now pass filter expressions as literal arguments instead of allowing Bash to interpret filter text.
- PowerShell template initialization now falls back to placeholder author details when Git or its configured identity is unavailable.
- Environment preflight now uses the .NET host's complete `global.json` resolution rules and reports invalid configuration instead of accepting incompatible SDKs.

[Unreleased]: https://github.com/__GitHubOwner__/__ProjectName__/commits/main
