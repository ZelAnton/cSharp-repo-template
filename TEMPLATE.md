# C# repository template

A starting point for C# repositories: central package management, a strict
`.editorconfig`, cross-platform CI, CodeQL, an optional NuGet release pipeline,
and conventions for agents in [CLAUDE.md](CLAUDE.md) / [AGENTS.md](AGENTS.md).

> **AI agents:** before initializing a repo from this template, read
> [docs/AGENT-INIT-GUIDE.md](docs/AGENT-INIT-GUIDE.md). It captures the mistakes
> past initialization sessions made (assuming the layout instead of reading it,
> mixing shells, fighting the permission model) and is a living document you are
> expected to extend when new mistakes happen.

## Using this template

1. Create a new repository from this one (GitHub: **Use this template**), or copy
   the files into a fresh repo.
2. **Check your environment is ready.** Before initializing, confirm this machine
   has the toolchain to build and test a C# project. Use whichever matches your
   shell — both do the same thing:

   ```pwsh
   pwsh ./scripts/check-env.ps1
   ```

   ```bash
   bash ./scripts/check-env.sh
   ```

   It asks the .NET host to resolve the committed `global.json`, including its
   exact `version`, `rollForward`, and `allowPrerelease` settings. If the file is
   invalid or no compatible SDK is installed, it names the configuration file,
   lists install guidance, and exits non-zero. **Don't run init until it reports
   the environment is ready.**
3. Run the init script once to stamp your project name in. Use whichever
   matches your shell — both do the same thing:

   ```pwsh
   pwsh ./scripts/init.ps1 -ProjectName Acme.Widgets -Author "Jane Doe" -GitHubOwner acme -Description "Widget toolkit"
   ```

   ```bash
   bash ./scripts/init.sh --project-name Acme.Widgets --author "Jane Doe" --github-owner acme --description "Widget toolkit"
   ```

   `-ProjectName` / `--project-name` is required; the rest are optional and fall
   back to sensible defaults (`git config user.name`, `git config user.email`,
   `your-org`, a TODO description, the current year). If Git is unavailable or
   either configured identity value is empty, the PowerShell initializer uses
   `Your Name` and `you@example.com` instead. An explicit empty optional metadata
   value uses the same fallback in both initializers. Every supplied metadata
   option must have a separate argument: the end of the command or another option
   is rejected before any file changes, rather than consuming that option as data.
   Empty project names and years are rejected. Both initializers accept a signed
   decimal year in the `Int32` range. The script:
   - validates all metadata and the complete `scripts/init-plan.tsv` mutation
     plan before writing: `ProjectName` must be 1-100 ASCII characters in
     dot-separated C# identifier segments, must begin with a letter so the
     generated `<ProjectName>-nuget` Docker volume is valid, and cannot use a
     reserved C# keyword as a segment; because the same value names files and directories,
     its leading basename cannot be a case-insensitive Windows device name
     (`CON`, `PRN`, `AUX`, `NUL`, `COM1`-`COM9`, or `LPT1`-`LPT9`), including
     one followed by an extension. Author, author email, and description must be
     single-line; GitHub owner must be 1-39 letters, digits, or hyphens, with no
     leading or trailing hyphen;
   - substitutes only the template-owned text files listed as `content` entries
     in that plan; it never recursively scans the repository, so unknown files,
     binary data, `.work`, caches, and unknown files inside the original
     token-named source directories remain byte-for-byte at their original paths;
   - requires every source in the current plan to exist with its declared file or
     directory type, and stops before the first mutation if any planned
     destination already exists, including a generated solution/project path or
     `.claude/settings.json`; it also rejects symlink, junction, or other
     reparse-point components in every planned source and destination;
   - replaces content through a new repository entry so an external hard-linked
     peer is never written through, while preserving file metadata, including
     Windows access-control rules under PowerShell and Git Bash;
   - restores the complete original tree if an I/O failure still occurs after
     preflight while content, paths, or template-only files are being changed;
   - replaces all placeholder tokens in one pass, so placeholder-like text inside
     a supplied value stays literal and does not trigger another replacement;
   - preserves quotes, backslashes, and shell/Python metacharacters as data,
     XML-escapes values written into XML project files, and safely serializes the
     release-commit identity before the workflow passes it to Bash;
   - moves only the listed solution, Rider settings, sample source/test, and two
     project files into `src/<project>` / `tests/<project>.Tests`; it removes an
     original token-named directory only when no local content remains there;
   - activates `.claude/settings.json` from its shipped `.template` form
     (sane shared permissions for `dotnet` commands);
   - deletes this `TEMPLATE.md`, `docs/AGENT-INIT-GUIDE.md`, the template-only
     `scripts/tests/init-substitution.tests.ps1`, and the consumed init plan;
     unless `-KeepScript` /
     `--keep-script` is set, it also removes **both** initializers — itself and its
     sibling — so a generated repo ships neither `init.ps1` nor `init.sh`.
