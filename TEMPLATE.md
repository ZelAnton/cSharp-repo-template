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
2. Run the init script once to stamp your project name in:

   ```pwsh
   pwsh ./scripts/init.ps1 -ProjectName Acme.Widgets -Author "Jane Doe" -GitHubOwner acme -Description "Widget toolkit"
   ```

   `-ProjectName` is required; the rest are optional and fall back to sensible
   defaults (`git config user.name`, `your-org`, a TODO description, the current
   year). The script:
   - replaces the placeholder tokens in every file's contents;
   - renames the token-named files and folders (`src/__ProjectName__`,
     `tests/__ProjectName__.Tests`, the `.csproj`/`.slnx`/`.sln.DotSettings`);
   - activates `.claude/settings.json` from its shipped `.template` form
     (sane shared permissions for `dotnet` commands);
   - deletes this `TEMPLATE.md` and (unless `-KeepScript`) itself.
3. Verify:

   ```pwsh
   dotnet build Acme.Widgets.slnx
   dotnet test  Acme.Widgets.slnx
   ```

4. Replace the placeholder `Greeter` type in `src/...` with your real API and
   delete the sample test.
5. **Keep the agent-instruction files local.** This template tracks and ships
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
   # jj-colocated: jj file untrack CLAUDE.md AGENTS.md .claude  (folds .gitignore + removals in; no separate commit)
   ```

   Appending `.claude/` last makes it win over the earlier `!.claude/...` ship
   lines. The names then appear in the pushed `.gitignore` (contents never leave
   your machine); for zero filename trace, and the full jj-colocated steps, see
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
| `__ProjectName__` | project / namespace / assembly / package id + file & folder names |
| `__Author__` | author (LICENSE, `<Authors>`, `<Copyright>`) |
| `__GitHubOwner__` | GitHub owner/org in repository URLs |
| `__Description__` | package description |
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
- **SDK pin** — `global.json` pins the .NET SDK feature band (10.0.1xx and up via
  `rollForward: latestFeature`) so builds are reproducible and a contributor on an
  older SDK gets a clear error instead of confusing analyzer failures. Bump it when
  you move to a newer band; delete it to always use whatever SDK is installed.
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
- **Release ordering** — the workflow pushes the git commit/tag *before* publishing
  to NuGet, so a blocked git push (e.g. branch protection) can't leave an orphaned,
  un-tagged package on the registry.

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
      before the first push (step 5 above); verify with `git status` / `jj st`.
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
      direct push of the release commit — give the release actor a bypass or add a
      `RELEASE_TOKEN` secret (see the note in `.github/workflows/release.yml`).
