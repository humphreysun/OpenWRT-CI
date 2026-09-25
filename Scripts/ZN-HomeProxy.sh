# ZN-HomeProxy V7
#
# Design:
#   1. Always remove existing luci-app-homeproxy source from the build tree.
#   2. Always fetch the upstream HomeProxy source.
#   3. Prefer szwjp/luci-app-homeproxy, fallback to htcnokia/luci-app-homeproxy.
#   4. Do not hard-code sing-box version compatibility.
#   5. Download required SRS files at build time.
#   6. Only localize the three built-in rule-sets:
#        geoip-cn
#        geosite-cn
#        geosite-noncn
#   7. Replace the complete RuleSet object, rather than patching individual
#      properties, so upstream remote/local implementation changes do not
#      leak into the final configuration.
#   8. Keep all other upstream HomeProxy logic untouched.
#   9. Persist /etc/homeproxy/private_srs through sysupgrade.
#
# Usage:
#   Scripts/ZN-HomeProxy.sh
#
# Optional:
#   ZN_HOMEProxy_BRANCH=some-branch Scripts/ZN-HomeProxy.sh
#
# If ZN_HOMEProxy_BRANCH is not set, git clone uses the repository's
# default branch automatically.

set -euo pipefail

ROOT="${1:-${GITHUB_WORKSPACE:-.}}"
ROOT="$(cd "$ROOT" && pwd)"

PRIMARY_REPO="https://github.com/szwjp/luci-app-homeproxy.git"
FALLBACK_REPO="https://github.com/htcnokia/luci-app-homeproxy.git"

# Empty means: use repository default branch.
HP_BRANCH="${ZN_HOMEProxy_BRANCH:-}"

PACKAGE_DIR="$ROOT/package"
TARGET_DIR="$PACKAGE_DIR/luci-app-homeproxy"

TMP_ROOT="$ROOT/.zn-homeproxy-tmp"
TMP_HP="$TMP_ROOT/luci-app-homeproxy"

SRS_DIR="$TARGET_DIR/root/etc/homeproxy/private_srs"

SYSUPGRADE_FILE="$ROOT/package/base-files/files/etc/sysupgrade.conf"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

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

