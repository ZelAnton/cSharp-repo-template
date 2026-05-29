# C# repository template

A starting point for C# repositories: central package management, a strict
`.editorconfig`, cross-platform CI, CodeQL, an optional NuGet release pipeline,
and conventions for agents in [CLAUDE.md](CLAUDE.md) / [AGENTS.md](AGENTS.md).

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

## Post-setup checklist

- [ ] `NUGET_API_KEY` repo secret added (only if publishing to NuGet).
- [ ] LICENSE author/year and license choice reviewed.
- [ ] `.csproj` package metadata (description, tags, URLs) filled in.
- [ ] `CLAUDE.md` "Architecture" section written for your project.
- [ ] Branch protection / required checks configured for `main` (CI, CodeQL).
