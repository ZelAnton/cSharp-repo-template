# Letting the release workflow push to a protected `main`

`.github/workflows/release.yml` pushes the release commit and tag straight to
`main` (see its "Push the release commit + tag" step). When `main` is protected
by a ruleset that **requires pull requests or status checks**, a direct push is
rejected — including the one the release workflow needs to make. This recipe sets
up a short-lived **GitHub App token** so that one push is allowed, without
weakening the rule for anyone else.

## Why a GitHub App (and not the alternatives)

- **`github-actions[bot]` / `GITHUB_TOKEN`** — cannot be added to a ruleset's
  bypass list. It is a system actor, not an App or team, so GitHub offers no way
  to grant it a bypass. A push as this actor is still subject to the rule.
- **A personal access token (PAT)** — works, but ties the release to one person's
  account and expires, so releases silently break when it lapses and it needs
  rotation. It also carries that user's full access.
- **A GitHub App installation token** — *can* be added to a ruleset bypass list,
  is minted fresh per run, expires automatically (~1 hour), is scoped to just the
  permissions the App declares, and needs no rotation. This is what the workflow
  uses when configured.

The workflow mints the token in its "Mint GitHub App token" step (via
`actions/create-github-app-token`), checks out with it, and therefore pushes
**as the App**. If the App is not configured, that step is skipped and the
checkout falls back to the default `GITHUB_TOKEN` — fine while `main` is
unprotected.

## One-time setup

### 1. Create the GitHub App

Settings → **Developer settings** → **GitHub Apps** → **New GitHub App**
(a user-owned App is fine; use an org-owned App if the repo lives in an org).

- **GitHub App name** — anything, e.g. `<your-repo> release bot`.
- **Homepage URL** — any valid URL (your repo URL is fine).
- **Webhook** — uncheck **Active** (no webhook needed).
- **Repository permissions** → **Contents: Read and write.** This is the only
  permission required to push the commit and tag. Leave everything else at *No
  access*.
- Create the App.

### 2. Note the App ID and generate a private key

On the App's page:

- Copy the **App ID** (a number).
- Under **Private keys**, click **Generate a private key**. A `.pem` file
  downloads — you will paste its full contents (including the
  `-----BEGIN/END ...-----` lines) as a secret below. Store it safely; it cannot
  be re-downloaded.

### 3. Install the App on the repository

App page → **Install App** → install it on the account that owns the repo and
select **Only select repositories → your repo**.

### 4. Add the credentials to the repository

Repo → **Settings** → **Secrets and variables** → **Actions**:

- **Variables** tab → **New repository variable**
  - Name: `RELEASE_APP_ID`
  - Value: the App ID from step 2.
- **Secrets** tab → **New repository secret**
  - Name: `RELEASE_APP_PRIVATE_KEY`
  - Value: the full contents of the `.pem` private key from step 2.

The workflow's "Mint GitHub App token" step runs only when `RELEASE_APP_ID` is
set, so adding these is what switches the release from `GITHUB_TOKEN` to the App.

### 5. Add the App to the branch ruleset's bypass list

Repo → **Settings** → **Rules** → **Rulesets** → open the ruleset protecting
`main` → **Bypass list** → **Add bypass** → select the App you created → save.

Without this step the App is authenticated but still subject to the rule, and the
push is rejected.

## Verify

Run the **Release** workflow (Actions → Release → **Run workflow**, from `main`).
The "Mint GitHub App token" step should run (not be skipped), and the "Push the
release commit + tag (atomic)" step should succeed. If the push is rejected with a
protected-branch error, re-check step 5 — the App must be in the ruleset's bypass
list, and the ruleset (not a legacy "branch protection rule") is where the bypass
lives.

## Notes

- The App token is scoped to **Contents: write** and expires automatically — it
  cannot do more than push to the repo, and there is nothing to rotate.
- The release commit uses the author and email supplied during initialization.
  Initialization serializes both values before placing them in workflow
  environment variables, and the workflow decodes them only as quoted `git config`
  data; quotes, backslashes, and shell metacharacters in the single-line values are
  not executed. The *pusher* is the App. That is expected — the bypass keys on the
  pusher, not the commit author.
- If you would rather not push to `main` at all from CI, the alternative is to drop
  the "Push the release commit + tag" step and open a PR with the release commit
  instead — but then the tag/version bump only lands once that PR merges, which the
  current single-run, idempotent design intentionally avoids.
