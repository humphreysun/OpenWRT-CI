#!/usr/bin/env bash
set -euo pipefail

# ZN-HomeProxy v2
#
# Design:
#   - szwjp is the primary HomeProxy upstream.
#   - htcnokia/luci-app-homeproxy is a fallback mirror/fork if the primary
#     repository is unavailable or disappears.
#   - ZN does NOT impose a sing-box upper version limit.
#   - sing-box syntax compatibility remains the responsibility of the
#     upstream HomeProxy generator.
#   - ZN only bundles SRS data and minimally localizes the three built-in
#     mainland-China rule-sets.
#   - Custom Routing and all other upstream generator logic are preserved.
#
# Optional environment variables:
#   ZN_HOMEProxy_PRIMARY_REPO
#   ZN_HOMEProxy_FALLBACK_REPO
#   ZN_HOMEProxy_BRANCH
#   ZN_HOMEProxy_AUTO_FETCH=0|1   (default: 1)
#   ZN_SKIP_SRS=1
#
# The script is intended to run after package/feed preparation, but can
# bootstrap HomeProxy itself if neither the primary nor fallback source is
# already present in the build tree.

ROOT="${1:-${GITHUB_WORKSPACE:-.}}"
ROOT="$(cd "$ROOT" && pwd)"

HP_SRS_REL="/etc/homeproxy/private_srs"

PRIMARY_REPO="${ZN_HOMEProxy_PRIMARY_REPO:-https://github.com/szwjp/luci-app-homeproxy.git}"
FALLBACK_REPO="${ZN_HOMEProxy_FALLBACK_REPO:-https://github.com/htcnokia/luci-app-homeproxy.git}"
HP_BRANCH="${ZN_HOMEProxy_BRANCH:-main}"
AUTO_FETCH="${ZN_HOMEProxy_AUTO_FETCH:-1}"

log()  { printf '[ZN-HomeProxy] %s\n' "$*"; }
warn() { printf '[ZN-HomeProxy][WARN] %s\n' "$*" >&2; }
die()  { printf '[ZN-HomeProxy][ERROR] %s\n' "$*" >&2; exit 1; }

is_homeproxy_lineage() {
    local p="$1"
    [ -f "$p/root/etc/homeproxy/scripts/generate_client.uc" ] &&
    [ -f "$p/root/etc/homeproxy/scripts/update_resources.sh" ] &&
    [ -f "$p/root/etc/homeproxy/scripts/update_crond.sh" ] &&
    [ -f "$p/root/etc/init.d/homeproxy" ] &&
    [ -f "$p/Makefile" ]
}

repo_origin_matches() {
    local p="$1" origin="$2"
    local remote=""
    if [ -d "$p/.git" ] && command -v git >/dev/null 2>&1; then
        remote="$(git -C "$p" remote get-url origin 2>/dev/null || true)"
        case "$remote" in
            "$origin"|"$origin/"*) return 0 ;;
            "https://github.com/"* )
                # Compare normalized GitHub owner/repo when possible.
                local a b
                a="${remote%.git}"
                b="${origin%.git}"
                [ "${a,,}" = "${b,,}" ] && return 0
                ;;
        esac
    fi
    return 1
}

