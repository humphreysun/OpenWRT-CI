#!/usr/bin/env bash
set -euo pipefail

# ZN-HomeProxy (optimized)
# Baseline: szwjp/luci-app-homeproxy
#
# Responsibilities:
#   1. Use the szwjp HomeProxy package as the ONLY HomeProxy source.
#   2. Keep its native update_resources.sh/update_crond.sh runtime updater.
#   3. Pre-bundle the required SRS files into /etc/homeproxy/private_srs/.
#   4. Convert HomeProxy's three built-in mainland rule-sets from remote to local.
#   5. Check the bundled HomeProxy generator against the sing-box version
#      supplied by the build tree (supported: 1.14.x and 1.15.x).
#   6. Persist private_srs across sysupgrade.
#
# It intentionally does NOT patch the UI, migrate_config.uc, homeproxy.js,
# or other HomeProxy core files. This avoids mixing the szwjp and VIKINGYFY
# implementations.

ROOT="${1:-${GITHUB_WORKSPACE:-.}}"
ROOT="$(cd "$ROOT" && pwd)"

HP_SRS_REL="/etc/homeproxy/private_srs"

find_homeproxy() {
    local p
    local candidates=(
        "$ROOT/package/luci-app-homeproxy"
        "$ROOT/package/homeproxy"
        "$ROOT/feeds/luci/luci-app-homeproxy"
        "$ROOT/feeds/luci/homeproxy"
        "$ROOT/feeds/packages/luci-app-homeproxy"
    )

    for p in "${candidates[@]}"; do
        if [ -f "$p/root/etc/homeproxy/scripts/generate_client.uc" ] &&
           [ -f "$p/root/etc/homeproxy/scripts/update_resources.sh" ] &&
           [ -f "$p/root/etc/homeproxy/scripts/update_crond.sh" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    mapfile -t found < <(
        find "$ROOT" -type f \
            -path '*/root/etc/homeproxy/scripts/generate_client.uc' 2>/dev/null |
        sed 's#/root/etc/homeproxy/scripts/generate_client.uc$##' |
        while IFS= read -r p; do
            [ -f "$p/root/etc/homeproxy/scripts/update_resources.sh" ] &&
            [ -f "$p/root/etc/homeproxy/scripts/update_crond.sh" ] &&
                printf '%s\n' "$p"
        done | sort -u
    )

    if [ "${#found[@]}" -eq 1 ]; then
        printf '%s\n' "${found[0]}"
        return 0
    fi

    if [ "${#found[@]}" -gt 1 ]; then
        echo "[ERROR] Multiple HomeProxy packages found; refusing to guess:" >&2
        printf '  %s\n' "${found[@]}" >&2
        return 2
    fi

    return 1
}

HP_PATH="$(find_homeproxy)" || {
    rc=$?
    [ "$rc" -eq 2 ] && exit 1
    echo "[ZN-HomeProxy] HomeProxy package not found, skip."
    exit 0
}

HP_ROOT="$HP_PATH/root/etc/homeproxy"
GEN_FILE="$HP_ROOT/scripts/generate_client.uc"
UPDATE_RESOURCES="$HP_ROOT/scripts/update_resources.sh"
UPDATE_CROND="$HP_ROOT/scripts/update_crond.sh"
INIT_FILE="$HP_PATH/root/etc/init.d/homeproxy"
MAKEFILE="$HP_PATH/Makefile"

echo "=== ZN HomeProxy: szwjp baseline + local SRS ==="
echo "[ZN-HomeProxy] Target package: $HP_PATH"

for f in "$GEN_FILE" "$UPDATE_RESOURCES" "$UPDATE_CROND" "$INIT_FILE" "$MAKEFILE"; do
    [ -f "$f" ] || {
        echo "[ERROR] Required file missing: $f"
        exit 1
    }
done

# ------------------------------------------------------------------
# 1. Verify this really is the intended szwjp-style baseline.
# ------------------------------------------------------------------
grep -q 'sing-box 1\.14' "$MAKEFILE" || {
    echo "[ERROR] Target HomeProxy Makefile is not the expected sing-box 1.14 baseline."
    echo "[ERROR] Refusing to combine an unknown HomeProxy implementation with ZN patches."
    exit 1
}

grep -q 'function add_mainland_rule_sets' "$GEN_FILE" || {
    echo "[ERROR] generate_client.uc has no add_mainland_rule_sets() function."
    echo "[ERROR] The local-SRS patch cannot be applied safely."
    exit 1
}

grep -q 'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs' "$GEN_FILE" || {
    echo "[ERROR] Expected upstream geoip-cn remote rule-set was not found."
    echo "[ERROR] The generator structure changed; refusing to guess."
    exit 1
}

grep -q 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs' "$GEN_FILE" || {
    echo "[ERROR] Expected upstream geosite-cn remote rule-set was not found."
    exit 1
}