4. Verify:

   ```pwsh
   dotnet build Acme.Widgets.slnx
   dotnet test  Acme.Widgets.slnx
   ```

   Template maintainers can reproduce the cross-shell hostile-input, syntax,
   build, and NUnit regression before initialization:

   ```pwsh
   pwsh ./scripts/tests/init-substitution.tests.ps1
   ```

   The regression requires PowerShell 7, Bash, Python with PyYAML or `yamllint`,
   and the .NET SDK pinned by `global.json`. It runs entirely in a temporary
   directory and removes that directory on completion.

5. Replace the placeholder `Greeter` type in `src/...` with your real API and
   delete the sample test.
6. **Keep the agent-instruction files local.** This template tracks and ships
   `CLAUDE.md`, `AGENTS.md`, and `.claude/` on purpose — but a repo *created from*
   it should keep them out of its remote: they are local guidance for tools, not
   something to publish, so each developer keeps their own. The init script does
   **not** do this — it is a by-hand step. Before your first push, git-ignore and
   untrack them (the files stay on disk). They start out tracked and the
   `.gitignore` here *deliberately* ships `.claude/settings.json`, so append the
   ignore rules **after** that block, then drop the files from the index:

   ```bash
   printf '\n/CLAUDE.md\n/AGENTS.md\n.claude/\n' >> .gitignore
   git rm -r --cached CLAUDE.md AGENTS.md .claude
   git add .gitignore && git commit -m "Keep agent instructions local"   # commit the ignore rule *and* the removals
   ```

   Appending `.claude/` last makes it win over the earlier `!.claude/...` ship
   lines. The names then appear in the pushed `.gitignore` (contents never leave
   your machine); for a zero-filename-trace alternative, see
   [docs/AGENT-INIT-GUIDE.md](docs/AGENT-INIT-GUIDE.md). One caveat: a repo created
   via **"Use this template"** already carries these files in its initial commit on
   the remote, so untracking keeps them out of *later* commits only; for a clean
   history, copy the template into a fresh `git init` and untrack before the first
   commit. Because `init` deletes this file and the guide, the surviving copy of
   this recipe downstream is the "Agent instruction files are local-only in
   generated repos" section of [AGENTS.md](AGENTS.md).

## Placeholder tokens

| Token | Meaning |
|---|---|
| `__ProjectName__` | validated C# namespace / assembly / NuGet package id + portable file, folder, and Docker-volume prefix |
| `__Author__` | single-line author (LICENSE, `<Authors>`, `<Copyright>`, release identity) |
| `__AuthorEmail__` | single-line author email (release-commit identity in `release.yml`) |
| `__GitHubOwner__` | 1-39 character GitHub owner/org path segment in repository URLs |
| `__Description__` | single-line package description |
| `__Year__` | copyright year |

## Optional pieces — remove what you don't need

- **NuGet publishing** — if this is an app or internal library, delete
  `.github/workflows/release.yml` and the packaging properties in the `.csproj`
  (`PackageId`, `Authors`, `Description`, URLs, symbols, SourceLink, the README/
  CHANGELOG `Pack` items). Keep `Directory.Build.props`, CI, and CodeQL.
- **Linux testing from Windows** — delete `scripts/test-linux.ps1` and
  `docs/linux-testing.md` if you don't need to run the Linux code path locally.
- **Rider settings** — delete `__ProjectName__.sln.DotSettings` if you don't use
  Rider/ReSharper.
- **SDK pin** — `global.json` starts at 10.0.100 and selects the latest installed
  .NET 10 feature band via `rollForward: latestFeature`; it does not cross into a
  later major or accept prerelease SDKs. The environment checks use the .NET host
  itself to enforce those settings. Bump the file when you move to a newer band;
  delete it to always use whatever SDK is installed.
- **Dependency updates** — `.github/dependabot.yml` opens weekly PRs to bump GitHub
  Actions and the central NuGet versions in `Directory.Packages.props`. Action and
  NuGet bumps are each grouped into a single weekly PR. Remove it if you update
  dependencies by hand.
- **Community-health files** — `SECURITY.md`, `CONTRIBUTING.md`,
  `.github/PULL_REQUEST_TEMPLATE.md`, and `.github/CODEOWNERS`. Edit them to taste;
  delete any you don't want. `CODEOWNERS` ships with its rule commented out — see
  the note inside before enabling it (it must reference a real user/team).