pass() {
	printf '[ZN-HomeProxy][PASS] %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# Basic helpers
# ---------------------------------------------------------------------------

require_command() {
	local cmd="$1"

	command -v "$cmd" >/dev/null 2>&1 || \
		die "Required command not found: $cmd"
}

is_homeproxy_lineage() {
	local dir="$1"
	local makefile="$dir/Makefile"

	[ -f "$makefile" ] || return 1

	grep -Eq \
		'(^|[[:space:]])PKG_NAME:?=[[:space:]]*luci-app-homeproxy([[:space:]]|$)|(^|[[:space:]])LUCI_PKGARCH:?=[[:space:]]*all' \
		"$makefile" || return 1

	return 0
}

repo_origin_matches() {
	local dir="$1"
	local expected="$2"
	local origin=""

	[ -d "$dir/.git" ] || return 1

	origin="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"

	[ "$origin" = "$expected" ] ||
		[ "$origin" = "${expected%.git}" ] ||
		[ "$origin" = "${expected%.git}/" ]
}

# ---------------------------------------------------------------------------
# Remove every existing luci-app-homeproxy source
# ---------------------------------------------------------------------------

remove_existing_homeproxy() {
	local found=0
	local path=""

	log "Scanning for existing luci-app-homeproxy sources..."

	while IFS= read -r -d '' path; do
		found=1
		log "Removing existing source: $path"
		rm -rf -- "$path"
	done < <(
		find "$ROOT" \
			-path "$ROOT/.git" -prune -o \
			-path "$ROOT/.zn-homeproxy-tmp" -prune -o \
			-type d \
			-name 'luci-app-homeproxy' \
			-print0
	)

	if [ "$found" -eq 0 ]; then
		log "No existing luci-app-homeproxy source found."
	fi

	mkdir -p "$PACKAGE_DIR"
	rm -rf -- "$TARGET_DIR"
}

# ---------------------------------------------------------------------------
# Fetch HomeProxy
# ---------------------------------------------------------------------------

fetch_homeproxy() {
	local repo=""
	local target=""
	local clone_args=()

	mkdir -p "$TMP_ROOT"
	rm -rf -- "$TMP_HP"

	for repo in "$PRIMARY_REPO" "$FALLBACK_REPO"; do
		rm -rf -- "$TMP_HP"

		log "Trying upstream: $repo"

		clone_args=(clone --depth 1)

		if [ -n "$HP_BRANCH" ]; then
			clone_args+=(--branch "$HP_BRANCH")
			log "Requested HomeProxy branch: $HP_BRANCH"
		else
			log "HomeProxy branch: repository default"
		fi

		clone_args+=("$repo" "$TMP_HP")

		if ! git "${clone_args[@]}" >/dev/null 2>&1; then
			warn "Failed to clone: $repo"
			continue
		fi

		if ! is_homeproxy_lineage "$TMP_HP"; then
			warn "Cloned repository does not look like a complete HomeProxy package: $repo"
			rm -rf -- "$TMP_HP"
			continue
		fi

		target="$TARGET_DIR"

		rm -rf -- "$target"
		mv "$TMP_HP" "$target"

		if ! is_homeproxy_lineage "$target"; then
			die "Selected path is not a complete HomeProxy package: $target"
		fi

		if ! repo_origin_matches "$target" "$repo"; then
			warn "Unable to verify git origin after move: $target"
		fi

		log "Using HomeProxy source: $repo"
		printf '%s\n' "$target"
		return 0
	done

	die "Unable to obtain a valid HomeProxy source from either upstream repository."
}

# ---------------------------------------------------------------------------
# SRS definitions
# ---------------------------------------------------------------------------

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
	local output="$2"
	local tmp="${output}.tmp"

	rm -f -- "$tmp"

	log "Downloading SRS: $(basename "$output")"

	if ! curl \
		-fL \
		--retry 3 \
		--retry-delay 2 \
		--connect-timeout 20 \
		--max-time 180 \
		-sS \
		"$url" \
		-o "$tmp"
	then
		rm -f -- "$tmp"
		die "Failed to download: $url"
	fi

	[ -s "$tmp" ] ||
		die "Downloaded SRS is empty: $url"

	# Reject obvious HTTP error pages / HTML responses accidentally saved
	# with a successful HTTP transport status.
	if LC_ALL=C head -c 1024 "$tmp" 2>/dev/null |
		tr '[:upper:]' '[:lower:]' |
		grep -Eq \
			'<!doctype[[:space:]]+html|<html([[:space:]>]|$)|<head([[:space:]>]|$)|<body([[:space:]>]|$)|404:[[:space:]]*not[[:space:]]*found|accessdenied|error[[:space:]]*code'
	then
		rm -f -- "$tmp"
		die "Downloaded file appears to be an HTML/error response: $url"
	fi

	mv -f -- "$tmp" "$output"
}

download_srs() {
	local name=""
	local url=""

	mkdir -p "$SRS_DIR"

	for name in "${!SRS_URLS[@]}"; do
		url="${SRS_URLS[$name]}"
		download_file "$url" "$SRS_DIR/$name"
	done
}

# ---------------------------------------------------------------------------
# Replace complete RuleSet objects
#
# Important:
#   We do NOT search for:
#       type: 'remote'
#       url: ...
#       download_detour: ...
#
# Instead, we identify the complete push(config.route.rule_set, {...})
# object by its tag and replace the whole object.
#
# This makes the patch tolerant of upstream changes to the implementation
# of remote/local RuleSets.
# ---------------------------------------------------------------------------

