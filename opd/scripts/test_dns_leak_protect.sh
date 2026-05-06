#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT_DIR/clashoo/files/usr/share/clashoo/runtime/dns_helpers.sh"
YUM_CHANGE="$ROOT_DIR/clashoo/files/usr/share/clashoo/runtime/yum_change.sh"

if grep -q 'echo "   geosite:" >> /tmp/fallback.yaml' "$YUM_CHANGE" ||
   grep -q 'DST-PORT,853,REJECT' "$YUM_CHANGE"; then
	echo "yum_change.sh still injects dns_leak_protect directly instead of leaving final reconciliation to dns_helpers.sh" >&2
	exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- 用例 1：2 空格缩进 + 已有 fallback-filter，开启 dns_leak_protect ---
cfg="$tmp/mihomo.yaml"
cat > "$cfg" <<'YAML'
mixed-port: 7890
dns:
  enable: true
  ipv6: true
  fallback:
    - https://cloudflare-dns.com/dns-query
  fallback-filter:
    geoip: true
rules:
  - DST-PORT,853,DIRECT
  - MATCH,Proxy
YAML

# 连续两次幂等：marker 块只能存在一份
dns_mihomo_apply_leak_protect "$cfg" 1 false
dns_mihomo_apply_leak_protect "$cfg" 1 false

[ "$(grep -c '^[[:space:]]*ipv6:' "$cfg")" -eq 1 ]
grep -q '^  ipv6: false$' "$cfg"
[ "$(grep -c '# >>> clashoo:dns_leak_protect$' "$cfg")" -eq 1 ]
[ "$(grep -c '# <<< clashoo:dns_leak_protect$' "$cfg")" -eq 1 ]
[ "$(grep -c '# >>> clashoo:dns_leak_protect_rule' "$cfg")" -eq 1 ]
[ "$(grep -c '# <<< clashoo:dns_leak_protect_rule' "$cfg")" -eq 1 ]
grep -q '^    geosite:$' "$cfg"
grep -q '^      - gfw$' "$cfg"
[ "$(grep -c '^[[:space:]]*- DST-PORT,853,REJECT' "$cfg")" -eq 1 ]
grep -q '^  - DST-PORT,853,DIRECT$' "$cfg"
# 用户原本的 geoip: true 必须保留
grep -q '^    geoip: true$' "$cfg"

# --- 用例 2：cycle 关闭，按 ipv6_value=true 收敛，marker/853 必须清理干净 ---
dns_mihomo_apply_leak_protect "$cfg" 0 true

grep -q '^  ipv6: true$' "$cfg"
[ "$(grep -c '^[[:space:]]*ipv6:' "$cfg")" -eq 1 ]
! grep -q 'clashoo:dns_leak_protect' "$cfg"
! grep -q '^[[:space:]]*- gfw$' "$cfg"
! grep -q '^[[:space:]]*- DST-PORT,853,REJECT' "$cfg"
# 用户原本的 fallback-filter 外壳 + geoip:true 应保留
grep -q '^  fallback-filter:$' "$cfg"
grep -q '^    geoip: true$' "$cfg"
grep -q '^  - DST-PORT,853,DIRECT$' "$cfg"

# --- 用例 3：再次开启，验证 cycle 1→0→1 后状态正确 ---
dns_mihomo_apply_leak_protect "$cfg" 1 false

grep -q '^  ipv6: false$' "$cfg"
[ "$(grep -c '# >>> clashoo:dns_leak_protect$' "$cfg")" -eq 1 ]
[ "$(grep -c '# >>> clashoo:dns_leak_protect_rule' "$cfg")" -eq 1 ]
grep -q '^      - gfw$' "$cfg"
[ "$(grep -c '^[[:space:]]*- DST-PORT,853,REJECT' "$cfg")" -eq 1 ]

# --- 用例 4：ipv6_value="" 时不写 ipv6 行（用户未配置 enable_ipv6 的场景）---
cfg_noipv6="$tmp/mihomo-noipv6.yaml"
cat > "$cfg_noipv6" <<'YAML'
dns:
  enable: true
rules:
  - MATCH,Proxy
YAML
dns_mihomo_apply_leak_protect "$cfg_noipv6" 0 ""
! grep -q '^[[:space:]]*ipv6:' "$cfg_noipv6"

# --- 用例 5：4 空格缩进 + 不存在 fallback-filter，需要创建骨架 ---
cfg4="$tmp/mihomo-4space.yaml"
cat > "$cfg4" <<'YAML'
dns:
    enable: true
    fallback:
      - https://dns.google/dns-query
proxies: []
YAML

dns_mihomo_apply_leak_protect "$cfg4" 1 false
grep -q '^    fallback-filter:$' "$cfg4"
grep -q '^      geoip: false$' "$cfg4"
grep -q '^      # >>> clashoo:dns_leak_protect$' "$cfg4"
grep -q '^      geosite:$' "$cfg4"
grep -q '^        - gfw$' "$cfg4"
grep -q '^      # <<< clashoo:dns_leak_protect$' "$cfg4"
grep -q '^    ipv6: false$' "$cfg4"
grep -q '^rules:$' "$cfg4"
grep -q '^  - DST-PORT,853,REJECT$' "$cfg4"

# --- 用例 6：用户原本已有 geosite:gfw 和 853 reject，开启/关闭不能重复或删除用户规则 ---
cfg_user="$tmp/mihomo-user-owned.yaml"
cat > "$cfg_user" <<'YAML'
dns:
  enable: true
  fallback-filter:
    geoip: true
    geosite:
      - gfw
rules:
  - DST-PORT,853,REJECT
  - MATCH,Proxy
YAML

dns_mihomo_apply_leak_protect "$cfg_user" 1 false
[ "$(grep -c '^[[:space:]]*geosite:' "$cfg_user")" -eq 1 ]
[ "$(grep -c '^[[:space:]]*- gfw$' "$cfg_user")" -eq 1 ]
! grep -q '# >>> clashoo:dns_leak_protect$' "$cfg_user"
[ "$(grep -c '^[[:space:]]*- DST-PORT,853,REJECT' "$cfg_user")" -eq 1 ]
! grep -q '# >>> clashoo:dns_leak_protect_rule$' "$cfg_user"

dns_mihomo_apply_leak_protect "$cfg_user" 0 true
grep -q '^  ipv6: true$' "$cfg_user"
grep -q '^      - gfw$' "$cfg_user"
grep -q '^  - DST-PORT,853,REJECT$' "$cfg_user"

printf 'DNS leak protect tests passed\n'
