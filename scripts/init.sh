#!/usr/bin/env bash
#
# Initializes this template into a concrete C# project (POSIX counterpart of
# init.ps1 — use whichever matches your shell; both do the same thing).
#
# Replaces the placeholder tokens (__ProjectName__, __Author__, __AuthorEmail__,
# __GitHubOwner__, __Description__, __Year__) in file contents AND in file/folder
# names, then removes the template-only files (TEMPLATE.md,
# docs/AGENT-INIT-GUIDE.md, scripts/tests/init-substitution.tests.ps1) and —
# unless --keep-script — both initializers (init.sh and init.ps1).
#
# Usage:
#   bash ./scripts/init.sh --project-name Acme.Widgets \
#       [--author "Jane Doe"] [--author-email you@example.com] \
#       [--github-owner acme] [--description "Widget toolkit"] \
#       [--year 2026] [--keep-script]
#
# --project-name is required; the rest fall back to sensible defaults so the
# result always builds. Author, author-email, and description must be single-line;
# GitHub owner must be a valid account-path segment. Edit LICENSE / the .csproj
# afterwards to refine them.

set -euo pipefail

project_name=""
author=""
author_email=""
github_owner=""
description=""
year=""
keep_script=0

die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project-name) project_name="${2:-}"; shift 2 ;;
    --author)       author="${2:-}"; shift 2 ;;
    --author-email) author_email="${2:-}"; shift 2 ;;
    --github-owner) github_owner="${2:-}"; shift 2 ;;
    --description)  description="${2:-}"; shift 2 ;;
    --year)         year="${2:-}"; shift 2 ;;
    --keep-script)  keep_script=1; shift ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *)              die "unknown argument: $1" ;;
  esac
done

[ -n "$project_name" ] || die "--project-name is required (e.g. --project-name Acme.Widgets)."

# Project / namespace / assembly / NuGet package id: letters, digits, underscores;
# dot-separated segments allowed (e.g. Acme.Widgets). Mirrors init.ps1's regex
# ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ via a per-segment check.
# Reject a leading or trailing '.' first: `read -ra` silently drops a trailing
# empty field, so "Acme." would otherwise slip through (the regex rejects it).
case "$project_name" in
  .*|*.) die "invalid --project-name '$project_name'. Use letters, digits, underscores; dot-separated segments allowed (e.g. Acme.Widgets)." ;;
esac
IFS='.' read -ra _segs <<< "$project_name"
for seg in "${_segs[@]}"; do
  case "$seg" in
    [A-Za-z_]*) ;;
    *) die "invalid --project-name '$project_name'. Use letters, digits, underscores; dot-separated segments allowed (e.g. Acme.Widgets)." ;;
  esac
  case "$seg" in
    *[!A-Za-z0-9_]*) die "invalid --project-name '$project_name'. Use letters, digits, underscores; dot-separated segments allowed (e.g. Acme.Widgets)." ;;
  esac
done

# Defaults (mirror init.ps1).
if [ -z "$author" ]; then
  author="$(git config user.name 2>/dev/null || true)"
  [ -n "$author" ] || author="Your Name"
fi
if [ -z "$author_email" ]; then
  author_email="$(git config user.email 2>/dev/null || true)"
  [ -n "$author_email" ] || author_email="you@example.com"
fi
[ -n "$github_owner" ] || github_owner="your-org"
[ -n "$description" ]  || description="TODO: project description"
[ -n "$year" ]         || year="$(date +%Y)"

case "$author" in
  *$'\r'*|*$'\n'*) die "invalid --author: line breaks are not allowed." ;;
esac
case "$author_email" in
  *$'\r'*|*$'\n'*) die "invalid --author-email: line breaks are not allowed." ;;
esac
case "$description" in
  *$'\r'*|*$'\n'*) die "invalid --description: line breaks are not allowed." ;;
