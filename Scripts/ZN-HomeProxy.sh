#!/bin/bash
set -euo pipefail

echo "=== ZN HomeProxy: 预置 SRS + patch generate_client.uc ==="

PKG_PATH="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}/wrt/package"
HP_PATH="$PKG_PATH/homeproxy"
HP_ROOT="$HP_PATH/root/etc/homeproxy"
HP_SRS="$HP_ROOT/private_srs"
GEN_FILE="$HP_ROOT/scripts/generate_client.uc"
SYSUPGRADE_CONF="$PKG_PATH/base-files/files/etc/sysupgrade.conf"

if [ ! -d "$HP_PATH" ]; then
    echo "[ZN-HomeProxy] HomeProxy package not found, skip."
    exit 0
fi

if [ ! -f "$GEN_FILE" ]; then
    echo "[ERROR] generate_client.uc not found: $GEN_FILE"
    exit 1
fi

# ---------- 1. 下载预置 SRS ----------
echo "[ZN-HomeProxy] Download official SRS..."
mkdir -p "$HP_SRS"

declare -A SRS_URLS=(
    ["cn.srs"]="https://fastly.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs"
    ["geosite-geolocation-cn.srs"]="https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs"
    ["geosite-geolocation-!cn.srs"]="https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-!cn.srs"
    ["geosite-google.srs"]="https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-google.srs"
    ["geosite-openai.srs"]="https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-openai.srs"
    ["geosite-anthropic.srs"]="https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-anthropic.srs"
    ["geosite-whatsapp.srs"]="https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-whatsapp.srs"
    ["geosite-zoom.srs"]="https://fastly.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-zoom.srs"
)

for FILE in "${!SRS_URLS[@]}"; do
    URL="${SRS_URLS[$FILE]}"
    echo "[ZN-HomeProxy] Download: $FILE"
    if ! curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$HP_SRS/$FILE" "$URL"; then
        echo "[ERROR] Failed to download: $URL"
        exit 1
    fi
    if [ ! -s "$HP_SRS/$FILE" ]; then
        echo "[ERROR] Empty SRS file: $HP_SRS/$FILE"
        exit 1
    fi
done

echo "[ZN-HomeProxy] All SRS downloaded successfully."

# ---------- 2. 关键 SRS 完整性复查 ----------
for FILE in cn.srs geosite-geolocation-cn.srs 'geosite-geolocation-!cn.srs'; do
    if [ ! -s "$HP_SRS/$FILE" ]; then
        echo "[ERROR] Invalid or empty SRS: $HP_SRS/$FILE"
        exit 1
    fi
done

echo "[ZN-HomeProxy] Preloaded SRS:"
ls -lh "$HP_SRS"

# ---------- 3. 修补 generate_client.uc ----------
if grep -qF "path: '/etc/homeproxy/private_srs/cn.srs'" "$GEN_FILE"; then
    echo "[ZN-HomeProxy] generate_client.uc already patched."
else
    echo "[ZN-HomeProxy] Patching generate_client.uc..."
    cp -f "$GEN_FILE" "$GEN_FILE.zn-original"
    python3 - "$GEN_FILE" <<'PY'
import sys
from pathlib import Path

file = Path(sys.argv[1])
text = file.read_text(encoding="utf-8")

replacements = [
    ("""                push(config.route.rule_set, {
                        type: 'remote',
                        tag: 'geoip-cn',
                        format: 'binary',
                        url: 'https://fastly.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs',
                        download_detour: 'main-out'
                });""",
     """                push(config.route.rule_set, {
                        type: 'local',
                        tag: 'geoip-cn',
                        format: 'binary',
                        path: '/etc/homeproxy/private_srs/cn.srs'
                });"""),
    ("""                push(config.route.rule_set, {
                        type: 'remote',
                        tag: 'geosite-cn',
                        format: 'binary',
                        url: 'https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs',
                        download_detour: 'main-out'
                });""",
     """                push(config.route.rule_set, {
                        type: 'local',
                        tag: 'geosite-cn',
                        format: 'binary',
                        path: '/etc/homeproxy/private_srs/geosite-geolocation-cn.srs'
                });"""),
    ("""                push(config.route.rule_set, {
                        type: 'remote',
                        tag: 'geosite-noncn',
                        format: 'binary',
                        url: 'https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-!cn.srs',
                        download_detour: 'main-out'
                });""",
     """                push(config.route.rule_set, {
                        type: 'local',
                        tag: 'geosite-noncn',
                        format: 'binary',
                        path: '/etc/homeproxy/private_srs/geosite-geolocation-!cn.srs'
                });"""),
]

missing = [old for old, _ in replacements if old not in text]
if missing:
    print(f"[ERROR] {len(missing)} patch target(s) not found, file NOT modified:")
    for m in missing:
        print("  -", m.splitlines()[0].strip())
    sys.exit(1)

for old, new in replacements:
    text = text.replace(old, new, 1)

tmp = file.with_suffix(file.suffix + ".zn-tmp")
tmp.write_text(text, encoding="utf-8")
tmp.replace(file)
print("[OK] generate_client.uc patched.")
PY
fi

# ---------- 4. 验证修补结果 ----------
echo "=== Verify HomeProxy RuleSet ==="
if ! grep -A5 -B1 -E "tag: '(geoip-cn|geosite-cn|geosite-noncn)'" "$GEN_FILE"; then
    echo "[ERROR] Verification failed: patched rule_set not found in $GEN_FILE"
    exit 1
fi
echo "=== ZN HomeProxy processing complete ==="

# ---------- 5. 固件升级保留 ----------
mkdir -p "$(dirname "$SYSUPGRADE_CONF")"
if ! grep -qxF "/etc/homeproxy/private_srs/" "$SYSUPGRADE_CONF" 2>/dev/null; then
    echo "/etc/homeproxy/private_srs/" >> "$SYSUPGRADE_CONF"
    echo "[ZN-HomeProxy] Added private_srs to sysupgrade.conf"
else
    echo "[ZN-HomeProxy] private_srs already exists in sysupgrade.conf"
fi
