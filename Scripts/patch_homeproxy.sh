#!/bin/bash
SEARCH_BASE="${PKG_PATH:-.}"
HP_TARGET_DIR=$(find "$SEARCH_BASE" -maxdepth 3 -type d -name "*homeproxy*" -print -quit)

if [ -n "$HP_TARGET_DIR" ]; then
  TARGET_SRS_DIR="$HP_TARGET_DIR/root/etc/homeproxy/private_srs"
else
  TARGET_SRS_DIR="files/etc/homeproxy/private_srs"
fi
mkdir -p "$TARGET_SRS_DIR"

RAW_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite"
for file in google.srs private.srs category-ads-all.srs cn.srs 'geolocation-!cn.srs' anthropic.srs openai.sr; do
  curl -sSL "$RAW_URL/$file" -o "$TARGET_SRS_DIR/$file"
done

# 编译期清理面板无用字体
if [ -n "$HP_TARGET_DIR" ]; then
  ABS_RM="$HP_TARGET_DIR/root/etc/homeproxy/dashboard/assets/ibm-plex-mono-cyrillic-400-normal-BSMlKf0J.woff2"
  [ -f "$ABS_RM" ] && rm -f "$ABS_RM"
fi

# 注入运行期更新逻辑与四个核心函数的优化
if [ -n "$HP_TARGET_DIR" ]; then
  ts=$(find "$HP_TARGET_DIR" -type f -name "update_resources.sh" -print -quit)
  if [ -f "$ts" ] && ! grep -qF "update_private_srs" "$ts"; then
    
    # 1. 在脚本尾部追加定义 update_private_srs 函数
    cat << 'EOF' >> "$ts"

update_private_srs() {
    mkdir -p /etc/homeproxy/private_srs
    local srs_base_url="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite"
    for file in google.srs private.srs category-ads-all.srs cn.srs "geolocation-!cn.srs anthropic.srs openai.sr"; do
        run_curl -fsSL "$srs_base_url/$file" -o "/etc/homeproxy/private_srs/$file"
    done
    rm -f "$DASHBOARD_DIR/assets/ibm-plex-mono-cyrillic-400-normal-BSMlKf0J.woff2" 2>/dev/null
}
EOF

    # 2. 使用 awk 替换原有脚本中的 download、版本获取等函数，并引入动态端口探测
    awk -i inplace '
    /UPDATE_PROXY="\${HOMEPROXY_UPDATE_PROXY:-\}"/ {
        print
        print ""
        print "# 动态智能检测当前 sing-box 或代理所使用的本地端口"
        print "if [ -z \"$UPDATE_PROXY\" ]; then"
        print "    for p in $(netstat -tln 2>/dev/null | awk '\''{print $4}'\'' | awk -F'\x27:\x27 '\''{print $NF}'\'' | sort -u); do"
        print "        if [ \"$p\" -ge 1024 ] && [ \"$p\" -le 65535 ] && nc -z 127.0.0.1 \"$p\" 2>/dev/null; then"
        print "            # 简单验证是否含有代理特征或直接采纳活跃的本地代理端口"
        print "            UPDATE_PROXY=\"http://127.0.0.1:$p\""
        print "            break"
        print "        fi"
        print "    done"
        print "fi"
        next
    }

    # 优化 download 函数（强制 HTTP/1.1、增加重试与超时）
    /^download\(\) \{/,/^\}/ {
        print "download() {"
        print "    local source_url=\"$1\""
        print "    local target_file=\"$2\""
        print ""
        print "    run_curl -fsSL --http1.1 --compressed --retry 10 --retry-all-errors --retry-delay 3 \\"
        print "        --connect-timeout 30 --max-time 300 \\"
        print "        -A \"$USER_AGENT\" \\"
        print "        -o \"$target_file\" \"$source_url\" && [ -s \"$target_file\" ]"
        print "}"
        next
    }

    # 优化 fetch_release_version 函数
    /^fetch_release_version\(\) \{/,/^\}/ {
        print "fetch_release_version() {"
        print "    local release_url=\"$1\""
        print "    local effective_url"
        print ""
        print "    effective_url=\"$(run_curl -fsSL --http1.1 --compressed --retry 5 --retry-all-errors --retry-delay 2 \\"
        print "        --connect-timeout 20 --max-time 60 \\"
        print "        -A \"$USER_AGENT\" -o \"/dev/null\" -w '\''%{url_effective}'\'' \"$release_url\")\" || return 1"
        print "    local release_version=\"${effective_url##*/}\""
        print "    case \"$release_version\" in"
        print "    '\'''\''|*[!0-9]*) return 1 ;;"
        print "    esac"
        print "    printf '\''%s\\n'\'' \"$release_version\""
        print "}"
        next
    }

    # 优化 fetch_dashboard_version (原 versioned_url) 函数
    /^versioned_url\(\) \{/,/^\}/ {
        print "fetch_dashboard_version() {"
        print "    local feed version"
        print "    feed=\"$(run_curl -fsSL --http1.1 --compressed --retry 5 --retry-all-errors --retry-delay 2 \\"
        print "        --connect-timeout 20 --max-time 60 -A \"$USER_AGENT\" \"$DASHBOARD_VERSION_URL\")\" || return 1"
        print "    version=\"$(printf '\''%s\\n'\'' \"$feed\" | awk -F '\''[<>]'\'' '\''"
        print "        /<updated>/ {"
        print "            version = $3"
        print "            gsub(/[-:TZ]/, \"\", version)"
        print "            print version"
        print "            exit"
        print "        }"
        print "    '\'')\""
        print "    case \"$version\" in"
        print "    ??????????????) case \"$version\" in *[!0-9]*) return 1 ;; esac ;;"
        print "    *) return 1 ;;"
        print "    esac"
        print "    printf '\''%s\\n'\'' \"$version\""
        print "}"
        next
    }

    # 在 dashboard 更新成功后触发私有 srs 更新
    /\[dashboard\] Successfully updated\./ {
        print
        print "            update_private_srs"
        next
    }
    { print }
    ' "$ts"

    chmod +x "$ts"
  fi
fi
