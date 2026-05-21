#!/bin/bash
set -euo pipefail

# ============================================================
#  KixDNS 一键部署/卸载脚本
#  https://github.com/olicesx/kixdns
#  用法（CDN优先，直连兜底）:
#    curl -fsSL https://cdn.jsdelivr.net/gh/utada1stlove/kixdns-deploy@main/deploy.sh -o /tmp/kixdns.sh && sudo bash /tmp/kixdns.sh
#  或代理加速:
#    curl -fsSL https://mirror.ghproxy.com/https://raw.githubusercontent.com/utada1stlove/kixdns-deploy/refs/heads/main/deploy.sh -o /tmp/kixdns.sh && sudo bash /tmp/kixdns.sh
#  或 GitHub 直连:
#    curl -fsSL https://raw.githubusercontent.com/utada1stlove/kixdns-deploy/refs/heads/main/deploy.sh -o /tmp/kixdns.sh && sudo bash /tmp/kixdns.sh
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

confirm() {
    local prompt="$1" default="${2:-Y}"
    local yn
    if [ "$default" = "Y" ]; then
        read -rp "$prompt [Y/n] " yn
        case "$yn" in [nN]*) return 1 ;; esac
    else
        read -rp "$prompt [y/N] " yn
        case "$yn" in [yY]) return 0 ;; esac
        return 1
    fi
    return 0
}

# ============================================================
#  预设 DNS 上游表
#  name|DoH URL|UDP addr|DoT URL
# ============================================================
DNS_PRESETS=(
    "阿里 DNS|https://dns.alidns.com/dns-query|223.5.5.5:53|dot://dns.alidns.com:853"
    "腾讯 DNSPod|https://doh.pub/dns-query|119.29.29.29:53|dot://dot.pub:853"
    "清华 TUNA|https://dns.tuna.tsinghua.edu.cn/dns-query|101.6.6.6:53|"
    "114 DNS||114.114.114.114:53|"
    "Cloudflare|https://cloudflare-dns.com/dns-query|1.1.1.1:53|dot://1.1.1.1:853"
    "Google|https://dns.google/dns-query|8.8.8.8:53|dot://8.8.8.8:853"
    "Quad9|https://dns.quad9.net/dns-query|9.9.9.9:53|dot://dns.quad9.net:853"
)

DNS_NAMES=(); DNS_DOHS=(); DNS_UDPS=(); DNS_DOTS=()
for entry in "${DNS_PRESETS[@]}"; do
    IFS='|' read -r name doh udp dot <<< "$entry"
    DNS_NAMES+=("$name"); DNS_DOHS+=("$doh")
    DNS_UDPS+=("$udp"); DNS_DOTS+=("$dot")
done

# ============================================================
#  检测 root / 架构
# ============================================================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "请以 root 运行: sudo bash deploy.sh"
    fi
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  BINARY="kixdns-linux-x86_64-gnu"  ;;
        aarch64) BINARY="kixdns-linux-arm64-gnu"    ;;
        *)       fail "不支持的架构: $arch（仅支持 x86_64 / aarch64）" ;;
    esac
    info "检测到架构: $arch → $BINARY"
}

# ============================================================
#  交互菜单
# ============================================================
print_menu() {
    local title="$1"; shift
    local items=("$@")
    echo ""
    echo "========================================"
    echo "  $title"
    echo "========================================"
    for i in "${!items[@]}"; do
        printf "  [%d] %s\n" $((i+1)) "${items[$i]}"
    done
    echo "----------------------------------------"
}

select_region() {
    local items=("国内版 — Ali DoQ 优先 + DNS 污染检测 + AAAA 抑制 + 广告拦截"
                 "海外版 — DoH/DoT 加密优先 + 保留 AAAA + 广告拦截")
    print_menu "选择部署模式" "${items[@]}"
    local choice
    read -rp "请输入数字 (1-2): " choice
    case "$choice" in
        1) REGION="cn";    ok "已选择: 国内版" ;;
        2) REGION="global"; ok "已选择: 海外版" ;;
        *) fail "输入无效" ;;
    esac
}

