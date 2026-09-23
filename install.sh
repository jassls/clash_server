#!/usr/bin/env bash
# =============================================================================
# clash-server —— Rocky Linux 9.x 一键部署 mihomo（Clash.Meta 内核）服务端
#
# 角色：让局域网/可达网络里的 Clash Verge 以 Shadowsocks（或带认证的 socks5/http）
#       节点接入本机，流量经本机出口转发（本机需可访问外网）。
#
# 用法（在目标 Rocky 9.8 机器上）：
#   sudo bash install.sh           # 安装 / 升级（重复执行安全，凭据复用）
#   sudo bash install.sh --force   # 重新生成全部凭据（Verge 侧需同步改密码）
#
# 可用环境变量覆盖默认值：
#   MIHOMO_VERSION=v1.19.31   mihomo 版本（默认自动取 GitHub 最新稳定版）
#   SS_PORT=8388              Shadowsocks 入站端口（Verge 用它接入，推荐）
#   MIXED_PORT=7890           http+socks5 混合入站端口（调试/备用）
#   API_PORT=9090             外部控制 API 端口（仅绑定 127.0.0.1）
#   CIPHER=aes-256-gcm        SS 加密方式（无 AES-NI 机器可用 chacha20-ietf-poly1305）
# =============================================================================
set -euo pipefail

GREEN='\033[32m'; YEL='\033[33m'; RED='\033[31m'; OFF='\033[0m'
log()  { echo -e "${GREEN}[install]${OFF} $*"; }
warn() { echo -e "${YEL}[warn]${OFF} $*"; }
die()  { echo -e "${RED}[error]${OFF} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $0"

FORCE=0; [[ "${1:-}" == "--force" ]] && FORCE=1

# ---------- 基本参数 ----------
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)        MH_ARCH=amd64 ;;
  aarch64|arm64) MH_ARCH=arm64 ;;
  *) die "不支持的架构: $ARCH（脚本支持 x86_64 / aarch64）" ;;
esac

MIHOMO_VERSION="${MIHOMO_VERSION:-}"
SS_PORT="${SS_PORT:-8388}"
MIXED_PORT="${MIXED_PORT:-7890}"
API_PORT="${API_PORT:-9090}"
CIPHER="${CIPHER:-aes-256-gcm}"

BIN=/usr/local/bin/mihomo
CONF_DIR=/etc/mihomo
CREDS="$CONF_DIR/credentials.env"
UNIT=/etc/systemd/system/mihomo.service
SVC=mihomo

for c in curl gzip sed grep systemctl; do
  command -v "$c" >/dev/null 2>&1 || die "缺少依赖命令: $c"
done
command -v openssl >/dev/null 2>&1 || { log "安装 openssl ..."; dnf -y install openssl >/dev/null; }

# ---------- 版本号 ----------
if [[ -z "$MIHOMO_VERSION" ]]; then
  MIHOMO_VERSION="$(curl -fsSL -m 15 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null \
    | grep -m1 -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 || true)"
fi
MIHOMO_VERSION="${MIHOMO_VERSION:-v1.19.31}"   # API 拿不到时的保底版本
log "目标版本: mihomo $MIHOMO_VERSION (linux-$MH_ARCH)"

# ---------- 下载二进制（GitHub 直连失败自动换加速镜像）----------
dl() { # dl <github-url> <out>
  local url="$1" out="$2" i
  local prefixes=("" "https://ghproxy.net/" "https://mirror.ghproxy.com/" "https://gh-proxy.com/")
  for i in "${!prefixes[@]}"; do
    if curl -fL --connect-timeout 10 -m 600 -o "$out.part" "${prefixes[$i]}$url" 2>/dev/null; then
      [[ -s "$out.part" ]] && { mv "$out.part" "$out"; return 0; }
    fi
    warn "下载失败，换源重试（${prefixes[i]:-GitHub 直连}）"
  done
  return 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -x "$BIN" ]] && "$BIN" -v 2>/dev/null | grep -q "$MIHOMO_VERSION"; then
  log "二进制已是目标版本，跳过下载"