patch_rulesets() {
	local script="$TMP_ROOT/patch_rulesets.py"

	cat > "$script" <<'PY'
#!/usr/bin/env python3

import re
import sys
from pathlib import Path

hp_dir = Path(sys.argv[1])
generate = hp_dir / "root/etc/homeproxy/scripts/generate_client.uc"

if not generate.is_file():
    raise SystemExit(
        f"generate_client.uc not found: {generate}"
    )

text = generate.read_text(encoding="utf-8")

targets = {
    "geoip-cn": "cn.srs",
    "geosite-cn": "geosite-geolocation-cn.srs",
    "geosite-noncn": "geosite-geolocation-!cn.srs",
}


def find_matching_brace(source, opening):
    """
    Find the closing brace corresponding to source[opening] == '{'.

    Handles:
      - single quoted strings
      - double quoted strings
      - template-like backtick strings
      - line comments
      - block comments

    This is intentionally a small scanner rather than a JavaScript parser.
    It is sufficient for locating the surrounding object while avoiding
    braces appearing inside strings/comments.
    """
    if opening >= len(source) or source[opening] != "{":
        raise ValueError("opening position is not '{'")

    depth = 0
    i = opening
    state = "normal"

    while i < len(source):
        c = source[i]
        n = source[i + 1] if i + 1 < len(source) else ""

        if state == "normal":
            if c == "'":
                state = "single"
            elif c == '"':
                state = "double"
            elif c == "`":
                state = "backtick"
            elif c == "/" and n == "/":
                state = "line_comment"
                i += 1
            elif c == "/" and n == "*":
                state = "block_comment"
                i += 1
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return i

        elif state == "single":
            if c == "\\":
                i += 1
            elif c == "'":
                state = "normal"

        elif state == "double":
            if c == "\\":
                i += 1
            elif c == '"':
                state = "normal"

        elif state == "backtick":
            if c == "\\":
                i += 1
            elif c == "`":
                state = "normal"

        elif state == "line_comment":
            if c == "\n":
                state = "normal"

        elif state == "block_comment":
            if c == "*" and n == "/":
                state = "normal"
                i += 1

        i += 1

    raise ValueError("unmatched '{' in generate_client.uc")


def find_ruleset_objects(source):
    """
    Return complete push(config.route.rule_set, {...}) ranges.

    Each result is:
        (start, closing_brace, full_call_end, body)

    full_call_end includes an optional trailing semicolon.
    """
    marker = "push(config.route.rule_set, {"
    pos = 0
    results = []

    while True:
        start = source.find(marker, pos)

        if start < 0:
            break

        opening = start + marker.rfind("{")
        closing = find_matching_brace(source, opening)

        end = closing + 1

        while end < len(source) and source[end] in " \t":
            end += 1

        if end < len(source) and source[end] == ";":
            end += 1

        body = source[opening + 1:closing]
        results.append((start, closing, end, body))

        pos = end

    return results


def extract_tag(body):
    patterns = [
        r"\btag\s*:\s*'([^']+)'",
        r'\btag\s*:\s*"([^"]+)"',
    ]

    for pattern in patterns:
        match = re.search(pattern, body)
        if match:
            return match.group(1)

    return None


objects = find_ruleset_objects(text)

matches = {tag: [] for tag in targets}

for item in objects:
    tag = extract_tag(item[3])

    if tag in matches:
        matches[tag].append(item)


for tag, found in matches.items():
    if len(found) == 0:
        raise SystemExit(
            f"required RuleSet tag not found: {tag}"
        )

    if len(found) > 1:
        raise SystemExit(
            f"duplicate RuleSet tag found ({len(found)} occurrences): {tag}"
        )


def local_object(tag, filename, indent):
    return (
        "push(config.route.rule_set, {\n"
        f"{indent}type: 'local',\n"
        f"{indent}tag: '{tag}',\n"
        f"{indent}format: 'binary',\n"
        f"{indent}path: HP_DIR + '/private_srs/{filename}'\n"
        "})"
    )


replacements = []

for tag, found in matches.items():
    start, closing, end, body = found[0]

    # Determine the indentation from the first property of the existing
    # object. Fall back to four spaces if upstream formatting is unusual.
    indent = "    "

    lines = body.splitlines()

    for line in lines:
        if line.strip():
            leading = line[:len(line) - len(line.lstrip())]
            if leading:
                indent = leading
            break

    replacement = local_object(
        tag,
        targets[tag],
        indent,
    )

    replacements.append((start, end, replacement))


# Apply from the end of the file backwards so offsets remain valid.
for start, end, replacement in reversed(replacements):
    text = text[:start] + replacement + text[end:]


generate.write_text(text, encoding="utf-8")

print(
    "localized RuleSets: "
    + ", ".join(targets.keys())
)


# ---------------------------------------------------------------------------
# Strict post-patch validation
# ---------------------------------------------------------------------------

new_text = generate.read_text(encoding="utf-8")
new_objects = find_ruleset_objects(new_text)


def normalize_body(body):
    return re.sub(r"\s+", " ", body).strip()


for tag, filename in targets.items():
    found = []

    for item in new_objects:
        if extract_tag(item[3]) == tag:
            found.append(item)

    if len(found) != 1:
        raise SystemExit(
            f"validation failed: expected exactly one RuleSet: {tag}"
        )

    body = found[0][3]

    required = [
        ("type", r"\btype\s*:\s*'local'"),
        ("tag", rf"\btag\s*:\s*'{re.escape(tag)}'"),
        ("format", r"\bformat\s*:\s*'binary'"),
        (
            "path",
            rf"\bpath\s*:\s*HP_DIR\s*\+\s*'/private_srs/{re.escape(filename)}'"
        ),
    ]

    for name, pattern in required:
        if not re.search(pattern, body):
            raise SystemExit(
                f"validation failed: {tag} missing required property: {name}"
            )

    forbidden = [
        r"\btype\s*:\s*'remote'",
        r"\btype\s*:\s*\"remote\"",
        r"\burl\s*:",
        r"\bdownload_detour\s*:",
        r"\bupdate_interval\s*:",
    ]

    for pattern in forbidden:
        if re.search(pattern, body):
            raise SystemExit(
                f"validation failed: {tag} still contains forbidden "
                f"remote property matching: {pattern}"
            )

    # Only these four properties should remain in the final RuleSet object.
    property_names = re.findall(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\s*:",
        body
    )

    allowed = {"type", "tag", "format", "path"}

    unexpected = [
        name for name in property_names
        if name not in allowed
    ]

    if unexpected:
        raise SystemExit(
            f"validation failed: {tag} contains unexpected properties: "
            + ", ".join(sorted(set(unexpected)))
        )

    print(f"[PASS] {tag} -> local {filename}")


# Confirm all three objects are still represented as push() calls.
for tag in targets:
    pattern = (
        r"push\s*\(\s*config\.route\.rule_set\s*,\s*\{"
        r"[^{}]*?"
        rf"\btag\s*:\s*'{re.escape(tag)}'"
        r"[^{}]*?"
        r"\}\s*\)"
    )

    if not re.search(pattern, new_text, flags=re.S):
        raise SystemExit(
            f"validation failed: malformed push() structure for {tag}"
        )

PY

	chmod +x "$script"

	log "Localizing HomeProxy RuleSets..."

	if ! python3 "$script" "$TARGET_DIR"; then
		die "Failed to localize HomeProxy RuleSets."
	fi

	rm -f -- "$script"
}

