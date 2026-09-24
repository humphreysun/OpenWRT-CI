#!/usr/bin/env bash
set -euo pipefail

echo "=== ZN HomeProxy: SRS + dynamic Custom Routing backport ==="

# ============================================================
# 2. 动态定位 HomeProxy package
#    不依赖 Git commit、文件日期或固定目录。
# ============================================================

ROOT="${1:-${GITHUB_WORKSPACE:-.}}"
ROOT="$(cd "$ROOT" && pwd)"

find_homeproxy() {
    local p
    local candidates=(
        "$ROOT/package/homeproxy"
        "$ROOT/package/luci-app-homeproxy"
        "$ROOT/feeds/packages/homeproxy"
        "$ROOT/feeds/luci/homeproxy"
        "$ROOT/feeds/luci/luci-app-homeproxy"
    )

    for p in "${candidates[@]}"; do
        if [ -f "$p/root/etc/homeproxy/scripts/generate_client.uc" ] &&
           [ -f "$p/htdocs/luci-static/resources/view/homeproxy/client.js" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    mapfile -t found < <(find "$ROOT" -type f -path '*/root/etc/homeproxy/scripts/generate_client.uc' 2>/dev/null \
        | sed 's#/root/etc/homeproxy/scripts/generate_client.uc$##' \
        | while IFS= read -r p; do
            [ -f "$p/htdocs/luci-static/resources/view/homeproxy/client.js" ] && printf '%s\n' "$p"
        done | sort -u)

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
    if [ "$rc" -eq 2 ]; then exit 1; fi
    echo "[ZN-HomeProxy] HomeProxy package not found, skip."
    exit 0
}

HP_ROOT="$HP_PATH/root/etc/homeproxy"
GEN_FILE="$HP_ROOT/scripts/generate_client.uc"
UI_FILE="$HP_PATH/htdocs/luci-static/resources/view/homeproxy/client.js"
MIGRATE_FILE="$HP_PATH/root/etc/homeproxy/scripts/migrate_config.uc"
INIT_FILE="$HP_PATH/root/etc/init.d/homeproxy"

printf '[ZN-HomeProxy] Target package: %s\n' "$HP_PATH"

# ============================================================
# 3. SRS
# ============================================================

HP_SRS="$HP_ROOT/private_srs"
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

if [ "${ZN_SKIP_SRS:-0}" != "1" ]; then
    echo "[ZN-HomeProxy] Download official SRS..."
    for FILE in "${!SRS_URLS[@]}"; do
        URL="${SRS_URLS[$FILE]}"
        echo "[ZN-HomeProxy] Download: $FILE"
        curl -fL --retry 3 --retry-delay 2 -o "$HP_SRS/$FILE" "$URL"
        [ -s "$HP_SRS/$FILE" ] || { echo "[ERROR] Empty SRS: $FILE"; exit 1; }
    done
else
    echo "[ZN-HomeProxy] ZN_SKIP_SRS=1: skip SRS download."
fi

# ============================================================
# 4. Dynamic Custom Routing patch
#    Embedded patch contains no source dates, absolute paths, or
#    repository-specific filenames. GNU patch matches source text.
# ============================================================

PATCH_FILE="$(mktemp)"
BACKUP_DIR="$(mktemp -d)"
cleanup() { rm -f "$PATCH_FILE"; rm -rf "$BACKUP_DIR"; }
trap cleanup EXIT

cat > "$PATCH_FILE" <<'ZN_HOMEProxy_PATCH_EOF'
diff -u a/htdocs/luci-static/resources/view/homeproxy/client.js b/htdocs/luci-static/resources/view/homeproxy/client.js
--- a/htdocs/luci-static/resources/view/homeproxy/client.js
+++ b/htdocs/luci-static/resources/view/homeproxy/client.js
@@ -341,7 +341,9 @@
 		for (let i in proxy_nodes)
 			o.value(i, proxy_nodes[i]);
 		o.default = 'nil';
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 		o.rmempty = false;
 		o.retain = true;
@@ -350,7 +352,9 @@
 			_('List of nodes to test.'));
 		for (let i in proxy_nodes)
 			o.value(i, proxy_nodes[i]);
+		o.depends({ routing_mode: 'gfwlist', main_node: 'urltest' });
 		o.depends({ routing_mode: 'bypass_mainland_china', main_node: 'urltest' });
+		o.depends({ routing_mode: 'proxy_mainland_china', main_node: 'urltest' });
 		o.depends({ routing_mode: 'global', main_node: 'urltest' });
 		o.rmempty = false;
 		o.retain = true;
@@ -359,7 +363,9 @@
 			_('The test interval in seconds.'));
 		o.datatype = 'uinteger';
 		o.placeholder = '120';
+		o.depends({ routing_mode: 'gfwlist', main_node: 'urltest' });
 		o.depends({ routing_mode: 'bypass_mainland_china', main_node: 'urltest' });
+		o.depends({ routing_mode: 'proxy_mainland_china', main_node: 'urltest' });
 		o.depends({ routing_mode: 'global', main_node: 'urltest' });
 		o.retain = true;
 
@@ -367,7 +373,9 @@
 			_('The test tolerance in milliseconds.'));
 		o.datatype = 'uinteger';
 		o.placeholder = '60';
+		o.depends({ routing_mode: 'gfwlist', main_node: 'urltest' });
 		o.depends({ routing_mode: 'bypass_mainland_china', main_node: 'urltest' });
+		o.depends({ routing_mode: 'proxy_mainland_china', main_node: 'urltest' });
 		o.depends({ routing_mode: 'global', main_node: 'urltest' });
 		o.retain = true;
 
@@ -375,7 +383,9 @@
 			_('Interrupt existing connections when the selected outbound has changed.'));
 		o.default = o.disabled;
 		o.rmempty = false;
+		o.depends({ routing_mode: 'gfwlist', main_node: 'urltest' });
 		o.depends({ routing_mode: 'bypass_mainland_china', main_node: 'urltest' });
+		o.depends({ routing_mode: 'proxy_mainland_china', main_node: 'urltest' });
 		o.depends({ routing_mode: 'global', main_node: 'urltest' });
 		o.retain = true;
 
@@ -390,7 +400,9 @@
 		o.value('https://dns.opendns.com/dns-query', _('Cisco Public DNS (DoH)'));
 		o.default = 'https://dns.quad9.net/dns-query';
 		o.rmempty = false;
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 		o.retain = true;
 		o.validate = function(section_id, value) {
@@ -452,14 +464,1103 @@
 		}
 
 		o = s.taboption('routing', form.ListValue, 'routing_mode', _('Routing mode'));
+		o.value('gfwlist', _('GFWList'));
 		o.value('bypass_mainland_china', _('Bypass mainland China'));
+		o.value('proxy_mainland_china', _('Only proxy mainland China'));
+		o.value('custom', _('Custom routing'));
 		o.value('global', _('Global'));
 		o.default = 'bypass_mainland_china';
 		o.rmempty = false;
 
