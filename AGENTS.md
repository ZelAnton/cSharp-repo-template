# AGENTS.md

## Project

- This repository contains `__ProjectName__`, a C# project.
- The public API lives in `src/__ProjectName__`.
- Tests live in `tests/__ProjectName__.Tests`.
- Keep the repository focused; do not introduce CLI, UI, hosting, logging, or dependency injection infrastructure unless explicitly requested.

## Agent instruction files are local-only in generated repos

> **Scope:** this section is for a repository **created from this template**, not
> the template itself. In the template, `CLAUDE.md`, `AGENTS.md`, and `.claude/`
> stay **tracked and pushed** — that is how the guidance ships. If you are reading
> this in the template repo, leave them tracked and do nothing.

In a generated repo, `CLAUDE.md`, `AGENTS.md`, and `.claude/` are local guidance for whoever (human or agent) works in the clone — not project source. Keep them **git-ignored and untracked** so they stay on disk for tooling but never reach the remote; each developer keeps their own. This is a **by-hand step — the init script does not do it** — done **before the first push**:

```bash
# Append last so `.claude/` overrides the earlier `!.claude/...` ship lines.
printf '\n/CLAUDE.md\n/AGENTS.md\n.claude/\n' >> .gitignore
git rm -r --cached CLAUDE.md AGENTS.md .claude
git add .gitignore && git commit -m "Keep agent instructions local"   # commit the ignore rule *and* the removals together
# jj-colocated: jj file untrack CLAUDE.md AGENTS.md .claude  (folds .gitignore + removals into the working copy; no separate commit)
```

`git rm --cached` keeps the files on disk; an ignore rule alone won't untrack already-committed files. `init` deletes `TEMPLATE.md` and `docs/AGENT-INIT-GUIDE.md`, so this section is the surviving copy of the recipe downstream — consult that guide while it exists for the precedence details, an optional zero-trace `.git/info/exclude` variant, and the caveat that a repo created via GitHub's *Use this template* already carries these files in its initial commit's history (untracking drops them from the tip only).

## Runtime

- Use .NET (target framework `net10.0`).
- Do not change the target framework unless explicitly asked.
- Use the repository-wide language settings from `Directory.Build.props`.

## Dependencies

- Do not introduce new NuGet packages without explicit approval.
- Use centralized package management.
- Manage package versions only in `Directory.Packages.props`.
- Do not put package versions on individual `PackageReference` items.
- `Directory.Packages.props` is not a fixed allow-list — add the production and test packages the project actually needs there. `Microsoft.NET.Test.Sdk` is required for test discovery and execution through `dotnet test`; do not remove it.

## Architecture

- Keep all functionality available as reusable library APIs.
- Keep implementation details (helpers, platform-specific code, internal types) internal to the library.
- Do not expose implementation types publicly unless explicitly requested.
- Prefer simple, direct code over new abstractions.
- Minimize public API surface area; public API changes must be intentional and documented.
- Do not add dependency injection unless there is a concrete need.

## Project References

- Do not use `ProjectReference`.
- Cross-project references must use `Reference`.
- Do not use `HintPath`.
- Projects that reference outputs from other projects must define `AssemblySearchPaths`.
- `AssemblySearchPaths` must contain the output directories of referenced projects.
- Project references must resolve through assembly lookup paths only.
- Build ordering is enforced by `BuildDependency` entries in `__ProjectName__.slnx`.

## Build Ordering

- Use the `.slnx` solution format.
- `.slnx` must define build dependencies between projects.
- Referencing projects must depend on referenced projects.
- Referenced projects must build before dependent projects.
- Build ordering must be explicit and deterministic.

## Repository Structure

- Use `__ProjectName__.slnx` as the solution file.
- Use `Directory.Build.props` for repository-wide MSBuild configuration.
- Use `Directory.Packages.props` for centralized package versions.
- Keep source code under `src/`.
- Keep tests under `tests/`.
- Keep helper scripts under `scripts/`.

## MSBuild Path Properties

- `Directory.Build.props` defines two canonical path properties available to every project in the repository:
	- `$(RepoRoot)` — absolute path to the repository root, with a trailing directory separator. Resolved from `$(MSBuildThisFileDirectory)` inside `Directory.Build.props`, which always equals the directory containing that file.
	- `$(MainProjectDir)` — absolute path to `src/__ProjectName__/` (the main library project directory).