- **YAML linting** — `.yamllint.yml` is tuned for GitHub Actions, and the CI
  `yaml-lint` job runs it on every push/PR. Run it locally with `yamllint .` (or
  `py -m yamllint .` on Windows). Delete the file and the job if you don't want it.

## Security hardening (on by default)

- **Pinned actions** — every GitHub Action is pinned to a full commit SHA (with a
  `# vN` comment), not a moving tag. Dependabot bumps the SHA and rewrites the
  comment. This blocks a re-tagged-action supply-chain attack.
- **Dependency auditing** — `Directory.Build.props` sets `NuGetAudit`/`NuGetAuditMode=all`
  so direct *and* transitive packages are checked against the NuGet advisory
  database on restore. Vulnerability findings stay warnings (not build-breaking
  errors) so a freshly disclosed CVE doesn't block every build; promote them per
  project for a hard gate.
- **NuGet Trusted Publishing (OIDC)** — the release workflow uses a long-lived
  `NUGET_API_KEY` by default, but documents how to switch to short-lived OIDC
  tokens (no stored secret). See the comment above the *Push to NuGet.org* step in
  `.github/workflows/release.yml`.
- **Release ordering** — the NuGet publish is the single irreversible step, so the
  workflow makes it the pivot. It captures the dispatch commit as a full immutable
  source SHA, checks out that SHA, and derives the version, package, notes, local
  release commit, and tag from it. Versioning considers only exact stable
  `vMAJOR.MINOR.PATCH` tag refs reachable from that source, then chooses the highest
  SemVer value; branch names, prerelease-like tags, and tags on unrelated history do
  not affect the result. Immediately before publication, `origin/main`
  must still equal the captured source; otherwise the workflow stops without a
  NuGet attempt. After acceptance, the atomic push can advance `main` only from that
  exact expected SHA. A structured terminal rejection proves that NuGet did not
  accept the package and leaves no remote recovery artifact. A timeout, cancellation,
  or unclassified client failure after an attempt is ambiguous, so the workflow
  preserves the exact bundle, packages, checksums, notes, source/release SHAs, and tag
  as a `release-recovery-vX.Y.Z` artifact; do not re-run until the version is
  confirmed absent. If NuGet accepted it, verify and use that run's immutable
  artifact instead of rebuilding, regardless of what the publish client or later
  steps reported (see `.github/workflows/release.yml`).

## Recommended add-ons (not enabled by default)

These are intentionally left off so the template stays general; turn them on per
project.

- **AOT / trim safety** — if the library should be Native-AOT and trim friendly,
  add `<IsAotCompatible>true</IsAotCompatible>` to the library `.csproj`. It turns
  on the trim/AOT/single-file analyzers, so (with warnings-as-errors) reflection or
  other AOT-unsafe patterns become build errors. For end-to-end verification add a
  small `tests/__ProjectName__.AotSmoke` project with `<PublishAot>true</PublishAot>`
  and a CI job that `dotnet publish`es it.
- **XML documentation in the package** — add
  `<GenerateDocumentationFile>true</GenerateDocumentationFile>` to ship IntelliSense
  docs with the NuGet package. With warnings-as-errors this also makes undocumented
  public members (CS1591) build errors — good discipline for a published API; add
  `<NoWarn>$(NoWarn);CS1591</NoWarn>` if you want the doc file without that rule.

## Post-setup checklist

- [ ] Agent-instruction files (`CLAUDE.md`, `AGENTS.md`, `.claude/`) git-ignored
      and untracked so they stay local and never reach the remote — by hand,
      before the first push (step 6 above); verify with `git status`.
- [ ] `NUGET_API_KEY` repo secret added (only if publishing to NuGet), or
      NuGet Trusted Publishing (OIDC) configured — see `release.yml`.
- [ ] LICENSE author/year and license choice reviewed.
- [ ] `.csproj` package metadata (description, tags, URLs) filled in.
- [ ] `SECURITY.md` reporting contact reviewed; `.github/CODEOWNERS` enabled if wanted.
- [ ] GitHub **Settings → Security → Private vulnerability reporting** enabled (for `SECURITY.md`).
- [ ] `CLAUDE.md` "Architecture" section written for your project.
- [ ] Branch protection for `main` configured — require pull requests (plus CI / CodeQL
      status checks). The agent docs (`CLAUDE.md` / `AGENTS.md`) already assume a
      feature-branch + PR flow into `main`. Requiring PRs blocks the release workflow's
      direct push of the release commit. The workflow pushes as a GitHub App when
      configured — add repo variable `RELEASE_APP_ID` + secret `RELEASE_APP_PRIVATE_KEY`,
      install the App, and add it to the ruleset's bypass list (recipe:
      `release-token-bypass.md`).
