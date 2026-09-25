#!/usr/bin/env bash
set -euo pipefail

# ZN-HomeProxy v6
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
#       2. replaces the three built-in mainland-China rule-set objects
#          with fixed local rule-set objects;
#       3. persists /etc/homeproxy/private_srs/ across sysupgrade.
#   - Custom Routing and all other upstream HomeProxy logic are preserved.
#
# Optional environment variables:
#   ZN_HOMEProxy_PRIMARY_REPO
#   ZN_HOMEProxy_FALLBACK_REPO
#   ZN_HOMEProxy_BRANCH
#       Empty by default: use repository default branch.
#       Set explicitly only when a specific branch is required.
#   ZN_HOMEProxy_AUTO_FETCH=0|1
#       Default: 1.
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
HP_BRANCH="${ZN_HOMEProxy_BRANCH:-}"
AUTO_FETCH="${ZN_HOMEProxy_AUTO_FETCH:-1}"

log() {
    printf '[ZN-HomeProxy] %s\n' "$*" >&2
}

warn() {
    printf '[ZN-HomeProxy][WARN] %s\n' "$*" >&2
}

die() {
    printf '[ZN-HomeProxy][ERROR] %s\n' "$*" >&2
    exit 1
}

pass_check() {
    printf '[PASS] %s\n' "$*"
}

fail_check() {
    printf '[FAIL] %s\n' "$*"
}

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
            -type d \
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
#
# Default behavior:
#   use repository default branch.
#
# Optional:
#   ZN_HOMEProxy_BRANCH=some-branch
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
    local -a clone_args

    rm -rf -- "$tmp"
    rm -rf -- "$target"

    clone_args=(
        --depth 1
    )

    if [ -n "$HP_BRANCH" ]; then
        clone_args+=(
            --branch "$HP_BRANCH"
        )

        log "HomeProxy branch override: $HP_BRANCH"
    else
        log "HomeProxy branch: repository default"
    fi

    printf '[ZN-HomeProxy] Trying primary upstream: %s\n' \
        "$PRIMARY_REPO" >&2

    if git clone \
        "${clone_args[@]}" \
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
        "${clone_args[@]}" \
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

    rm -f -- "$out.tmp"

    if command -v curl >/dev/null 2>&1; then
        curl \
            -fL \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 15 \
            --max-time 120 \
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

    [ -s "$out.tmp" ] || {
        warn "Downloaded file is empty: $url"
        return 1
    }

    # Reject obvious HTML/text error pages.
    #
    # SRS is binary data. This check is intentionally conservative:
    # it only rejects unmistakable web/error-page signatures.
    if LC_ALL=C head -c 256 "$out.tmp" |
        grep -Eiq \
            '<!doctype html|<html|<head|<body|404:[[:space:]]*not[[:space:]]*found|access denied'
    then
        warn "Downloaded response looks like an HTML/text error page: $url"
        return 1
    fi

    mv -f "$out.tmp" "$out"
}


for FILE in \
    "cn.srs" \
    "geosite-geolocation-cn.srs" \
    "geosite-geolocation-!cn.srs" \
    "geosite-google.srs" \
    "geosite-openai.srs" \
    "geosite-anthropic.srs" \
    "geosite-whatsapp.srs" \
    "geosite-zoom.srs"
do
    log "SRS: $FILE"

    download_file \
        "${SRS_URLS[$FILE]}" \
        "$HP_SRS/$FILE" || {
            rm -f -- "$HP_SRS/$FILE.tmp"
            die "Failed to download SRS: $FILE"
        }
done


# ------------------------------------------------------------------
# 4. Replace only the three semantic rule-set objects.
#
# IMPORTANT:
#   The entire matching object is replaced.
#
# This deliberately does NOT modify an existing object in-place.
# Therefore no future upstream remote-only attributes can accidentally
# leak into the local rule-set definition.
# ------------------------------------------------------------------

python3 - "$GEN_FILE" "$GEN_FILE.tmp" "$HP_SRS_REL" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
s = src.read_text()

