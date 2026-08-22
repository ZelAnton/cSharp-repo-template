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

set -Eeuo pipefail

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

script_dir="$(cd -P "$(dirname "$0")" && pwd -P)"
repo_root="$(cd -P "$script_dir/.." && pwd -P)"
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
is_link_or_reparse() { [ -L "$1" ] || [ -n "$(readlink "$1" 2>/dev/null || true)" ]; }

windows_acl_mode=0
windows_path_tool=""
windows_pwsh_command=""
windows_metadata_helper="$script_dir/init-windows-metadata.ps1"
windows_metadata_helper_path=""
windows_staging_parent=""
windows_interop_environment="${WSLENV:-}"
windows_pwsh_launcher='JABFAHIAcgBvAHIAQQBjAHQAaQBvAG4AUAByAGUAZgBlAHIAZQBuAGMAZQAgAD0AIAAiAFMAdABvAHAAIgAKACQAaABlAGwAcABlAHIAIAA9ACAAWwBFAG4AdgBpAHIAbwBuAG0AZQBuAHQAXQA6ADoARwBlAHQARQBuAHYAaQByAG8AbgBtAGUAbgB0AFYAYQByAGkAYQBiAGwAZQAoACIAQwBTAEgAQQBSAFAAXwBUAEUATQBQAEwAQQBUAEUAXwBNAEUAVABBAEQAQQBUAEEAXwBIAEUATABQAEUAUgAiACwAIAAiAFAAcgBvAGMAZQBzAHMAIgApAAoAJABhAGMAdABpAG8AbgAgAD0AIABbAEUAbgB2AGkAcgBvAG4AbQBlAG4AdABdADoAOgBHAGUAdABFAG4AdgBpAHIAbwBuAG0AZQBuAHQAVgBhAHIAaQBhAGIAbABlACgAIgBDAFMASABBAFIAUABfAFQARQBNAFAATABBAFQARQBfAE0ARQBUAEEARABBAFQAQQBfAEEAQwBUAEkATwBOACIALAAgACIAUAByAG8AYwBlAHMAcwAiACkACgAmACAAJABoAGUAbABwAGUAcgAgAC0AQQBjAHQAaQBvAG4AIAAkAGEAYwB0AGkAbwBuAA=='
case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*)
    windows_acl_mode=1
    command -v pwsh >/dev/null 2>&1 || die "Windows file security metadata cannot be preserved because pwsh is unavailable. No files were changed."
    command -v cygpath >/dev/null 2>&1 || die "Windows file security metadata cannot be preserved because cygpath is unavailable. No files were changed."
    windows_path_tool="cygpath"
    windows_pwsh_command="pwsh"
    ;;
  Linux)
    if [ -r /proc/sys/kernel/osrelease ] && grep -qi microsoft /proc/sys/kernel/osrelease; then
      command -v wslpath >/dev/null 2>&1 || die "Windows file security metadata cannot be preserved because wslpath is unavailable. No files were changed."
      case "$(wslpath -w "$repo_root")" in
        [A-Za-z]:\\*)
          windows_acl_mode=1
          command -v pwsh.exe >/dev/null 2>&1 || die "Windows file security metadata cannot be preserved because pwsh.exe is unavailable to WSL. No files were changed."
          windows_path_tool="wslpath"
          windows_pwsh_command="pwsh.exe"
          windows_interop_environment="${windows_interop_environment:+$windows_interop_environment:}CSHARP_TEMPLATE_METADATA_PATH:CSHARP_TEMPLATE_METADATA_HELPER:CSHARP_TEMPLATE_METADATA_ACTION:CSHARP_TEMPLATE_METADATA_B64"
          ;;
      esac
    fi
    ;;