grep -q 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs' "$GEN_FILE" || {
    echo "[ERROR] Expected upstream geosite-noncn remote rule-set was not found."
    exit 1
}

# The szwjp package already has its own runtime resource updater.
# Do not execute it on the build host: it writes to /etc/homeproxy and
# expects OpenWrt runtime tools (uci/jsonfilter/flock). We only verify that
# the native updater is present and is wired into update_crond.sh.
grep -q 'update_resources\.sh' "$UPDATE_CROND" || {
    echo "[ERROR] update_crond.sh does not call update_resources.sh."
    echo "[ERROR] Native HomeProxy resource-update workflow is incomplete."
    exit 1
}

# ------------------------------------------------------------------
# 2. Match the HomeProxy generator to the sing-box package in this tree.
#
# Supported:
#   1.14.x : native szwjp baseline
#   1.15.x : supported; remove deprecated TUN stack field below
#
# Refuse 1.13 or older and 1.16+ rather than producing an unverified mix.
# ------------------------------------------------------------------
find_singbox_makefile() {
    local p
    local candidates=(
        "$ROOT/package/feeds/packages/sing-box/Makefile"
        "$ROOT/feeds/packages/net/sing-box/Makefile"
        "$ROOT/feeds/packages/sing-box/Makefile"
        "$ROOT/package/sing-box/Makefile"
    )

    for p in "${candidates[@]}"; do
        [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
    done

    mapfile -t found < <(
        find "$ROOT" -type f -path '*/sing-box/Makefile' 2>/dev/null | sort -u
    )
    if [ "${#found[@]}" -eq 1 ]; then
        printf '%s\n' "${found[0]}"
        return 0
    fi
    if [ "${#found[@]}" -gt 1 ]; then
        echo "[ERROR] Multiple sing-box Makefiles found; refusing to guess:" >&2
        printf '  %s\n' "${found[@]}" >&2
        return 2
    fi
    return 1
}

SB_MAKEFILE="$(find_singbox_makefile)" || {
    rc=$?
    [ "$rc" -eq 2 ] && exit 1
    echo "[ERROR] Cannot locate sing-box/Makefile in the build tree."
    echo "[ERROR] Refusing to build HomeProxy without a verified sing-box version."
    exit 1
}

SB_VERSION="$(
    sed -n \
        -e 's/^[[:space:]]*PKG_VERSION[[:space:]]*[:?+]*=[[:space:]]*//p' \
        -e 's/^[[:space:]]*PKG_VERSION[[:space:]]*:=//p' \
        "$SB_MAKEFILE" | head -n1 | tr -d '[:space:]'
)"

if [[ ! "$SB_VERSION" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)? ]]; then
    echo "[ERROR] Cannot parse sing-box PKG_VERSION from:"
    echo "        $SB_MAKEFILE"
    exit 1
fi

SB_MAJOR="${BASH_REMATCH[1]}"
SB_MINOR="${BASH_REMATCH[2]}"