else
  log "下载 mihomo 二进制 ..."
  dl "https://github.com/MetaCubeX/mihomo/releases/download/$MIHOMO_VERSION/mihomo-linux-$MH_ARCH-$MIHOMO_VERSION.gz" \
     "$TMP/mihomo.gz" || die "mihomo 二进制下载失败（检查出网，或手动指定 MIHOMO_VERSION）"
  gunzip -c "$TMP/mihomo.gz" > "$BIN.new"
  chmod 0755 "$BIN.new"
  "$BIN.new" -v >/dev/null 2>&1 || die "下载的二进制无法执行"
  mv "$BIN.new" "$BIN"
fi
log "已就绪: $BIN ($("$BIN" -v 2>/dev/null | head -1))"

# ---------- 凭据（存在则复用；--force 重新生成）----------
mkdir -p "$CONF_DIR"
if [[ -f "$CREDS" && "$FORCE" -eq 0 ]]; then
  # shellcheck source=/dev/null
  . "$CREDS"
  log "复用已有凭据: $CREDS"
fi
: "${SS_PASS:=$(openssl rand -hex 16)}"
: "${MIXED_USER:=verge}"
: "${MIXED_PASS:=$(openssl rand -hex 12)}"
: "${API_SECRET:=$(openssl rand -hex 16)}"

cat > "$CREDS" <<CREDS_EOF
SS_PASS='$SS_PASS'
MIXED_USER='$MIXED_USER'
MIXED_PASS='$MIXED_PASS'
API_SECRET='$API_SECRET'
CREDS_EOF
chmod 600 "$CREDS"

# ---------- 配置文件 ----------
if [[ -f "$CONF_DIR/config.yaml" ]]; then
  cp -a "$CONF_DIR/config.yaml" "$CONF_DIR/config.yaml.bak.$(date +%Y%m%d%H%M%S)"
  log "旧配置已备份到 $CONF_DIR/config.yaml.bak.*"
fi

cat > "$CONF_DIR/config.yaml" <<'MIHOMO_CFG_EOF'
# mihomo 服务端配置 —— 由 install.sh 渲染生成，手工改动会被下次安装覆盖
mixed-port: __MIXED_PORT__
allow-lan: true
bind-address: "*"
# mixed(http+socks5) 入站的账号密码
authentication:
  - "__MIXED_USER__:__MIXED_PASS__"
skip-auth-prefixes:
  - 127.0.0.1/8
# 外部控制 API 仅绑本机回环（如需从别的机器访问面板，自行改绑并放行防火墙）
external-controller: "127.0.0.1:__API_PORT__"
secret: "__API_SECRET__"

mode: rule
log-level: info
ipv6: false

# —— 性能相关 ——
tcp-concurrent: true      # 并发拨号：多个解析结果竞速建连，降低首包延迟
unified-delay: true       # 统一延迟计算口径
keep-alive-interval: 30   # 长连接保活间隔（秒）

# 内置 DNS 缓存：nameserver 用 system＝跟随本机 /etc/resolv.conf，零配置风险
dns:
  enable: true
  ipv6: false
  nameservers:
    - system

# Shadowsocks 服务端入站：Clash Verge 用 type: ss 节点接入（链路加密，推荐入口）
# 监听说明：0.0.0.0 = 所有网卡。云主机（腾讯云等）的公网 IP 由平台 NAT 到网卡私网 IP，
# 网卡上并不存在公网地址——监听 0.0.0.0 即已覆盖公网访问，切勿改成"绑定公网 IP"（会绑定失败）。
listeners:
  - name: ss-in
    type: shadowsocks
    listen: 0.0.0.0
    port: __SS_PORT__
    password: "__SS_PASS__"
    cipher: __CIPHER__
    udp: true