esac
if [ "$windows_acl_mode" -eq 1 ]; then
  [ -f "$windows_metadata_helper" ] || die "Windows file security metadata helper is missing: scripts/init-windows-metadata.ps1. No files were changed."
  windows_metadata_helper_path="$("$windows_path_tool" -w "$windows_metadata_helper")" ||
    die "Windows file security metadata helper path cannot be resolved. No files were changed."
  windows_staging_parent="$({
    CSHARP_TEMPLATE_METADATA_HELPER="$windows_metadata_helper_path" \
      CSHARP_TEMPLATE_METADATA_ACTION='temp' \
      WSLENV="$windows_interop_environment" \
      MSYS2_ARG_CONV_EXCL='*' "$windows_pwsh_command" -NoLogo -NoProfile -NonInteractive \
        -EncodedCommand "$windows_pwsh_launcher"
  })" || die "Windows temporary path cannot be resolved. No files were changed."
  windows_staging_parent="$("$windows_path_tool" -u "$windows_staging_parent")" ||
    die "Windows temporary path cannot be converted. No files were changed."
  [ -d "$windows_staging_parent" ] || die "Windows temporary path is not a directory. No files were changed."
fi

declare -a windows_metadata_paths=()
declare -a windows_metadata_values=()

capture_windows_metadata() {
  local path="$1"
  local windows_path
  local metadata
  [ "$windows_acl_mode" -eq 1 ] || return 0
  windows_path="$("$windows_path_tool" -w "$path")" || return 1
  metadata="$({
    CSHARP_TEMPLATE_METADATA_PATH="$windows_path" \
      CSHARP_TEMPLATE_METADATA_HELPER="$windows_metadata_helper_path" \
      CSHARP_TEMPLATE_METADATA_ACTION='capture' \
      WSLENV="$windows_interop_environment" \
      MSYS2_ARG_CONV_EXCL='*' "$windows_pwsh_command" -NoLogo -NoProfile -NonInteractive \
        -EncodedCommand "$windows_pwsh_launcher"
  })" || return 1
  [ -n "$metadata" ] || return 1
  windows_metadata_value="$metadata"
}

