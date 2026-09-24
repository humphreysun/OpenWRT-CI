#!/usr/bin/env bash
set -euo pipefail

echo "=== ZN HomeProxy: 预置 SRS + patch generate_client.uc ==="

PKG_PATH="${GITHUB_WORKSPACE}/wrt/package"
HP_PATH="$PKG_PATH/homeproxy"
HP_ROOT="$HP_PATH/root/etc/homeproxy"
HP_SRS="$HP_ROOT/private_srs"
GEN_FILE="$HP_ROOT/scripts/generate_client.uc"

if [ ! -d "$HP_PATH" ]; then
    echo "[ZN-HomeProxy] HomeProxy package not found, skip."
    exit 0
fi

if [ ! -f "$GEN_FILE" ]; then
    echo "[ERROR] generate_client.uc not found:"
    echo "$GEN_FILE"
    exit 1
fi


# ============================================================
# 1. 下载 SRS
# ============================================================

echo "[ZN-HomeProxy] Download official SRS..."

mkdir -p "$HP_SRS"

declare -A SRS_URLS

SRS_URLS["cn.srs"]="https://fastly.jsdelivr.net/gh/1715173329/IPCIDR-CHINA@rule-set/cn.srs"

SRS_URLS["geosite-geolocation-cn.srs"]="https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-cn.srs"

SRS_URLS["geosite-geolocation-!cn.srs"]="https://fastly.jsdelivr.net/gh/1715173329/sing-geosite@rule-set-unstable/geosite-geolocation-!cn.srs"

SRS_URLS["geosite-google.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-google.srs"

SRS_URLS["geosite-openai.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"

SRS_URLS["geosite-anthropic.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-anthropic.srs"

SRS_URLS["geosite-whatsapp.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-whatsapp.srs"

SRS_URLS["geosite-zoom.srs"]="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-zoom.srs"


for FILE in "${!SRS_URLS[@]}"; do
    URL="${SRS_URLS[$FILE]}"

    echo "[ZN-HomeProxy] Download: $FILE"

    if ! curl -fL \
        --retry 3 \
        --retry-delay 2 \
        -o "$HP_SRS/$FILE" \
        "$URL"
    then
        echo "[ERROR] Failed to download:"
        echo "  $URL"
        exit 1
    fi

    if [ ! -s "$HP_SRS/$FILE" ]; then
        echo "[ERROR] Empty SRS file:"
        echo "  $HP_SRS/$FILE"
        exit 1
    fi
done


echo "[ZN-HomeProxy] All SRS downloaded successfully."


# ============================================================
# 2. 检查三个需要替换的远程 RuleSet
# ============================================================

for TAG in geoip-cn geosite-cn geosite-noncn; do
    if ! grep -q "tag: '$TAG'," "$GEN_FILE"; then
        echo "[ERROR] Patch target not found: $TAG"
        exit 1
    fi
done


# ============================================================
# 3. 备份 generate_client.uc
# ============================================================

PATCH_BACKUP="$GEN_FILE.zn-original"

cp -f "$GEN_FILE" "$PATCH_BACKUP"

echo "[ZN-HomeProxy] Backup created:"
echo "$PATCH_BACKUP"


# ============================================================
# 4. Patch RuleSet
# ============================================================

echo "[ZN-HomeProxy] Patching generate_client.uc..."

awk '
function emit(tag, path) {
    print "                push(config.route.rule_set, {"
    print "                        type: '\''local'\'',"
    print "                        tag: '\''" tag "'\'',"
    print "                        format: '\''binary'\'',"
    print "                        path: '\''" path "'\''"
    print "                });"
}

{
    # 找到目标 RuleSet 的 tag
    if ($0 ~ /tag: '\''geoip-cn'\'',/) {
        emit("geoip-cn", "/etc/homeproxy/private_srs/cn.srs")
        skip = 1
        next
    }

    if ($0 ~ /tag: '\''geosite-cn'\'',/) {
        emit("geosite-cn", "/etc/homeproxy/private_srs/geosite-geolocation-cn.srs")
        skip = 1
        next
    }

    if ($0 ~ /tag: '\''geosite-noncn'\'',/) {
        emit("geosite-noncn", "/etc/homeproxy/private_srs/geosite-geolocation-!cn.srs")
        skip = 1
        next
    }

    # 删除原 RuleSet 对象剩余内容
    if (skip) {
        if ($0 ~ /^[[:space:]]*}\);[[:space:]]*$/) {
            skip = 0
        }
        next
    }

    print
}
' "$GEN_FILE" > "$GEN_FILE.tmp"

mv -f "$GEN_FILE.tmp" "$GEN_FILE"


# ============================================================
# 5. Patch 验证
# ============================================================

echo "[ZN-HomeProxy] Verifying patch..."

if ! grep -q "tag: 'geoip-cn'," "$GEN_FILE" ||
   ! grep -q "type: 'local'," "$GEN_FILE" ||
   ! grep -q "path: '/etc/homeproxy/private_srs/cn.srs'" "$GEN_FILE"
then
    echo "[ERROR] geoip-cn patch verification failed"
    cp -f "$PATCH_BACKUP" "$GEN_FILE"
    exit 1
fi


if ! grep -q "tag: 'geosite-cn'," "$GEN_FILE" ||
   ! grep -q "path: '/etc/homeproxy/private_srs/geosite-geolocation-cn.srs'" "$GEN_FILE"
then
    echo "[ERROR] geosite-cn patch verification failed"
    cp -f "$PATCH_BACKUP" "$GEN_FILE"
    exit 1
fi


if ! grep -q "tag: 'geosite-noncn'," "$GEN_FILE" ||
   ! grep -q "path: '/etc/homeproxy/private_srs/geosite-geolocation-!cn.srs'" "$GEN_FILE"
then
    echo "[ERROR] geosite-noncn patch verification failed"
    cp -f "$PATCH_BACKUP" "$GEN_FILE"
    exit 1
fi


# 确认三个目标已经不再使用远程下载
if grep -A6 -B1 -E "tag: '(geoip-cn|geosite-cn|geosite-noncn)'" "$GEN_FILE" |
   grep -q "download_detour: 'main-out'"
then
    echo "[ERROR] Remote download_detour still exists in patched RuleSet"
    cp -f "$PATCH_BACKUP" "$GEN_FILE"
    exit 1
fi


echo "[ZN-HomeProxy] Patch verification passed."


# ============================================================
# 6. 显示最终 RuleSet
# ============================================================

echo "=== Verify HomeProxy RuleSet ==="

grep -A5 -B1 \
    -E "tag: '(geoip-cn|geosite-cn|geosite-noncn)'" \
    "$GEN_FILE"


# ============================================================
# 7. 加入 sysupgrade.conf
# ============================================================

SYSUPGRADE_CONF="$PKG_PATH/base-files/files/etc/sysupgrade.conf"

mkdir -p "$(dirname "$SYSUPGRADE_CONF")"

if ! grep -qxF "/etc/homeproxy/private_srs/" "$SYSUPGRADE_CONF" 2>/dev/null; then

    echo "/etc/homeproxy/private_srs/" >> "$SYSUPGRADE_CONF"

    echo "[ZN-HomeProxy] Added private_srs to sysupgrade.conf"

else

    echo "[ZN-HomeProxy] private_srs already exists in sysupgrade.conf"

fi


echo "=== ZN HomeProxy processing complete ==="