rules:
  # 全部从本机出口直连（本机可通外网）
  - MATCH,DIRECT

# 进阶：让本机中继你的订阅（多设备共享一个订阅时用）
# proxy-providers:
#   my-sub:
#     type: http
#     url: "你的订阅链接"
#     interval: 86400
#     path: ./providers/my-sub.yaml
#     health-check: { enable: true, url: "https://www.gstatic.com/generate_204", interval: 300 }
# 用法一：给上面 ss-in 加一行  proxy: 某节点名   （该入口固定走某上游节点）
# 用法二：把 rules 的 MATCH,DIRECT 换成策略组按规则分流
MIHOMO_CFG_EOF

sed -i -e "s|__SS_PASS__|$SS_PASS|g" \
       -e "s|__MIXED_PORT__|$MIXED_PORT|g" \
       -e "s|__MIXED_USER__|$MIXED_USER|g" \
       -e "s|__MIXED_PASS__|$MIXED_PASS|g" \
       -e "s|__API_PORT__|$API_PORT|g" \
       -e "s|__API_SECRET__|$API_SECRET|g" \
       -e "s|__SS_PORT__|$SS_PORT|g" \
       -e "s|__CIPHER__|$CIPHER|g" \
       "$CONF_DIR/config.yaml"
if grep -q '__' "$CONF_DIR/config.yaml"; then
  die "配置渲染后仍残留占位符，请检查"
fi

# ---------- 运行账号 ----------
id clash >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d "$CONF_DIR" clash
chown -R clash:clash "$CONF_DIR"
chmod 750 "$CONF_DIR"
chmod 640 "$CONF_DIR/config.yaml"

# ---------- 内核网络参数优化（BBR/fq、缓冲区、队列、连接管理、conntrack）----------
SYSCTL_CONF=/etc/sysctl.d/99-mihomo-opt.conf
cat > "$SYSCTL_CONF" <<'SYSCTL_EOF'
# mihomo 代理服务端内核优化 —— 由 install.sh 生成（卸载：uninstall.sh --purge）
# ---- 拥塞控制：BBR + fq（高时延国际链路吞吐的关键）----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# ---- 收发缓冲区：高 BDP（约 200ms RTT × 1Gbps ≈ 24MB）链路跑满带宽；UDP 中继同样受益 ----
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.rmem_default = 1048576
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
# ---- 队列：突发建连与高 PPS 不丢包 ----
net.core.somaxconn = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000
# ---- 连接管理：适配代理海量长/短连接 ----
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
# ---- 文件描述符与内存行为 ----
fs.file-max = 2097152
vm.swappiness = 10
SYSCTL_EOF

# conntrack 参数仅在本机已启用连接追踪（firewalld 等）时写入，避免引用不存在的键
if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
  cat >> "$SYSCTL_CONF" <<'SYSCTL_CT_EOF'
# ---- 连接追踪上限与空闲超时收敛 ----
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
SYSCTL_CT_EOF
fi

mkdir -p /etc/modules-load.d
printf 'tcp_bbr\nnf_conntrack\n' > /etc/modules-load.d/mihomo-opt.conf
modprobe tcp_bbr 2>/dev/null || true

sysctl --system >/dev/null 2>&1 || true
# default_qdisc 只对“之后出现”的网卡生效，给默认路由网卡立即换上 fq
IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
if [[ -n "$IFACE" ]] && command -v tc >/dev/null 2>&1; then
  tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true
fi
CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
QD="$(tc qdisc show dev "$IFACE" 2>/dev/null | awk '{print $2; exit}' || true)"
log "内核优化已应用: 拥塞控制=$CC qdisc=${QD:-未知} 持久化=$SYSCTL_CONF"

# ---------- systemd 服务 ----------
cat > "$UNIT" <<'UNIT_EOF'
[Unit]
Description=mihomo proxy server (clash.meta core)
After=network-online.target
Wants=network-online.target

[Service]
User=clash
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1
systemctl restart "$SVC"

