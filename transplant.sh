#!/bin/bash
set -euo pipefail

# KixDNS 移植脚本 — 从 ali 复制工作配置到本机

BIN_SRC="ssh ali cat /usr/local/bin/kixdns"
CONFIG_SRC="ssh ali cat /etc/kixdns/claude.json"

echo "=== 从 ali 移植 kixdns ==="

# 1. 复制二进制
echo "[1/4] 复制 kixdns 二进制..."
$BIN_SRC > /usr/local/bin/kixdns
chmod +x /usr/local/bin/kixdns
/usr/local/bin/kixdns --version
echo "  OK"

# 2. 创建配置目录
mkdir -p /etc/kixdns

# 3. 下载 geosite.dat（广告拦截需要）
echo "[2/4] 下载 geosite.dat..."
GEOSITE_URLS=(
  "https://mirror.ghproxy.com/https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
  "https://gh-proxy.com/https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
  "https://cdn.jsdelivr.net/gh/v2fly/domain-list-community@release/dlc.dat"
  "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
)
DL_OK=false
for url in "${GEOSITE_URLS[@]}"; do
  if wget -q --timeout=15 "$url" -O /etc/kixdns/geosite.dat 2>/dev/null; then
    DL_OK=true; break
  fi
done
$DL_OK && echo "  OK" || echo "  WARN: 下载失败，广告拦截不可用"

# 4. 写配置（从 claude.json 精简，去掉 internal/geoip 依赖）
echo "[3/4] 生成 /etc/kixdns/config.json..."
cat > /etc/kixdns/config.json << 'CONFIGEOF'
{
  "version": "1.0",
  "settings": {
    "bind_udp": "0.0.0.0:8844",
    "bind_tcp": "0.0.0.0:8844",
    "min_ttl": 30,
    "default_upstream": "223.5.5.5:53,119.29.29.29:53",
    "upstream_timeout_ms": 3000,
    "request_timeout_ms": 7500,
    "response_jump_limit": 10,
    "enable_tcp_fallback": true,
    "udp_pool_size": 128,
    "tcp_pool_size": 64,
    "doh_pool_size": 16,
    "dot_pool_size": 32,
    "doq_pool_size": 16,
    "doq_enable_0rtt": true,
    "cache_capacity": 50000,
    "cache_max_ttl": 86400,
    "cache_background_refresh": true,
    "cache_refresh_threshold_percent": 15,
    "cache_refresh_min_ttl": 10,
    "serve_stale": true,
    "serve_stale_ttl": 30,
    "serve_stale_expire_ttl": 172800,
    "serve_stale_ttl_reset": true,
    "flow_control_enabled": true,
    "flow_control_initial_permits": 500,
    "flow_control_min_permits": 100,
    "flow_control_max_permits": 1200,
    "flow_control_latency_threshold_ms": 150,
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
          { "type": "static_ip_response", "rcode": "NOERROR", "ip": "0.0.0.0" }
        ]
      }]
    },
    {
      "id": "default",
      "rules": [
        {
          "name": "primary-alidns-doh",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "log", "level": "debug" },
            { "type": "forward", "upstream": "https://223.5.5.5/dns-query" }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" },
            { "operator": "not", "type": "response_answer_ip", "cidr": "0.0.0.0/8,127.0.0.0/8,169.254.0.0/16" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [{ "type": "continue" }]
        },
        {
          "name": "dot-fallback-quad9",
          "matchers": [{ "type": "any" }],
          "actions": [
            { "type": "forward", "upstream": "dot://9.9.9.9:853?sni=dns.quad9.net" }
          ],
          "response_matchers": [
            { "type": "response_rcode", "value": "NOERROR" },
            { "operator": "or", "type": "response_rcode", "value": "NXDOMAIN" }
          ],
          "response_actions_on_match": [{ "type": "allow" }],
          "response_actions_on_miss": [
            { "type": "static_response", "rcode": "SERVFAIL" }
          ]
        }
      ]
    }
  ]
}
CONFIGEOF
echo "  OK"

# 5. systemd 服务
echo "[4/4] 配置 systemd 服务..."
cat > /etc/systemd/system/kixdns.service << 'UNITEOF'
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
UNITEOF

systemctl daemon-reload
systemctl enable kixdns
systemctl start kixdns
echo "  OK"

# 6. 验证
echo ""
echo "=== 验证 ==="
sleep 2
if systemctl is-active --quiet kixdns; then
  echo "  [OK] kixdns 运行中"
  echo "  测试: dig @127.0.0.1 -p 8844 www.baidu.com"
else
  echo "  [FAIL] kixdns 未运行，日志:"
  journalctl -u kixdns -n 20 --no-pager
  exit 1
fi