find_existing_homeproxy() {
    local p
    local candidates=(
        "$ROOT/package/luci-app-homeproxy"
        "$ROOT/package/homeproxy"
        "$ROOT/feeds/luci/luci-app-homeproxy"
        "$ROOT/feeds/luci/homeproxy"
        "$ROOT/feeds/packages/luci-app-homeproxy"
    )

    # First prefer a known primary/fallback git origin.
    for p in "${candidates[@]}"; do
        if is_homeproxy_lineage "$p" && repo_origin_matches "$p" "$PRIMARY_REPO"; then
            printf '%s\n' "$p"
            return 0
        fi
    done
    for p in "${candidates[@]}"; do
        if is_homeproxy_lineage "$p" && repo_origin_matches "$p" "$FALLBACK_REPO"; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    # Then accept a package that has the expected HomeProxy runtime structure.
    # This keeps local/non-git build trees usable.
    for p in "${candidates[@]}"; do
        if is_homeproxy_lineage "$p"; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    mapfile -t found < <(
        find "$ROOT" -type f \
            -path '*/root/etc/homeproxy/scripts/generate_client.uc' 2>/dev/null |
        sed 's#/root/etc/homeproxy/scripts/generate_client.uc$##' |
        while IFS= read -r p; do
            is_homeproxy_lineage "$p" && printf '%s\n' "$p"
        done | sort -u
    )

    if [ "${#found[@]}" -eq 1 ]; then
        printf '%s\n' "${found[0]}"
        return 0
    fi

    if [ "${#found[@]}" -gt 1 ]; then
        # Prefer recognized origins among discovered paths.
        local p
        for p in "${found[@]}"; do
            if repo_origin_matches "$p" "$PRIMARY_REPO"; then
                printf '%s\n' "$p"
                return 0
            fi
        done
        for p in "${found[@]}"; do
            if repo_origin_matches "$p" "$FALLBACK_REPO"; then
                printf '%s\n' "$p"
                return 0
            fi
        done

        echo "[ERROR] Multiple HomeProxy packages found; refusing to guess:" >&2
        printf '  %s\n' "${found[@]}" >&2
        return 2
    fi

    return 1
}

fetch_homeproxy() {
    [ "$AUTO_FETCH" = "1" ] || return 1
    command -v git >/dev/null 2>&1 || {
        warn "git is unavailable; cannot bootstrap HomeProxy source."
        return 1
    }

    local target="$ROOT/package/luci-app-homeproxy"
    local tmp="$ROOT/.zn-homeproxy-bootstrap"

    rm -rf "$tmp"

    log "HomeProxy package not found in build tree."
    log "Trying primary upstream: $PRIMARY_REPO"

    if git clone --depth 1 --branch "$HP_BRANCH" "$PRIMARY_REPO" "$tmp" >/dev/null 2>&1; then
        rm -rf "$target"
        mkdir -p "$(dirname "$target")"
        mv "$tmp" "$target"
        log "Using primary HomeProxy source: $PRIMARY_REPO"
        printf '%s\n' "$target"
        return 0
    fi

    warn "Primary HomeProxy source unavailable."
    log "Trying fallback fork: $FALLBACK_REPO"

    rm -rf "$tmp"
    if git clone --depth 1 --branch "$HP_BRANCH" "$FALLBACK_REPO" "$tmp" >/dev/null 2>&1; then
        rm -rf "$target"
        mkdir -p "$(dirname "$target")"
        mv "$tmp" "$target"
        log "Using fallback HomeProxy source: $FALLBACK_REPO"
        printf '%s\n' "$target"
        return 0
    fi

    rm -rf "$tmp"
    warn "Both HomeProxy sources are unavailable."
    return 1
}

HP_PATH="$(find_existing_homeproxy 2>/dev/null)" || {
    rc=$?
    if [ "$rc" -eq 2 ]; then
        exit 1
    fi
    HP_PATH="$(fetch_homeproxy)" || {
        die "HomeProxy package not found and neither upstream nor fallback could be fetched."
    }
}

is_homeproxy_lineage "$HP_PATH" || die "Selected path is not a complete HomeProxy package: $HP_PATH"

HP_ROOT="$HP_PATH/root/etc/homeproxy"
GEN_FILE="$HP_ROOT/scripts/generate_client.uc"
UPDATE_RESOURCES="$HP_ROOT/scripts/update_resources.sh"
UPDATE_CROND="$HP_ROOT/scripts/update_crond.sh"
INIT_FILE="$HP_PATH/root/etc/init.d/homeproxy"
MAKEFILE="$HP_PATH/Makefile"

log "Selected HomeProxy package: $HP_PATH"