select_dns() {
    local items=("${DNS_NAMES[@]}" "自定义")
    print_menu "选择上游 DNS（多选，多个用逗号或范围分隔，如 1,3,5 或 1-4）" "${items[@]}"
    local choice total=$(( ${#DNS_NAMES[@]} + 1 ))
    read -rp "请输入数字: " choice

    local -a selected_indices=()
    IFS=',' read -ra parts <<< "$choice"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((i=10#${BASH_REMATCH[1]}; i<=10#${BASH_REMATCH[2]}; i++)); do
                selected_indices+=("$i")
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            selected_indices+=("$part")
        fi
    done

    local -a upstreams=()
    local first_udp=""
    local -a selected_names=()

    for idx in "${selected_indices[@]}"; do
        if [ "$idx" -eq "$total" ]; then
            echo "--- 自定义 DNS ---"
            read -rp "DoH URL（留空跳过）: " custom_doh
            read -rp "UDP 地址（留空跳过）: " custom_udp
            read -rp "DoT URL（留空跳过）: " custom_dot
            if [ -n "$custom_doh" ]; then upstreams+=("$custom_doh"); fi
            if [ -n "$custom_dot" ]; then upstreams+=("$custom_dot"); fi
            if [ -n "$custom_udp" ]; then upstreams+=("$custom_udp"); fi
            if [ ${#upstreams[@]} -eq 0 ]; then
                fail "自定义上游至少需要一个 URL"
            fi
            selected_names+=("自定义")
            [ -z "$first_udp" ] && [ -n "$custom_udp" ] && first_udp="$custom_udp"
        elif [ "$idx" -ge 1 ] && [ "$idx" -le "${#DNS_NAMES[@]}" ]; then
            local i=$((idx-1))
            local doh="${DNS_DOHS[$i]}" dot="${DNS_DOTS[$i]}" udp="${DNS_UDPS[$i]}"
            [ -n "$doh" ] && upstreams+=("$doh")
            [ -n "$dot" ] && upstreams+=("$dot")
            [ -n "$udp" ] && upstreams+=("$udp")
            selected_names+=("${DNS_NAMES[$i]}")
            [ -z "$first_udp" ] && [ -n "$udp" ] && first_udp="$udp"
        fi
    done

    if [ ${#upstreams[@]} -eq 0 ]; then
        fail "请至少选择一个有效的 DNS 上游"
    fi

    local json_items=""
    for u in "${upstreams[@]}"; do
        json_items+="\"$u\","
    done
    json_items="${json_items%,}"
    UPSTREAMS_JSON="[$json_items]"

    if [ -z "$first_udp" ]; then
        DEFAULT_UDP="${upstreams[0]}"
    else
        DEFAULT_UDP="$first_udp"
    fi

    local names_str=""
    for n in "${selected_names[@]}"; do
        names_str+="$n, "
    done
    SELECTED_NAMES="${names_str%, }"

    ok "已选择: $SELECTED_NAMES"
}

# ============================================================
#  CDN 下载（带镜像回退）
# ============================================================
try_download() {
    local dest="$1"; shift
    for url in "$@"; do
        if command -v wget &>/dev/null; then
            if wget -q --timeout=15 "$url" -O "$dest" 2>/dev/null; then
                return 0
            fi
        elif command -v curl &>/dev/null; then
            if curl -fsSL --connect-timeout 15 "$url" -o "$dest" 2>/dev/null; then
                return 0
            fi
        fi
    done
    return 1
}

download_binary() {
    info "下载 kixdns 二进制..."
    mkdir -p /usr/local/bin

    local gh_url="https://github.com/olicesx/kixdns/releases/download/v0.1.0/$BINARY"
    local urls=(
        "https://mirror.ghproxy.com/$gh_url"
        "https://gh-proxy.com/$gh_url"
        "$gh_url"
    )

    if try_download /usr/local/bin/kixdns "${urls[@]}"; then
        chmod +x /usr/local/bin/kixdns
        ok "二进制已安装: /usr/local/bin/kixdns"
    else
        fail "下载失败，请手动下载:\n  wget $gh_url -O /usr/local/bin/kixdns && chmod +x /usr/local/bin/kixdns"
    fi
}

download_geosite() {
    local gh_url="https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
    local urls=(
        "https://mirror.ghproxy.com/$gh_url"
        "https://gh-proxy.com/$gh_url"
        "https://cdn.jsdelivr.net/gh/v2fly/domain-list-community@release/dlc.dat"
        "$gh_url"
    )

    if confirm "下载 geosite.dat (~10MB)？广告/恶意域名拦截需要此文件"; then
        info "下载 geosite.dat ..."
        if try_download /etc/kixdns/geosite.dat "${urls[@]}"; then
            ok "geosite.dat 已下载"
        else
            warn "下载失败，请手动下载:"
            echo "  sudo wget -O /etc/kixdns/geosite.dat \\"
            echo "    $gh_url"
        fi
    else
        warn "跳过 geosite.dat 下载。需要时运行："
        echo "  sudo wget -O /etc/kixdns/geosite.dat \\"
        echo "    $gh_url"
    fi
}

# ============================================================
#  生成配置
# ============================================================
generate_config() {
    info "生成 /etc/kixdns/config.json ..."
    mkdir -p /etc/kixdns

    if [ "$REGION" = "cn" ]; then
        generate_cn_config
    else
        generate_global_config
    fi

    sed -i "s|__UPSTREAMS__|${UPSTREAMS_JSON}|g" /etc/kixdns/config.json
    sed -i "s|__DEFAULT_UDP__|${DEFAULT_UDP}|g" /etc/kixdns/config.json

    ok "配置已生成: /etc/kixdns/config.json"
}

generate_cn_config() {
    cat > /etc/kixdns/config.json << 'CNEOF'
{
  "version": "1.0",
  "settings": {
    "bind_udp": "0.0.0.0:8844",
    "bind_tcp": "0.0.0.0:8844",
    "min_ttl": 60,
    "default_upstream": "__DEFAULT_UDP__",
    "upstream_timeout_ms": 3000,
    "request_timeout_ms": 9000,
    "response_jump_limit": 10,
    "enable_tcp_fallback": true,
    "cache_capacity": 50000,
    "cache_max_ttl": 86400,
    "cache_background_refresh": true,
    "cache_refresh_threshold_percent": 15,
    "cache_refresh_min_ttl": 10,
    "serve_stale": true,
    "serve_stale_ttl": 60,
    "serve_stale_expire_ttl": 172800,
    "serve_stale_ttl_reset": true,
    "udp_pool_size": 128,
    "tcp_pool_size": 64,
    "doh_pool_size": 16,
    "dot_pool_size": 16,
    "doq_pool_size": 16,
    "doq_enable_0rtt": true,
    "flow_control_enabled": true,
    "flow_control_initial_permits": 500,
    "flow_control_min_permits": 100,
    "flow_control_max_permits": 1200,
    "flow_control_latency_threshold_ms": 180,
    "geosite_data_paths": ["/etc/kixdns/geosite.dat"]
  },
  "pipeline_select": [
    {
      "pipeline": "ipv6_off",
      "matchers": [{ "type": "qtype", "value": "AAAA" }]
    },
    {
      "pipeline": "blocked",
      "matchers": [{ "type": "geo_site", "value": "category-ads" }]
    },
    {
      "pipeline": "blocked",
      "matchers": [{ "type": "geo_site", "value": "malware" }]
    },
    {
      "pipeline": "sinkhole",
      "matchers": [{ "type": "domain_regex", "value": "(?i)(^|\\.)(track(er|ing)?|analytics|pixel|beacon)\\.(com|io|net|org|cn)" }]
    },
    {
      "pipeline": "internal",
      "matchers": [
        { "type": "client_ip", "cidr": "10.0.0.0/8" },
        { "type": "client_ip", "cidr": "172.16.0.0/12", "operator": "or" },
        { "type": "client_ip", "cidr": "192.168.0.0/16", "operator": "or" }
      ]
    },
    {
      "pipeline": "china_dns",
      "matchers": [{ "type": "geo_site", "value": "cn" }]
    },
    {
      "pipeline": "international",
      "matchers": [{ "type": "geo_site_not", "value": "cn" }]
    },
    {
      "pipeline": "default",
      "matchers": [{ "type": "any" }]
    }
  ],
  "pipelines": [
    {
      "id": "ipv6_off",
      "rules": [{
        "name": "suppress-aaaa",
        "matchers": [{ "type": "any" }],
        "actions": [
          { "type": "log", "level": "debug" },
          { "type": "static_response", "rcode": "NOERROR" }
        ]
      }]
    },
    {
      "id": "blocked",
      "rules": [{
        "name": "block-ads-malware",
        "matchers": [{ "type": "any" }],
        "actions": [
          { "type": "log", "level": "warn" },
          { "type": "static_response", "rcode": "NXDOMAIN" }
        ]
      }]
    },
    {
      "id": "sinkhole",
      "rules": [{
        "name": "sinkhole-tracking",
        "matchers": [{ "type": "any" }],
        "actions": [
          { "type": "log", "level": "info" },
          { "type": "static_ip_response", "rcode": "NOERROR", "ips": ["0.0.0.0", "::1"] }
        ]
      }]
    },
    {
      "id": "internal",
      "rules": [
        {
          "name": "internal-block-ads",
          "matchers": [{ "type": "geo_site", "value": "category-ads" }],
          "actions": [
            { "type": "log", "level": "warn" },
            { "type": "deny" }
          ]
        },
        {
          "name": "internal-wpad-sinkhole",
          "matchers": [{ "type": "domain_suffix", "value": ".wpad" }],
          "actions": [
            { "type": "static_ip_response", "rcode": "NOERROR", "ips": ["127.0.0.1"] }
          ]
        },
        {
          "name": "internal-forward",
          "matchers": [{ "type": "any" }],
          "actions": [{ "type": "forward", "upstream": "tcp://10.0.0.53:53" }],
          "response_matchers": [
            { "type": "upstream_equals", "value": "10.0.0.53:53" },
            { "type": "response_rcode", "value": "NOERROR", "operator": "and" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [
            { "type": "log", "level": "warn" },
            { "type": "continue" }
          ]
        },
        {
          "name": "internal-non-cn-fallback",
          "matchers": [{ "type": "geo_site_not", "value": "cn" }],
          "actions": [{ "type": "forward", "upstream": null, "transport": "udp" }],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        }
      ]
    },
    {
      "id": "china_dns",
      "rules": [
        {
          "name": "cn-primary",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "log", "level": "debug" },
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" },
            { "operator": "and_not", "type": "response_answer_ip", "cidr": "0.0.0.0/8,127.0.0.0/8,169.254.0.0/16" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "cn-fallback",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "log", "level": "info" },
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "jump_to_pipeline", "pipeline": "default" }]
        }
      ]
    },
    {
      "id": "international",
      "rules": [
        {
          "name": "non-cn-primary",
          "matchers": [{ "type": "geoip_country", "country_codes": ["CN"] }],
          "actions": [
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "non-cn-fallback",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" },
            { "operator": "and_not", "type": "response_answer_ip", "cidr": "0.0.0.0/8,127.0.0.0/8" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "jump_to_pipeline", "pipeline": "default" }]
        }
      ]
    },
    {
      "id": "default",
      "rules": [
        {
          "name": "default-cn-client-or-domain",
          "matchers": [
            { "type": "geoip_country", "country_codes": ["CN"] },
            { "type": "geo_site", "value": "cn", "operator": "or" }
          ],
          "actions": [
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" },
            { "operator": "and_not", "type": "response_answer_ip", "cidr": "0.0.0.0/8,127.0.0.0/8,100.64.0.0/10" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "default-primary-with-pollution-detection",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "log", "level": "debug" },
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            {
              "operator": "not",
              "type": "response_answer_ip",
              "cidr": "0.0.0.0/8,127.0.0.0/8,169.254.0.0/16,192.0.2.0/24,198.51.100.0/24,203.0.113.0/24"
            }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "default-fallback-race",
          "actions": [
            {
              "type": "forward",
              "upstream": __UPSTREAMS__
            }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [
            { "type": "log", "level": "warn" },
            { "type": "static_response", "rcode": "SERVFAIL" }
          ]
        }
      ]
    }
  ]
}
CNEOF
}

generate_global_config() {
    cat > /etc/kixdns/config.json << 'GLOBALEOF'
{
  "version": "1.0",
  "settings": {
    "bind_udp": "0.0.0.0:8844",
    "bind_tcp": "0.0.0.0:8844",
    "min_ttl": 30,
    "default_upstream": "__DEFAULT_UDP__",
    "upstream_timeout_ms": 2000,
    "request_timeout_ms": 7500,
    "response_jump_limit": 10,
    "enable_tcp_fallback": true,
    "cache_capacity": 50000,
    "cache_max_ttl": 86400,
    "cache_background_refresh": true,
    "cache_refresh_threshold_percent": 10,
    "cache_refresh_min_ttl": 5,
    "serve_stale": true,
    "serve_stale_ttl": 30,
    "serve_stale_expire_ttl": 86400,
    "serve_stale_ttl_reset": true,
    "udp_pool_size": 128,
    "tcp_pool_size": 64,
    "doh_pool_size": 16,
    "dot_pool_size": 32,
    "doq_pool_size": 16,
    "doq_enable_0rtt": true,
    "flow_control_enabled": true,
    "flow_control_initial_permits": 400,
    "flow_control_min_permits": 50,
    "flow_control_max_permits": 800,
    "flow_control_latency_threshold_ms": 80,
    "geosite_data_paths": ["/etc/kixdns/geosite.dat"]
  },
  "pipeline_select": [
    {
      "pipeline": "blocked",
      "matchers": [{ "type": "geo_site", "value": "category-ads" }]
    },
    {
      "pipeline": "blocked",
      "matchers": [{ "type": "geo_site", "value": "malware" }]
    },
    {
      "pipeline": "sinkhole",
      "matchers": [{ "type": "domain_regex", "value": "(?i)(^|\\.)(track(er|ing)?|analytics|pixel|beacon)\\.(com|io|net|org)" }]
    },
    {
      "pipeline": "trusted",
      "matchers": [{ "type": "geo_site", "value": "google" }]
    },
    {
      "pipeline": "china_dns",
      "matchers": [{ "type": "geo_site", "value": "cn" }]
    },
    {
      "pipeline": "main",
      "matchers": [{ "type": "geo_site_not", "value": "cn" }]
    },
    {
      "pipeline": "default",
      "matchers": [{ "type": "any" }]
    }
  ],
  "pipelines": [
    {
      "id": "blocked",
      "rules": [{
        "name": "block-ads-malware",
        "matchers": [{ "type": "any" }],
        "actions": [
          { "type": "log", "level": "warn" },
          { "type": "static_response", "rcode": "NXDOMAIN" }
        ]
      }]
    },
    {
      "id": "sinkhole",
      "rules": [{
        "name": "sinkhole-tracking",
        "matchers": [{ "type": "any" }],
        "actions": [
          { "type": "log", "level": "info" },
          { "type": "static_ip_response", "rcode": "NOERROR", "ips": ["0.0.0.0", "::1"] }
        ]
      }]
    },
    {
      "id": "trusted",
      "rules": [
        {
          "name": "trusted-primary",
          "matchers": [
            { "type": "geoip_private", "expect": false },
            { "type": "edns_present", "expect": true, "operator": "and" }
          ],
          "actions": [
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "trusted-fallback",
          "actions": [
            {
              "type": "forward",
              "upstream": __UPSTREAMS__
            }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "jump_to_pipeline", "pipeline": "default" }]
        }
      ]
    },
    {
      "id": "china_dns",
      "rules": [
        {
          "name": "cn-primary",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" },
            { "operator": "and_not", "type": "response_answer_ip", "cidr": "0.0.0.0/8,127.0.0.0/8" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "cn-fallback",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "jump_to_pipeline", "pipeline": "default" }]
        }
      ]
    },
    {
      "id": "main",
      "rules": [
        {
          "name": "non-cn-edns-primary",
          "matchers": [
            { "type": "edns_present", "expect": true },
            { "type": "geoip_country", "country_codes": ["CN"], "operator": "not" }
          ],
          "actions": [
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" },
            { "operator": "and_not", "type": "response_answer_ip", "cidr": "0.0.0.0/8,127.0.0.0/8" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "non-cn-fallback",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" },
            { "operator": "or", "type": "response_edns_present", "expect": true }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "non-cn-ultimate-race",
          "actions": [
            {
              "type": "forward",
              "upstream": __UPSTREAMS__
            }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "jump_to_pipeline", "pipeline": "default" }]
        }
      ]
    },
    {
      "id": "default",
      "rules": [
        {
          "name": "default-cn-client-or-domain",
          "matchers": [
            { "type": "geoip_country", "country_codes": ["CN"] },
            { "type": "geo_site", "value": "cn", "operator": "or" }
          ],
          "actions": [
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" },
            { "operator": "and_not", "type": "response_answer_ip", "cidr": "0.0.0.0/8,127.0.0.0/8" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "default-primary-with-pollution-detection",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "log", "level": "debug" },
            { "type": "forward", "upstream": __UPSTREAMS__ }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            {
              "operator": "not",
              "type": "response_answer_ip",
              "cidr": "0.0.0.0/8,127.0.0.0/8,169.254.0.0/16,240.0.0.0/4"
            }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "default-fallback-race",
          "actions": [
            {
              "type": "forward",
              "upstream": __UPSTREAMS__
            }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [
            { "type": "log", "level": "warn" },
            { "type": "static_response", "rcode": "SERVFAIL" }
          ]
        }
      ]
    }
  ]
}
GLOBALEOF
}

# ============================================================
#  systemd 服务
# ============================================================
setup_systemd() {
    info "配置 systemd 服务..."
    cat > /etc/systemd/system/kixdns.service << UNIT
[Unit]
Description=KixDNS DNS Forwarder
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/kixdns run -c /etc/kixdns/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable kixdns
    systemctl start kixdns
    ok "systemd 服务已启用并启动"
}

# ============================================================
#  卸载
# ============================================================
uninstall() {
    echo ""
    echo "========================================"
    echo "  卸载 KixDNS"
    echo "========================================"

    if ! confirm "确认卸载 KixDNS？" "N"; then
        info "已取消"
        exit 0
    fi

    if systemctl is-active --quiet kixdns 2>/dev/null; then
        info "停止 kixdns 服务..."
        systemctl stop kixdns
    fi
    if systemctl is-enabled --quiet kixdns 2>/dev/null; then
        systemctl disable kixdns
    fi

    rm -f /etc/systemd/system/kixdns.service
    systemctl daemon-reload
    ok "systemd 服务已移除"

    if [ -f /usr/local/bin/kixdns ]; then
        rm -f /usr/local/bin/kixdns
        ok "二进制已删除: /usr/local/bin/kixdns"
    fi

    if confirm "删除配置文件？(/etc/kixdns/)"; then
        rm -rf /etc/kixdns/
        ok "配置文件已删除"
    fi

    echo ""
    echo "========================================"
    echo -e "  ${GREEN}KixDNS 已卸载${NC}"
    echo "========================================"
    echo ""
}

# ============================================================
#  验证
# ============================================================
verify() {
    echo ""
    echo "========================================"
    echo "  验证部署"
    echo "========================================"
    sleep 2

    if systemctl is-active --quiet kixdns; then
        ok "kixdns 服务运行中"
    else
        warn "kixdns 服务未运行，检查日志："
        journalctl -u kixdns -n 20 --no-pager
        return 1
    fi

    if command -v dig &>/dev/null; then
        if dig @127.0.0.1 -p 8844 www.baidu.com +short &>/dev/null; then
            ok "DNS 查询正常 (www.baidu.com)"
        else
            warn "dig 查询失败，请检查防火墙配置"
        fi
    else
        warn "未安装 dig，跳过验证查询"
    fi

    echo ""
    echo "========================================"
    echo -e "  ${GREEN}KixDNS 部署完成!${NC}"
    echo "========================================"
    echo ""
    echo "  监听地址: 0.0.0.0:8844 (UDP/TCP)"
    echo "  配置文件: /etc/kixdns/config.json"
    echo "  服务管理:"
    echo "    sudo systemctl status kixdns"
    echo "    sudo journalctl -u kixdns -f"
    echo "  测试查询:"
    echo "    dig @127.0.0.1 -p 8844 www.baidu.com"
    echo "    dig @127.0.0.1 -p 8844 google.com"
    echo ""
}

# ============================================================
#  主流程
# ============================================================
main() {
    echo ""
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║        KixDNS 一键部署脚本           ║"
    echo "  ║  https://github.com/olicesx/kixdns   ║"
    echo "  ╚══════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""

    check_root

    local items=("安装 KixDNS" "卸载 KixDNS" "退出")
    print_menu "请选择操作" "${items[@]}"
    local action
    read -rp "请输入数字 (1-3): " action

    case "$action" in
        1) : ;; # 继续安装
        2) uninstall; exit 0 ;;
        *) info "已退出"; exit 0 ;;
    esac

    detect_arch
    select_region
    select_dns

    echo ""
    echo "========================================"
    echo "  配置摘要"
    echo "========================================"
    echo "  版本:     $( [ "$REGION" = "cn" ] && echo '国内版' || echo '海外版' )"
    echo "  上游 DNS: $SELECTED_NAMES"
    echo "  监听:     0.0.0.0:8844"
    echo ""

    if ! confirm "确认以上配置，开始部署？"; then
        info "已取消"
        exit 0
    fi

    download_binary
    generate_config
    download_geosite
    setup_systemd
    verify
}

main "$@"