if [ "$SB_MAJOR" -ne 1 ] || [ "$SB_MINOR" -lt 14 ] || [ "$SB_MINOR" -ge 16 ]; then
    echo "[ERROR] Unsupported sing-box $SB_VERSION for this HomeProxy baseline."
    echo "[ERROR] Supported range: >= 1.14.0 and < 1.16.0."
    exit 1
fi

echo "[ZN-HomeProxy] sing-box package: $SB_VERSION"
echo "[ZN-HomeProxy] sing-box Makefile: $SB_MAKEFILE"

# ------------------------------------------------------------------
# 3. Download the private SRS bundle at firmware build time.
#
# This is deliberately independent of HomeProxy startup. Therefore a
# first boot cannot fail merely because the remote rule-set CDN is
# unreachable.
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
        echo "[ERROR] Neither curl nor wget is available on the build host."
        return 1
    fi
    [ -s "$out.tmp" ] || return 1
    mv -f "$out.tmp" "$out"
}

if [ "${ZN_SKIP_SRS:-0}" = "1" ]; then
    echo "[ZN-HomeProxy] ZN_SKIP_SRS=1: SRS download skipped."
else
    for FILE in "${!SRS_URLS[@]}"; do
        echo "[ZN-HomeProxy] SRS: $FILE"
        download_file "${SRS_URLS[$FILE]}" "$HP_SRS/$FILE" || {
            echo "[ERROR] Failed to download SRS: $FILE"
            rm -f "$HP_SRS/$FILE.tmp"
            exit 1
        }
    done
fi

# The three built-in rule-sets must exist; otherwise the generator would
# point sing-box at files that are absent from the firmware.
for FILE in \
    "cn.srs" \
    "geosite-geolocation-cn.srs" \
    "geosite-geolocation-!cn.srs"; do
    [ -s "$HP_SRS/$FILE" ] || {
        echo "[ERROR] Required private SRS missing or empty: $FILE"
        exit 1
    }
done

# ------------------------------------------------------------------
# 4. Convert the three built-in mainland rule-sets to local files.
#
# We patch only the exact upstream block. No UI or routing logic is copied
# from VIKINGYFY. This is the only HomeProxy generator modification.
# ------------------------------------------------------------------
python3 - "$GEN_FILE" "$GEN_FILE.tmp" "$SB_MINOR" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
sb_minor = int(sys.argv[3])
s = src.read_text()

marker = "if (routing_mode === 'bypass_mainland_china') {"
start = s.find(marker)
if start < 0:
    raise SystemExit("bypass_mainland_china block not found")

end_marker = "\n\tif (isEmpty(config.route.rule_set))"
end = s.find(end_marker, start)
if end < 0:
    raise SystemExit("end of bypass_mainland_china rule-set block not found")

block = s[start:end]

urls = [
    "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
    "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs",
    "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
]
for u in urls:
    if u not in block:
        raise SystemExit(f"expected upstream URL missing: {u}")

new_block = """if (routing_mode === 'bypass_mainland_china') {
\t\t/*
\t\t * ZN: bundled local SRS. Keeping these three rule-sets local avoids
\t\t * making the first HomeProxy startup depend on remote CDN access.
\t\t */
\t\tpush(config.route.rule_set, {
\t\t\ttype: 'local',
\t\t\ttag: 'geoip-cn',
\t\t\tformat: 'binary',
\t\t\tpath: HP_DIR + '/private_srs/cn.srs'
\t\t});
\t\tpush(config.route.rule_set, {
\t\t\ttype: 'local',
\t\t\ttag: 'geosite-cn',
\t\t\tformat: 'binary',
\t\t\tpath: HP_DIR + '/private_srs/geosite-geolocation-cn.srs'
\t\t});
\t\tpush(config.route.rule_set, {
\t\t\ttype: 'local',
\t\t\ttag: 'geosite-noncn',
\t\t\tformat: 'binary',
\t\t\tpath: HP_DIR + '/private_srs/geosite-geolocation-!cn.srs'
\t\t});
\t}
"""
s = s[:start] + new_block.rstrip("\n") + s[end:]

