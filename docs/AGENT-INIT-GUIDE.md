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

## TL;DR — the seven rules

1. **Read before you write.** Read `TEMPLATE.md`, this file, `AGENTS.md`, and
   `CLAUDE.md` *first*. Do not generate a single file based on an assumed layout.
2. **Check the toolchain first.** Run `scripts/check-env.ps1` (or
   `scripts/check-env.sh`). The check delegates SDK selection to the .NET host, so
   an invalid `global.json` or an installed SDK outside its `version`,
   `rollForward`, and `allowPrerelease` policy is a failure. If it reports a
   problem, STOP and offer the user the install guidance it prints — don't run
   init against an environment that can't build or test.
3. **Prefer the init script over hand-rolling.** `scripts/init.ps1` is the
   supported path for a standard single-project init. Run it; don't recreate its
   work by hand.
4. **Match the shell to the tool.** On Windows the Bash tool is POSIX (git bash);
   PowerShell cmdlets fail there. Use the PowerShell tool for cmdlets.
5. **Don't fight the permission model.** `.claude/settings.json` ships as a
   `.template`; activating it is the script's / user's job, not something you
   force by writing allow-rules yourself.
6. **Verify, then clean.** `dotnet build` + `dotnet test` (+ `dotnet pack` if it
   publishes), then remove build artifacts before finishing.
