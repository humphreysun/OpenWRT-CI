#!/usr/bin/env bash
# Scripts/ZN-Packages.sh

set -Eeuo pipefail

# ============================================================
# 通用文件下载函数
# 用法：DOWNLOAD_FILE "源URL" "目标文件"
# ============================================================
DOWNLOAD_FILE() {
    local URL="$1"
    local DEST="$2"

    echo "[Download] $URL"
    echo "[Download] -> $DEST"

    mkdir -p "$(dirname "$DEST")"

    if ! curl -fsSL --retry 3 --retry-delay 2 -o "$DEST" "$URL"; then
        echo "[ERROR] Download failed: $URL"
        exit 1
    fi

    if [ ! -s "$DEST" ]; then
        echo "[ERROR] Downloaded file is empty: $DEST"
        exit 1
    fi
}

# ============================================================
# 安装和更新软件包（单仓库 / 大杂烩仓库模糊提取）
# 用法：UPDATE_PACKAGE "包名" "项目地址" "项目分支" "pkg，可选" "额外删除名称列表，可选"
# ============================================================
UPDATE_PACKAGE() {
    local PKG_NAME="$1"
    local PKG_REPO="$2"
    local PKG_BRANCH="$3"
    local PKG_SPECIAL="${4:-}"
    local EXTRA_NAMES="${5:-}"
    local REPO_NAME="${PKG_REPO#*/}"
    local REPO_PATH="./.package-repos/$REPO_NAME"

    local PKG_LIST=("$PKG_NAME")
    if [ -n "$EXTRA_NAMES" ]; then
        local EXTRA_LIST=()
        read -r -a EXTRA_LIST <<< "$EXTRA_NAMES"
        PKG_LIST+=("${EXTRA_LIST[@]}")
    fi

    echo
    echo "[ZN-Packages] Updating $PKG_NAME from $PKG_REPO@$PKG_BRANCH"

    # 删除本地 / feeds 中可能存在的同名或相关名称软件包
    for NAME in "${PKG_LIST[@]}"; do
        echo "[ZN-Packages] Searching directory: $NAME"
        local FOUND=0
        while IFS= read -r -d '' DIR; do
            rm -rf "$DIR"
            echo "[ZN-Packages] Deleted directory: $DIR"
            FOUND=1
        done < <(
            find ./feeds/luci ./feeds/packages ./package \
                -maxdepth 4 -type d \
                -iname "*${NAME}*" -print0 2>/dev/null
        )
        [ "$FOUND" -eq 1 ] || echo "[ZN-Packages] Not found directory: $NAME"
    done

    # 克隆仓库到 package 目录之外的临时位置，避免污染编译树
    rm -rf "$REPO_PATH"
    mkdir -p "$(dirname "$REPO_PATH")"

    if ! git clone --depth=1 --single-branch \
        --branch "$PKG_BRANCH" \
        "https://github.com/$PKG_REPO.git" \
        "$REPO_PATH"; then
        echo "[ERROR] Failed to clone: $PKG_REPO"
        exit 1
    fi

    if [ "$PKG_SPECIAL" = "pkg" ]; then
        # 从大杂烩仓库中单独提取匹配的包目录
        local IMPORTED=0
        while IFS= read -r -d '' DIR; do
            cp -a "$DIR" ./package/
            echo "[ZN-Packages] Imported: $DIR"
            IMPORTED=1
        done < <(
            find "$REPO_PATH" -type d \
                -iname "*${PKG_NAME}*" -print0
        )

        if [ "$IMPORTED" -eq 0 ]; then
            echo "[ERROR] Package directory not found: $PKG_NAME"
            rm -rf "$REPO_PATH"
            exit 1
        fi

        rm -rf "$REPO_PATH"
    else
        cp -a "$REPO_PATH" "./package/$REPO_NAME"
        rm -rf "$REPO_PATH"
    fi

    echo "[ZN-Packages] $PKG_NAME imported."
}