if sb_minor >= 15:
    s2, n = re.subn(r"(?m)^\s*stack: tcpip_stack,\n", "", s)
    if n != 1:
        raise SystemExit(f"sing-box 1.15.x expected one TUN stack field, got {n}")
    s = s2

dst.write_text(s)

PY
mv -f "$GEN_FILE.tmp" "$GEN_FILE"

# ------------------------------------------------------------------
# 5. Strict validation.
# ------------------------------------------------------------------
fail=0
pass_check() { printf '[PASS] %s\n' "$1"; }
fail_check() { printf '[FAIL] %s\n' "$1"; fail=1; }

if grep -q "path: HP_DIR + '/private_srs/cn.srs'" "$GEN_FILE"; then
    pass_check "geoip-cn -> local cn.srs"
else
    fail_check "geoip-cn -> local cn.srs"
fi

if grep -q "path: HP_DIR + '/private_srs/geosite-geolocation-cn.srs'" "$GEN_FILE"; then
    pass_check "geosite-cn -> local geosite-geolocation-cn.srs"
else
    fail_check "geosite-cn -> local geosite-geolocation-cn.srs"
fi

if grep -q "path: HP_DIR + '/private_srs/geosite-geolocation-!cn.srs'" "$GEN_FILE"; then
    pass_check "geosite-noncn -> local geosite-geolocation-!cn.srs"
else
    fail_check "geosite-noncn -> local geosite-geolocation-!cn.srs"
fi

if ! grep -q "raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs" "$GEN_FILE" &&
   ! grep -q "raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-cn.srs" "$GEN_FILE" &&
   ! grep -q "raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs" "$GEN_FILE"; then
    pass_check "three built-in mainland SRS are no longer remote"
else
    fail_check "three built-in mainland SRS still contain remote URLs"
fi

if [ "$SB_MINOR" -ge 15 ]; then
    if grep -q 'stack: tcpip_stack' "$GEN_FILE"; then
        fail_check "sing-box 1.15 TUN stack migration"
    else
        pass_check "sing-box 1.15 TUN stack migration"
    fi
fi

grep -q 'update_resources\.sh' "$UPDATE_CROND" &&
    pass_check "native update_crond -> update_resources.sh" ||
    fail_check "native update_crond -> update_resources.sh"

grep -q 'mkdir -p "\$RESOURCES_DIR"' "$UPDATE_RESOURCES" &&
    pass_check "native update_resources.sh preserved" ||
    fail_check "native update_resources.sh preserved"

if grep -q 'sing-box >= 1\.14\.0 required' "$INIT_FILE"; then
    pass_check "runtime sing-box minimum check >= 1.14"
else
    fail_check "runtime sing-box minimum check >= 1.14"
fi

if [ "$fail" -ne 0 ]; then
    echo "[ERROR] ZN HomeProxy validation failed."
    exit 1
fi

# ------------------------------------------------------------------
# 6. Persist private SRS across sysupgrade.
# ------------------------------------------------------------------
SYSUPGRADE_CONF="$ROOT/package/base-files/files/etc/sysupgrade.conf"
if [ -d "$ROOT/package/base-files" ]; then
    mkdir -p "$(dirname "$SYSUPGRADE_CONF")"
    if ! grep -qxF "$HP_SRS_REL/" "$SYSUPGRADE_CONF" 2>/dev/null; then
        echo "$HP_SRS_REL/" >> "$SYSUPGRADE_CONF"
        echo "[ZN-HomeProxy] Added $HP_SRS_REL/ to sysupgrade.conf"
    else
        echo "[ZN-HomeProxy] $HP_SRS_REL/ already exists in sysupgrade.conf"
    fi
fi

echo "[ZN-HomeProxy] Installed SRS:"
find "$HP_SRS" -maxdepth 1 -type f -name '*.srs' -printf '  %f %s bytes\n' 2>/dev/null |
    sort || true

echo "=== ZN HomeProxy processing complete ==="