7. **Keep agent files local.** In the *new* repo, git-ignore and untrack the
   agent-instruction files (`CLAUDE.md`, `AGENTS.md`, `.claude/`) so they stay on
   disk for tools but never reach the remote. See
   [Keep agent-instruction files local](#keep-agent-instruction-files-local-to-the-new-repo).

## What this template actually is

Confirm these facts by reading, not by assuming — they are exactly the
assumptions a past agent got wrong:

- It is a **token template**, not a ready project. Placeholder tokens
  (`__ProjectName__`, `__Author__`, `__AuthorEmail__`, `__GitHubOwner__`,
  `__Description__`, `__Year__`) appear in file *contents* and in file/folder
  *names*. They are
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
2. **Check the environment.** Run `scripts/check-env.ps1` (or `check-env.sh`). If
   it flags a missing tool, stop and offer the user the install commands it prints
   before continuing — don't init against an environment that can't build or test.
3. **Run the init script** with the values the user gave you:

   ```pwsh
   pwsh ./scripts/init.ps1 -ProjectName Acme.Widgets -Author "Jane Doe" -GitHubOwner acme -Description "Widget toolkit"
   ```

   `-ProjectName` is required; the rest fall back to sensible defaults. The
   PowerShell initializer reads author and email from Git when available, then
   uses `Your Name` and `you@example.com` when Git or either configured value is
   unavailable. Author, author email, and description must be single-line;
   GitHub owner must be 1-39 letters, digits, or hyphens with no leading or
   trailing hyphen. Quotes,
   backslashes, shell/Python metacharacters, and placeholder-like text are safe:
   replacement is one pass, XML destinations are escaped, and the workflow
   identity is serialized before Bash receives it. Validation happens before any
   file is changed. The script substitutes tokens, renames files/folders, activates
   `.claude/settings.json` from its `.template`, and deletes `TEMPLATE.md` (and
   itself unless `-KeepScript`).
4. **Verify**:

   ```pwsh
   dotnet build Acme.Widgets.slnx
   dotnet test  Acme.Widgets.slnx
   ```

   Template maintainers can verify both initializers against equivalent hostile
   inputs, generated-file syntax, build, and real NUnit discovery with:

   ```pwsh
   pwsh ./scripts/tests/init-substitution.tests.ps1
   ```

   This requires PowerShell 7, Bash, Python with PyYAML or `yamllint`, and the
   pinned .NET SDK. The test uses and cleans a temporary directory outside the
   checkout; the initializer removes the template-only regression script from a
   generated repository.

   Before shipping release-workflow changes, also run
   `pwsh ./scripts/tests/release-state.tests.ps1`. The generated workflow pins one
   dispatch source SHA for checkout, build, versioning, tag, and recovery; it must
   fail before NuGet if remote `main` moved, and a post-pivot recovery must use only
   the exact bundle and integrity manifest from that run.
5. Replace the placeholder `Greeter` type with the real API, delete the sample
   test, fill in the `CLAUDE.md` "Architecture" section, and work through the
   `TEMPLATE.md` post-setup checklist.
6. **Git-ignore and untrack the agent-instruction files** (`CLAUDE.md` /
   `AGENTS.md` / `.claude/`) so they stay local and never reach the remote — see
   [Keep agent-instruction files local](#keep-agent-instruction-files-local-to-the-new-repo).
7. Remove build artifacts (`bin/`, `obj/`, any `artifacts/`) before finishing.

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
- Still git-ignore and untrack `CLAUDE.md` / `AGENTS.md` / `.claude/` so they stay
  local (see
  [Keep agent-instruction files local](#keep-agent-instruction-files-local-to-the-new-repo)).
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

## Keep agent-instruction files local to the new repo

This template *itself* tracks and ships its agent-instruction files — that is
intentional and must not change here. But a repository **created from** this
template should keep those files **out of its remote**: they are local guidance
for whoever (human or agent) works in the clone, not something to publish or push
to collaborators. So make them *untracked* in the new repo — present on disk,
invisible to version control, never pushed. **The init script does not touch
tracking; this is a by-hand step, done before the first push.**

Which files: `CLAUDE.md`, `AGENTS.md`, and the `.claude/` directory (after the
init script activates `settings.json`). Include any other agent-instruction files
you add later — e.g. `.cursorrules`, `.github/copilot-instructions.md`. (Note
`TEMPLATE.md` and `docs/AGENT-INIT-GUIDE.md` are template-only and the init script
deletes them outright, so they need no handling.) Because this guide and
`TEMPLATE.md` are deleted on init, the surviving copy of this recipe downstream is
the "Agent instruction files are local-only in generated repos" section of
`AGENTS.md` — that is the one to consult after init or on the by-hand path.

Two facts make it more than a one-line `.gitignore` append:

1. The files start out *tracked* (the template committed `CLAUDE.md`, `AGENTS.md`,
   and `.claude/settings.json.template`; the init script renames the last to
   `.claude/settings.json`). An ignore rule never untracks an already-tracked
   file — you must also drop it from the index.
2. The template's `.gitignore` **deliberately ships** `.claude/settings.json` —
   `.claude/*` followed by negations (`!.claude/settings.json`,
   `!.claude/settings.json.template`). So you must *either* append `.claude/`
   **after** that block (a later directory-exclude overrides the negations) *or*
   delete the two negation lines. A plain ignore placed *before* them won't hide
   `.claude/settings.json`.

Append the ignore patterns, then untrack (the working copy is kept), then commit:

```bash
printf '\n/CLAUDE.md\n/AGENTS.md\n.claude/\n' >> .gitignore
git rm -r --cached CLAUDE.md AGENTS.md .claude
git add .gitignore && git commit -m "Keep agent instructions local"   # commit the ignore rule *and* the removals together
# jj-colocated: jj file untrack CLAUDE.md AGENTS.md .claude  (folds .gitignore + removals into the working copy; no separate commit)
```

`jj file untrack` only drops paths *already* matched by an ignore rule, so add the
patterns first (jj honors `.gitignore` and `.git/info/exclude` alike).

**Zero filename trace in the remote (optional).** `CLAUDE.md` and `AGENTS.md`
aren't mentioned in `.gitignore`, so you can instead keep *them* in a local,
never-pushed `.git/info/exclude` — then their names never appear in the pushed
repo (the trade-off: it is per-clone, so a fresh clone re-tracks them and you
re-apply):

```bash
printf '/CLAUDE.md\n/AGENTS.md\n' >> .git/info/exclude
git rm --cached CLAUDE.md AGENTS.md
```

`.claude` can't use this route — the ship-negations outrank `.git/info/exclude`,
so its rule still has to live in (or be removed from) the tracked `.gitignore` as
above.

Verify with `git status` (or `jj st`): the files must not appear as tracked or as
new/untracked-to-be-added, and a `git push` must not carry them.

**Caveat — files already in the remote's history.** The untrack-and-ignore above
stops the files from going *forward* in new commits, which is what matters for
day-to-day work. But if you created the repo via GitHub's **"Use this template"**
(or any flow that already pushed an initial commit), the template's copies are
*already* in that first commit on the remote — removing them now drops them from
the tip but they survive in history. For a repo that has **never** contained
them, create it by copying the template files into a fresh `git init` and untrack
*before* the first commit; or, if you must start from a pushed "Use this template"
repo and want a clean history, fold the removal into the initial commit (e.g.
amend it) before the first push you control.

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

### 2026-08-21 — Metadata could cascade or enter the release shell as code
- **Symptom:** Quotes, shell metacharacters, line breaks, or another placeholder
  inside init metadata could change generated files or the release workflow.
- **Root cause:** Both initializers replaced tokens sequentially and wrote raw
  release identity values directly into a Bash `run` block.
- **Rule:** Validate context-limited values before writing, replace original tokens
  in one pass, and transfer release identity through a non-executable serialization;
  keep `scripts/tests/init-substitution.tests.ps1` green for both initializers.

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
