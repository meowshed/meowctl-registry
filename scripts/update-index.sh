#!/usr/bin/env bash
# update-index.sh — auto-update meowctl-registry/index.toml with new releases.
#
# For every module entry that has a `repo = "owner/repo"` field, the script:
#   1. Fetches all GitHub releases for that repo (using the GH CLI).
#   2. Compares available versions against what is already in index.toml.
#   3. For each new version, downloads the tarball (substituting {name}/{version}
#      into the module's source template), computes the sha384 SRI hash, appends
#      the version to the versions list, and adds the SRI to the per-version
#      [modules.<name>.integrity] subtable.
#
# The script modifies index.toml in-place. Callers (the workflow) are responsible
# for committing and pushing any changes.
#
# Requirements: bash, curl, openssl, gh (GitHub CLI).
# GITHUB_TOKEN is used by the gh CLI automatically when set in CI.
#
# Usage:
#   update-index.sh [path/to/index.toml]
#   Defaults to index.toml in the current directory.

set -euo pipefail

INDEX="${1:-index.toml}"

if [ ! -f "$INDEX" ]; then
    echo "error: index file not found: $INDEX" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()    { echo "  → $*"; }
success() { echo "  ✓ $*"; }
skip()    { echo "  - $*"; }

# sri <file>  — outputs sha384 SRI string for a file
sri() {
    local hash
    hash=$(openssl dgst -sha384 -binary "$1" | openssl base64 -A)
    echo "sha384-${hash}"
}

# gh_releases <owner/repo>  — lists all release tag names, newest first
gh_releases() {
    gh api "repos/${1}/releases" --paginate --jq '.[].tag_name'
}

# strip_v <tag>  — strips leading 'v': "v0.1.1" → "0.1.1"
strip_v() { echo "${1#v}"; }

# version_in_list <version> <space-separated-list>
version_in_list() {
    local ver="$1" v
    for v in $2; do [ "$v" = "$ver" ] && return 0; done
    return 1
}

# build_source_url <template> <name> <version>
build_source_url() {
    local tmpl="${1//\{name\}/$2}"
    local ver_no_v="${3#v}"
    tmpl="${tmpl//\{version\}/$3}"
    echo "${tmpl//\{version_no_v\}/$ver_no_v}"
}

# ---------------------------------------------------------------------------
# Parse index.toml
# ---------------------------------------------------------------------------
declare -a MOD_NAMES=()
declare -A MOD_REPO MOD_VERSIONS MOD_SOURCE MOD_INTEGRITY_VERSIONS

