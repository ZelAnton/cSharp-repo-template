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
- Release workflow makes the NuGet publish the single irreversible pivot: build, test, pack and a **local** commit/tag run before it, and the commit/tag are pushed to `main` (plus the GitHub Release created) only **after** a successful publish — so any failure up to and including the publish leaves no remote or registry trace and is safe to re-run.
- All GitHub Actions are pinned to a commit SHA (with a version comment) instead of a moving tag; Dependabot now groups action bumps into a single weekly PR.

### Fixed
- Template initialization now rejects unsafe multiline or repository-owner metadata and preserves quoted, metacharacter-rich, or placeholder-like values without cascading replacements or release-workflow injection.

[Unreleased]: https://github.com/__GitHubOwner__/__ProjectName__/commits/main