targets = {
    "geoip-cn": "cn.srs",
    "geosite-cn": "geosite-geolocation-cn.srs",
    "geosite-noncn": "geosite-geolocation-!cn.srs",
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
            elif c == "\\":
                escape = True
            elif c == quote:
                quote = None
            continue

        if c in ("'", '"'):
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1

            if depth == 0:
                return i

    return -1


def find_rule_objects(text):
    pos = 0

    while True:
        start = text.find(needle, pos)

        if start < 0:
            return

        brace = text.find("{", start)

        if brace < 0:
            raise SystemExit(
                "Unable to locate opening brace for rule-set object"
            )

        end = matching_brace(text, brace)

        if end < 0:
            raise SystemExit(
                "Unbalanced rule-set object in generate_client.uc"
            )

        # Include the object's closing brace, but not the trailing ';'.
        yield start, end + 1, text[start:end + 1]

        pos = end + 1


def detect_indent(obj):
    match = re.search(
        r"\n([ \t]+)(?:type|tag|format|path)\s*:",
        obj
    )

    if match:
        return match.group(1)

    return "\t\t"


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

    filename = targets[tag]

    indent = detect_indent(obj)

    local_obj = (
        "push(config.route.rule_set, {\n"
        f"{indent}type: 'local',\n"
        f"{indent}tag: '{tag}',\n"
        f"{indent}format: 'binary',\n"
        f"{indent}path: HP_DIR + '/private_srs/{filename}'\n"
        "});"
    )

    # Replace the entire object including push(...), not just selected
    # properties. This guarantees that remote-only upstream attributes
    # cannot survive the transformation.
    replacements.append(
        (start, end, local_obj[:-2])  # exclude "});" because source end is "}"
    )

# The replacement range currently ends at the object's closing "}".
# Reconstruct the exact object while preserving the original trailing ';'.
#
# Since the original source is:
#   push(config.route.rule_set, {...});
#
# replace the complete range from push(...) through "}" and retain ";".

for start, end, new_obj_without_semicolon in reversed(replacements):
    s = (
        s[:start]
        + new_obj_without_semicolon
        + "}"
        + s[end:]
    )

for tag in targets:
    if tag not in found:
        raise SystemExit(
            f"Required built-in rule-set tag not found: {tag}"
        )

dst.write_text(s)
PY

mv -f "$GEN_FILE.tmp" "$GEN_FILE"


# ------------------------------------------------------------------
# 5. Strict structural validation.
#
# Validation is performed against the actual brace-delimited object,
# never with grep context ranges.
# ------------------------------------------------------------------

python3 - "$GEN_FILE" <<'PY'
import re
import sys
from pathlib import Path

s = Path(sys.argv[1]).read_text()

targets = {
    "geoip-cn": "cn.srs",
    "geosite-cn": "geosite-geolocation-cn.srs",
    "geosite-noncn": "geosite-geolocation-!cn.srs",
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
            elif c == "\\":
                escape = True
            elif c == quote:
                quote = None
            continue

        if c in ("'", '"'):
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1

            if depth == 0:
                return i

    return -1


found = set()
pos = 0

while True:
    start = s.find(needle, pos)

    if start < 0:
        break

    brace = s.find("{", start)

    if brace < 0:
        raise SystemExit(
            "Unable to locate opening brace for rule-set object"
        )

    end = matching_brace(s, brace)

    if end < 0:
        raise SystemExit("Unbalanced rule-set object")

    obj = s[start:end + 1]

    tag_match = re.search(
        r"\btag\s*:\s*['\"]([^'\"]+)['\"]",
        obj
    )

    if tag_match:
        tag = tag_match.group(1)

        if tag in targets:
            found.add(tag)

            expected_file = targets[tag]

            if re.search(
                r"\btype\s*:\s*['\"]remote['\"]",
                obj
            ):
                raise SystemExit(
                    f"{tag} is still remote"
                )

            if not re.search(
                r"\btype\s*:\s*['\"]local['\"]",
                obj
            ):
                raise SystemExit(
                    f"{tag} has no local type"
                )

            expected_path = (
                r"HP_DIR\s*\+\s*['\"]"
                r"/private_srs/"
                + re.escape(expected_file)
                + r"['\"]"
            )

            if not re.search(
                rf"\bpath\s*:\s*{expected_path}",
                obj
            ):
                raise SystemExit(
                    f"{tag} has incorrect or missing local path"
                )

            if re.search(r"\burl\s*:", obj):
                raise SystemExit(
                    f"{tag} still contains url"
                )

            if re.search(r"\bdownload_detour\s*:", obj):
                raise SystemExit(
                    f"{tag} still contains download_detour"
                )

            if re.search(r"\bupdate_interval\s*:", obj):
                raise SystemExit(
                    f"{tag} still contains update_interval"
                )

            properties = re.findall(
                r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:",
                obj,
                flags=re.MULTILINE,
            )

            allowed = {
                "type",
                "tag",
                "format",
                "path",
            }

            unexpected = [
                prop for prop in properties
                if prop not in allowed
            ]

            if unexpected:
                raise SystemExit(
                    f"{tag} contains unexpected properties: "
                    + ", ".join(unexpected)
                )

            print(
                f"[PASS] {tag} -> local "
                f"/etc/homeproxy/private_srs/{expected_file}"
            )

    pos = end + 1


missing = set(targets) - found

if missing:
    raise SystemExit(
        "Missing required rule-set tags: "
        + ", ".join(sorted(missing))
    )
PY


# ------------------------------------------------------------------
# 6. Validate all eight SRS files.
# ------------------------------------------------------------------

for FILE in \
    "cn.srs" \
    "geosite-geolocation-cn.srs" \
    "geosite-geolocation-!cn.srs" \
    "geosite-google.srs" \
    "geosite-openai.srs" \
    "geosite-anthropic.srs" \
    "geosite-whatsapp.srs" \
    "geosite-zoom.srs"
do
    [ -s "$HP_SRS/$FILE" ] || \
        die "Required private SRS missing or empty: $FILE"
done

pass_check "all 8 bundled SRS files are present and non-empty"


# ------------------------------------------------------------------
# 7. Native HomeProxy workflow checks.
# ------------------------------------------------------------------

if grep -q 'update_resources\.sh' "$UPDATE_CROND"; then
    pass_check "native update_crond -> update_resources.sh"
else
    die "native update_crond -> update_resources.sh is missing"
fi


if grep -q 'bypass_mainland_china' "$GEN_FILE"; then
    pass_check "upstream bypass_mainland_china routing model preserved"
else
    die "upstream bypass_mainland_china routing model missing"
fi


if grep -q 'routing_mode' "$GEN_FILE"; then
    pass_check "upstream routing_mode handling preserved"
else
    die "upstream routing_mode handling missing"
fi


if grep -q 'sing-box' "$GEN_FILE"; then
    pass_check "upstream sing-box handling preserved"
else
    die "upstream sing-box handling missing"
fi


if grep -q 'sing-box version' "$INIT_FILE"; then
    pass_check "upstream HomeProxy retains runtime sing-box version detection"
else
    warn "Could not find literal 'sing-box version' in init script."
    warn "This is informational only; no sing-box version logic is being added."
fi


# ------------------------------------------------------------------
# 8. Persist private SRS across sysupgrade.
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

    pass_check "sysupgrade persistence configured"
else
    warn "base-files package not found; sysupgrade.conf was not modified."
fi


# ------------------------------------------------------------------
# 9. Final report.
# ------------------------------------------------------------------

log "=============================================="
log "ZN-HomeProxy v6 processing complete"
log "=============================================="

log "HomeProxy source:"

if repo_origin_matches "$HP_PATH" "$PRIMARY_REPO"; then
    log "  primary : $PRIMARY_REPO"
elif repo_origin_matches "$HP_PATH" "$FALLBACK_REPO"; then
    log "  fallback: $FALLBACK_REPO"
else
    log "  local/unidentified source: $HP_PATH"
fi

log "Generator:"
log "  $GEN_FILE"

log "Private SRS:"
log "  $HP_SRS"

log "Sysupgrade:"
log "  $SYSUPGRADE_CONF"

log "Installed SRS:"

find "$HP_SRS" \
    -maxdepth 1 \
    -type f \
    -name '*.srs' \
    -printf '  %f %s bytes\n' \
    2>/dev/null |
    sort || true

log "=============================================="