# ============================================================
# 从多软件包集合仓库精确提取指定包目录（递归支持子目录）
# 用法：IMPORT_PACKAGE_FROM_REPO "包目录名" "仓库地址" "分支，默认 main"
# ============================================================
IMPORT_PACKAGE_FROM_REPO() {
    local PKG_DIR="$1"
    local PKG_REPO="$2"
    local PKG_BRANCH="${3:-main}"
    local TMP_DIR="./.package-repos/${PKG_REPO##*/}"

    echo
    echo "[ZN-Packages] Importing $PKG_DIR from $PKG_REPO@$PKG_BRANCH"

    while IFS= read -r -d '' DIR; do
        rm -rf "$DIR"
        echo "[ZN-Packages] Deleted directory: $DIR"
    done < <(
        find ./feeds/luci ./feeds/packages ./package \
            -maxdepth 4 -type d \
            -iname "*${PKG_DIR}*" -print0 2>/dev/null
    )

    rm -rf "$TMP_DIR"
    mkdir -p "$(dirname "$TMP_DIR")"

    if ! git clone --depth=1 --filter=blob:none --no-checkout \
        --single-branch --branch "$PKG_BRANCH" \
        "https://github.com/$PKG_REPO.git" \
        "$TMP_DIR"; then
        echo "[ERROR] Failed to clone: $PKG_REPO"
        exit 1
    fi

    if ! git -C "$TMP_DIR" sparse-checkout init --cone; then
        echo "[ERROR] Failed to initialize sparse checkout"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    if ! git -C "$TMP_DIR" sparse-checkout set "$PKG_DIR"; then
        echo "[ERROR] Package path not found: $PKG_DIR"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    # 关键补丁：sparse-checkout 只写配置，需要 checkout 才会真正取回文件
    if ! git -C "$TMP_DIR" checkout "$PKG_BRANCH"; then
        echo "[ERROR] Checkout failed: $PKG_BRANCH"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    if [ ! -f "$TMP_DIR/$PKG_DIR/Makefile" ]; then
        echo "[ERROR] Makefile not found: $TMP_DIR/$PKG_DIR/Makefile"
        rm -rf "$TMP_DIR"
        exit 1
    fi

    cp -a "$TMP_DIR/$PKG_DIR" "./package/"
    rm -rf "$TMP_DIR"

    echo "[ZN-Packages] $PKG_DIR imported successfully."
}

# ============================================================
# 软件包调用列表
# UPDATE_PACKAGE "包名" "项目地址" "项目分支" "pkg，可选，从大杂烩中单独提取包名插件"
# ============================================================
UPDATE_PACKAGE "argon" "sbwml/luci-theme-argon" "openwrt-25.12"
UPDATE_PACKAGE "aurora" "eamonxg/luci-theme-aurora" "master"
UPDATE_PACKAGE "aurora-config" "eamonxg/luci-app-aurora-config" "master"
UPDATE_PACKAGE "kucat" "sirpdboy/luci-theme-kucat" "master"
UPDATE_PACKAGE "kucat-config" "sirpdboy/luci-app-kucat-config" "master"
UPDATE_PACKAGE "noobwrt" "nooblk-98/luci-theme-noobwrt" "master"
UPDATE_PACKAGE "shadcn" "eamonxg/luci-theme-shadcn" "main"
UPDATE_PACKAGE "theme-fluent" "LazuliKao/luci-theme-fluent" "main"

# ============================================================
# VIKINGYFY 最新 sing-box（精确提取，替代原 UPDATE_PACKAGE "pkg" 方式）
# ============================================================
echo "[ZN-Packages] Importing VIKINGYFY sing-box..."

IMPORT_PACKAGE_FROM_REPO "sing-box" "VIKINGYFY/packages" "main"

# homeproxy-pro（使用支持官方5个路由模式的源，只保留一次调用）
rm -rf ./package/luci-app-homeproxy
UPDATE_PACKAGE "luci-app-homeproxy" "szwjp/luci-app-homeproxy-pro" "main"

find . -maxdepth 4 -type d \( -name "*timecontrol*" \) -exec rm -rf {} + 2>/dev/null || true
UPDATE_PACKAGE "luci-app-timecontrol" "gaobin89/luci-app-timecontrol" "js" "" "timecontrol"

UPDATE_PACKAGE "natmapt" "muink/openwrt-natmapt" "master"
UPDATE_PACKAGE "stuntman" "muink/openwrt-stuntman" "master"
UPDATE_PACKAGE "luci-app-natmapt" "muink/luci-app-natmapt" "master"

find . -maxdepth 4 -type d \( -name "*gecoosac*" \) -exec rm -rf {} + 2>/dev/null || true
UPDATE_PACKAGE "luci-app-gecoosac" "laipeng668/luci-app-gecoosac" "main" "" "gecoosac"

