#!/usr/bin/env bash
set -euo pipefail

# ZN-HomeProxy v4
#
# Design:
#   - Always remove any existing luci-app-homeproxy source from the build tree.
#   - szwjp/luci-app-homeproxy is the primary HomeProxy upstream.
#   - htcnokia/luci-app-homeproxy is the fallback mirror/fork.
#   - ZN does NOT provide, replace, or version-lock sing-box.
#   - sing-box syntax compatibility remains the responsibility of the
#     selected upstream HomeProxy generator.
#   - ZN only:
#       1. bundles 8 SRS files;
#       2. localizes the three built-in mainland-China rule-sets;
#       3. persists /etc/homeproxy/private_srs/ across sysupgrade.
#   - Custom Routing and all other upstream HomeProxy logic are preserved.
#
# Optional environment variables:
#   ZN_HOMEProxy_PRIMARY_REPO
#   ZN_HOMEProxy_FALLBACK_REPO
#   ZN_HOMEProxy_BRANCH
#   ZN_HOMEProxy_AUTO_FETCH=0|1   (default: 1)
#   ZN_SKIP_SRS=1
#
# Usage:
#   ./ZN-HomeProxy.sh
#   ./ZN-HomeProxy.sh /path/to/openwrt
#
# The script is intended to run after package/feed preparation.

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


# ------------------------------------------------------------------
# Basic HomeProxy package validation.
# ------------------------------------------------------------------

is_homeproxy_lineage() {
    local p="$1"

    [ -f "$p/root/etc/homeproxy/scripts/generate_client.uc" ] &&
    [ -f "$p/root/etc/homeproxy/scripts/update_resources.sh" ] &&
    [ -f "$p/root/etc/homeproxy/scripts/update_crond.sh" ] &&
    [ -f "$p/root/etc/init.d/homeproxy" ] &&
    [ -f "$p/Makefile" ]
}


# ------------------------------------------------------------------
# Compare git origin with an expected repository.
# ------------------------------------------------------------------

repo_origin_matches() {
    local p="$1"
    local origin="$2"
    local remote=""

    if [ -d "$p/.git" ] && command -v git >/dev/null 2>&1; then
        remote="$(git -C "$p" remote get-url origin 2>/dev/null || true)"

        case "$remote" in
            "$origin"|"$origin/"*)
                return 0
                ;;
            "https://github.com/"*)
                local a b
                a="${remote%.git}"
                b="${origin%.git}"
                [ "${a,,}" = "${b,,}" ] && return 0
                ;;
        esac
    fi

    return 1
}


# ------------------------------------------------------------------
# Remove every existing luci-app-homeproxy source from the build tree.
# ------------------------------------------------------------------