cur=""
in_integrity=0
while IFS= read -r line; do
    if [[ "$line" =~ ^\[modules\.([^].]+)\]$ ]]; then
        cur="${BASH_REMATCH[1]}"
        in_integrity=0
        MOD_NAMES+=("$cur")
        MOD_REPO["$cur"]=""
        MOD_VERSIONS["$cur"]=""
        MOD_SOURCE["$cur"]=""
        MOD_INTEGRITY_VERSIONS["$cur"]=""   # space-sep list of versions that already have integrity
        continue
    fi
    if [[ "$line" =~ ^\[modules\.([^].]+)\.integrity\]$ ]]; then
        cur="${BASH_REMATCH[1]}"
        in_integrity=1
        continue
    fi
    if [[ "$line" =~ ^\[ ]]; then
        in_integrity=0
        cur=""
        continue
    fi
    [ -z "$cur" ] && continue

    if [ "$in_integrity" -eq 1 ]; then
        if [[ "$line" =~ ^\"([^\"]+)\" ]]; then
            MOD_INTEGRITY_VERSIONS["$cur"]+=" ${BASH_REMATCH[1]}"
        fi
    else
        if [[ "$line" =~ ^repo[[:space:]]*=[[:space:]]*\"(.+)\" ]]; then
            MOD_REPO["$cur"]="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ ^versions[[:space:]]*= ]]; then
            MOD_VERSIONS["$cur"]=$(echo "$line" | grep -oE '"[^"]+"' | tr -d '"' | tr '\n' ' ' | xargs)
        fi
        if [[ "$line" =~ ^source[[:space:]]*=[[:space:]]*\"(.+)\" ]]; then
            MOD_SOURCE["$cur"]="${BASH_REMATCH[1]}"
        fi
    fi
done < "$INDEX"

# ---------------------------------------------------------------------------
# Process each module
# ---------------------------------------------------------------------------
UPDATED_MODULES=()
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

for MOD in "${MOD_NAMES[@]}"; do
    REPO="${MOD_REPO[$MOD]:-}"
    if [ -z "$REPO" ]; then
        skip "$MOD: no repo field, skipping"
        continue
    fi

    echo ""
    echo "[$MOD] checking $REPO ..."

    all_tags=$(gh_releases "$REPO" 2>/dev/null) || {
        echo "  warning: failed to fetch releases for $REPO, skipping" >&2
        continue
    }

    new_versions=()
    new_tags=()
    while IFS= read -r tag; do
        ver=$(strip_v "$tag")
        if ! version_in_list "$ver" "${MOD_VERSIONS[$MOD]}"; then
            new_versions+=("$ver")
            new_tags+=("$tag")
        fi
    done <<< "$all_tags"

    if [ ${#new_versions[@]} -eq 0 ]; then
        skip "$MOD: up to date"
        continue
    fi

    # Build associative array: stripped_ver → tag
    declare -A ver_to_tag=()
    for i in "${!new_versions[@]}"; do
        ver_to_tag["${new_versions[$i]}"]="${new_tags[$i]}"
    done

    sorted_new=$(printf '%s\n' "${new_versions[@]}" | sort -V)

    # Collect new version → SRI pairs to write.
    declare -A new_integ=()
    added_versions=()

    while IFS= read -r ver; do
        tag="${ver_to_tag[$ver]}"
        url=$(build_source_url "${MOD_SOURCE[$MOD]}" "$MOD" "$tag")
        info "downloading $MOD@$ver ..."
        if ! curl -fsSL --max-time 60 -o "$tmpfile" "$url"; then
            echo "  warning: failed to download $url, skipping $ver" >&2
            continue
        fi
        integ=$(sri "$tmpfile")
        info "$MOD@$ver → $integ"
        new_integ["$ver"]="$integ"
        MOD_VERSIONS["$MOD"]+=" $ver"
        MOD_VERSIONS["$MOD"]=$(echo "${MOD_VERSIONS[$MOD]}" | xargs)
        added_versions+=("$ver")
    done <<< "$sorted_new"

    if [ ${#added_versions[@]} -eq 0 ]; then
        skip "$MOD: all new versions failed to download"
        unset new_integ
        declare -A new_integ=()
        continue
    fi

    # Patch index.toml via python3.
    # Build args: list of "version=sri" pairs.
    integ_args=()
    for v in "${added_versions[@]}"; do
        integ_args+=("${v}=${new_integ[$v]}")
    done

    python3 - "$INDEX" "$MOD" "${MOD_VERSIONS[$MOD]}" "${integ_args[@]}" <<'PYEOF'
import sys, re

index_file  = sys.argv[1]
mod_name    = sys.argv[2]
new_versions_str = sys.argv[3]          # space-separated full version list
integ_pairs = sys.argv[4:]              # "ver=sri" strings for new versions only

# Sort versions by tuple of numeric parts (simple semver sort without packaging)
def sort_key(v):
    parts = v.split('.')
    return tuple(int(p) for p in parts if p.isdigit())

versions = sorted(new_versions_str.split(), key=sort_key)
new_integ = dict(p.split('=', 1) for p in integ_pairs)

with open(index_file, 'r') as f:
    lines = f.readlines()

# Find and patch the module section
in_module = False
in_integrity = False
module_start = -1
integrity_start = -1
integrity_end = -1
versions_line_idx = -1

for i, line in enumerate(lines):
    if re.match(rf'^\[modules\.{re.escape(mod_name)}\]$', line.strip()):
        in_module = True
        in_integrity = False
        module_start = i
        continue
    if re.match(rf'^\[modules\.{re.escape(mod_name)}\.integrity\]$', line.strip()):
        in_integrity = True
        in_module = False
        integrity_start = i
        continue
    if line.startswith('[') and (in_module or in_integrity):
        if in_integrity:
            integrity_end = i
        in_module = False
        in_integrity = False
        continue
    if in_module and line.strip().startswith('versions'):
        versions_line_idx = i
    if in_module and line.strip().startswith('source'):
        in_module = False  # end of module header

# Build new versions line
new_versions_line = 'versions = [' + ', '.join(f'"{v}"' for v in versions) + ']\n'

# Replace versions line
if versions_line_idx >= 0:
    lines[versions_line_idx] = new_versions_line

# Patch integrity: replace from integrity_start to integrity_end (or end of file)
if integrity_start >= 0:
    end = integrity_end if integrity_end >= 0 else len(lines)
    # Build new integrity section
    new_integrity_lines = [f'[modules.{mod_name}.integrity]\n']
    # Keep existing entries that are NOT in new_integ
    for i in range(integrity_start + 1, end):
        m = re.match(r'^"([^"]+)"', lines[i])
        if m and m.group(1) not in new_integ:
            new_integrity_lines.append(lines[i])
    # Append new entries
    for v, sri in new_integ.items():
        new_integrity_lines.append(f'"{v}" = "{sri}"\n')
    # Ensure blank line separator after integrity section
    if not new_integrity_lines[-1].endswith('\n\n'):
        new_integrity_lines.append('\n')
    lines[integrity_start:end] = new_integrity_lines
else:
    # No integrity section exists — append at end
    new_block = f'\n[modules.{mod_name}.integrity]\n'
    for v, sri in new_integ.items():
        new_block += f'"{v}" = "{sri}"\n'
    lines.append(new_block)

with open(index_file, 'w') as f:
    f.writelines(lines)

print(f"  patched [modules.{mod_name}] — added versions: {list(new_integ.keys())}")
PYEOF

    success "$MOD: added ${added_versions[*]}"
    UPDATED_MODULES+=("$MOD")
    unset new_integ
    declare -A new_integ=()
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [ ${#UPDATED_MODULES[@]} -eq 0 ]; then
    echo "=== No updates — index.toml unchanged ==="
    exit 0
fi

echo "=== Updated modules: ${UPDATED_MODULES[*]} ==="
exit 0