register_windows_metadata() {
  local path="$1"
  local existing
  [ "$windows_acl_mode" -eq 1 ] || return 0
  for existing in "${windows_metadata_paths[@]-}"; do
    [ "$existing" != "$path" ] || return 0
  done
  capture_windows_metadata "$path" || die "Windows file security metadata cannot be read: ${path#"$repo_root/"}. No files were changed."
  windows_metadata_paths[${#windows_metadata_paths[@]}]="$path"
  windows_metadata_values[${#windows_metadata_values[@]}]="$windows_metadata_value"
}

lookup_windows_metadata() {
  local path="$1"
  local i
  [ "$windows_acl_mode" -eq 1 ] || return 0
  for ((i = 0; i < ${#windows_metadata_paths[@]}; i++)); do
    if [ "${windows_metadata_paths[$i]}" = "$path" ]; then
      windows_metadata_value="${windows_metadata_values[$i]}"
      return 0
    fi
  done
  return 1
}

apply_windows_metadata() {
  local path="$1"
  local metadata="$2"
  local windows_path
  [ "$windows_acl_mode" -eq 1 ] || return 0
  windows_path="$("$windows_path_tool" -w "$path")" || return 1
  CSHARP_TEMPLATE_METADATA_PATH="$windows_path" \
    CSHARP_TEMPLATE_METADATA_B64="$metadata" \
    CSHARP_TEMPLATE_METADATA_HELPER="$windows_metadata_helper_path" \
    CSHARP_TEMPLATE_METADATA_ACTION='apply' \
    WSLENV="$windows_interop_environment" \
    MSYS2_ARG_CONV_EXCL='*' "$windows_pwsh_command" -NoLogo -NoProfile -NonInteractive \
      -EncodedCommand "$windows_pwsh_launcher" >/dev/null
}

assert_no_link_components() {
  local relative="$1"
  local role="$2"
  local current="$repo_root"
  local component
  local -a components=()
  IFS='/' read -ra components <<< "$relative"
  for component in "${components[@]}"; do
    current="$current/$component"
    ! is_link_or_reparse "$current" || die "unsafe symbolic link or reparse point in $role path '$relative'. No files were changed."
  done
}

assert_changeable_parent() {
  local path="$1"
  local relative="$2"
  local role="$3"
  local parent
  parent="$(dirname "$path")"
  while ! path_exists "$parent"; do
    [ "$parent" != "$repo_root" ] || break
    parent="$(dirname "$parent")"
  done
  [ -d "$parent" ] || die "$role parent is not a directory: $relative. No files were changed."
  [ -w "$parent" ] || die "$role parent is not writable: $relative. No files were changed."
  [ -x "$parent" ] || die "$role parent is not traversable: $relative. No files were changed."
}

assert_no_link_components "scripts/init-plan.tsv" "plan"

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

  assert_no_link_components "$source_relative" "source"
  if [ -n "$destination_relative" ]; then
    assert_no_link_components "$destination_relative" "destination"
  fi

  case "$kind" in
    content)
      path_exists "$source" || die "required template content source is missing: $source_relative. No files were changed."
      [ -f "$source" ] || die "template content path is not a file: $source_relative. No files were changed."
      case "$source" in
        *.csproj|*.props|*.targets|*.slnx|*.config) mode=xml ;;
        *) mode=raw ;;
      esac
      content="$(cat "$source"; printf x)"; content="${content%x}"
      transformed="$(replace_tokens "$content" "$mode"; printf x)"; transformed="${transformed%x}"
      if [ "$transformed" != "$content" ]; then
        [ -w "$source" ] || die "template content path is not writable: $source_relative. No files were changed."
        assert_changeable_parent "$source" "$source_relative" "template content replacement"
        register_windows_metadata "$source"
        content_paths[${#content_paths[@]}]="$source"
        content_values[${#content_values[@]}]="$transformed"
      fi
      ;;
    directory)
      path_exists "$source" || die "required template directory source is missing: $source_relative. No files were changed."
      [ -d "$source" ] || die "template directory path is not a directory: $source_relative. No files were changed."
      [ "$source" != "$destination" ] || continue
      ! path_exists "$destination" || die "initialization target collision: $destination_relative already exists. No files were changed."
      assert_changeable_parent "$destination" "$destination_relative" "initialization target"
      register_target "$destination"
      directory_sources[${#directory_sources[@]}]="$source"
      directory_targets[${#directory_targets[@]}]="$destination"
      ;;
    move|activate)
      path_exists "$source" || die "required template $kind source is missing: $source_relative. No files were changed."
      [ -f "$source" ] || die "template move source is not a file: $source_relative. No files were changed."
      [ "$source" != "$destination" ] || continue
      ! path_exists "$destination" || die "initialization target collision: $destination_relative already exists. No files were changed."
      parent="$(dirname "$destination")"
      if path_exists "$parent" && [ ! -d "$parent" ]; then
        die "initialization target parent is not a directory: $destination_relative. No files were changed."
      fi
      assert_changeable_parent "$destination" "$destination_relative" "initialization target"
      assert_changeable_parent "$source" "$source_relative" "template move source"
      register_target "$destination"
      move_sources[${#move_sources[@]}]="$source"
      move_targets[${#move_targets[@]}]="$destination"
      ;;
    remove)
      path_exists "$source" || die "required template removal source is missing: $source_relative. No files were changed."
      if [ ! -f "$source" ]; then
        die "template-only removal path is not a file: $source_relative. No files were changed."
      fi
      [ -w "$source" ] || die "template-only removal path is not writable: $source_relative. No files were changed."
      assert_changeable_parent "$source" "$source_relative" "template-only removal"
      register_windows_metadata "$source"
      remove_paths[${#remove_paths[@]}]="$source"
      ;;
  esac
done

if [ "$keep_script" -ne 1 ]; then
  for path in "$sibling_ps1" "$self"; do
    if [ -f "$path" ]; then
      register_windows_metadata "$path"
    fi
  done
fi

echo "==> Initializing template as '$project_name'"
echo "    Preflight validated ${#plan_kinds[@]} template-owned operation(s)."

staging_parent="${TMPDIR:-/tmp}"
if [ "$windows_acl_mode" -eq 1 ]; then
  staging_parent="$windows_staging_parent"
fi
staging_dir="$(mktemp -d "$staging_parent/csharp-template-init.XXXXXXXX")"
declare -a backup_originals=()
declare -a backup_copies=()
declare -a mutated_backup_originals=()
declare -a mutated_backup_copies=()
declare -a completed_move_sources=()
declare -a completed_move_targets=()
declare -a created_directories=()
declare -a removed_directories=()

rollback_transaction() {
  local exit_code=$?
  local rollback_failed=0
  local original backup existing
  trap - ERR INT TERM
  set +e

  for existing in "${removed_directories[@]-}"; do
    mkdir -p -- "$existing" || rollback_failed=1
  done
  for ((i = ${#completed_move_sources[@]} - 1; i >= 0; i--)); do
    if path_exists "${completed_move_targets[$i]}" && ! path_exists "${completed_move_sources[$i]}"; then
      mv -- "${completed_move_targets[$i]}" "${completed_move_sources[$i]}" || rollback_failed=1
    fi
  done
  for ((i = 0; i < ${#mutated_backup_originals[@]}; i++)); do
    original="${mutated_backup_originals[$i]}"
    backup="${mutated_backup_copies[$i]}"
    restore_file "$backup" "$original" || rollback_failed=1
  done
  for ((i = ${#created_directories[@]} - 1; i >= 0; i--)); do
    rmdir -- "${created_directories[$i]}" 2>/dev/null || true
  done
  rm -rf -- "$staging_dir" || rollback_failed=1

  if [ "$rollback_failed" -ne 0 ]; then
    echo "error: initialization failed and rollback was incomplete." >&2
  else
    echo "error: initialization failed; all changes were rolled back." >&2
  fi
  [ "$exit_code" -ne 0 ] || exit_code=1
  exit "$exit_code"
}

trap rollback_transaction ERR INT TERM

if [ "$windows_acl_mode" -eq 1 ]; then
  staged_windows_metadata_helper="$staging_dir/init-windows-metadata.ps1"
  cp -- "$windows_metadata_helper" "$staged_windows_metadata_helper"
  windows_metadata_helper_path="$("$windows_path_tool" -w "$staged_windows_metadata_helper")"
fi

backup_file() {
  local original="$1"
  local existing
  local backup
  for existing in "${backup_originals[@]-}"; do
    [ "$existing" != "$original" ] || return 0
  done
  backup="$staging_dir/${#backup_originals[@]}.bak"
  cp -p -- "$original" "$backup"
  backup_originals[${#backup_originals[@]}]="$original"
  backup_copies[${#backup_copies[@]}]="$backup"
}

journal_backup() {
  local original="$1"
  local existing
  local i
  for existing in "${mutated_backup_originals[@]-}"; do
    [ "$existing" != "$original" ] || return 0
  done
  for ((i = 0; i < ${#backup_originals[@]}; i++)); do
    if [ "${backup_originals[$i]}" = "$original" ]; then
      mutated_backup_originals[${#mutated_backup_originals[@]}]="$original"
      mutated_backup_copies[${#mutated_backup_copies[@]}]="${backup_copies[$i]}"
      return 0
    fi
  done
  return 1
}

replace_file_content() {
  local original="$1"
  local content="$2"
  local temporary
  temporary="$(mktemp "$(dirname "$original")/.csharp-template-init.XXXXXXXX")"
  if ! cp -p -- "$original" "$temporary" ||
    ! printf '%s' "$content" > "$temporary" ||
    ! touch -r "$original" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  # Replacing the directory entry prevents a hard-linked peer outside the repository from being truncated.
  if ! mv -f -- "$temporary" "$original"; then
    rm -f -- "$temporary"
    return 1
  fi
  journal_backup "$original"
  if [ "$windows_acl_mode" -eq 1 ]; then
    lookup_windows_metadata "$original" || return 1
    apply_windows_metadata "$original" "$windows_metadata_value" || return 1
  fi
}

restore_file() {
  local backup="$1"
  local original="$2"
  local temporary
  temporary="$(mktemp "$(dirname "$original")/.csharp-template-init.XXXXXXXX")"
  if ! cp -p -- "$backup" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  # Rollback uses the same replacement rule and never writes through an existing hard link.
  if ! mv -f -- "$temporary" "$original"; then
    rm -f -- "$temporary"
    return 1
  fi
  if [ "$windows_acl_mode" -eq 1 ]; then
    lookup_windows_metadata "$original" || return 1
    apply_windows_metadata "$original" "$windows_metadata_value" || return 1
  fi
}

for path in "${content_paths[@]-}" "${remove_paths[@]-}"; do
  if [ -n "$path" ] && [ -f "$path" ]; then
    backup_file "$path"
  fi
done
if [ "$keep_script" -ne 1 ]; then
  for path in "$sibling_ps1" "$self"; do
    if [ -f "$path" ]; then
      backup_file "$path"
    fi
  done
fi

for ((i = 0; i < ${#content_paths[@]}; i++)); do
  relative="${content_paths[$i]#"$repo_root/"}"
  assert_no_link_components "$relative" "content source"
  replace_file_content "${content_paths[$i]}" "${content_values[$i]}"
done
echo "    Updated contents in ${#content_paths[@]} file(s)."

# Destination directories are created empty; only listed files move into them.
# Unknown files inside token-named source directories stay at their original paths.
for ((i = 0; i < ${#directory_sources[@]}; i++)); do
  assert_no_link_components "${directory_sources[$i]#"$repo_root/"}" "directory source"
  assert_no_link_components "${directory_targets[$i]#"$repo_root/"}" "directory destination"
  mkdir -- "${directory_targets[$i]}"
  created_directories[${#created_directories[@]}]="${directory_targets[$i]}"
done
for ((i = 0; i < ${#move_sources[@]}; i++)); do
  assert_no_link_components "${move_sources[$i]#"$repo_root/"}" "move source"
  assert_no_link_components "${move_targets[$i]#"$repo_root/"}" "move destination"
  mv -- "${move_sources[$i]}" "${move_targets[$i]}"
  completed_move_sources[${#completed_move_sources[@]}]="${move_sources[$i]}"
  completed_move_targets[${#completed_move_targets[@]}]="${move_targets[$i]}"
  echo "    Moved ${move_sources[$i]#"$repo_root/"} -> ${move_targets[$i]#"$repo_root/"}"
done
for path in "${remove_paths[@]}"; do
  if [ -f "$path" ]; then
    assert_no_link_components "${path#"$repo_root/"}" "removal source"
    rm -f -- "$path"
    journal_backup "$path"
    echo "    Removed ${path#"$repo_root/"}"
  fi
done

for ((i = ${#directory_sources[@]} - 1; i >= 0; i--)); do
  assert_no_link_components "${directory_sources[$i]#"$repo_root/"}" "directory cleanup source"
  if rmdir -- "${directory_sources[$i]}" 2>/dev/null; then
    removed_directories[${#removed_directories[@]}]="${directory_sources[$i]}"
  fi
done
for path in "$repo_root/docs" "$repo_root/scripts/tests"; do
  assert_no_link_components "${path#"$repo_root/"}" "directory cleanup source"
  if rmdir -- "$path" 2>/dev/null; then
    removed_directories[${#removed_directories[@]}]="$path"
  fi
done

if [ "$keep_script" -ne 1 ]; then
  if [ -f "$sibling_ps1" ]; then
    rm -f -- "$sibling_ps1"
    journal_backup "$sibling_ps1"
  fi
  if [ -f "$self" ]; then
    rm -f -- "$self"
    journal_backup "$self"
  fi
fi

trap - ERR INT TERM
rm -rf -- "$staging_dir"

echo ""
echo "Done. Next steps:"
echo "  1. dotnet build $project_name.slnx"
echo "  2. dotnet test  $project_name.slnx"
echo "  3. Review LICENSE (author/year) and the .csproj package metadata."
echo "  4. NuGet publishing: add the NUGET_API_KEY repo secret, or delete"
echo "     .github/workflows/release.yml and the packaging properties in the .csproj."
echo "  5. Commit the initialized project."