remove_existing_homeproxy() {
    local found=0
    local p

    log "Scanning for existing luci-app-homeproxy sources..."

    while IFS= read -r -d '' p; do
        [ -n "$p" ] || continue

        # Never remove anything outside the build root.
        case "$p" in
            "$ROOT"/*)
                ;;
            *)
                warn "Ignoring HomeProxy path outside build root: $p"
                continue
                ;;
        esac

        log "Removing existing HomeProxy source: $p"
        rm -rf -- "$p"
        found=1
    done < <(
        find "$ROOT" \
            -depth \
            -name 'luci-app-homeproxy' \
            -print0 \
            2>/dev/null
    )

    if [ "$found" -eq 0 ]; then
        log "No existing luci-app-homeproxy source found."
    else
        log "Existing luci-app-homeproxy source cleanup complete."
    fi
}


# ------------------------------------------------------------------
# Fetch HomeProxy from the primary source, with fallback.
# ------------------------------------------------------------------

fetch_homeproxy() {
    [ "$AUTO_FETCH" = "1" ] || {
        warn "ZN_HOMEProxy_AUTO_FETCH=0; automatic HomeProxy fetch disabled."
        return 1
    }

    command -v git >/dev/null 2>&1 || {
        warn "git is unavailable; cannot fetch HomeProxy source."
        return 1
    }

    local target="$ROOT/package/luci-app-homeproxy"
    local tmp="$ROOT/.zn-homeproxy-bootstrap"

    rm -rf -- "$tmp"
    rm -rf -- "$target"

    printf '[ZN-HomeProxy] Trying primary upstream: %s\n' \
        "$PRIMARY_REPO" >&2

    if git clone \
        --depth 1 \
        --branch "$HP_BRANCH" \
        "$PRIMARY_REPO" \
        "$tmp" \
        >/dev/null 2>&1
    then
        if is_homeproxy_lineage "$tmp"; then
            mkdir -p "$(dirname "$target")"
            mv "$tmp" "$target"

            printf '[ZN-HomeProxy] Using primary HomeProxy source: %s\n' \
                "$PRIMARY_REPO" >&2
            printf '%s\n' "$target"
            return 0
        fi

        warn "Primary clone succeeded but is not a complete HomeProxy package."
        rm -rf -- "$tmp"
    else
        warn "Primary HomeProxy source unavailable."
        rm -rf -- "$tmp"
    fi

    printf '[ZN-HomeProxy] Trying fallback fork: %s\n' \
        "$FALLBACK_REPO" >&2

    if git clone \
        --depth 1 \
        --branch "$HP_BRANCH" \
        "$FALLBACK_REPO" \
        "$tmp" \
        >/dev/null 2>&1
    then
        if is_homeproxy_lineage "$tmp"; then
            mkdir -p "$(dirname "$target")"
            mv "$tmp" "$target"

            printf '[ZN-HomeProxy] Using fallback HomeProxy source: %s\n' \
                "$FALLBACK_REPO" >&2
            printf '%s\n' "$target"
            return 0
        fi

        warn "Fallback clone succeeded but is not a complete HomeProxy package."
        rm -rf -- "$tmp"
    else
        warn "Fallback HomeProxy source unavailable."
        rm -rf -- "$tmp"
    fi

    die "Both HomeProxy sources are unavailable or incomplete."
}


# ------------------------------------------------------------------
# 0. Clean any existing HomeProxy source.
# ------------------------------------------------------------------

remove_existing_homeproxy


# ------------------------------------------------------------------
# 1. Fetch the intended HomeProxy source.
# ------------------------------------------------------------------

HP_PATH="$(fetch_homeproxy)"

is_homeproxy_lineage "$HP_PATH" || \
    die "Selected path is not a complete HomeProxy package: $HP_PATH"

HP_ROOT="$HP_PATH/root/etc/homeproxy"

GEN_FILE="$HP_ROOT/scripts/generate_client.uc"
UPDATE_RESOURCES="$HP_ROOT/scripts/update_resources.sh"
UPDATE_CROND="$HP_ROOT/scripts/update_crond.sh"
INIT_FILE="$HP_PATH/root/etc/init.d/homeproxy"
MAKEFILE="$HP_PATH/Makefile"

log "Selected HomeProxy package: $HP_PATH"

for f in \
    "$GEN_FILE" \
    "$UPDATE_RESOURCES" \
    "$UPDATE_CROND" \
    "$INIT_FILE" \
    "$MAKEFILE"
do
    [ -f "$f" ] || die "Required file missing: $f"
done


# ------------------------------------------------------------------
# 2. Upstream sanity checks.
# ------------------------------------------------------------------

grep -q 'bypass_mainland_china' "$GEN_FILE" || \
    die "The selected generator has no bypass_mainland_china routing mode."

grep -q 'update_resources\.sh' "$UPDATE_CROND" || \
    die "update_crond.sh no longer calls update_resources.sh; refusing to alter the upstream workflow."


# ------------------------------------------------------------------
# 3. Bundle the SRS data.
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
    local url="$1"
    local out="$2"

    if command -v curl >/dev/null 2>&1; then
        curl \
            -fL \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 15 \
            -o "$out.tmp" \
            "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget \
            -q \
            --timeout=20 \
            --tries=3 \
            -O "$out.tmp" \
            "$url"
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

        download_file \
            "${SRS_URLS[$FILE]}" \
            "$HP_SRS/$FILE" || {
                rm -f "$HP_SRS/$FILE.tmp"
                die "Failed to download SRS: $FILE"
            }
    done
fi


for FILE in \
    "cn.srs" \
    "geosite-geolocation-cn.srs" \
    "geosite-geolocation-!cn.srs"
do
    [ -s "$HP_SRS/$FILE" ] || \
        die "Required private SRS missing or empty: $FILE"
done


# ------------------------------------------------------------------
# 4. Localize only the three semantic rule-set objects.
# ------------------------------------------------------------------

python3 - "$GEN_FILE" "$GEN_FILE.tmp" "$HP_SRS_REL" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])

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
            elif c == '\\':
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
            raise SystemExit(
                "Unbalanced rule-set object in generate_client.uc"
            )

        yield start, end + 1, text[start:end + 1]

        pos = end + 1


s = src.read_text()

objects = list(find_rule_objects(s))

found = set()
replacements = []


for start, end, obj in objects:
    tag_match = re.search(
        r"\btag\s*:\s*['\"]([^'\"]+)['\"]",
        obj
    )

    if not tag_match:
        continue

    tag = tag_match.group(1)

    if tag not in targets:
        continue

    found.add(tag)

    if re.search(r"\btype\s*:\s*['\"]local['\"]", obj):
        if not re.search(r"\bpath\s*:", obj):
            raise SystemExit(
                f"{tag}: already local but has no path; refusing to guess"
            )
        continue

    if not re.search(r"\btype\s*:\s*['\"]remote['\"]", obj):
        raise SystemExit(
            f"{tag}: unsupported rule-set type; refusing to guess"
        )

    filename = targets[tag]
    local_path = f"HP_DIR + '/private_srs/{filename}'"

    # remote -> local
    new_obj = re.sub(
        r"(\btype\s*:\s*)['\"]remote['\"]",
        r"\1'local'",
        obj,
        count=1,
    )

    # 灵活移除 url 字段（容忍任意前导空格、行首/非行首及多余逗号与换行）
    new_obj, n_url = re.subn(
        r"[ \t]*\burl\s*:\s*['\"][^'\"]+['\"]\s*,?[ \t]*\n?",
        "",
        new_obj,
        count=1,
    )

    if n_url != 1:
        raise SystemExit(
            f"{tag}: remote rule-set has no recognizable url field"
        )

    # 灵活移除 download_detour 字段
    new_obj = re.sub(
        r"[ \t]*\bdownload_detour\s*:\s*[^,\n]+,?[ \t]*\n?",
        "",
        new_obj,
    )

    # 灵活移除 update_interval 字段
    new_obj = re.sub(
        r"[ \t]*\bupdate_interval\s*:\s*[^,\n]+,?[ \t]*\n?",
        "",
        new_obj,
    )

    # 补全或替换 local path
    if re.search(r"\bpath\s*:", new_obj):
        new_obj = re.sub(
            r"(\bpath\s*:\s*)[^,\n]+,?",
            rf"\1{local_path}",
            new_obj,
            count=1,
        )
    else:
        format_match = re.search(
            r"(?m)^([ \t]*format\s*:\s*[^,\n]+,)[ \t]*\n",
            new_obj
        )

        if format_match:
            indent = re.match(r"[ \t]*", format_match.group(1)).group(0)
            replacement = (
                format_match.group(1)
                + "\n"
                + indent
                + f"path: {local_path},"
                + "\n"
            )
            new_obj = (
                new_obj[:format_match.start()]
                + replacement
                + new_obj[format_match.end():]
            )
        else:
            type_match = re.search(
                r"(?m)^([ \t]*type\s*:\s*['\"]local['\"],)[ \t]*\n",
                new_obj
            )

            if not type_match:
                raise SystemExit(
                    f"{tag}: cannot determine where to insert local path"
                )

            indent = re.match(r"[ \t]*", type_match.group(1)).group(0)
            replacement = (
                type_match.group(1)
                + "\n"
                + indent
                + f"path: {local_path},"
                + "\n"
            )
            new_obj = (
                new_obj[:type_match.start()]
                + replacement
                + new_obj[type_match.end():]
            )

    replacements.append((start, end, new_obj))


for tag in targets:
    if tag not in found:
        raise SystemExit(
            f"Required built-in rule-set tag not found: {tag}"
        )


for start, end, new_obj in reversed(replacements):
    s = s[:start] + new_obj + s[end:]


dst.write_text(s)
PY

mv -f "$GEN_FILE.tmp" "$GEN_FILE"


# ------------------------------------------------------------------
# 5. Validation.
# ------------------------------------------------------------------

fail=0

pass_check() {
    printf '[PASS] %s\n' "$1"
}

fail_check() {
    printf '[FAIL] %s\n' "$1"
    fail=1
}


for spec in \
    "geoip-cn|cn.srs" \
    "geosite-cn|geosite-geolocation-cn.srs" \
    "geosite-noncn|geosite-geolocation-!cn.srs"
do
    tag="${spec%%|*}"
    file="${spec#*|}"

    if grep \
        -A12 \
        -B2 \
        "tag: '$tag'" \
        "$GEN_FILE" |
        grep -q "type: 'local'"
    then
        if grep \
            -A12 \
            -B2 \
            "tag: '$tag'" \
            "$GEN_FILE" |
            grep -q "path: HP_DIR + '/private_srs/$file'"
        then
            pass_check "$tag -> local $file"
        else
            fail_check "$tag -> missing local path $file"
        fi
    else
        fail_check "$tag -> not local"
    fi
done


# Strictly verify that the three target objects are no longer remote.
python3 - "$GEN_FILE" <<'PY'
import re
import sys
from pathlib import Path

s = Path(sys.argv[1]).read_text()

targets = {
    "geoip-cn",
    "geosite-cn",
    "geosite-noncn",
}

needle = "push(config.route.rule_set, {"


def matching_brace(text, opening):
    depth = 0
    quote = None
    escape = False

    for i in range(opening, len(text)):
        c = text[i]

        if quote:
            if escape:
                escape = False
            elif c == '\\':
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


pos = 0

while True:
    start = s.find(needle, pos)

    if start < 0:
        break

    brace = s.find("{", start)
    end = matching_brace(s, brace)

    if end < 0:
        raise SystemExit("Unbalanced rule-set object")

    obj = s[start:end + 1]

    tag_match = re.search(
        r"\btag\s*:\s*['\"]([^'\"]+)['\"]",
        obj
    )

    if tag_match and tag_match.group(1) in targets:
        tag = tag_match.group(1)

        if re.search(r"\btype\s*:\s*['\"]remote['\"]", obj):
            raise SystemExit(f"{tag} is still remote")

        if not re.search(r"\btype\s*:\s*['\"]local['\"]", obj):
            raise SystemExit(f"{tag} has no local type")

        if re.search(r"\burl\s*:", obj):
            raise SystemExit(f"{tag} still contains url")

        if re.search(r"\bdownload_detour\s*:", obj):
            raise SystemExit(f"{tag} still contains download_detour")

        if re.search(r"\bupdate_interval\s*:", obj):
            raise SystemExit(f"{tag} still contains update_interval")

    pos = end + 1
PY

pass_check "three built-in mainland rule-sets are local-only"


# Native HomeProxy resource updater must remain untouched.
if grep -q 'update_resources\.sh' "$UPDATE_CROND"; then
    pass_check "native update_crond -> update_resources.sh"
else
    fail_check "native update_crond -> update_resources.sh"
fi


if grep -q 'sing-box version' "$INIT_FILE"; then
    pass_check "upstream HomeProxy retains runtime sing-box version detection"
else
    fail_check "upstream HomeProxy runtime version detection"
fi


if grep -q 'routing_mode' "$GEN_FILE"; then
    pass_check "upstream routing model preserved"
else
    fail_check "upstream routing model missing"
fi


if [ "$fail" -ne 0 ]; then
    die "ZN HomeProxy validation failed."
fi


# ------------------------------------------------------------------
# 6. Persist private SRS across sysupgrade.
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


# ------------------------------------------------------------------
# 7. Final report.
# ------------------------------------------------------------------

log "HomeProxy source:"

if repo_origin_matches "$HP_PATH" "$PRIMARY_REPO"; then
    log "  primary: $PRIMARY_REPO"
elif repo_origin_matches "$HP_PATH" "$FALLBACK_REPO"; then
    log "  fallback: $FALLBACK_REPO"
else
    log "  local/unidentified source: $HP_PATH"
fi


log "Installed SRS:"

find "$HP_SRS" \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    -printf '  %f %s bytes\n' \
    2>/dev/null |
    sort || true


echo "=== ZN HomeProxy v4 processing complete ==="