UPDATE_PACKAGE "openwrt-bandix" "timsaya/openwrt-bandix" "main" "" "openwrt-bandix"
UPDATE_PACKAGE "luci-app-bandix" "timsaya/luci-app-bandix" "main" "" "luci-app-bandix"


# ============================================================
# 更新软件包版本
# ============================================================
UPDATE_VERSION() {
    local PKG_NAME="$1"
    local PKG_MARK="${2:-false}"

    local PKG_FILES=()
    mapfile -t PKG_FILES < <(
        find ./ ./feeds/packages/ \
            -maxdepth 3 -type f \
            -wholename "*/$PKG_NAME/Makefile" 2>/dev/null
    )

    if [ "${#PKG_FILES[@]}" -eq 0 ]; then
        echo "[ZN-Packages] $PKG_NAME not found!"
        return 0
    fi

    echo
    echo "[ZN-Packages] $PKG_NAME version update started!"

    for PKG_FILE in "${PKG_FILES[@]}"; do
        local PKG_REPO
        PKG_REPO=$(grep -Po "PKG_SOURCE_URL:=https://.*github.com/\K[^/]+/[^/]+(?=.*)" "$PKG_FILE" || true)

        [ -n "$PKG_REPO" ] || {
            echo "[ZN-Packages] Skip $PKG_FILE: no GitHub source URL found."
            continue
        }

        local PKG_TAG
        PKG_TAG=$(curl -fsSL "https://api.github.com/repos/$PKG_REPO/releases" \
            | jq -r "map(select(.prerelease == $PKG_MARK)) | first | .tag_name" \
            || true)

        [ -n "$PKG_TAG" ] && [ "$PKG_TAG" != "null" ] || {
            echo "[ZN-Packages] Skip $PKG_NAME: no release found for $PKG_REPO."
            continue
        }

        local OLD_VER OLD_URL OLD_FILE OLD_HASH
        OLD_VER=$(grep -Po "PKG_VERSION:=\K.*" "$PKG_FILE" || true)
        OLD_URL=$(grep -Po "PKG_SOURCE_URL:=\K.*" "$PKG_FILE" || true)
        OLD_FILE=$(grep -Po "PKG_SOURCE:=\K.*" "$PKG_FILE" || true)
        OLD_HASH=$(grep -Po "PKG_HASH:=\K.*" "$PKG_FILE" || true)

        # 支持 git 源（git.+ 格式 URL），直接构造 releases 下载地址
        local PKG_URL
        if [[ "$OLD_URL" == *"/archive/"* ]] || [[ "$OLD_URL" == *"/releases/"* ]]; then
            PKG_URL="$OLD_URL"
            [[ "$PKG_URL" == *"/releases/"* ]] && PKG_URL="${PKG_URL%/}/$OLD_FILE"
        else
            PKG_URL="https://github.com/$PKG_REPO/archive/refs/tags"
        fi

        local NEW_VER
        NEW_VER=$(echo "$PKG_TAG" | sed -E 's/[^0-9]+/\./g; s/^\.|\.$//g')

        local NEW_URL NEW_HASH
        NEW_URL=$(echo "$PKG_URL" | sed "s/\$(PKG_VERSION)/$NEW_VER/g; s/\$(PKG_NAME)/$PKG_NAME/g")
        NEW_HASH=$(curl -fsSL "$NEW_URL" | sha256sum | cut -d ' ' -f 1)

        echo "old version: $OLD_VER $OLD_HASH"
        echo "new version: $NEW_VER $NEW_HASH"

        if [[ "$NEW_VER" =~ ^[0-9] ]] && [ -n "$OLD_VER" ] \
            && dpkg --compare-versions "$OLD_VER" lt "$NEW_VER"; then
            sed -i "s/PKG_VERSION:=.*/PKG_VERSION:=$NEW_VER/g" "$PKG_FILE"
            sed -i "s/PKG_HASH:=.*/PKG_HASH:=$NEW_HASH/g" "$PKG_FILE"
            echo "[ZN-Packages] $PKG_FILE version has been updated!"
        else
            echo "[ZN-Packages] $PKG_FILE version is already the latest!"
        fi
    done
}

#UPDATE_VERSION "软件包名" "测试版，true，可选，默认为否"
#UPDATE_VERSION "sing-box"

# ============================================================
# 引入私有扩展脚本
# ============================================================
if [ -f "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh" ]; then
    # shellcheck disable=SC1091
    source "$GITHUB_WORKSPACE/Scripts/PRIVATE.sh"
fi