esac
if [[ ! "$github_owner" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
  die "invalid --github-owner '$github_owner'. Use 1-39 letters, digits, or hyphens, with no leading or trailing hyphen."
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
self="$script_dir/$(basename "$0")"
sibling_ps1="$script_dir/init.ps1"

# Values written into XML files (e.g. the .csproj <Authors>/<Description>) must be
# XML-escaped — a literal & or < in an author/description would break the project
# file. Escape & first so the &-introducing entities aren't double-escaped.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
project_x="$(xml_escape "$project_name")"
author_x="$(xml_escape "$author")"
author_email_x="$(xml_escape "$author_email")"
owner_x="$(xml_escape "$github_owner")"
desc_x="$(xml_escape "$description")"
year_x="$(xml_escape "$year")"
author_b64="$(printf '%s' "$author" | base64 | tr -d '\r\n')"
author_email_b64="$(printf '%s' "$author_email" | base64 | tr -d '\r\n')"

token_pattern='(__ProjectName__|__AuthorEmailBase64__|__AuthorBase64__|__AuthorEmail__|__Author__|__GitHubOwner__|__Description__|__Year__)'

replace_tokens() {
  local content="$1"
  local mode="$2"
  local rest="$content"
  local output=""
  local token prefix replacement

  while [[ "$rest" =~ $token_pattern ]]; do
    token="${BASH_REMATCH[1]}"
    prefix="${rest%%"$token"*}"
    output+="$prefix"
    case "$token" in
      __ProjectName__)      if [ "$mode" = xml ]; then replacement="$project_x"; else replacement="$project_name"; fi ;;
      __Author__)           if [ "$mode" = xml ]; then replacement="$author_x"; else replacement="$author"; fi ;;
      __AuthorEmail__)      if [ "$mode" = xml ]; then replacement="$author_email_x"; else replacement="$author_email"; fi ;;
      __AuthorBase64__)     replacement="$author_b64" ;;
      __AuthorEmailBase64__) replacement="$author_email_b64" ;;
      __GitHubOwner__)      if [ "$mode" = xml ]; then replacement="$owner_x"; else replacement="$github_owner"; fi ;;
      __Description__)      if [ "$mode" = xml ]; then replacement="$desc_x"; else replacement="$description"; fi ;;
      __Year__)             if [ "$mode" = xml ]; then replacement="$year_x"; else replacement="$year"; fi ;;
    esac
    output+="$replacement"
    rest="${rest#*"$token"}"
  done
  printf '%s%s' "$output" "$rest"
}

echo "==> Initializing template as '$project_name'"

# 1) Replace tokens in file contents. Both initializers are skipped: they carry
#    the literal token strings as search keys, so substituting inside them would
#    corrupt the sibling script. Excluded dirs (.git/.jj/bin/obj) are pruned.
changed=0
while IFS= read -r -d '' file; do
  case "$file" in
    "$self"|"$sibling_ps1") continue ;;
  esac
  # Skip binary files: they carry no tokens, and reading them through a shell
  # command substitution strips NUL bytes, which would corrupt the file on rewrite.
  # The template ships none, but a downstream user may add e.g. a strong-name key
  # or a NuGet package icon before running init.
  case "$file" in
    *.snk|*.pfx|*.png|*.jpg|*.jpeg|*.gif|*.ico|*.zip) continue ;;
  esac
  case "$file" in
    *.csproj|*.props|*.targets|*.slnx|*.config)
      mode=xml ;;
    *)
      mode=raw ;;
  esac
  # Preserve trailing newlines: append a sentinel before capture, strip it after.
  content="$(cat "$file"; printf x)"; content="${content%x}"
  orig="$content"
  content="$(replace_tokens "$content" "$mode"; printf x)"; content="${content%x}"
  if [ "$content" != "$orig" ]; then
    printf '%s' "$content" > "$file"
    changed=$((changed + 1))
  fi
done < <(find "$repo_root" -type d \( -name .git -o -name .jj -o -name bin -o -name obj \) -prune -o -type f -print0)
echo "    Updated contents in $changed file(s)."

# 2) Rename files and folders whose name contains the project-name token. -depth
#    processes children before parents so a renamed dir doesn't invalidate paths
#    (deepest paths first, mirroring init.ps1's length-descending sort).
while IFS= read -r -d '' item; do
  case "$item" in
    */.git/*|*/.jj/*|*/bin/*|*/obj/*) continue ;;
  esac
  dir="$(dirname "$item")"
  base="$(basename "$item")"
  newbase="${base//__ProjectName__/$project_name}"
  if [ "$newbase" != "$base" ]; then
    mv "$item" "$dir/$newbase"
    echo "    Renamed $base -> $newbase"
  fi
done < <(find "$repo_root" -depth -name '*__ProjectName__*' -print0)

# 3) Activate the Claude Code shared settings. Shipped inert as a .template file
#    so the template repository itself does not auto-grant any permissions.
if [ -f "$repo_root/.claude/settings.json.template" ]; then
  mv -f "$repo_root/.claude/settings.json.template" "$repo_root/.claude/settings.json"
  echo "    Activated .claude/settings.json"
fi

# 4) Remove template-only files — documentation that only applies while this is a
#    template, not after it has been stamped into a concrete project.
rm -f \
  "$repo_root/TEMPLATE.md" \
  "$repo_root/docs/AGENT-INIT-GUIDE.md" \
  "$repo_root/scripts/tests/init-substitution.tests.ps1"
# Drop docs/ if it's now empty (it usually isn't — linux-testing.md also lives here).
rmdir "$repo_root/docs" 2>/dev/null || true
rmdir "$repo_root/scripts/tests" 2>/dev/null || true

echo ""
echo "Done. Next steps:"
echo "  1. dotnet build $project_name.slnx"
echo "  2. dotnet test  $project_name.slnx"
echo "  3. Review LICENSE (author/year) and the .csproj package metadata."
echo "  4. NuGet publishing: add the NUGET_API_KEY repo secret, or delete"
echo "     .github/workflows/release.yml and the packaging properties in the .csproj."
echo "  5. Commit the initialized project."

# 5) Remove both initializers unless asked to keep them.
if [ "$keep_script" -ne 1 ]; then
  rm -f "$sibling_ps1"
  rm -f "$self"
fi
