#!/usr/bin/env bash
# validate-index.sh — meowctl-registry PR validation script.
#
# Checks:
#   1. index.toml has a valid compat field.
#   2. Every module entry has versions and source fields.
#   3. Every version listed in versions has a corresponding integrity entry
#      in the [modules.<name>.integrity] subtable.
#   4. No existing (module, version) has been removed compared to base branch.
#   5. Every tarball URL resolves (HTTP HEAD, 200 OK).
#
# Usage:
#   validate-index.sh <head-index.toml> [base-index.toml]
#
# base-index.toml is optional. When absent, the no-overwrite check is skipped.

set -euo pipefail

HEAD_INDEX="${1:?usage: validate-index.sh <head-index.toml> [base-index.toml]}"
BASE_INDEX="${2:-}"

FAIL=0

pass() { echo "    OK: $*"; }
fail() { echo "    FAIL: $*" >&2; FAIL=1; }

# ---------------------------------------------------------------------------
# parse_index <file>
#   Reads an index.toml and populates:
#     MOD_VERSIONS["name"]          — space-separated version list
#     MOD_SOURCE["name"]            — source URL template
#     MOD_INTEGRITY["name@version"] — integrity hash for each version
#   Uses associative arrays; caller must declare them before calling.
# ---------------------------------------------------------------------------
parse_index() {
    local file="$1"
    local cur=""
    local in_integrity=0
    while IFS= read -r line; do
        # Top-level module section: [modules.name]
        if [[ "$line" =~ ^\[modules\.([^].]+)\]$ ]]; then
            cur="${BASH_REMATCH[1]}"
            in_integrity=0
            continue
        fi
        # Integrity subtable section: [modules.name.integrity]
        if [[ "$line" =~ ^\[modules\.([^].]+)\.integrity\]$ ]]; then
            cur="${BASH_REMATCH[1]}"
            in_integrity=1
            continue
        fi
        # Any other section header — stop tracking.
        if [[ "$line" =~ ^\[ ]]; then
            cur=""
            in_integrity=0
            continue
        fi
        [ -z "$cur" ] && continue

        if [ "$in_integrity" -eq 1 ]; then
            # Lines like: "0.1.1" = "sha384-..."
            if [[ "$line" =~ ^\"([^\"]+)\"[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
                MOD_INTEGRITY["${cur}@${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
            fi
        else
            if [[ "$line" =~ ^versions[[:space:]]*= ]]; then
                MOD_VERSIONS["$cur"]=$(echo "$line" | grep -oE '"[^"]+"' | tr -d '"' | tr '\n' ' ' | xargs)
            fi
            if [[ "$line" =~ ^source[[:space:]]*=[[:space:]]*\"(.+)\" ]]; then
                MOD_SOURCE["$cur"]="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$file"
}

# ---------------------------------------------------------------------------
# 1. compat field
# ---------------------------------------------------------------------------
echo ""
echo "[1] compat field ..."
if grep -qE '^compat[[:space:]]*=[[:space:]]*[0-9]+' "$HEAD_INDEX"; then
    COMPAT=$(grep -E '^compat[[:space:]]*=' "$HEAD_INDEX" | head -1 | sed 's/.*=[[:space:]]*//' | tr -d '[:space:]')
    pass "compat = $COMPAT"
else
    fail "missing 'compat' field at root of index.toml"
fi

# ---------------------------------------------------------------------------
# 2. Module entries — required fields + per-version integrity
# ---------------------------------------------------------------------------
echo ""
echo "[2] Module entry required fields and per-version integrity ..."
declare -A MOD_VERSIONS MOD_SOURCE MOD_INTEGRITY
parse_index "$HEAD_INDEX"

MODULES=$(grep -oE '^\[modules\.[^].]+\]$' "$HEAD_INDEX" | sed 's/\[modules\.\(.*\)\]/\1/')
if [ -z "$MODULES" ]; then
    pass "no modules defined (empty registry)"
else
    for MOD in $MODULES; do
        if [ -z "${MOD_VERSIONS[$MOD]:-}" ]; then
            fail "module '$MOD': missing 'versions' field"
            continue
        fi
        if [ -z "${MOD_SOURCE[$MOD]:-}" ]; then
            fail "module '$MOD': missing 'source' field"
        fi
        # Check each listed version has an integrity entry.
        for VER in ${MOD_VERSIONS[$MOD]}; do
            if [ -z "${MOD_INTEGRITY["${MOD}@${VER}"]:-}" ]; then
                fail "module '$MOD': missing integrity entry for version $VER in [modules.$MOD.integrity]"
            fi
        done
    done
    [ "$FAIL" -eq 0 ] && pass "all module entries have required fields and per-version integrity"
fi

# ---------------------------------------------------------------------------
# 3. No-overwrite check
# ---------------------------------------------------------------------------
echo ""
echo "[3] No-overwrite check ..."
if [ -z "$BASE_INDEX" ] || [ ! -f "$BASE_INDEX" ] || [ ! -s "$BASE_INDEX" ]; then
    echo "    SKIP: no base index provided (new registry or first commit)"
else
    declare -A BASE_MOD_VERSIONS BASE_MOD_SOURCE BASE_MOD_INTEGRITY
    MOD_VERSIONS=() MOD_SOURCE=() MOD_INTEGRITY=()
    # Parse base into temp arrays.
    (
        declare -A MOD_VERSIONS MOD_SOURCE MOD_INTEGRITY
        parse_index "$BASE_INDEX"
        for MOD in "${!MOD_VERSIONS[@]}"; do
            for VER in ${MOD_VERSIONS[$MOD]:-}; do
                echo "${MOD}@${VER}"
            done
        done
    ) | sort > /tmp/_base_pairs.txt

    MOD_VERSIONS=() MOD_SOURCE=() MOD_INTEGRITY=()
    parse_index "$HEAD_INDEX"
    (
        for MOD in "${!MOD_VERSIONS[@]}"; do
            for VER in ${MOD_VERSIONS[$MOD]:-}; do
                echo "${MOD}@${VER}"
            done
        done
    ) | sort > /tmp/_head_pairs.txt

    REMOVED=$(comm -23 /tmp/_base_pairs.txt /tmp/_head_pairs.txt || true)
    rm -f /tmp/_base_pairs.txt /tmp/_head_pairs.txt

    if [ -n "$REMOVED" ]; then
        fail "versions removed from index (published versions are immutable): $REMOVED"
    else
        pass "no published versions removed"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Tarball URL reachability
# ---------------------------------------------------------------------------
echo ""
echo "[4] Tarball URL reachability ..."
URL_COUNT=0
for MOD in "${!MOD_SOURCE[@]}"; do
    SOURCE="${MOD_SOURCE[$MOD]}"
    for VER in ${MOD_VERSIONS[$MOD]:-}; do
        URL="${SOURCE//\{name\}/$MOD}"
        URL="${URL//\{version\}/$VER}"
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --head --max-time 15 "$URL" || echo "000")
        if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "302" ] || [ "$HTTP_STATUS" = "301" ]; then
            pass "$MOD@$VER → $HTTP_STATUS"
        else
            fail "$MOD@$VER: HEAD $URL → HTTP $HTTP_STATUS"
        fi
        URL_COUNT=$((URL_COUNT + 1))
    done
done

if [ "$URL_COUNT" -eq 0 ]; then
    echo "    SKIP: no module versions to check"
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -eq 1 ]; then
    echo "=== Result: FAIL ==="
    exit 1
else
    echo "=== Result: PASS ==="
fi
