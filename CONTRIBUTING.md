# Contributing to __ProjectName__

Thanks for your interest in improving **__ProjectName__**.

## Prerequisites

- A .NET SDK accepted by [`global.json`](global.json): 10.0.100 or a later .NET
  10 feature band, excluding prerelease SDKs.
- Optional: PowerShell 7+ and Docker/Rancher Desktop to run the Linux test
  helper (`scripts/test-linux.ps1`).

## Build and test

```sh
dotnet build __ProjectName__.slnx
dotnet test  __ProjectName__.slnx
```

The build treats **warnings as errors** and enforces code style on build, so a
clean local build is required before opening a pull request. Run a single test
with:

```sh
dotnet test __ProjectName__.slnx --filter "FullyQualifiedName~TestMethodName"
```

## Conventions

- **Formatting** is governed by [`.editorconfig`](.editorconfig) — tabs for
  indentation, LF line endings, file-scoped namespaces. Do not reformat code you
  are not changing.
- **Dependencies** use Central Package Management — declare versions only in
  [`Directory.Packages.props`](Directory.Packages.props); `PackageReference`
  items carry no `Version`.
- **Cross-project references** use `Reference` + `AssemblySearchPaths`, never
  `ProjectReference`. Build order comes from `BuildDependency` in the `.slnx`.
- See [`AGENTS.md`](AGENTS.md) for the full, authoritative set of conventions
  (exception-handling style, comments, architecture).

## Changelog

Every user-visible change ships its [`CHANGELOG.md`](CHANGELOG.md) entry in the
same change set, under `## [Unreleased]`. Write the bullet for a consumer of the
library, not the implementer. Pure internal refactors are exempt.

## Pull requests

- Keep changes focused; unrelated cleanups belong in their own PR.
- Ensure CI (build/test on Linux, Windows, macOS) and CodeQL pass.
- Fill in the pull-request checklist.