# ---------------------------------------------------------------------------
# Validate required native HomeProxy components
# ---------------------------------------------------------------------------

validate_homeproxy() {
	local init_file="$TARGET_DIR/root/etc/init.d/homeproxy"
	local updater="$TARGET_DIR/root/etc/homeproxy/scripts/update_crond.sh"
	local generator="$TARGET_DIR/root/etc/homeproxy/scripts/generate_client.uc"
	local routing_mode=""

	[ -f "$init_file" ] ||
		die "Missing HomeProxy init script: $init_file"

	[ -f "$updater" ] ||
		die "Missing native HomeProxy resource updater: $updater"

	[ -f "$generator" ] ||
		die "Missing HomeProxy generate_client.uc: $generator"

	# Custom Routing must remain native. We only verify its presence; we do
	# not modify the routing implementation.
	if grep -Eq 'routing_mode.*custom|custom.*routing_mode' "$generator"; then
		pass "Custom Routing support detected"
	else
		warn "Could not positively detect Custom Routing handling in generate_client.uc"
	fi

	# Ensure the native resource updater remains available.
	if grep -Eq 'update_resources|resources' "$updater"; then
		pass "Native HomeProxy resource updater preserved"
	else
		warn "Could not positively detect native resource updater implementation"
	fi

	# Runtime sing-box compatibility remains owned by upstream HomeProxy.
	# Do not inject version-specific logic here.
	if grep -Eq 'sing-box|sing_box|singbox' "$generator"; then
		pass "Upstream sing-box handling preserved"
	else
		warn "Could not positively detect sing-box handling in generate_client.uc"
	fi

	# Make sure we did not accidentally replace the complete generator with
	# something unrelated.
	if ! grep -q 'config.route.rule_set' "$generator"; then
		die "generate_client.uc does not contain route.rule_set handling"
	fi
}