# ---------- 防火墙（节点端口放行；控制 API 不放行）----------
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent \
    --add-port="$SS_PORT/tcp" --add-port="$SS_PORT/udp" \
    --add-port="$MIXED_PORT/tcp" --add-port="$MIXED_PORT/udp" >/dev/null
  firewall-cmd --reload >/dev/null
  log "firewalld 已放行 $SS_PORT tcp/udp、$MIXED_PORT tcp/udp"
else
  warn "未检测到运行中的 firewalld，请自行确认端口可访问（云主机还要放行安全组）"
fi

# ---------- 启动校验 ----------
ok=0
for _ in $(seq 1 15); do
  systemctl is-active --quiet "$SVC" && { ok=1; break; }
  sleep 1
done
if [[ "$ok" -ne 1 ]]; then
  journalctl -u "$SVC" -n 50 --no-pager || true
  die "mihomo 服务启动失败，见上方日志"
fi

ss -lnt 2>/dev/null | grep -q ":$SS_PORT "  || warn "$SS_PORT 未在监听"
ss -lnt 2>/dev/null | grep -q ":$MIXED_PORT " || warn "$MIXED_PORT 未在监听"

code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://127.0.0.1:$API_PORT/version" || true)"
if [[ "$code" == "401" || "$code" == "200" ]]; then
  log "控制 API 正常 (HTTP $code)"
else
  warn "控制 API 未响应 (HTTP $code)"
fi

# 经 mixed 代理做一次真实出网测试
http="$(curl -s -o /dev/null -w '%{http_code}' -m 12 \
  -x "http://$MIXED_USER:$MIXED_PASS@127.0.0.1:$MIXED_PORT" \
  https://www.gstatic.com/generate_204 || true)"
if [[ "$http" == "204" ]]; then
  log "代理链路自检通过：经本机代理访问 generate_204 => 204"
else
  warn "代理出网自检未通过 (HTTP $http)：确认本机可直接访问外网"
fi

# ---------- 输出 Clash Verge 接入信息 ----------
SRV_IP="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
[[ -n "${SRV_IP:-}" ]] || SRV_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[[ -n "${SRV_IP:-}" ]] || SRV_IP="<本机IP>"

# 接入地址策略：节点/链接里的 server 一律优先用自探测的公网出口 IP。
# 云主机（腾讯云/AWS 等）的公网 IP 由平台 NAT 到网卡地址，网卡上不存在公网地址；
# 若客户端走内网/VPC 直连，可用环境变量覆盖：CLIENT_ADDR=172.19.x.x bash install.sh
PUB_IP="$(curl -4 -fsSL -m 8 https://ifconfig.me 2>/dev/null || curl -4 -fsSL -m 8 https://api.ipify.org 2>/dev/null || true)"
case "$SRV_IP" in
  10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|100.6[4-9].*|100.7[01].*) SRV_PRIVATE=1 ;;
  *) SRV_PRIVATE=0 ;;
esac
if [[ -n "${CLIENT_ADDR:-}" ]]; then
  CLIENT_IP="$CLIENT_ADDR"
  IP_NOTE="接入地址由环境变量 CLIENT_ADDR 指定: $CLIENT_ADDR"
elif [[ -n "${PUB_IP:-}" ]]; then
  CLIENT_IP="$PUB_IP"
  if [[ "$SRV_PRIVATE" -eq 1 ]]; then
    IP_NOTE="接入使用自探测公网 IP $PUB_IP（网卡地址 $SRV_IP 为内网 IP，仅同内网/VPC 可达）"
  elif [[ "$PUB_IP" != "$SRV_IP" ]]; then
    IP_NOTE="接入使用自探测公网出口 IP $PUB_IP（与网卡地址 $SRV_IP 不同，说明存在上层 NAT）"
  else
    IP_NOTE=""
  fi