for f in "$GEN_FILE" "$UPDATE_RESOURCES" "$UPDATE_CROND" "$INIT_FILE" "$MAKEFILE"; do
    [ -f "$f" ] || die "Required file missing: $f"
done

# ------------------------------------------------------------------
# 1. Upstream sanity checks.
#
# No sing-box upper/lower version is imposed here. The generator shipped
# by the selected HomeProxy source is the authority for sing-box syntax.
# ------------------------------------------------------------------
grep -q 'bypass_mainland_china' "$GEN_FILE" || \
    die "The selected generator has no bypass_mainland_china routing mode."

grep -q 'update_resources\.sh' "$UPDATE_CROND" || \
    die "update_crond.sh no longer calls update_resources.sh; refusing to alter the upstream workflow."

# ------------------------------------------------------------------
# 2. Bundle the SRS data.
# ------------------------------------------------------------------
HP_SRS="$HP_PATH/root$HP_SRS_REL"
mkdir -p "$HP_SRS"

declare -A SRS_URLS=(
    ["cn.srs"]="https://fastly.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs"
    ["geosite-geolocation-cn.srs"]="https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs"
    ["geosite-geolocation-!cn.srs"]="https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-!cn.srs"
    ["geosite-google.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs"
    ["geosite-openai.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"
    ["geosite-anthropic.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-anthropic.srs"
    ["geosite-whatsapp.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-whatsapp.srs"
    ["geosite-zoom.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-zoom.srs"
)

download_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 \
            -o "$out.tmp" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=20 --tries=3 -O "$out.tmp" "$url"
    else
        echo "[ERROR] Neither curl nor wget is available on the build host." >&2
        return 1
    fi
    [ -s "$out.tmp" ] || return 1
    mv -f "$out.tmp" "$out"
}

if [ "${ZN_SKIP_SRS:-0}" = "1" ]; then
    log "ZN_SKIP_SRS=1: SRS download skipped."
else
    for FILE in "${!SRS_URLS[@]}"; do
        log "SRS: $FILE"
        download_file "${SRS_URLS[$FILE]}" "$HP_SRS/$FILE" || {
            rm -f "$HP_SRS/$FILE.tmp"
            die "Failed to download SRS: $FILE"
        }
    done
fi

for FILE in \
    "cn.srs" \
    "geosite-geolocation-cn.srs" \
    "geosite-geolocation-!cn.srs"; do
    [ -s "$HP_SRS/$FILE" ] || die "Required private SRS missing or empty: $FILE"
done

# ------------------------------------------------------------------
# 3. Localize only the three semantic rule-set objects.
#
# We deliberately do NOT replace the whole bypass_mainland_china block.
# The Python helper finds push(config.route.rule_set, { ... }) objects by
# their tags and changes only the object fields needed for local storage.
#
# If an upstream version already made one of these rule-sets local, it is
# left untouched. This makes the patch idempotent and future-friendly.
# ------------------------------------------------------------------
python3 - "$GEN_FILE" "$GEN_FILE.tmp" "$HP_SRS_REL" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
srs_rel = sys.argv[3]
s = src.read_text()

targets = {
    "geoip-cn": "cn.srs",
    "geosite-cn": "geosite-geolocation-cn.srs",
    "geosite-noncn": "geosite-geolocation-!cn.srs",
}

def matching_brace(text, opening):
    depth = 0
    quote = None
    escape = False
    for i in range(opening, len(text)):
        c = text[i]
        if quote:
            if escape:
                escape = False
            elif c == '\\\\':
                escape = True
            elif c == quote:
                quote = None
            continue
        if c in ("'", '"'):
            quote = c
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
    return -1

def find_rule_objects(text):
    needle = "push(config.route.rule_set, {"
    pos = 0
    while True:
        start = text.find(needle, pos)
        if start < 0:
            return
        brace = text.find("{", start)
        end = matching_brace(text, brace)
        if end < 0:
            raise SystemExit("Unbalanced rule-set object in generate_client.uc")
        yield start, end + 1, text[start:end + 1]
        pos = end + 1

objects = list(find_rule_objects(s))

found = {}
replacements = []

for start, end, obj in objects:
    tag_match = re.search(r"\btag\s*:\s*['\"]([^'\"]+)['\"]", obj)
    if not tag_match:
        continue
    tag = tag_match.group(1)
    if tag not in targets:
        continue

    found[tag] = True

    # Already local: leave upstream implementation untouched.
    if re.search(r"\btype\s*:\s*['\"]local['\"]", obj):
        if not re.search(r"\bpath\s*:", obj):
            raise SystemExit(f"{tag}: already local but has no path; refusing to guess")
        continue

    # We only accept a remote rule-set here. This prevents us from silently
    # rewriting a future rule-set type we do not understand.
    if not re.search(r"\btype\s*:\s*['\"]remote['\"]", obj):
        raise SystemExit(f"{tag}: unsupported rule-set type; refusing to guess")

    filename = targets[tag]
    local_path = f"HP_DIR + '/private_srs/{filename}'"

    # Replace only type/url/download_detour. Preserve tag, format, comments,
    # update_interval, and any future fields added by upstream.
    new_obj = re.sub(
        r"(\btype\s*:\s*)['\"]remote['\"]",
        r"\1'local'",
        obj,
        count=1,
    )

    # Remove the URL property from the object.
    new_obj, n_url = re.subn(
        r"(?m)^\s*url\s*:\s*['\"][^'\"]+['\"]\s*,\s*\n",
        "",
        new_obj,
        count=1,
    )
    if n_url != 1:
        raise SystemExit(f"{tag}: remote rule-set has no recognizable url field")

    # download_detour belongs to remote downloading; remove it if present.
    new_obj = re.sub(
        r"(?m)^\s*download_detour\s*:\s*[^,\n]+,\s*\n",
        "",
        new_obj,
        count=1,
    )

    # Add local path immediately after format when possible; otherwise after type.
    if re.search(r"\bpath\s*:", new_obj):
        new_obj = re.sub(
            r"(\bpath\s*:\s*)[^,\n]+,",
            f"\\1{local_path},",
            new_obj,
            count=1,
        )
    elif re.search(r"(\bformat\s*:\s*[^,\n]+,\s*\n)", new_obj):
        new_obj = re.sub(
            r"(\bformat\s*:\s*[^,\n]+,\s*\n)",
            rf"\1\t\t\tpath: {local_path},\n",
            new_obj,
            count=1,
        )
    else:
        new_obj = re.sub(
            r"(\btype\s*:\s*['\"]local['\"]\s*,\s*\n)",
            rf"\1\t\t\tpath: {local_path},\n",
            new_obj,
            count=1,
        )

    replacements.append((start, end, new_obj))

for tag in targets:
    if tag not in found:
        raise SystemExit(f"Required built-in rule-set tag not found: {tag}")

for start, end, new_obj in reversed(replacements):
    s = s[:start] + new_obj + s[end:]

dst.write_text(s)
PY
mv -f "$GEN_FILE.tmp" "$GEN_FILE"

# ------------------------------------------------------------------
# 4. Validation.
# ------------------------------------------------------------------
fail=0
pass_check() { printf '[PASS] %s\n' "$1"; }
fail_check() { printf '[FAIL] %s\n' "$1"; fail=1; }

for spec in \
    "geoip-cn|cn.srs" \
    "geosite-cn|geosite-geolocation-cn.srs" \
    "geosite-noncn|geosite-geolocation-!cn.srs"; do
    tag="${spec%%|*}"
    file="${spec#*|}"
    if grep -A12 -B2 "tag: '$tag'" "$GEN_FILE" | grep -q "type: 'local'" &&
       grep -A12 -B2 "tag: '$tag'" "$GEN_FILE" | grep -q "path: HP_DIR + '/private_srs/$file'"; then
        pass_check "$tag -> local $file"
    else
        fail_check "$tag -> local $file"
    fi
done

# The old three remote URLs must not remain in the generator for the target tags.
python3 - "$GEN_FILE" <<'PY'
import re, sys
from pathlib import Path
s = Path(sys.argv[1]).read_text()

targets = {"geoip-cn", "geosite-cn", "geosite-noncn"}
needle = "push(config.route.rule_set, {"

def matching_brace(text, opening):
    depth = 0
    quote = None
    esc = False
    for i in range(opening, len(text)):
        c = text[i]
        if quote:
            if esc:
                esc = False
            elif c == '\\':
                esc = True
            elif c == quote:
                quote = None
            continue
        if c in "'\"":
            quote = c
        elif c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
    return -1

pos = 0
while True:
    start = s.find(needle, pos)
    if start < 0:
        break
    brace = s.find("{", start)
    end = matching_brace(s, brace)
    if end < 0:
        raise SystemExit("Unbalanced rule-set object")
    obj = s[start:end+1]
    m = re.search(r"\btag\s*:\s*['\"]([^'\"]+)['\"]", obj)
    if m and m.group(1) in targets:
        if re.search(r"\btype\s*:\s*['\"]remote['\"]", obj):
            raise SystemExit(f"{m.group(1)} is still remote")
        if not re.search(r"\btype\s*:\s*['\"]local['\"]", obj):
            raise SystemExit(f"{m.group(1)} has no local type")
    pos = end + 1
PY
pass_check "three built-in mainland rule-sets are no longer remote"

grep -q 'update_resources\.sh' "$UPDATE_CROND" &&
    pass_check "native update_crond -> update_resources.sh" ||
    fail_check "native update_crond -> update_resources.sh"

# Do not hard-code a particular sing-box version. We only verify that the
# upstream runtime script still performs its own minimum-version check.
grep -q 'sing-box version' "$INIT_FILE" &&
    pass_check "upstream HomeProxy retains runtime sing-box version detection" ||
    fail_check "upstream HomeProxy runtime version detection"

# Verify that Custom Routing is still present in the generator.
grep -q 'routing_mode' "$GEN_FILE" &&
    pass_check "upstream routing model preserved" ||
    fail_check "upstream routing model missing"

# Verify no old whole-block replacement markers remain.
if grep -q 'ZN: bundled local SRS' "$GEN_FILE"; then
    warn "Local SRS annotations are present; this is expected."
fi

if [ "$fail" -ne 0 ]; then
    die "ZN HomeProxy validation failed."
fi

# ------------------------------------------------------------------
# 5. Persist private SRS across sysupgrade.
# ------------------------------------------------------------------
SYSUPGRADE_CONF="$ROOT/package/base-files/files/etc/sysupgrade.conf"
if [ -d "$ROOT/package/base-files" ]; then
    mkdir -p "$(dirname "$SYSUPGRADE_CONF")"
    if ! grep -qxF "$HP_SRS_REL/" "$SYSUPGRADE_CONF" 2>/dev/null; then
        echo "$HP_SRS_REL/" >> "$SYSUPGRADE_CONF"
        log "Added $HP_SRS_REL/ to sysupgrade.conf"
    else
        log "$HP_SRS_REL/ already exists in sysupgrade.conf"
    fi
else
    warn "base-files package not found; sysupgrade.conf was not modified."
fi

log "HomeProxy source:"
if repo_origin_matches "$HP_PATH" "$PRIMARY_REPO"; then
    log "  primary: $PRIMARY_REPO"
elif repo_origin_matches "$HP_PATH" "$FALLBACK_REPO"; then
    log "  fallback: $FALLBACK_REPO"
else
    log "  local/unidentified source: $HP_PATH"
fi

log "Installed SRS:"
find "$HP_SRS" -maxdepth 1 -type f -name '*.srs' -printf '  %f %s bytes\n' 2>/dev/null |
    sort || true

echo "=== ZN HomeProxy v2 processing complete ==="