# ---------------------------------------------------------------------------
# Persist private SRS directory through sysupgrade
# ---------------------------------------------------------------------------

ensure_sysupgrade_persistence() {
	local line="/etc/homeproxy/private_srs/"
	local tmp="${SYSUPGRADE_FILE}.tmp"

	mkdir -p "$(dirname "$SYSUPGRADE_FILE")"

	if [ -f "$SYSUPGRADE_FILE" ] &&
		grep -Fxq "$line" "$SYSUPGRADE_FILE"
	then
		pass "sysupgrade persistence already configured"
		return 0
	fi

	if [ -f "$SYSUPGRADE_FILE" ]; then
		cp -f "$SYSUPGRADE_FILE" "$tmp"
	else
		: > "$tmp"
	fi

	printf '%s\n' "$line" >> "$tmp"

	mv -f "$tmp" "$SYSUPGRADE_FILE"

	pass "Added /etc/homeproxy/private_srs/ to sysupgrade persistence"
}

# ---------------------------------------------------------------------------
# Validate SRS files
# ---------------------------------------------------------------------------

validate_srs() {
	local name=""
	local file=""
	local size=""

	for name in "${!SRS_URLS[@]}"; do
		file="$SRS_DIR/$name"

		[ -s "$file" ] ||
			die "Required SRS file missing or empty: $file"

		size="$(wc -c < "$file" | tr -d ' ')"

		log "SRS ready: $name (${size} bytes)"
	done

	for name in \
		"cn.srs" \
		"geosite-geolocation-cn.srs" \
		"geosite-geolocation-!cn.srs"
	do
		file="$SRS_DIR/$name"

		[ -s "$file" ] ||
			die "Critical local RuleSet is missing: $file"
	done

	pass "All required SRS files validated"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
	rm -rf -- "$TMP_ROOT"
}

trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local HP_PATH=""
	local name=""

	require_command git
	require_command curl
	require_command python3

	log "ZN-HomeProxy V7 starting..."
	log "Build root: $ROOT"

	remove_existing_homeproxy

	HP_PATH="$(fetch_homeproxy)"

	[ -n "$HP_PATH" ] ||
		die "HomeProxy source path is empty"

	[ -d "$HP_PATH" ] ||
		die "Selected HomeProxy path does not exist: $HP_PATH"

	if ! is_homeproxy_lineage "$HP_PATH"; then
		die "Selected path is not a complete HomeProxy package: $HP_PATH"
	fi

	log "Selected HomeProxy package: $HP_PATH"

	download_srs
	validate_srs

	patch_rulesets
	validate_homeproxy

	ensure_sysupgrade_persistence

	log "Final HomeProxy source: $HP_PATH"
	log "Final private SRS directory: $SRS_DIR"

	log "Bundled SRS files:"
	for name in "${!SRS_URLS[@]}"; do
		printf '  - %s\n' "$name" >&2
	done

	pass "ZN-HomeProxy V7 completed successfully."
}

main "$@"