- Use these properties instead of relative constructs (`..\..\`, `$(MSBuildThisFileDirectory)..\`, etc.) whenever a project file needs to reference a file or directory outside its own directory.
- Do not hardcode cross-project or cross-directory relative paths in `.csproj`, `.props`, or `.targets` files.
- If a new project is added that other projects must reference by path, add a corresponding `$(XxxProjectDir)` property to `Directory.Build.props`.

## Build And Test

- Use `dotnet build __ProjectName__.slnx` to validate compilation.
- Use `dotnet test tests/__ProjectName__.Tests/__ProjectName__.Tests.csproj --no-build` to run tests after a successful build.
- Test execution must report NUnit discovery and a test summary, for example:
	- `NUnit3TestExecutor discovered ...`
	- `Test summary: total: ..., failed: 0, succeeded: ...`
- A successful test run must execute the discovered tests, not only complete MSBuild targets.
- Because project-to-project references use `Reference` instead of `ProjectReference`, build ordering must come from `__ProjectName__.slnx`.

## Linux Testing (local, from Windows)

- `scripts/test-linux.ps1` runs the full test suite inside a Linux container using Rancher Desktop or Docker Desktop. It is an optional helper — remove it (and `docs/linux-testing.md`) if your project does not need it.
- Requires PowerShell 7+ and a running Docker daemon (`docker` on PATH).
- The script shadows `bin/` and `obj/` folders with anonymous Docker volumes so Windows IDE artifacts do not leak into the Linux build.
- A named volume (`__ProjectName__-nuget`) caches NuGet packages between runs.
- Supports `-Filter`, `-Configuration`, and `-Rebuild` parameters.
- Do not modify the anonymous-volume list in the script without also verifying that the Linux build still resolves `__ProjectName__.dll` correctly (the test project uses `AssemblySearchPaths` pointing to the standard `src/__ProjectName__/bin/` location).

## Formatting

- `.editorconfig` is the source of truth for indentation and line endings — follow it.
- Use tabs for indentation in C#, MSBuild, and config files (`.cs`, `.csproj`, `.props`, `.targets`, `.slnx`, `.json`, `.config`, `.md`).
- YAML (`.yml`/`.yaml`) and PowerShell (`.ps1`) use spaces, per `.editorconfig` (tabs are invalid in YAML).
- Do not mix tabs and spaces for indentation within a file.
- Preserve LF line endings, except Windows batch files (`.cmd`/`.bat`) which require CRLF.

## C# Style

- Use file-scoped namespaces.
- Keep nullable annotations enabled.
- Keep implicit usings enabled.
- Treat warnings as errors.
- Prefer simple, direct code over new abstractions.
- Minimize public API surface area.
- Public API changes must be intentional and documented.

### Exception handling style

- **No one-line `try`/`catch`/`finally`.** Every `try`, `catch`, and `finally` keyword must own a brace block on its own lines. Forbidden:
	```csharp
	try { foo(); } catch { }
	try { foo(); } catch (IOException) { /* swallow */ }
	finally { stream.Dispose(); }
	```
	Required:
	```csharp
	try
	{
		foo();
	}
	catch (IOException)
	{
		// swallowed - pipe closed by the OS during teardown; nothing actionable.
	}
	```
- **Empty `catch` blocks must contain a short comment explaining why the exception is swallowed.** "What is being caught" plus "why ignoring is correct here". A bare `catch { }` (or `catch (X) { }`) without a justification comment is not acceptable. Examples:
	```csharp
	catch (ObjectDisposedException)
	{
		// already torn down — observers see disposal as EOF, nothing to recover.
	}

	catch
	{
		// best-effort cleanup in a catch block; rethrowing here would mask the original exception.
	}
	```
- The comment must explain the **rationale**, not just restate the catch clause. "// ignored" or "// swallow" alone is not enough.

## Documentation

- All documentation must be written in English.
- All code comments must be written in English.
- Functional changes must include corresponding README updates when behavior, requirements, usage, or public API changes.
- README updates must reflect the current behavior of the module.
- Documentation changes must be completed after implementation and successful validation.
- Do not leave changed behavior undocumented.

## Changelog

- `CHANGELOG.md` is the single source of truth for release notes.
- The release workflow reads `## [Unreleased]` automatically to populate the GitHub Release body and the NuGet `<PackageReleaseNotes>` field.
- **Every user-visible change must be accompanied by a `CHANGELOG.md` update in the same change set.** This is non-negotiable for: new or modified public API, behavioural changes, bug fixes, deprecations, removals. Pure internal refactors that do not alter observable behaviour are the only exemption.
	- The changelog entry is part of the change, not an optional follow-up. Do not split it into a separate commit unless explicitly asked.
	- If a single change set produces multiple user-visible effects, write one bullet per effect — do not bundle.
- Add a manual bullet under `## [Unreleased]` in `CHANGELOG.md`. Use the appropriate subsection:
	- `### Added` — new features or API members
	- `### Changed` — modified behaviour or API
	- `### Fixed` — bug fixes
	- `### Removed` — removed features or API members
	- `### Deprecated` — features still present but marked for removal
- Write the entry for a consumer of the library, not the implementer. Keep it to one line.
- Replace the placeholder `-` with a real bullet; do not leave placeholder lines alongside real entries.
- Do not modify versioned sections (`## [1.0.0]`, etc.) — those are managed by the release workflow.

### Auto-fill fallback

- If `## [Unreleased]` has no real bullets at release time, the workflow auto-generates entries from commits since the previous tag using `git-cliff` (config: `cliff.toml`). Manual entries always win over auto-fill.
- The first word of the commit subject decides the bucket (case-insensitive):
	- `Add`, `Feat` → `### Added`
	- `Fix`, `Bug` → `### Fixed`
	- `Remove`, `Delete`, `Drop` → `### Removed`
	- `Refactor`, `Update`, `Change`, `Rename`, `Perf`, `CI`, `Cleanup`, etc. → `### Changed`
	- `Doc`, `Chore`, `Test`, `Style` → skipped (excluded from notes)
	- `Release v...` and merge commits → skipped
	- anything unrecognised → `### Changed` (fallback)
- Write commit subjects with these prefixes when you want them to land in the right bucket without editing `CHANGELOG.md`.
- If the auto-fill produces no entries (e.g. only skipped commits since the previous tag), the release fails with a clear error — add a manual entry to unblock it.

## Release Checksums

> Applies only when the repository ships a NuGet package. Remove this section and `.github/workflows/release.yml` for apps or internal libraries.

- The release workflow (`.github/workflows/release.yml`) does **not** author-sign the `.nupkg`/`.snupkg`. NuGet.org adds a repository signature on the publisher account automatically; that is what attributes the package to the `__ProjectName__` owner.
- A `SHA256SUMS` manifest is generated from the packed artifacts and attached to the GitHub Release. Format is the standard `<hex>  <filename>` consumed by `sha256sum -c` — this is how downstream consumers verify integrity of artifacts downloaded from the GitHub Release.
- Publishing requires one repository secret:
	- `NUGET_API_KEY` — nuget.org API key with push permission for the `__ProjectName__` package
- **Step ordering invariant:** the NuGet publish is the only irreversible step, so it is the pivot. A secret preflight runs first; build/test/pack and a *local* (unpushed) commit+tag run before the pivot; the publish (retried, `--skip-duplicate`) runs next; the atomic commit+tag push to `main` and the idempotent+retried GitHub Release run after. Re-run only when NuGet did not accept the package. **Once NuGet accepts it, never re-run or rebuild the release, regardless of whether the tag push succeeded** — download that run's immutable `release-recovery-vX.Y.Z` artifact and use its exact bundle, packages, checksums, and release notes to finish the tag push or GitHub Release. When editing `release.yml`, preserve this ordering: never move the publish after the tag push, and keep the post-pivot steps idempotent.
- Do not reintroduce `dotnet nuget sign` against a self-signed certificate: nuget.org validates the author signature's certificate chain against the Microsoft Trusted Root Program and rejects self-signed packages with `NU3018`. If author-signing is brought back later, the cert must be from a public CA.

## Security Scanning

- `.github/workflows/codeql.yml` runs GitHub CodeQL against the C# codebase on pull requests, pushes to `main`, and weekly on a cron schedule. It uses the `security-and-quality` query suite (broader than the default `security-extended`) so injection patterns, unsafe interop, and quality issues are surfaced.
- Build mode is `manual` (the workflow runs `dotnet build __ProjectName__.slnx`) because autobuild does not always select the right SDK or solution format.
- CodeQL findings appear under the repository's **Security → Code scanning** tab. Treat new alerts the same as build warnings — investigate and fix or, when a finding is a confirmed false positive, dismiss it in the GitHub UI with a written justification.
- Do not silence or skip CodeQL by editing the workflow to exclude paths or queries without explicit approval — the smaller the suppression surface, the more value the scan provides.

## Comments

- Minimize comments.
- Write comments only when explaining:
	- why something exists
	- architectural decisions
	- non-obvious platform or runtime behavior
- Do not write comments describing what the code already says.

## Version control (jujutsu)

This repository uses [jujutsu (`jj`)](https://jj-vcs.github.io/jj/) for version control. The repo is colocated with git, but `jj` is the primary tool — use `jj` commands for everything in this workflow, not raw `git`.

### Describing the current change

- When you start a new piece of work, set the change description right away:
	```
	jj describe -m "Concise summary of what this change does"
	```
- For larger work, fold subsequent small edits into the current change without asking the user — keep extending the same change rather than starting a new one for each follow-up.
- If the scope of the current change shifts mid-work, refresh the description with another `jj describe -m "..."`. The description must always reflect what's actually being done.

- **Per-prompt evaluation (mandatory).** Before any edits, run `jj st` and
  classify the incoming prompt against the current change description:

	| Signal in prompt | Category | Action |
	|---|---|---|
	| Same topic, refinement, follow-up of in-progress work | **Continuation** | Just work. jj auto-folds edits into the current change. |
	| Same change but goal has been refined or expanded | **Scope shift** | `jj describe -m "<refined summary>"`. **Don't** start a new change. |
	| Orthogonal topic, different area, "теперь сделай X" | **New work** | If current change is finished → `jj new -m "<summary>"` (descendant). If still in progress → `jj new @- -m "..."` (parallel sibling). |

	Reliable signals: word changes like "теперь" / "now" / "next" / "также сделай" / "and also" usually mean **new work** or **scope shift**. Imperative follow-ups inside the same scope ("исправь это", "fix this", "продолжи") mean **continuation**. When in doubt, ask the user.

### Starting unrelated work

When the per-prompt evaluation above lands on **New work**, branch rather than mixing topics into the current change:
- **Current change is complete** → `jj new -m "Description of the new task"` (a descendant).
- **Current change still needs more work** → `jj new @- -m "Description of the unrelated task"` (a parallel change off the same parent, so the user can return to the current one later).
- Do not silently mix the two — every change must stay coherent.

### Pushing to remote

The user signals "synchronise with remote" with a short trigger word (typically `pull` or `push`). On that signal, run the full sync:
1. `jj git fetch` — pull down remote movement (merged PRs, CI release commits, other contributors) **before** doing anything else.
2. If `main@origin` has moved past the local change, rebase onto it: `jj rebase -r @- -d main@origin` (or `jj rebase -d main@origin` for a stack).
3. Put the work on a **feature bookmark — never advance `main` locally to publish.** First push: `jj bookmark create <topic> -r @` then `jj git push --allow-new -b <topic>`. Later pushes: `jj bookmark move <topic> --to @` then `jj git push -b <topic>`.
4. Open / update a pull request into `main` (`gh pr create --base main --head <topic> --fill`). `main` advances only when the PR merges; afterwards `jj git fetch` and `jj bookmark delete <topic>`.

Never push without an explicit signal from the user. **Direct-push fallback:** where `main` is unprotected the old single-step flow still works — `jj bookmark move main --to @` then `jj git push -b main`; once PRs are required this is rejected for everyone except the release workflow's GitHub App, which sits in the ruleset's bypass list (`RELEASE_APP_ID` + `RELEASE_APP_PRIVATE_KEY`; see `release-token-bypass.md`).

### Undoing work

When the user decides to abandon work in progress, prefer `jj`'s native undo facilities — they are safer than hand-rolled cleanup:

- **`jj undo`** (alias of `jj op undo`) — reverses the last operation (describe / edit / squash / rebase / abandon / push / etc.). Use this when the latest step was the wrong call. It is repeatable: `jj undo` again undoes the previous one.
- **`jj abandon <rev>`** — drops a specific change entirely. Descendants automatically rebase onto its parent. Useful for "this whole change is the wrong direction; throw it away".
- **`jj restore`** — discards working-copy modifications and resets `@` to its parent's tree. Useful for "I haven't committed yet, just wipe what I did".
- **`jj op log`** is the reflog equivalent — every operation is reachable. If `jj undo` overshoots, `jj op restore <op-id>` jumps to any prior point.

Never hide a deliberate undo: if the user asks to "undo the last commit/change", run `jj undo` (or `jj abandon`) and tell them what was reverted.

### Bookmarks

Work is published through a **feature bookmark per PR** (short kebab-case topic name), merged into `main` via pull request — this keeps the flow compatible with branch protection on `main`. Create the bookmark when you're ready to push for review; `main` is never advanced locally to publish (it moves only via merged PRs and the release workflow's tagged commit). Where `main` is unprotected, a direct push to `main` stays a valid shortcut — see "Pushing to remote".

### Safety

- Do not revert or amend changes the user authored without explicit agreement.
- Do not rewrite unrelated files when making a focused change.

## Command Conventions

- Commands and APIs should be idempotent where possible.
- Output should remain concise.
- Output should remain script-friendly.
- Breaking changes must be explicit.
