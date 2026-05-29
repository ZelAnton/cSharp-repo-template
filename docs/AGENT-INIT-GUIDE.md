# Agent guide: initializing a repo from this template

This guide is for an AI agent (Claude Code or similar) asked to "initialize a new
repository from this template." It exists because real initialization sessions
have gone wrong in avoidable ways. **Read it before touching any files.**

> **Living document — keep it accurate.** This guide is meant to grow. If you
> make a mistake while initializing a repo (or watch one happen), add it to
> [Failure log](#failure-log) below with the symptom, the root cause, and the
> rule that prevents it. Fix or sharpen existing entries when they turn out to be
> incomplete. The whole point is that the *next* agent doesn't repeat what the
> last one got wrong. See [Updating this guide](#updating-this-guide).

## TL;DR — the five rules

1. **Read before you write.** Read `TEMPLATE.md`, this file, `AGENTS.md`, and
   `CLAUDE.md` *first*. Do not generate a single file based on an assumed layout.
2. **Prefer the init script over hand-rolling.** `scripts/init.ps1` is the
   supported path for a standard single-project init. Run it; don't recreate its
   work by hand.
3. **Match the shell to the tool.** On Windows the Bash tool is POSIX (git bash);
   PowerShell cmdlets fail there. Use the PowerShell tool for cmdlets.
4. **Don't fight the permission model.** `.claude/settings.json` ships as a
   `.template`; activating it is the script's / user's job, not something you
   force by writing allow-rules yourself.
5. **Verify, then clean.** `dotnet build` + `dotnet test` (+ `dotnet pack` if it
   publishes), then remove build artifacts before finishing.

## What this template actually is

Confirm these facts by reading, not by assuming — they are exactly the
assumptions a past agent got wrong:

- It is a **token template**, not a ready project. Placeholder tokens
  (`__ProjectName__`, `__Author__`, `__GitHubOwner__`, `__Description__`,
  `__Year__`) appear in file *contents* and in file/folder *names*. They are
  substituted by `scripts/init.ps1`.
- It is **single-project** by default: one library in `src/__ProjectName__`, one
  test project in `tests/__ProjectName__.Tests`.
- Stack and conventions (all enforced — see `AGENTS.md`):
  - **net10**, NUnit (not xUnit), `TreatWarningsAsErrors` (warnings *are* errors).
  - **`.slnx`** solution format with explicit `BuildDependency` for build order.
  - Cross-project references use **`Reference` + `AssemblySearchPaths`**, never
    `ProjectReference`, never `HintPath`.
  - **Central Package Management** — versions live only in
    `Directory.Packages.props`; `PackageReference` items carry no `Version`.
  - **Tabs** for indentation in `.cs`/`.csproj`/`.props`/`.json`/`.md`; spaces
    only in `.yml`/`.ps1` (see `.editorconfig`).
  - File-scoped namespaces; canonical MSBuild path props (`$(RepoRoot)`,
    `$(MainProjectDir)`) instead of `..\..\`.
- It uses **jujutsu (`jj`)** colocated with git. Drive VCS through `jj`.

## The happy path (standard single-project init)

1. **Read** `TEMPLATE.md` and this guide. Skim `AGENTS.md` / `CLAUDE.md`.
2. **Run the init script** with the values the user gave you:

   ```pwsh
   pwsh ./scripts/init.ps1 -ProjectName Acme.Widgets -Author "Jane Doe" -GitHubOwner acme -Description "Widget toolkit"
   ```

   `-ProjectName` is required; the rest fall back to sensible defaults. The
   script substitutes tokens, renames files/folders, activates
   `.claude/settings.json` from its `.template`, and deletes `TEMPLATE.md` (and
   itself unless `-KeepScript`).
3. **Verify**:

   ```pwsh
   dotnet build Acme.Widgets.slnx
   dotnet test  Acme.Widgets.slnx
   ```
4. Replace the placeholder `Greeter` type with the real API, delete the sample
   test, fill in the `CLAUDE.md` "Architecture" section, and work through the
   `TEMPLATE.md` post-setup checklist.
5. Remove build artifacts (`bin/`, `obj/`, any `artifacts/`) before finishing.

If the user only asks to "initialize from the template" with a project name and
nothing structurally unusual, **this is the whole job.** Resist the urge to
redesign.

## When you must deviate (e.g. multiple projects)

The init script assumes one project. If the user wants several (e.g. three
libraries, each its own NuGet package), the script's single-token substitution
won't fit, so you adapt by hand — but still respect every convention above:

- One folder per library under `src/`, one matching test project under `tests/`.
- Put **shared packaging metadata once** in `src/Directory.Build.props` (authors,
  license, URLs, symbols, SourceLink, README/CHANGELOG pack items). Each library
  `.csproj` then carries only `PackageId`, `Description`, `PackageTags`.
  *Duplicating metadata across N csproj files is a defect — it caused a typo to
  be fixed three times in one real session.*
- Keep a single shared `<Version>` (in `Directory.Build.props`), not per-project.
- Add a `BuildDependency` per test→library pair in the `.slnx`.
- Give each test project an `AssemblySearchPaths` pointing at its library's
  output; add a matching `$(XxxProjectDir)` property in `Directory.Build.props`.
- The release workflow should pack the **solution**, not a single hard-coded
  `.csproj`.
- Still verify with build + test + pack, then clean artifacts.

Whatever you change, update `AGENTS.md` / `CLAUDE.md` so they describe the layout
you actually produced.

## Tooling discipline (this is where agents slip)

- **Shell ≠ shell.** The Bash tool runs POSIX (git bash) here. `Get-ChildItem`,
  `Select-Object`, etc. fail in it with `command not found`. Use the PowerShell
  tool for cmdlets and the Bash tool only for POSIX commands. Prefer the
  dedicated Read / Glob / Grep tools over either shell for file inspection.
- **Don't over-batch.** A failure in one call of a parallel batch can cancel the
  rest. Never put *exploratory* calls (whose results you need) or calls that
  *depend on each other / on unanswered questions* in the same batch as file
  writes. Read and ask first; write once you know the answers.
- **Permission model.** Do not write permission allow-rules into
  `.claude/settings.json` yourself — the self-modification classifier will (and
  should) block it. The template ships `.claude/settings.json.template`; the init
  script activates it, or the user does. Leave it inert otherwise.
- **VCS.** The repo is jj-colocated. Use `jj` commands; if you must use raw git,
  follow with `jj git import`.

## Updating this guide

When something goes wrong during an init — yours or one you review — do this in
the **same change set**, not as a follow-up:

1. Add an entry to [Failure log](#failure-log): the symptom (what was observed),
   the root cause (why it happened), and the rule (what to do instead).
2. If the lesson generalizes, also fold it into the TL;DR or the relevant section
   above so it's seen in the normal reading flow, not just the log.
3. If `scripts/init.ps1`, `TEMPLATE.md`, `AGENTS.md`, or `CLAUDE.md` could be
   changed to make the mistake *impossible* (rather than merely documented),
   prefer that fix and note it in the entry.

Keep entries short and concrete. Delete or rewrite an entry if it turns out to be
wrong or obsolete.

## Failure log

Newest first. Each entry: **Symptom → Root cause → Rule.**

### 2026-05-29 — Generated ~30 files against an imagined layout
- **Symptom:** Created csproj/test files assuming a multi-project, xUnit, net9,
  `test/` layout. The template is single-project, NUnit, net10, `tests/`, with
  `.slnx` + `Reference`/`AssemblySearchPaths` + tabs. Nearly everything had to be
  thrown away and redone.
- **Root cause:** Started writing before reading `TEMPLATE.md` / the template
  tree. Assumed a conventional layout instead of checking.
- **Rule:** Read first (TL;DR #1). Confirm the facts in
  [What this template actually is](#what-this-template-actually-is) by reading,
  never by assuming.

### 2026-05-29 — PowerShell cmdlets run in the Bash (POSIX) tool
- **Symptom:** `Get-ChildItem: command not found`; a whole parallel batch was
  cancelled when that first call errored.
- **Root cause:** Put PowerShell cmdlets into the Bash tool, and batched
  dependent work with file writes.
- **Rule:** Match shell to tool; don't over-batch (see
  [Tooling discipline](#tooling-discipline-this-is-where-agents-slip)).

### 2026-05-29 — Tried to write allow-rules into `.claude/settings.json`
- **Symptom:** Write denied by the self-modification classifier.
- **Root cause:** Attempted to grant the agent its own permissions directly.
- **Rule:** Leave `.claude/settings.json.template` inert; let the init script or
  the user activate it.

### 2026-05-29 — Duplicated packaging metadata across multiple csproj files
- **Symptom:** In a multi-project adaptation, ~20 identical metadata lines lived
  in each library `.csproj`; one owner-name typo had to be fixed in three places.
- **Root cause:** No shared packaging props file for the multi-project case.
- **Rule:** Consolidate shared packaging metadata in `src/Directory.Build.props`;
  per-project `.csproj` carries only identity (see
  [When you must deviate](#when-you-must-deviate-eg-multiple-projects)).
