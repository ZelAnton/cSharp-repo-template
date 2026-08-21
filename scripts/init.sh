#!/usr/bin/env bash
#
# Initializes this template into a concrete C# project (POSIX counterpart of
# init.ps1 — use whichever matches your shell; both do the same thing).
#
# Replaces placeholder tokens only in the template-owned files listed by
# scripts/init-plan.tsv, moves the listed project files to their generated paths,
# and removes the listed template-only files. Unless --keep-script is supplied,
# it also removes both initializers (init.sh and init.ps1). The complete plan is
# validated before the first write; an existing target leaves the tree unchanged.
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

plan_path="$script_dir/init-plan.tsv"
[ -f "$plan_path" ] || die "initialization plan is missing: scripts/init-plan.tsv. No files were changed."

resolve_plan_path() {
  local path_template="$1"
  local relative="${path_template//\{ProjectName\}/$project_name}"
  case "$relative" in
    ""|/*|*\\*|.|..|./*|../*|*/./*|*/../*|*/.|*/..|*//*)
      die "unsafe path '$path_template' in scripts/init-plan.tsv. No files were changed." ;;
  esac
  printf '%s' "$relative"
}

path_exists() { [ -e "$1" ] || [ -L "$1" ]; }

declare -a plan_kinds=()
declare -a plan_sources=()
declare -a plan_destinations=()
line_number=0
while IFS=$'\t' read -r kind source destination extra || [ -n "${kind:-}${source:-}${destination:-}${extra:-}" ]; do
  line_number=$((line_number + 1))
  kind="${kind%$'\r'}"
  source="${source%$'\r'}"
  destination="${destination%$'\r'}"
  extra="${extra%$'\r'}"
  case "$kind" in
    ""|\#*) continue ;;
    content|remove)
      [ -n "$source" ] && [ -z "$destination" ] && [ -z "$extra" ] ||
        die "invalid entry at scripts/init-plan.tsv:$line_number. No files were changed." ;;
    directory|move|activate)
      [ -n "$source" ] && [ -n "$destination" ] && [ -z "$extra" ] ||
        die "invalid entry at scripts/init-plan.tsv:$line_number. No files were changed." ;;
    *)
      die "invalid entry at scripts/init-plan.tsv:$line_number. No files were changed." ;;
  esac

  plan_kinds[${#plan_kinds[@]}]="$kind"
  plan_sources[${#plan_sources[@]}]="$(resolve_plan_path "$source")"
  if [ -n "$destination" ]; then
    plan_destinations[${#plan_destinations[@]}]="$(resolve_plan_path "$destination")"
  else
    plan_destinations[${#plan_destinations[@]}]=""
  fi
done < "$plan_path"

[ "${#plan_kinds[@]}" -gt 0 ] || die "initialization plan is empty: scripts/init-plan.tsv. No files were changed."

declare -a planned_targets=()
declare -a content_paths=()
declare -a content_values=()
declare -a directory_sources=()
declare -a directory_targets=()
declare -a move_sources=()
declare -a move_targets=()
declare -a remove_paths=()

register_target() {
  local target="$1"
  local existing
  for existing in "${planned_targets[@]-}"; do
    [ "$existing" != "$target" ] || die "duplicate initialization target: ${target#"$repo_root/"}. No files were changed."
  done
  planned_targets[${#planned_targets[@]}]="$target"
}

# Build the complete mutation set and every replacement in memory before the
# first write. Paths not listed in the plan are never inspected or modified.
for ((i = 0; i < ${#plan_kinds[@]}; i++)); do
  kind="${plan_kinds[$i]}"
  source_relative="${plan_sources[$i]}"
  destination_relative="${plan_destinations[$i]}"
  source="$repo_root/$source_relative"
  destination=""
  if [ -n "$destination_relative" ]; then
    destination="$repo_root/$destination_relative"
  fi

  case "$kind" in
    content)
      path_exists "$source" || continue
      [ -f "$source" ] || die "template content path is not a file: $source_relative. No files were changed."
      case "$source" in
        *.csproj|*.props|*.targets|*.slnx|*.config) mode=xml ;;
        *) mode=raw ;;
      esac
      content="$(cat "$source"; printf x)"; content="${content%x}"
      transformed="$(replace_tokens "$content" "$mode"; printf x)"; transformed="${transformed%x}"
      if [ "$transformed" != "$content" ]; then
        content_paths[${#content_paths[@]}]="$source"
        content_values[${#content_values[@]}]="$transformed"
      fi
      ;;
    directory)
      path_exists "$source" || continue
      [ -d "$source" ] || die "template directory path is not a directory: $source_relative. No files were changed."
      [ "$source" != "$destination" ] || continue
      ! path_exists "$destination" || die "initialization target collision: $destination_relative already exists. No files were changed."
      register_target "$destination"
      directory_sources[${#directory_sources[@]}]="$source"
      directory_targets[${#directory_targets[@]}]="$destination"
      ;;
    move|activate)
      path_exists "$source" || continue
      { [ -f "$source" ] || [ -L "$source" ]; } || die "template move source is not a file: $source_relative. No files were changed."
      [ "$source" != "$destination" ] || continue
      ! path_exists "$destination" || die "initialization target collision: $destination_relative already exists. No files were changed."
      parent="$(dirname "$destination")"
      if path_exists "$parent" && [ ! -d "$parent" ]; then
        die "initialization target parent is not a directory: $destination_relative. No files were changed."
      fi
      register_target "$destination"
      move_sources[${#move_sources[@]}]="$source"
      move_targets[${#move_targets[@]}]="$destination"
      ;;
    remove)
      if path_exists "$source" && { [ ! -f "$source" ] && [ ! -L "$source" ]; }; then
        die "template-only removal path is not a file: $source_relative. No files were changed."
      fi
      remove_paths[${#remove_paths[@]}]="$source"
      ;;
  esac
done

echo "==> Initializing template as '$project_name'"
echo "    Preflight validated ${#plan_kinds[@]} template-owned operation(s)."

for ((i = 0; i < ${#content_paths[@]}; i++)); do
  printf '%s' "${content_values[$i]}" > "${content_paths[$i]}"
done
echo "    Updated contents in ${#content_paths[@]} file(s)."

# Destination directories are created empty; only listed files move into them.
# Unknown files inside token-named source directories stay at their original paths.
for ((i = 0; i < ${#directory_sources[@]}; i++)); do
  mkdir -- "${directory_targets[$i]}"
done
for ((i = 0; i < ${#move_sources[@]}; i++)); do
  mv -- "${move_sources[$i]}" "${move_targets[$i]}"
  echo "    Moved ${move_sources[$i]#"$repo_root/"} -> ${move_targets[$i]#"$repo_root/"}"
done
for path in "${remove_paths[@]}"; do
  if [ -f "$path" ] || [ -L "$path" ]; then
    rm -f -- "$path"
    echo "    Removed ${path#"$repo_root/"}"
  fi
done

for ((i = ${#directory_sources[@]} - 1; i >= 0; i--)); do
  rmdir -- "${directory_sources[$i]}" 2>/dev/null || true
done
rmdir -- "$repo_root/docs" 2>/dev/null || true
rmdir -- "$repo_root/scripts/tests" 2>/dev/null || true

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