else
  CLIENT_IP="$SRV_IP"
  if [[ "$SRV_PRIVATE" -eq 1 ]]; then
    IP_NOTE="警告：网卡地址 $SRV_IP 是内网 IP 且公网出口探测失败，跨网接入前请手动把节点 server 改成公网 IP"
  else
    IP_NOTE=""
  fi
fi
ADDR_COMMENT="# 接入地址: $CLIENT_IP（公网出口: ${PUB_IP:-探测失败}，网卡地址: $SRV_IP；内网直连可用 CLIENT_ADDR 覆盖）"

SS_USERINFO="$(printf '%s:%s' "$CIPHER" "$SS_PASS" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
SS_LINK="ss://${SS_USERINFO}@${CLIENT_IP}:${SS_PORT}#rocky-clash"

cat > "$CONF_DIR/clash-verge-client.yaml" <<CLIENT_EOF
# ============================================================
# Clash Verge 接入参考片段（本文件不是完整配置，按注释把各段贴进 Verge）
# IP/端口/密码与本机安装输出一致；--force 轮换凭据后需同步更新客户端
# $ADDR_COMMENT
#
# 重要：Verge 的「代理」页只显示【代理组 proxy-groups】，不显示没进组的散装节点！
#   - 节点必须挂在某个 proxy-group 里，规则模式下才可见、可用；
#   - 快速自测：Verge 切到「全局」模式，GLOBAL 组里能看到这两个节点即已加载。
#
# 推荐接法：Verge 配置页 → 当前配置右键 →「编辑 Merge / 扩展配置」，
# 把下面 proxies / proxy-groups / rules 三段分别作为 prepend-proxies /
# prepend-proxy-groups / prepend-rules 的值贴进去（注意加 prepend- 前缀）。
# ============================================================
ss-link: "$SS_LINK"

proxies:
  - name: rocky-clash
    type: ss
    server: $CLIENT_IP
    port: $SS_PORT
    cipher: $CIPHER
    password: "$SS_PASS"
    udp: true
  # 备用：带认证的 socks5 入口（同机同出口）
  - name: rocky-mixed
    type: socks5
    server: $CLIENT_IP
    port: $MIXED_PORT
    username: $MIXED_USER
    password: "$MIXED_PASS"
    udp: true

# 建一个组把节点挂进去，规则模式下才会出现在「代理」页
proxy-groups:
  - name: rocky-relay
    type: select
    proxies:
      - rocky-clash
      - rocky-mixed

# 分流规则（Merge 中键名用 prepend-rules）：
#   - MATCH,rocky-relay                    # 全部流量走 rocky
#   - DOMAIN-SUFFIX,google.com,rocky-relay # 或只让指定域名走
# 也可以不动规则：直接用 Verge 的「全局」模式选 rocky-clash。
CLIENT_EOF

echo
echo "==================== 安装完成 ===================="
echo " 服务状态 : systemctl status $SVC"
echo " 日志     : journalctl -u $SVC -f"
echo " 配置     : $CONF_DIR/config.yaml"
echo " 凭据     : $CREDS  (600)"
echo " 内核优化 : $SYSCTL_CONF（拥塞控制=$CC qdisc=${QD:-fq}，重启持久）"
echo "--------------------------------------------------"
echo " Shadowsocks 入口 : $CLIENT_IP:$SS_PORT ($CIPHER)"
echo " mixed 入口       : $CLIENT_IP:$MIXED_PORT (账号 $MIXED_USER)"
[[ -n "$IP_NOTE" ]] && echo " 地址说明 : $IP_NOTE"
echo " 安全组提醒 : 云主机请在平台安全组放行 $SS_PORT/tcp+udp、$MIXED_PORT/tcp（与本机 firewalld 无关）"
echo " Verge 导入链接   :"
echo "   $SS_LINK"
echo " 客户端配置片段   : $CONF_DIR/clash-verge-client.yaml"
echo "=================================================="
echo
cat "$CONF_DIR/clash-verge-client.yaml"