+		/* ZN: ImmortalWrt custom routing feature backport */
+		so = ss.option(form.ListValue, 'domain_strategy', _('Domain strategy'),
+			_('If set, the requested domain name will be resolved to IP before routing.'));
+		for (let i in hp.dns_strategy)
+			so.value(i, hp.dns_strategy[i]);
+
+		so = ss.option(form.ListValue, 'default_outbound', _('Default outbound'),
+			_('Default outbound for connections not matched by any routing rules.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('nil', _('Disable (the service)'));
+			this.value('direct-out', _('Direct'));
+			this.value('block-out', _('Block'));
+			uci.sections(data[0], 'routing_node', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.default = 'nil';
+		so.rmempty = false;
+
+		so = ss.option(form.ListValue, 'default_outbound_dns', _('Default outbound DNS'),
+			_('Default DNS server for resolving domain name in the server address.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('default-dns', _('Default DNS (issued by WAN)'));
+			this.value('system-dns', _('System DNS'));
+			uci.sections(data[0], 'dns_server', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.default = 'default-dns';
+		so.rmempty = false;
+		/* Routing settings end */
+
+		/* Routing nodes start */
+		s.tab('routing_node', _('Routing Nodes'));
+		o = s.taboption('routing_node', form.SectionValue, '_routing_node', form.GridSection, 'routing_node');
+		o.depends('routing_mode', 'custom');
+
+		ss = o.subsection;
+		ss.addremove = true;
+		ss.rowcolors = true;
+		ss.sortable = true;
+		ss.nodescriptions = true;
+		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('Routing node'), _('Add a routing node'), data[0]);
+		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
+		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss);
+
+		so = ss.option(form.Value, 'label', _('Label'));
+		so.load = L.bind(hp.loadDefaultLabel, this, data[0]);
+		so.validate = L.bind(hp.validateUniqueValue, this, data[0], 'routing_node', 'label');
+		so.modalonly = true;
+
+		so = ss.option(form.Flag, 'enabled', _('Enable'));
+		so.default = so.enabled;
+		so.rmempty = false;
+		so.editable = true;
+
+		so = ss.option(form.ListValue, 'node', _('Node'),
+			_('Outbound node'));
+		so.value('urltest', _('URLTest'));
+		for (let i in proxy_nodes)
+			so.value(i, proxy_nodes[i]);
+		so.validate = L.bind(hp.validateUniqueValue, this, data[0], 'routing_node', 'node');
+		so.editable = true;
+
+		so = ss.option(form.ListValue, 'domain_resolver', _('Domain resolver'),
+			_('For resolving domain name in the server address.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('', _('Default'));
+			this.value('default-dns', _('Default DNS (issued by WAN)'));
+			this.value('system-dns', _('System DNS'));
+			uci.sections(data[0], 'dns_server', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.depends({'node': 'urltest', '!reverse': true});
+		so.modalonly = true;
+
+		so = ss.option(form.ListValue, 'domain_strategy', _('Domain strategy'),
+			_('The domain strategy for resolving the domain name in the address.'));
+		for (let i in hp.dns_strategy)
+			so.value(i, hp.dns_strategy[i]);
+		so.depends({'node': 'urltest', '!reverse': true});
+		so.modalonly = true;
+
+		so = ss.option(widgets.DeviceSelect, 'bind_interface', _('Bind interface'),
+			_('The network interface to bind to.'));
+		so.multiple = false;
+		so.noaliases = true;
+		so.depends({'outbound': '', 'node': /^((?!urltest$).)+$/});
+		so.modalonly = true;
+
+		so = ss.option(form.ListValue, 'outbound', _('Outbound'),
+			_('The tag of the upstream outbound.<br/>Other dial fields will be ignored when enabled.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('', _('Direct'));
+			uci.sections(data[0], 'routing_node', (res) => {
+				if (res['.name'] !== section_id && res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.validate = function(section_id, value) {
+			if (section_id && value) {
+				let node = this.section.formvalue(section_id, 'node');
+
+				let conflict = false;
+				uci.sections(data[0], 'routing_node', (res) => {
+					if (res['.name'] !== section_id) {
+						if (res.outbound === section_id && res['.name'] == value)
+							conflict = true;
+						else if (res.node === 'urltest' && res.urltest_nodes?.includes(node) && res['.name'] == value)
+							conflict = true;
+					}
+				});
+				if (conflict)
+					return _('Recursive outbound detected!');
+			}
+
+			return true;
+		}
+		so.depends({'node': 'urltest', '!reverse': true});
+		so.editable = true;
+
+		so = ss.option(hp.CBIStaticList, 'urltest_nodes', _('URLTest nodes'),
+			_('List of nodes to test.'));
+		for (let i in proxy_nodes)
+			so.value(i, proxy_nodes[i]);
+		so.depends('node', 'urltest');
+		so.validate = function(section_id) {
+			let value = this.section.formvalue(section_id, 'urltest_nodes');
+			if (section_id && !value.length)
+				return _('Expecting: %s').format(_('non-empty value'));
+
+			return true;
+		}
+		so.modalonly = true;
+
+		so = ss.option(form.Value, 'urltest_url', _('Test URL'),
+			_('The URL to test.'));
+		so.placeholder = 'https://www.gstatic.com/generate_204';
+		so.validate = function(section_id, value) {
+			if (section_id && value) {
+				try {
+					let url = new URL(value);
+					if (!url.hostname)
+						return _('Expecting: %s').format(_('valid URL'));
+				}
+				catch(e) {
+					return _('Expecting: %s').format(_('valid URL'));
+				}
+			}
+
+			return true;
+		}
+		so.depends('node', 'urltest');
+		so.modalonly = true;
+
+		so = ss.option(form.Value, 'urltest_interval', _('Test interval'),
+			_('The test interval in seconds.'));
+		so.datatype = 'uinteger';
+		so.placeholder = '180';
+		so.validate = function(section_id, value) {
+			if (section_id && value) {
+				let idle_timeout = this.section.formvalue(section_id, 'idle_timeout') || '1800';
+				if (parseInt(value) > parseInt(idle_timeout))
+					return _('Test interval must be less or equal than idle timeout.');
+			}
+
+			return true;
+		}
+		so.depends('node', 'urltest');
+		so.modalonly = true;
+
+		so = ss.option(form.Value, 'urltest_tolerance', _('Test tolerance'),
+			_('The test tolerance in milliseconds.'));
+		so.datatype = 'uinteger';
+		so.placeholder = '50';
+		so.depends('node', 'urltest');
+		so.modalonly = true;
+
+		so = ss.option(form.Value, 'urltest_idle_timeout', _('Idle timeout'),
+			_('The idle timeout in seconds.'));
+		so.datatype = 'uinteger';
+		so.placeholder = '1800';
+		so.depends('node', 'urltest');
+		so.modalonly = true;
+
+		so = ss.option(form.Flag, 'urltest_interrupt_exist_connections', _('Interrupt existing connections'),
+			_('Interrupt existing connections when the selected outbound has changed.'));
+		so.depends('node', 'urltest');
+		so.modalonly = true;
+		/* Routing nodes end */
+
+		/* Routing rules start */
+		s.tab('routing_rule', _('Routing Rules'));
+		o = s.taboption('routing_rule', form.SectionValue, '_routing_rule', form.GridSection, 'routing_rule');
+		o.depends('routing_mode', 'custom');
+
+		ss = o.subsection;
+		ss.addremove = true;
+		ss.rowcolors = true;
+		ss.sortable = true;
+		ss.nodescriptions = true;
+		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('Routing rule'), _('Add a routing rule'), data[0]);
+		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
+		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss);
+
+		ss.tab('field_other', _('Other fields'));
+		ss.tab('field_host', _('Host/IP fields'));
+		ss.tab('field_port', _('Port fields'));
+		ss.tab('fields_process', _('Process fields'));
+
+		so = ss.taboption('field_other', form.Value, 'label', _('Label'));
+		so.load = L.bind(hp.loadDefaultLabel, this, data[0]);
+		so.validate = L.bind(hp.validateUniqueValue, this, data[0], 'routing_rule', 'label');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'enabled', _('Enable'));
+		so.default = so.enabled;
+		so.rmempty = false;
+		so.editable = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'mode', _('Mode'),
+			_('The default rule uses the following matching logic:<br/>' +
+			'<code>(domain || domain_suffix || domain_keyword || domain_regex || ip_cidr || ip_is_private)</code> &&<br/>' +
+			'<code>(port || port_range)</code> &&<br/>' +
+			'<code>(source_ip_cidr || source_ip_is_private)</code> &&<br/>' +
+			'<code>(source_port || source_port_range)</code> &&<br/>' +
+			'<code>other fields</code>.<br/>' +
+			'Additionally, included rule sets can be considered merged rather than as a single rule sub-item.'));
+		so.value('default', _('Default'));
+		so.default = 'default';
+		so.rmempty = false;
+		so.readonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'ip_version', _('IP version'),
+			_('4 or 6. Not limited if empty.'));
+		so.value('4', _('IPv4'));
+		so.value('6', _('IPv6'));
+		so.value('', _('Both'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.MultiValue, 'protocol', _('Protocol'),
+			_('Sniffed protocol, see <a target="_blank" href="https://sing-box.sagernet.org/configuration/route/sniff/">Sniff</a> for details.'));
+		so.value('bittorrent', _('BitTorrent'));
+		so.value('dns', _('DNS'));
+		so.value('dtls', _('DTLS'));
+		so.value('http', _('HTTP'));
+		so.value('quic', _('QUIC'));
+		so.value('rdp', _('RDP'));
+		so.value('ssh', _('SSH'));
+		so.value('stun', _('STUN'));
+		so.value('tls', _('TLS'));
+
+		so = ss.taboption('field_other', form.Value, 'client', _('Client'),
+			_('Sniffed client type (QUIC client type or SSH client name).'));
+		so.value('chromium', _('Chromium / Cronet'));
+		so.value('firefox', _('Firefox / uquic firefox'));
+		so.value('quic-go', _('quic-go / uquic chrome'));
+		so.value('safari', _('Safari / Apple Network API'));
+		so.depends('protocol', 'quic');
+		so.depends('protocol', 'ssh');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'network', _('Network'));
+		so.value('tcp', _('TCP'));
+		so.value('udp', _('UDP'));
+		so.value('', _('Both'));
+
+		so = ss.taboption('field_other', form.DynamicList, 'user', _('User'),
+			_('Match user name.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', hp.CBIStaticList, 'rule_set', _('Rule set'),
+			_('Match rule set.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			uci.sections(data[0], 'ruleset', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'rule_set_ip_cidr_match_source', _('Rule set IP CIDR as source IP'),
+			_('Make IP CIDR in rule set used to match the source IP.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'invert', _('Invert'),
+			_('Invert match result.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'action', _('Action'));
+		so.value('route', _('Route'));
+		so.value('route-options', _('Route options'));
+		so.value('reject', _('Reject'));
+		so.value('resolve', _('Resolve'));
+		so.default = 'route';
+		so.rmempty = false;
+		so.editable = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'outbound', _('Outbound'),
+			_('Tag of the target outbound.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('direct-out', _('Direct'));
+			uci.sections(data[0], 'routing_node', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.rmempty = false;
+		so.depends('action', 'route');
+		so.editable = true;
+
+		so = ss.taboption('field_other', form.Value, 'override_address', _('Override address'),
+			_('Override the connection destination address.'));
+		so.datatype = 'ipaddr';
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Value, 'override_port', _('Override port'),
+			_('Override the connection destination port.'));
+		so.datatype = 'port';
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'udp_disable_domain_unmapping', _('Disable UDP domain unmapping'),
+			_('If enabled, for UDP proxy requests addressed to a domain, the original packet address will be sent in the response instead of the mapped domain.'));
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'udp_connect', _('connect UDP connections'),
+			_('If enabled, attempts to connect UDP connection to the destination instead of listen.'));
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Value, 'udp_timeout', _('UDP timeout'),
+			_('Timeout for UDP connections.<br/>Setting a larger value than the UDP timeout in inbounds will have no effect.'));
+		so.datatype = 'uinteger';
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'tls_record_fragment', _('TLS record fragment'),
+			_('Fragment TLS handshake into multiple TLS records.'));
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'tls_fragment', _('TLS fragment'),
+			_('Fragment TLS handshakes. Due to poor performance, try <code>%s</code> first.').format(
+				_('TLS record fragment')));
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Value, 'tls_fragment_fallback_delay', _('Fragment fallback delay'),
+			_('The fallback value in milliseconds used when TLS segmentation cannot automatically determine the wait time.'));
+		so.datatype = 'uinteger';
+		so.placeholder = '500';
+		so.depends('tls_fragment', '1');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Value, 'tls_spoof', _('TLS spoof SNI (1.14)'),
+			_('Inject a forged TLS ClientHello carrying this SNI before the real one to fool SNI-filtering middleboxes. Requires elevated privileges.'));
+		so.datatype = 'hostname';
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'tls_spoof_method', _('TLS spoof method (1.14)'),
+			_('How the forged segment is rejected by the real server.'));
+		so.value('', _('wrong-sequence (default)'));
+		so.value('wrong-checksum', _('wrong-checksum'));
+		so.value('wrong-ack', _('wrong-ack'));
+		so.value('wrong-md5', _('wrong-md5'));
+		so.value('wrong-timestamp', _('wrong-timestamp'));
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.depends('tls_spoof', /[\s\S]/);
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'resolve_server', _('DNS server'),
+			_('Specifies DNS server tag to use instead of selecting through DNS routing.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('', _('Default'));
+			this.value('default-dns', _('Default DNS (issued by WAN)'));
+			this.value('system-dns', _('System DNS'));
+			uci.sections(data[0], 'dns_server', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.depends('action', 'resolve');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'reject_method', _('Method'));
+		so.value('default', _('Reply with TCP RST / ICMP port unreachable'));
+		so.value('drop', _('Drop packets'));
+		so.depends('action', 'reject');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'reject_no_drop', _('Don\'t drop packets'),
+			_('<code>%s</code> will be temporarily overwritten to <code>%s</code> after 50 triggers in 30s if not enabled.').format(
+			_('Method'), _('Drop packets')));
+		so.depends('reject_method', 'default');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'resolve_strategy', _('Resolve strategy'),
+			_('Domain strategy for resolving the domain names.'));
+		for (let i in hp.dns_strategy)
+			so.value(i, hp.dns_strategy[i]);
+		so.depends('action', 'resolve');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'resolve_disable_cache', _('Disable DNS cache'),
+			_('Disable DNS cache in this query.'));
+		so.depends('action', 'resolve');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Value, 'resolve_rewrite_ttl', _('Rewrite TTL'),
+			_('Rewrite TTL in DNS responses.'));
+		so.datatype = 'uinteger';
+		so.depends('action', 'resolve');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Value, 'resolve_client_subnet', _('EDNS Client subnet'),
+			_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
+			'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
+		so.datatype = 'or(cidr, ipaddr)';
+		so.depends('action', 'resolve');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'resolve_disable_optimistic_cache', _('Disable optimistic cache'),
+			_('Disable optimistic DNS caching in this lookup (1.14).'));
+		so.depends('action', 'resolve');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Value, 'resolve_timeout', _('Query timeout'),
+			_('Override dns.timeout for this lookup, in seconds (1.14).'));
+		so.datatype = 'uinteger';
+		so.depends('action', 'resolve');
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'domain', _('Domain name'),
+			_('Match full domain.'));
+		so.datatype = 'hostname';
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'domain_suffix', _('Domain suffix'),
+			_('Match domain suffix.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'domain_keyword', _('Domain keyword'),
+			_('Match domain using keyword.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'domain_regex', _('Domain regex'),
+			_('Match domain using regular expression.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'source_ip_cidr', _('Source IP CIDR'),
+			_('Match source IP CIDR.'));
+		so.datatype = 'or(cidr, ipaddr)';
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.Flag, 'source_ip_is_private', _('Match private source IP'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'ip_cidr', _('IP CIDR'),
+			_('Match IP CIDR.'));
+		so.datatype = 'or(cidr, ipaddr)';
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.Flag, 'ip_is_private', _('Match private IP'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'source_mac_address', _('Source MAC address'),
+			_('Match LAN device by MAC address.'));
+		so.datatype = 'macaddr';
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'source_hostname', _('Source hostname'),
+			_('Match LAN device hostname via neighbor resolution; enable find_neighbor.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_port', form.DynamicList, 'source_port', _('Source port'),
+			_('Match source port.'));
+		so.datatype = 'port';
+		so.modalonly = true;
+
+		so = ss.taboption('field_port', form.DynamicList, 'source_port_range', _('Source port range'),
+			_('Match source port range. Format as START:/:END/START:END.'));
+		so.validate = hp.validatePortRange;
+		so.modalonly = true;
+
+		so = ss.taboption('field_port', form.DynamicList, 'port', _('Port'),
+			_('Match port.'));
+		so.datatype = 'port';
+		so.modalonly = true;
+
+		so = ss.taboption('field_port', form.DynamicList, 'port_range', _('Port range'),
+			_('Match port range. Format as START:/:END/START:END.'));
+		so.validate = hp.validatePortRange;
+		so.modalonly = true;
+
+		so = ss.taboption('fields_process', form.DynamicList, 'process_name', _('Process name'),
+			_('Match process name.'));
+		so.modalonly = true;
+
+		so = ss.taboption('fields_process', form.DynamicList, 'process_path', _('Process path'),
+			_('Match process path.'));
+		so.modalonly = true;
+
+		so = ss.taboption('fields_process', form.DynamicList, 'process_path_regex', _('Process path (regex)'),
+			_('Match process path using regular expression.'));
+		so.modalonly = true;
+		/* Routing rules end */
+
+		/* DNS settings start */
+		s.tab('dns', _('DNS Settings'));
+		o = s.taboption('dns', form.SectionValue, '_dns', form.NamedSection, 'dns', 'homeproxy');
+		o.depends('routing_mode', 'custom');
+
+		ss = o.subsection;
+		so = ss.option(form.ListValue, 'default_strategy', _('Default DNS strategy'),
+			_('The DNS strategy for resolving the domain name in the address.'));
+		for (let i in hp.dns_strategy)
+			so.value(i, hp.dns_strategy[i]);
+
+		so = ss.option(form.ListValue, 'default_server', _('Default DNS server'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('default-dns', _('Default DNS (issued by WAN)'));
+			this.value('system-dns', _('System DNS'));
+			uci.sections(data[0], 'dns_server', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.default = 'default-dns';
+		so.rmempty = false;
+
+		so = ss.option(form.Flag, 'disable_cache', _('Disable DNS cache'));
+
+		so = ss.option(form.Flag, 'disable_cache_expire', _('Disable cache expire'));
+		so.depends('disable_cache', '0');
+
+		so = ss.option(form.Flag, 'independent_cache', _('Independent cache per server'),
+			_('Make each DNS server\'s cache independent for special purposes. If enabled, will slightly degrade performance.'));
+		so.depends('disable_cache', '0');
+
+		so = ss.option(form.Value, 'client_subnet', _('EDNS Client subnet'),
+			_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
+			'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
+		so.datatype = 'or(cidr, ipaddr)';
+
+		so = ss.option(form.Flag, 'cache_file_store_rdrc', _('Store RDRC'),
+			_('Store rejected DNS response cache.<br/>' +
+			'The check results of <code>Address filter DNS rule items</code> will be cached until expiration.'));
+
+		so = ss.option(form.Value, 'cache_file_rdrc_timeout', _('RDRC timeout'),
+			_('Timeout of rejected DNS response cache in seconds. <code>604800 (7d)</code> is used by default.'));
+		so.datatype = 'uinteger';
+		so.depends('cache_file_store_rdrc', '1');
+		/* DNS settings end */
+
+		/* DNS servers start */
+		s.tab('dns_server', _('DNS Servers'));
+		o = s.taboption('dns_server', form.SectionValue, '_dns_server', form.GridSection, 'dns_server');
+		o.depends('routing_mode', 'custom');
+
+		ss = o.subsection;
+		ss.addremove = true;
+		ss.rowcolors = true;
+		ss.sortable = true;
+		ss.nodescriptions = true;
+		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('DNS server'), _('Add a DNS server'), data[0]);
+		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
+		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss);
+
+		so = ss.option(form.Value, 'label', _('Label'));
+		so.load = L.bind(hp.loadDefaultLabel, this, data[0]);
+		so.validate = L.bind(hp.validateUniqueValue, this, data[0], 'dns_server', 'label');
+		so.modalonly = true;
+
+		so = ss.option(form.Flag, 'enabled', _('Enable'));
+		so.default = so.enabled;
+		so.rmempty = false;
+		so.editable = true;
+
+		so = ss.option(form.ListValue, 'type', _('Type'));
+		so.value('udp', _('UDP'));
+		so.value('tcp', _('TCP'));
+		so.value('tls', _('TLS'));
+		so.value('https', _('HTTPS'));
+		so.value('h3', _('HTTP/3'));
+		so.value('quic', _('QUIC'));
+		so.default = 'udp';
+		so.rmempty = false;
+
+		so = ss.option(form.Value, 'server', _('Address'),
+			_('The address of the dns server.'));
+		so.datatype = 'or(hostname, ipaddr)';
+		so.rmempty = false;
+
+		so = ss.option(form.Value, 'server_port', _('Port'),
+			_('The port of the DNS server.'));
+		so.placeholder = 'auto';
+		so.datatype = 'port';
+
+		so = ss.option(form.Value, 'path', _('Path'),
+			_('The path of the DNS server.'));
+		so.placeholder = '/dns-query';
+		so.depends('type', 'https');
+		so.depends('type', 'h3');
+		so.modalonly = true;
+
+		so = ss.option(form.DynamicList, 'headers', _('Headers'),
+			_('Additional headers to be sent to the DNS server.'));
+		so.depends('type', 'https');
+		so.depends('type', 'h3');
+		so.modalonly = true;
+
+		so = ss.option(form.Value, 'tls_sni', _('TLS SNI'),
+			_('Used to verify the hostname on the returned certificates.'));
+		so.depends('type', 'tls');
+		so.depends('type', 'https');
+		so.depends('type', 'h3');
+		so.depends('type', 'quic');
+		so.modalonly = true;
+
+		so = ss.option(form.ListValue, 'address_resolver', _('Address resolver'),
+			_('Tag of a another server to resolve the domain name in the address. Required if address contains domain.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('', _('None'));
+			this.value('default-dns', _('Default DNS (issued by WAN)'));
+			this.value('system-dns', _('System DNS'));
+			uci.sections(data[0], 'dns_server', (res) => {
+				if (res['.name'] !== section_id && res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.validate = function(section_id, value) {
+			if (section_id && value) {
+				let conflict = false;
+				uci.sections(data[0], 'dns_server', (res) => {
+					if (res['.name'] !== section_id)
+						if (res.address_resolver === section_id && res['.name'] == value)
+							conflict = true;
+				});
+				if (conflict)
+					return _('Recursive resolver detected!');
+			}
+
+			return true;
+		}
+		so.modalonly = true;
+
+		so = ss.option(form.ListValue, 'address_strategy', _('Address strategy'),
+			_('The domain strategy for resolving the domain name in the address.'));
+		for (let i in hp.dns_strategy)
+			so.value(i, hp.dns_strategy[i]);
+		so.depends({'address_resolver': '', '!reverse': true});
+		so.modalonly = true;
+
+		so = ss.option(form.ListValue, 'outbound', _('Outbound'),
+			_('Tag of an outbound for connecting to the dns server.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('direct-out', _('Direct'));
+			uci.sections(data[0], 'routing_node', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.default = 'direct-out';
+		so.rmempty = false;
+		so.editable = true;
+		/* DNS servers end */
+
+		/* DNS rules start */
+		s.tab('dns_rule', _('DNS Rules'));
+		o = s.taboption('dns_rule', form.SectionValue, '_dns_rule', form.GridSection, 'dns_rule');
+		o.depends('routing_mode', 'custom');
+
+		ss = o.subsection;
+		ss.addremove = true;
+		ss.rowcolors = true;
+		ss.sortable = true;
+		ss.nodescriptions = true;
+		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('DNS rule'), _('Add a DNS rule'), data[0]);
+		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
+		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss);
+
+		ss.tab('field_other', _('Other fields'));
+		ss.tab('field_host', _('Host/IP fields'));
+		ss.tab('field_port', _('Port fields'));
+		ss.tab('fields_process', _('Process fields'));
+
+		so = ss.taboption('field_other', form.Value, 'label', _('Label'));
+		so.load = L.bind(hp.loadDefaultLabel, this, data[0]);
+		so.validate = L.bind(hp.validateUniqueValue, this, data[0], 'dns_rule', 'label');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'enabled', _('Enable'));
+		so.default = so.enabled;
+		so.rmempty = false;
+		so.editable = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'mode', _('Mode'),
+			_('The default rule uses the following matching logic:<br/>' +
+			'<code>(domain || domain_suffix || domain_keyword || domain_regex)</code> &&<br/>' +
+			'<code>(port || port_range)</code> &&<br/>' +
+			'<code>(source_ip_cidr || source_ip_is_private)</code> &&<br/>' +
+			'<code>(source_port || source_port_range)</code> &&<br/>' +
+			'<code>other fields</code>.<br/>' +
+			'Additionally, included rule sets can be considered merged rather than as a single rule sub-item.'));
+		so.value('default', _('Default'));
+		so.default = 'default';
+		so.rmempty = false;
+		so.readonly = true;
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'ip_version', _('IP version'));
+		so.value('4', _('IPv4'));
+		so.value('6', _('IPv6'));
+		so.value('', _('Both'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.DynamicList, 'query_type', _('Query type'),
+			_('Match query type.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'network', _('Network'));
+		so.value('tcp', _('TCP'));
+		so.value('udp', _('UDP'));
+		so.value('', _('Both'));
+
+		so = ss.taboption('field_other', form.MultiValue, 'protocol', _('Protocol'),
+			_('Sniffed protocol, see <a target="_blank" href="https://sing-box.sagernet.org/configuration/route/sniff/">Sniff</a> for details.'));
+		so.value('bittorrent', _('BitTorrent'));
+		so.value('dtls', _('DTLS'));
+		so.value('http', _('HTTP'));
+		so.value('quic', _('QUIC'));
+		so.value('rdp', _('RDP'));
+		so.value('ssh', _('SSH'));
+		so.value('stun', _('STUN'));
+		so.value('tls', _('TLS'));
+
+		so = ss.taboption('field_other', form.DynamicList, 'user', _('User'),
+			_('Match user name.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', hp.CBIStaticList, 'rule_set', _('Rule set'),
+			_('Match rule set.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			uci.sections(data[0], 'ruleset', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'rule_set_ip_cidr_match_source', _('Rule set IP CIDR as source IP'),
+			_('Make IP CIDR in rule sets match the source IP.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'rule_set_ip_cidr_accept_empty', _('Accept empty query response'),
+			_('Make IP CIDR in rule-sets accept empty query response.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'invert', _('Invert'),
+			_('Invert match result.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'action', _('Action'));
+		so.value('route', _('Route'));
+		so.value('route-options', _('Route options'));
+		so.value('reject', _('Reject'));
+		so.value('predefined', _('Predefined'));
+		so.default = 'route';
+		so.rmempty = false;
+		so.editable = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'server', _('Server'),
+			_('Tag of the target dns server.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('default-dns', _('Default DNS (issued by WAN)'));
+			this.value('system-dns', _('System DNS'));
+			uci.sections(data[0], 'dns_server', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.rmempty = false;
+		so.editable = true;
+		so.depends('action', 'route');
+
+		so = ss.taboption('field_other', form.ListValue, 'domain_strategy', _('Domain strategy'),
+			_('Set domain strategy for this query.'));
+		for (let i in hp.dns_strategy)
+			so.value(i, hp.dns_strategy[i]);
+		so.depends('action', 'route');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'dns_disable_cache', _('Disable dns cache'),
+			_('Disable cache and save cache in this query.'));
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Value, 'rewrite_ttl', _('Rewrite TTL'),
+			_('Rewrite TTL in DNS responses.'));
+		so.datatype = 'uinteger';
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Value, 'client_subnet', _('EDNS Client subnet'),
+			_('Append a <code>edns0-subnet</code> OPT extra record with the specified IP prefix to every query by default.<br/>' +
+			'If value is an IP address instead of prefix, <code>/32</code> or <code>/128</code> will be appended automatically.'));
+		so.datatype = 'or(cidr, ipaddr)';
+		so.depends('action', 'route');
+		so.depends('action', 'route-options');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'reject_method', _('Method'));
+		so.value('default', _('Reply with REFUSED'));
+		so.value('drop', _('Drop requests'));
+		so.default = 'default';
+		so.depends('action', 'reject');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.Flag, 'reject_no_drop', _('Don\'t drop requests'),
+			_('<code>%s</code> will be temporarily overwritten to <code>%s</code> after 50 triggers in 30s if not enabled.').format(
+				_('Method'), _('Drop requests')));
+		so.depends('reject_method', 'default');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.ListValue, 'predefined_rcode', _('RCode'),
+			_('The response code.'));
+		so.value('NOERROR');
+		so.value('FORMERR');
+		so.value('SERVFAIL');
+		so.value('NXDOMAIN');
+		so.value('NOTIMP');
+		so.value('REFUSED');
+		so.default = 'NOERROR';
+		so.depends('action', 'predefined');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.DynamicList, 'predefined_answer', _('Answer'),
+			_('List of text DNS record to respond as answers.'));
+		so.depends('action', 'predefined');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.DynamicList, 'predefined_ns', _('NS'),
+			_('List of text DNS record to respond as name servers.'));
+		so.depends('action', 'predefined');
+		so.modalonly = true;
+
+		so = ss.taboption('field_other', form.DynamicList, 'predefined_extra', _('Extra records'),
+			_('List of text DNS record to respond as extra records.'));
+		so.depends('action', 'predefined');
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'domain', _('Domain name'),
+			_('Match full domain.'));
+		so.datatype = 'hostname';
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'domain_suffix', _('Domain suffix'),
+			_('Match domain suffix.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'domain_keyword', _('Domain keyword'),
+			_('Match domain using keyword.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'domain_regex', _('Domain regex'),
+			_('Match domain using regular expression.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'source_ip_cidr', _('Source IP CIDR'),
+			_('Match source IP CIDR.'));
+		so.datatype = 'or(cidr, ipaddr)';
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.Flag, 'source_ip_is_private', _('Match private source IP'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.DynamicList, 'ip_cidr', _('IP CIDR'),
+			_('Match IP CIDR with query response. Current rule will be skipped if not match.'));
+		so.datatype = 'or(cidr, ipaddr)';
+		so.modalonly = true;
+
+		so = ss.taboption('field_host', form.Flag, 'ip_is_private', _('Match private IP'),
+			_('Match private IP with query response.'));
+		so.modalonly = true;
+
+		so = ss.taboption('field_port', form.DynamicList, 'source_port', _('Source port'),
+			_('Match source port.'));
+		so.datatype = 'port';
+		so.modalonly = true;
+
+		so = ss.taboption('field_port', form.DynamicList, 'source_port_range', _('Source port range'),
+			_('Match source port range. Format as START:/:END/START:END.'));
+		so.validate = hp.validatePortRange;
+		so.modalonly = true;
+
+		so = ss.taboption('field_port', form.DynamicList, 'port', _('Port'),
+			_('Match port.'));
+		so.datatype = 'port';
+		so.modalonly = true;
+
+		so = ss.taboption('field_port', form.DynamicList, 'port_range', _('Port range'),
+			_('Match port range. Format as START:/:END/START:END.'));
+		so.validate = hp.validatePortRange;
+		so.modalonly = true;
+
+		so = ss.taboption('fields_process', form.DynamicList, 'process_name', _('Process name'),
+			_('Match process name.'));
+		so.modalonly = true;
+
+		so = ss.taboption('fields_process', form.DynamicList, 'process_path', _('Process path'),
+			_('Match process path.'));
+		so.modalonly = true;
+
+		so = ss.taboption('fields_process', form.DynamicList, 'process_path_regex', _('Process path (regex)'),
+			_('Match process path using regular expression.'));
+		so.modalonly = true;
+		/* DNS rules end */
+		/* Custom routing settings end */
+		/* Rule set settings start */
+		s.tab('ruleset', _('Rule Set'));
+		o = s.taboption('ruleset', form.SectionValue, '_ruleset', form.GridSection, 'ruleset');
+		o.depends('routing_mode', 'custom');
+
+		ss = o.subsection;
+		ss.addremove = true;
+		ss.rowcolors = true;
+		ss.sortable = true;
+		ss.nodescriptions = true;
+		ss.modaltitle = L.bind(hp.loadModalTitle, this, _('Rule set'), _('Add a rule set'), data[0]);
+		ss.sectiontitle = L.bind(hp.loadDefaultLabel, this, data[0]);
+		ss.renderSectionAdd = L.bind(hp.renderSectionAdd, this, ss);
+
+		so = ss.option(form.Value, 'label', _('Label'));
+		so.load = L.bind(hp.loadDefaultLabel, this, data[0]);
+		so.validate = L.bind(hp.validateUniqueValue, this, data[0], 'ruleset', 'label');
+		so.modalonly = true;
+
+		so = ss.option(form.Flag, 'enabled', _('Enable'));
+		so.default = so.enabled;
+		so.rmempty = false;
+		so.editable = true;
+
+		so = ss.option(form.ListValue, 'type', _('Type'));
+		so.value('local', _('Local'));
+		so.value('remote', _('Remote'));
+		so.default = 'remote';
+		so.rmempty = false;
+
+		so = ss.option(form.ListValue, 'format', _('Format'));
+		so.value('binary', _('Binary file'));
+		so.value('source', _('Source file'));
+		so.default = 'binary';
+		so.rmempty = false;
+
+		so = ss.option(form.Value, 'path', _('Path'));
+		so.datatype = 'file';
+		so.placeholder = '/etc/homeproxy/ruleset/example.json';
+		so.rmempty = false;
+		so.depends('type', 'local');
+		so.modalonly = true;
+
+		so = ss.option(form.Value, 'url', _('Rule set URL'));
+		so.validate = function(section_id, value) {
+			if (section_id) {
+				if (!value)
+					return _('Expecting: %s').format(_('non-empty value'));
+
+				try {
+					let url = new URL(value);
+					if (!url.hostname)
+						return _('Expecting: %s').format(_('valid URL'));
+				}
+				catch(e) {
+					return _('Expecting: %s').format(_('valid URL'));
+				}
+			}
+
+			return true;
+		}
+		so.rmempty = false;
+		so.depends('type', 'remote');
+		so.modalonly = true;
+
+		so = ss.option(form.ListValue, 'outbound', _('Outbound'),
+			_('Tag of the outbound to download rule set.'));
+		so.load = function(section_id) {
+			delete this.keylist;
+			delete this.vallist;
+
+			this.value('', _('Default'));
+			this.value('direct-out', _('Direct'));
+			uci.sections(data[0], 'routing_node', (res) => {
+				if (res.enabled === '1')
+					this.value(res['.name'], res.label);
+			});
+
+			return this.super('load', section_id);
+		}
+		so.depends('type', 'remote');
+
+		so = ss.option(form.Value, 'update_interval', _('Update interval'),
+			_('Update interval of rule set.'));
+		so.placeholder = '1d';
+		so.depends('type', 'remote');
+		/* Rule set settings end */
 		o = s.taboption('routing', form.Value, 'routing_port', _('Routing ports'),
 			_('Specify target ports to be proxied. Multiple ports must be separated by commas.'));
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 		o.value('', _('All ports'));
 		o.value('common', _('Common ports only (bypass P2P traffic)'));
@@ -482,13 +1583,17 @@
 		o = s.taboption('routing', form.Flag, 'ipv6_support', _('IPv6 support'));
 		o.default = o.enabled;
 		o.rmempty = false;
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 
 		o = s.taboption('dashboard', form.Flag, 'dashboard_enabled', _('Enable dashboard'));
 		o.default = '0';
 		o.rmempty = false;
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 
 		o = s.taboption('dashboard', form.Value, 'dashboard_port', _('Listen port'),
@@ -497,14 +1602,18 @@
 		o.datatype = 'port';
 		o.rmempty = false;
 		o.retain = true;
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 
 		o = s.taboption('dashboard', form.Value, 'dashboard_secret', _('API secret'));
 		o.password = true;
 		o.rmempty = true;
 		o.retain = true;
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 
 		o = s.taboption('dashboard', form.Button, '_open_dashboard', _('sing-box dashboard'));
@@ -524,7 +1633,9 @@
 		s.tab('control', _('Access Control'));
 
 		o = s.taboption('control', form.SectionValue, '_control', form.NamedSection, 'control', 'homeproxy');
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 		ss = o.subsection;
 
@@ -632,7 +1743,9 @@
 		s.tab('diversion', _('Diversion Control'));
 
 		o = s.taboption('diversion', form.SectionValue, '_diversion', form.NamedSection, 'diversion', 'homeproxy');
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 		ss = o.subsection;
 
@@ -752,7 +1865,9 @@
 		s.tab('tailscale', _('Tailscale'));
 
 		o = s.taboption('tailscale', form.SectionValue, '_tailscale', form.NamedSection, 'tailscale', 'homeproxy');
+		o.depends('routing_mode', 'gfwlist');
 		o.depends('routing_mode', 'bypass_mainland_china');
+		o.depends('routing_mode', 'proxy_mainland_china');
 		o.depends('routing_mode', 'global');
 		ss = o.subsection;
 
diff -u a/root/etc/homeproxy/scripts/generate_client.uc b/root/etc/homeproxy/scripts/generate_client.uc
--- a/root/etc/homeproxy/scripts/generate_client.uc
+++ b/root/etc/homeproxy/scripts/generate_client.uc
@@ -8,6 +8,7 @@
 'use strict';
 
 import { readfile, writefile } from 'fs';
+import { isnan } from 'math';
 import { connect } from 'ubus';
 import { cursor } from 'uci';
 
@@ -32,12 +33,20 @@
       ucicontrol = 'control',
       ucitalscale = 'tailscale';
 
+const uciroutingsetting = 'routing',
+      uciroutingnode = 'routing_node',
+      uciroutingrule = 'routing_rule',
+      ucidnssetting = 'dns',
+      ucidnsserver = 'dns_server',
+      ucidnsrule = 'dns_rule',
+      uciruleset = 'ruleset';
+
 const ucinode = 'node';
 
 const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';
 
-if (!(routing_mode in ['bypass_mainland_china', 'global']))
-	die('Unsupported routing mode. Select bypass_mainland_china or global.');
+if (!(routing_mode in ['gfwlist', 'bypass_mainland_china', 'proxy_mainland_china', 'custom', 'global']))
+	die('Unsupported routing mode.');
 
 const lan_policy = resolveLanPolicy(uci, uciconfig);
 
@@ -80,7 +89,26 @@
 
 const ipv6_support = uci.get(uciconfig, ucimain, 'ipv6_support') || '0';
 
-const main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';
+let main_node, default_outbound, default_outbound_dns, domain_strategy,
+    dns_default_strategy = (ipv6_support === '1') ? 'prefer_ipv6' : 'prefer_ipv4',
+    dns_default_server, dns_disable_cache, dns_disable_cache_expire, dns_independent_cache,
+    dns_client_subnet, cache_file_store_rdrc, cache_file_rdrc_timeout;
+
+if (routing_mode === 'custom') {
+	default_outbound = uci.get(uciconfig, uciroutingsetting, 'default_outbound') || 'nil';
+	default_outbound_dns = uci.get(uciconfig, uciroutingsetting, 'default_outbound_dns') || 'default-dns';
+	domain_strategy = uci.get(uciconfig, uciroutingsetting, 'domain_strategy');
+	dns_default_strategy = uci.get(uciconfig, ucidnssetting, 'default_strategy') || dns_default_strategy;
+	dns_default_server = uci.get(uciconfig, ucidnssetting, 'default_server') || 'default-dns';
+	dns_disable_cache = uci.get(uciconfig, ucidnssetting, 'disable_cache');
+	dns_disable_cache_expire = uci.get(uciconfig, ucidnssetting, 'disable_cache_expire');
+	dns_independent_cache = uci.get(uciconfig, ucidnssetting, 'independent_cache');
+	dns_client_subnet = uci.get(uciconfig, ucidnssetting, 'client_subnet');
+	cache_file_store_rdrc = uci.get(uciconfig, ucidnssetting, 'cache_file_store_rdrc');
+	cache_file_rdrc_timeout = uci.get(uciconfig, ucidnssetting, 'cache_file_rdrc_timeout');
+} else {
+	main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';
+}
 
 const tailscale_tag = 'tailscale-out';
 const tailscale_enabled = uci.get(uciconfig, ucitalscale, 'enabled') === '1';
@@ -112,9 +140,12 @@
 	if (isEmpty(china_dns_server) || type(china_dns_server) !== 'string' || china_dns_server === 'wan')
 		china_dns_server = wan_dns;
 }
-const dns_default_strategy = (ipv6_support === '1') ? 'prefer_ipv6' : 'prefer_ipv4';
-
 let domain_groups = [];
+let mode_domain_list = [];
+if (routing_mode === 'gfwlist')
+	mode_domain_list = normalizeDomainList(readfile(HP_DIR + '/resources/gfw_list.txt'));
+else if (routing_mode === 'proxy_mainland_china')
+	mode_domain_list = normalizeDomainList(readfile(HP_DIR + '/resources/china_list.txt'));
 
 function add_domain_group(id, kind, node) {
 	const domains = normalizeDomainList(readfile(domainListPath(id)));
@@ -425,6 +456,50 @@
 	return endpoint;
 }
 
+function parse_port(strport) {
+	if (type(strport) !== 'array' || isEmpty(strport))
+		return null;
+	let ports = [];
+	for (let i in strport)
+		push(ports, int(i));
+	return ports;
+}
+
+function parse_dnsquery(strquery) {
+	if (type(strquery) !== 'array' || isEmpty(strquery))
+		return null;
+	let querys = [];
+	for (let i in strquery)
+		isnan(int(i)) ? push(querys, i) : push(querys, int(i));
+	return querys;
+}
+
+function get_resolver(cfg) {
+	if (isEmpty(cfg))
+		return null;
+	if (cfg in ['default-dns', 'system-dns'])
+		return cfg;
+	return 'cfg-' + cfg + '-dns';
+}
+
+function get_custom_outbound(cfg) {
+	if (isEmpty(cfg))
+		return null;
+	if (cfg in ['direct-out', 'block-out'])
+		return cfg;
+	return 'cfg-' + cfg + '-out';
+}
+
+function get_ruleset(cfg) {
+	if (isEmpty(cfg))
+		return null;
+	let rules = [];
+	for (let i in cfg)
+		if (!isEmpty(i))
+			push(rules, 'cfg-' + i + '-rule');
+	return rules;
+}
+
 /* Config helper end */
 
 const config = {};
@@ -489,6 +564,13 @@
 	});
 	config.dns.final = 'main-dns';
 
+	if (routing_mode in ['gfwlist', 'proxy_mainland_china'] && length(mode_domain_list))
+		push(config.dns.rules, {
+			rule_set: routing_mode === 'gfwlist' ? 'gfw-list' : 'china-list',
+			action: 'route',
+			server: 'main-dns'
+		});
+
 	if (tailscale_enabled) {
 		push(config.dns.servers, {
 			type: 'tailscale',
@@ -581,6 +663,69 @@
 			server: 'china-dns'
 		});
 	}
+} else if (routing_mode === 'custom' && !isEmpty(default_outbound)) {
+	uci.foreach(uciconfig, ucidnsserver, (cfg) => {
+		if (cfg.enabled !== '1')
+			return;
+		push(config.dns.servers, {
+			tag: 'cfg-' + cfg['.name'] + '-dns',
+			type: cfg.type,
+			server: cfg.server,
+			server_port: strToInt(cfg.server_port),
+			path: cfg.path,
+			headers: cfg.headers,
+			tls: cfg.tls_sni ? { enabled: true, server_name: cfg.tls_sni } : null,
+			domain_resolver: (cfg.address_resolver || cfg.address_strategy) ? {
+				server: get_resolver(cfg.address_resolver || dns_default_server),
+				strategy: cfg.address_strategy
+			} : null,
+			detour: get_custom_outbound(cfg.outbound)
+		});
+	});
+
+	uci.foreach(uciconfig, ucidnsrule, (cfg) => {
+		if (cfg.enabled !== '1')
+			return;
+		push(config.dns.rules, {
+			ip_version: strToInt(cfg.ip_version),
+			query_type: parse_dnsquery(cfg.query_type),
+			network: cfg.network,
+			protocol: cfg.protocol,
+			domain: cfg.domain,
+			domain_suffix: cfg.domain_suffix,
+			domain_keyword: cfg.domain_keyword,
+			domain_regex: cfg.domain_regex,
+			port: parse_port(cfg.port),
+			port_range: cfg.port_range,
+			source_ip_cidr: cfg.source_ip_cidr,
+			source_ip_is_private: strToBool(cfg.source_ip_is_private),
+			ip_cidr: cfg.ip_cidr,
+			ip_is_private: strToBool(cfg.ip_is_private),
+			source_port: parse_port(cfg.source_port),
+			source_port_range: cfg.source_port_range,
+			process_name: cfg.process_name,
+			process_path: cfg.process_path,
+			process_path_regex: cfg.process_path_regex,
+			user: cfg.user,
+			rule_set: get_ruleset(cfg.rule_set),
+			rule_set_ip_cidr_match_source: strToBool(cfg.rule_set_ip_cidr_match_source),
+			rule_set_ip_cidr_accept_empty: strToBool(cfg.rule_set_ip_cidr_accept_empty),
+			invert: strToBool(cfg.invert),
+			action: cfg.action,
+			server: get_resolver(cfg.server),
+			strategy: cfg.domain_strategy,
+			disable_cache: strToBool(cfg.dns_disable_cache),
+			rewrite_ttl: strToInt(cfg.rewrite_ttl),
+			client_subnet: cfg.client_subnet,
+			method: cfg.reject_method,
+			no_drop: strToBool(cfg.reject_no_drop),
+			rcode: cfg.predefined_rcode,
+			answer: cfg.predefined_answer,
+			ns: cfg.predefined_ns,
+			extra: cfg.predefined_extra
+		});
+	});
+	config.dns.final = get_resolver(dns_default_server);
 }
 /* DNS end */
 
@@ -707,6 +852,65 @@
 	for (let group in domain_groups)
 		if (group.kind === 'node' && !(group.node === main_node && main_node !== 'urltest'))
 			append_required_node(group.node);
+} else if (routing_mode === 'custom' && !isEmpty(default_outbound)) {
+	let routing_nodes = [], urltest_nodes = [];
+	push(config.outbounds, { type: 'block', tag: 'block-out' });
+
+	uci.foreach(uciconfig, uciroutingnode, (cfg) => {
+		if (cfg.enabled !== '1')
+			return;
+		if (cfg.node === 'urltest') {
+			push(config.outbounds, {
+				type: 'urltest',
+				tag: 'cfg-' + cfg['.name'] + '-out',
+				outbounds: map(cfg.urltest_nodes, (k) => get_node_outbound_tag(k)),
+				url: cfg.urltest_url,
+				interval: strToTime(cfg.urltest_interval),
+				tolerance: strToInt(cfg.urltest_tolerance),
+				idle_timeout: strToTime(cfg.urltest_idle_timeout),
+				interrupt_exist_connections: strToBool(cfg.urltest_interrupt_exist_connections)
+			});
+			urltest_nodes = [...urltest_nodes, ...filter(cfg.urltest_nodes, (l) => !~index(urltest_nodes, l))];
+			return;
+		}
+		const outbound = uci.get_all(uciconfig, cfg.node) || {};
+		if (isEmpty(outbound))
+			die(`Routing node ${cfg['.name']} references unavailable node ${cfg.node}.`);
+		if (outbound.type === 'wireguard') {
+			const endpoint = generate_endpoint(outbound);
+			if (endpoint) {
+				endpoint.tag = 'cfg-' + cfg['.name'] + '-out';
+				endpoint.bind_interface = cfg.bind_interface;
+				endpoint.detour = get_custom_outbound(cfg.outbound);
+				if (cfg.domain_resolver)
+					endpoint.domain_resolver = { server: get_resolver(cfg.domain_resolver), strategy: cfg.domain_strategy };
+				push(config.endpoints, endpoint);
+			}
+		} else {
+			const rendered = generate_outbound(outbound);
+			if (rendered) {
+				addECHDNS(config, outbound, { server: 'default-dns', strategy: dns_default_strategy });
+				rendered.tag = 'cfg-' + cfg['.name'] + '-out';
+				rendered.bind_interface = cfg.bind_interface;
+				rendered.detour = get_custom_outbound(cfg.outbound);
+				if (cfg.domain_resolver)
+					rendered.domain_resolver = { server: get_resolver(cfg.domain_resolver), strategy: cfg.domain_strategy };
+				push(config.outbounds, rendered);
+			}
+		}
+		push(routing_nodes, cfg.node);
+	});
+
+	for (let i in filter(urltest_nodes, (l) => !~index(routing_nodes, l))) {
+		const node = uci.get_all(uciconfig, i) || {};
+		if (node.type === 'wireguard') {
+			const endpoint = generate_endpoint(node);
+			if (endpoint) { endpoint.tag = get_node_outbound_tag(i); push(config.endpoints, endpoint); }
+		} else {
+			const rendered = generate_outbound(node);
+			if (rendered) push(config.outbounds, rendered);
+		}
+	}
 }
 
 if (isEmpty(config.endpoints))
@@ -789,6 +993,20 @@
 		push_route(config.route.rules, { preferred_by: tailscale_tag }, tailscale_tag);
 	add_control_fallback_rules(config.route.rules, control);
 
+	if (routing_mode in ['gfwlist', 'proxy_mainland_china'] && length(mode_domain_list))
+		push(config.route.rules, {
+			rule_set: routing_mode === 'gfwlist' ? 'gfw-list' : 'china-list',
+			action: 'route',
+			outbound: 'main-out'
+		});
+
+	if (routing_mode in ['gfwlist', 'proxy_mainland_china'] && length(mode_domain_list))
+		push(config.route.rule_set, {
+			type: 'inline',
+			tag: routing_mode === 'gfwlist' ? 'gfw-list' : 'china-list',
+			rules: [{ domain_suffix: mode_domain_list }]
+		});
+
 	if (routing_mode === 'bypass_mainland_china') {
 		push(config.route.rules, {
 			rule_set: 'geosite-cn',
@@ -802,7 +1020,7 @@
 		});
 	}
 
-	config.route.final = 'main-out';
+	config.route.final = (routing_mode in ['gfwlist', 'proxy_mainland_china']) ? 'direct-out' : 'main-out';
 
 	for (let group in domain_groups) {
 		add_inline_domain_rule_set(config.route.rule_set, group, 'suffix');
@@ -815,12 +1033,98 @@
 
 	if (isEmpty(config.route.rule_set))
 		config.route.rule_set = null;
+} else if (routing_mode === 'custom' && !isEmpty(default_outbound)) {
+	config.route.default_domain_resolver = {
+		action: 'resolve',
+		server: get_resolver(default_outbound_dns)
+	};
+
+	if (domain_strategy)
+		push(config.route.rules, { action: 'resolve', strategy: domain_strategy });
+
+	uci.foreach(uciconfig, uciroutingrule, (cfg) => {
+		if (cfg.enabled !== '1')
+			return;
+
+		const rule = {
+			ip_version: strToInt(cfg.ip_version),
+			protocol: cfg.protocol,
+			network: cfg.network,
+			client: cfg.client,
+			domain: cfg.domain,
+			domain_suffix: cfg.domain_suffix,
+			domain_keyword: cfg.domain_keyword,
+			domain_regex: cfg.domain_regex,
+			source_ip_cidr: cfg.source_ip_cidr,
+			source_ip_is_private: strToBool(cfg.source_ip_is_private),
+			ip_cidr: cfg.ip_cidr,
+			ip_is_private: strToBool(cfg.ip_is_private),
+			source_mac_address: cfg.source_mac_address,
+			source_hostname: cfg.source_hostname,
+			source_port: parse_port(cfg.source_port),
+			source_port_range: cfg.source_port_range,
+			port: parse_port(cfg.port),
+			port_range: cfg.port_range,
+			process_name: cfg.process_name,
+			process_path: cfg.process_path,
+			process_path_regex: cfg.process_path_regex,
+			user: cfg.user,
+			rule_set: get_ruleset(cfg.rule_set),
+			rule_set_ip_cidr_match_source: strToBool(cfg.rule_set_ip_cidr_match_source),
+			invert: strToBool(cfg.invert),
+			action: cfg.action,
+			outbound: get_custom_outbound(cfg.outbound),
+			override_address: cfg.override_address,
+			override_port: strToInt(cfg.override_port),
+			udp_disable_domain_unmapping: strToBool(cfg.udp_disable_domain_unmapping),
+			udp_connect: strToBool(cfg.udp_connect),
+			udp_timeout: strToTime(cfg.udp_timeout),
+			tls_fragment: strToBool(cfg.tls_fragment),
+			tls_fragment_fallback_delay: strToTime(cfg.tls_fragment_fallback_delay),
+			tls_record_fragment: strToBool(cfg.tls_record_fragment),
+			tls_spoof: cfg.tls_spoof || null,
+			tls_spoof_method: cfg.tls_spoof_method || null
+		};
+		if (cfg.action === 'resolve') {
+			rule.server = get_resolver(cfg.resolve_server);
+			rule.strategy = cfg.resolve_strategy;
+			rule.disable_cache = strToBool(cfg.resolve_disable_cache);
+			rule.disable_optimistic_cache = strToBool(cfg.resolve_disable_optimistic_cache);
+			rule.rewrite_ttl = strToInt(cfg.resolve_rewrite_ttl);
+			rule.timeout = strToTime(cfg.resolve_timeout);
+			rule.client_subnet = cfg.resolve_client_subnet;
+		}
+		if (cfg.action === 'reject') {
+			rule.method = cfg.reject_method;
+			rule.no_drop = strToBool(cfg.reject_no_drop);
+		}
+		push(config.route.rules, rule);
+	});
+
+	config.route.final = get_custom_outbound(default_outbound);
+
+	uci.foreach(uciconfig, uciruleset, (cfg) => {
+		if (cfg.enabled !== '1')
+			return;
+		push(config.route.rule_set, {
+			type: cfg.type,
+			tag: 'cfg-' + cfg['.name'] + '-rule',
+			format: cfg.format,
+			path: cfg.path,
+			url: cfg.url,
+			download_detour: get_custom_outbound(cfg.outbound),
+			update_interval: cfg.update_interval
+		});
+	});
+
+	if (isEmpty(config.route.rule_set))
+		config.route.rule_set = null;
 }
 /* Routing rules end */
 
 /* Experimental start */
 const enable_clash_api = main_node === 'urltest';
-const enable_cache_file = routing_mode === 'bypass_mainland_china';
+const enable_cache_file = routing_mode in ['bypass_mainland_china', 'custom'];
 if (enable_clash_api || enable_cache_file) {
 	config.experimental = {
 		clash_api: enable_clash_api ? {
diff -u a/root/etc/homeproxy/scripts/migrate_config.uc b/root/etc/homeproxy/scripts/migrate_config.uc
--- a/root/etc/homeproxy/scripts/migrate_config.uc
+++ b/root/etc/homeproxy/scripts/migrate_config.uc
@@ -86,7 +86,7 @@
 	setDefault('infra', 'common_port', updatedCommonPort);
 
 /* Keep only the supported routing modes. */
-if (!(uci.get(uciconfig, 'config', 'routing_mode') in ['bypass_mainland_china', 'global']))
+if (!(uci.get(uciconfig, 'config', 'routing_mode') in ['gfwlist', 'bypass_mainland_china', 'proxy_mainland_china', 'custom', 'global']))
 	uci.set(uciconfig, 'config', 'routing_mode', 'bypass_mainland_china');
 deleteOptions('config', [
 	'proxy_mode',
diff -u a/root/etc/init.d/homeproxy b/root/etc/init.d/homeproxy
--- a/root/etc/init.d/homeproxy
+++ b/root/etc/init.d/homeproxy
@@ -202,7 +202,11 @@
 	config_get routing_mode "config" "routing_mode" "bypass_mainland_china"
 
 	local outbound_node
-	config_get outbound_node "config" "main_node" "nil"
+	if [ "$routing_mode" = "custom" ]; then
+		config_get outbound_node "routing" "default_outbound" "nil"
+	else
+		config_get outbound_node "config" "main_node" "nil"
+	fi
 
 	local server_enabled
 	config_get_bool server_enabled "server" "enabled" "0"
@@ -268,13 +272,17 @@
 	fi
 
 	case "$client_ready:$routing_mode" in
-	"1:bypass_mainland_china")
+	"1:bypass_mainland_china"|"1:custom")
 		mkdir -p "$CACHE_DIR"
 		touch "$CACHE_PATH"
 		chown -R sing-box:sing-box "$CACHE_DIR"
 		;;
 	esac
 
+	if [ "$client_ready" -eq 1 ] && [ "$routing_mode" = "custom" ]; then
+		mkdir -p "$HP_DIR/ruleset"
+	fi
+
 	# Prepare firewall before sing-box inserts native TUN auto-redirect rules.
 	local firewall_ready=1
 	if ! HOMEPROXY_SERVER_READY="$server_ready" \
ZN_HOMEProxy_PATCH_EOF

# Hard guarantees: this patch must never use fuzz/force/reverse.
if grep -qE '/mnt/data/|^[+-]{3} .*\t[0-9]{4}-[0-9]{2}-[0-9]{2}' "$PATCH_FILE"; then
    echo "[ERROR] Embedded patch contains snapshot path/date metadata."
    exit 1
fi

# Already-patched detection: all major markers must agree.
is_already_patched() {
    grep -q "routing_mode.*custom" "$GEN_FILE" &&
    grep -q "routing_node" "$GEN_FILE" &&
    grep -q "routing_rule" "$GEN_FILE" &&
    grep -q "routing_rule" "$UI_FILE" &&
    grep -q "source_mac_address" "$GEN_FILE" &&
    grep -q "source_hostname" "$GEN_FILE" &&
    grep -q "tls_spoof_method" "$GEN_FILE" &&
    grep -q "disable_optimistic_cache" "$GEN_FILE" &&
    grep -q "resolve_timeout" "$GEN_FILE" &&
    ! grep -q "sniff_override_destination" "$GEN_FILE" &&
    ! grep -q "stack: tcpip_stack" "$GEN_FILE"
}

if is_already_patched; then
    echo "[ZN-HomeProxy] Custom Routing patch already present; no changes made."
else
    # Detect partial/legacy merge. Never guess how to repair it.
    if grep -q "routing_node" "$GEN_FILE" || grep -q "routing_rule" "$GEN_FILE" || \
       grep -q "routing_node" "$UI_FILE" || grep -q "routing_rule" "$UI_FILE"; then
        echo "[ERROR] Partial/foreign Custom Routing changes detected; refusing to guess."
        exit 1
    fi

    cp -a "$GEN_FILE" "$BACKUP_DIR/generate_client.uc"
    cp -a "$UI_FILE" "$BACKUP_DIR/client.js"
    [ -f "$MIGRATE_FILE" ] && cp -a "$MIGRATE_FILE" "$BACKUP_DIR/migrate_config.uc"
    [ -f "$INIT_FILE" ] && cp -a "$INIT_FILE" "$BACKUP_DIR/homeproxy.init"

    echo "[ZN-HomeProxy] Dry-run Custom Routing patch..."
    if ! (cd "$HP_PATH" && patch --dry-run --batch --forward --fuzz=0 -p1 < "$PATCH_FILE"); then
        echo "[ERROR] Patch does not cleanly apply to current HomeProxy source."
        echo "[ERROR] No source files were modified."
        exit 1
    fi

    echo "[ZN-HomeProxy] Applying Custom Routing patch..."
    if ! (cd "$HP_PATH" && patch --batch --forward --fuzz=0 -p1 < "$PATCH_FILE"); then
        echo "[ERROR] Patch application failed; restoring backups."
        cp -af "$BACKUP_DIR/generate_client.uc" "$GEN_FILE"
        cp -af "$BACKUP_DIR/client.js" "$UI_FILE"
        [ -f "$BACKUP_DIR/migrate_config.uc" ] && cp -af "$BACKUP_DIR/migrate_config.uc" "$MIGRATE_FILE"
        [ -f "$BACKUP_DIR/homeproxy.init" ] && cp -af "$BACKUP_DIR/homeproxy.init" "$INIT_FILE"
        exit 1
    fi
fi

# ============================================================
# 5. Strict post-patch validation
# ============================================================

fail=0
check() {
    local desc="$1"; shift
    if "$@"; then
        printf '[PASS] %s\n' "$desc"
    else
        printf '[FAIL] %s\n' "$desc"
        fail=1
    fi
}

check "five routing modes" bash -c "grep -q \"o.value('gfwlist'\" '$UI_FILE' && grep -q \"o.value('bypass_mainland_china'\" '$UI_FILE' && grep -q \"o.value('proxy_mainland_china'\" '$UI_FILE' && grep -q \"o.value('custom'\" '$UI_FILE' && grep -q \"o.value('global'\" '$UI_FILE'"
check "generator custom mode" grep -q "routing_mode === 'custom'" "$GEN_FILE"
check "routing_node" grep -q "uciroutingnode" "$GEN_FILE"
check "routing_rule" grep -q "uciroutingrule" "$GEN_FILE"
check "client" grep -q "client:" "$GEN_FILE"
check "source_mac_address" grep -q "source_mac_address:" "$GEN_FILE"
check "source_hostname" grep -q "source_hostname:" "$GEN_FILE"
check "tls_spoof" grep -q "tls_spoof:" "$GEN_FILE"
check "tls_spoof_method" grep -q "tls_spoof_method:" "$GEN_FILE"
check "resolve.disable_optimistic_cache" grep -q "resolve_disable_optimistic_cache" "$GEN_FILE"
check "resolve.timeout" grep -q "resolve_timeout" "$GEN_FILE"
check "modern sniff" grep -q "action: 'sniff'" "$GEN_FILE"
check "no legacy sniff_override_destination" bash -c "! grep -q 'sniff_override_destination' '$GEN_FILE'"
check "no legacy TUN stack" bash -c "! grep -q 'stack: tcpip_stack' '$GEN_FILE'"
check "migration supports five routing modes" bash -c 'grep -q "routing_mode.*custom" "$1" && grep -q "tcpip_stack" "$1"' _ "$MIGRATE_FILE"
check "init validation uses sing-box check" grep -q '\$PROG" check --config' "$INIT_FILE"

if [ "$fail" -ne 0 ]; then
    echo "[ERROR] Validation failed; restoring patched source."
    cp -af "$BACKUP_DIR/generate_client.uc" "$GEN_FILE" 2>/dev/null || true
    cp -af "$BACKUP_DIR/client.js" "$UI_FILE" 2>/dev/null || true
    [ -f "$BACKUP_DIR/migrate_config.uc" ] && cp -af "$BACKUP_DIR/migrate_config.uc" "$MIGRATE_FILE" 2>/dev/null || true
    [ -f "$BACKUP_DIR/homeproxy.init" ] && cp -af "$BACKUP_DIR/homeproxy.init" "$INIT_FILE" 2>/dev/null || true
    exit 1
fi

# ============================================================
# 6. sysupgrade persistence
# ============================================================

SYSUPGRADE_CONF="$ROOT/package/base-files/files/etc/sysupgrade.conf"
if [ -d "$ROOT/package/base-files" ]; then
    mkdir -p "$(dirname "$SYSUPGRADE_CONF")"
    if ! grep -qxF "/etc/homeproxy/private_srs/" "$SYSUPGRADE_CONF" 2>/dev/null; then
        echo "/etc/homeproxy/private_srs/" >> "$SYSUPGRADE_CONF"
        echo "[ZN-HomeProxy] Added private_srs to sysupgrade.conf"
    else
        echo "[ZN-HomeProxy] private_srs already exists in sysupgrade.conf"
    fi
fi

echo "=== ZN HomeProxy processing complete ==="
