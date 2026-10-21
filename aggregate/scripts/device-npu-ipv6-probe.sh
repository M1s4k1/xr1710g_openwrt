#!/bin/sh
# device-npu-ipv6-probe.sh — XR1710G IPv6 NPU offload 多路深度/广度测试
#
# 用法：
#   ./scripts/device-npu-ipv6-probe.sh                 # 默认配置，多路齐发
#   TCP_ROUNDS=1 UDP_SECONDS=20 SAMPLES=10 INTERVAL=3 ./scripts/device-npu-ipv6-probe.sh
#   DEVICE_HOST=root@192.168.123.1 LAN6_PREFIX=2409:8a55:c966:6fd0 ./scripts/device-npu-ipv6-probe.sh
#
# 说明：
#   - 路 A：IPv6 配置/RPC/PPE/conntrack 基线（只读）。
#   - 路 B：IPv6 TCP 多源并发打流（host 侧多源 IPv6 地址 + cloudflare __down），
#           同时远端采样 conntrack/PPE，确认 [HW_OFFLOAD] 与 PPE BND 是否出现。
#   - 路 C：IPv6 UDP 长流（DNS over UDP，host 侧绑定多源地址），远端采样，
#           确认 UDP [HW_OFFLOAD] 与 PPE entries UNB 行为。
#   - 路 D：ICMPv6 对照 + dmesg/logread 错误扫描 + 内存/NPU 时钟稳定性。
#   - 全程只读，不切换 flow_offloading_hw（1→0→1 曾触发重启，见 F34）。
#   - 测试会在 host 侧添加/删除临时 IPv6 源地址（LAN6_PREFIX::11-17/64）。
#   - 输出写入 /tmp/device-npu-ipv6-probe-<route>.log，并打印尾部摘要。
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST=${DEVICE_HOST:-root@192.168.123.1}
LAN6_PREFIX=${LAN6_PREFIX:-}
TCP_SRC_IDS=${TCP_SRC_IDS:-11 12 13 14 15}
UDP_SRC_IDS=${UDP_SRC_IDS:-16 17}
TCP_BYTES=${TCP_BYTES:-20000000}
TCP_RATE=${TCP_RATE:-1M}
TCP_ROUNDS=${TCP_ROUNDS:-2}
UDP_SECONDS=${UDP_SECONDS:-40}
SAMPLES=${SAMPLES:-30}
INTERVAL=${INTERVAL:-3}
OUT_PREFIX=${OUT_PREFIX:-/tmp/device-npu-ipv6-probe}

if [ -x "$REPO_DIR/.ssh/ssh-device" ]; then
    SSH_CMD="$REPO_DIR/.ssh/ssh-device"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$REPO_DIR/.ssh/known_hosts -i $REPO_DIR/.ssh/id_ed25519 $HOST"
fi

# 自动推导 LAN6_PREFIX：取 host 侧 /64 global 地址的前 4 组（PPPoE 场景常见 /60 下发，
# /64 子网是设备 br-lan 实际 on-link 前缀）。覆盖：LAN6_PREFIX 环境变量。
if [ -z "$LAN6_PREFIX" ]; then
    auto6=$(ip -6 -o addr show 2>/dev/null | awk '$4 ~ /\/64$/ {print $4; exit}')
    if [ -n "$auto6" ]; then
        LAN6_PREFIX=$(printf '%s\n' "$auto6" | awk -F: '/\//{printf "%s:%s:%s:%s",$1,$2,$3,$4}')
    fi
fi
if [ -z "$LAN6_PREFIX" ]; then
    echo "ERROR: cannot derive LAN6_PREFIX; set LAN6_PREFIX env (e.g. 2409:8a55:c966:6fd0)" >&2
    exit 1
fi
echo "LAN6_PREFIX=$LAN6_PREFIX"

# 在 host 侧添加临时 IPv6 源地址；不删除既有地址
added_ids=""
for id in $TCP_SRC_IDS $UDP_SRC_IDS; do
    ip="$LAN6_PREFIX::$id"
    if ! ip -6 addr show 2>/dev/null | grep -q "inet6 $ip/64"; then
        ip -6 addr add "$ip/64" dev eth0 nodad 2>/dev/null || true
        added_ids="$added_ids $id"
    fi
done
cleanup() {
    for id in $added_ids; do
        ip -6 addr del "$LAN6_PREFIX::$id/64" dev eth0 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

: > "$OUT_PREFIX.route_a.log"
: > "$OUT_PREFIX.route_b.log"
: > "$OUT_PREFIX.route_c.log"
: > "$OUT_PREFIX.route_d.log"
: > "$OUT_PREFIX.sampler.log"

# 路 A：只读基线 —— IPv6 地址/路由/配置/RPC/PPE/conntrack
route_a() {
    $SSH_CMD '
echo "===== A1 IPv6 addrs/routes ====="
ip -6 addr show scope global
ip -6 route show
echo "===== A2 offload config ====="
uci show firewall | grep -i offload
echo "===== A3 nft flowtable ====="
nft list flowtable inet fw4 ft 2>/dev/null | head -20
echo "===== A4 RPC flow/pppoe/vlan offload ====="
ubus call luci.airoha_flowsense getFlowOffload 2>&1
ubus call luci.airoha_flowsense getPppoeOffload 2>&1
ubus call luci.airoha_flowsense getVlanOffload 2>&1
echo "===== A5 PPE baseline ====="
echo "ppe_bind_rows=$(wc -l < /sys/kernel/debug/ppe/bind 2>/dev/null)"
echo "ppe_bnd_v4=$(grep -cE "^[0-9a-fA-F]+ BND IPv4" /sys/kernel/debug/ppe/bind 2>/dev/null)"
echo "ppe_bnd_v6=$(grep -cE "^[0-9a-fA-F]+ BND IPv6" /sys/kernel/debug/ppe/bind 2>/dev/null)"
echo "ppe_entries=$(wc -l < /sys/kernel/debug/ppe/entries 2>/dev/null)"
echo "conntrack_v6=$(grep -c "^ipv6" /proc/net/nf_conntrack 2>/dev/null)"
echo "conntrack_v6_hw=$(grep "^ipv6" /proc/net/nf_conntrack 2>/dev/null | grep -c HW_OFFLOAD)"
echo "conntrack_v6_off=$(grep "^ipv6" /proc/net/nf_conntrack 2>/dev/null | grep -cE "\[OFFLOAD\]")"
echo "===== A6 RPC getPpeEntries summary ====="
ubus call luci.airoha_flowsense getPpeEntries 2>/dev/null | jsonfilter -e "@.bnd.total" -e "@.bnd.ipv4" -e "@.bnd.ipv6" -e "@.bnd.band_bnd" -e "@.bnd.port_bnd" -e "@.bnd.client_bnd"
echo "===== A6.1 RPC getPpeFlowStats summary (issue #5 conntrack per-flow counters) ====="
ubus call luci.airoha_flowsense getPpeFlowStats 2>/dev/null | jsonfilter -e '@.available' -e '@.summary.bnd_total' -e '@.summary.bnd_ct_matched' -e '@.summary.bnd_hw' -e '@.summary.bnd_hw_packets' -e '@.summary.bnd_hw_bytes' -e '@.summary.unb_total' -e '@.summary.unb_ct_matched' 2>/dev/null || true
'
}

# 远端采样器：ssh 传递环境变量并喂给 sh -s，避免复杂引号
route_sampler() {
    $SSH_CMD "SAMPLES=$SAMPLES INTERVAL=$INTERVAL sh -s" <<'REMOTE_SAMPLER'
for i in $(seq 1 "$SAMPLES"); do
    ts=$(date +%s)
    ct6=$(grep -c '^ipv6' /proc/net/nf_conntrack 2>/dev/null)
    hw=$(grep '^ipv6' /proc/net/nf_conntrack 2>/dev/null | grep -c HW_OFFLOAD)
    off=$(grep '^ipv6' /proc/net/nf_conntrack 2>/dev/null | grep -cE '\[OFFLOAD\]')
    bnd=$(grep -cE '^[0-9a-fA-F]+ BND' /sys/kernel/debug/ppe/bind 2>/dev/null)
    bnd6=$(grep -cE '^[0-9a-fA-F]+ BND IPv6' /sys/kernel/debug/ppe/bind 2>/dev/null)
    ent=$(wc -l < /sys/kernel/debug/ppe/entries 2>/dev/null)
    npu=$(cat /sys/kernel/debug/clk/npu/clk_rate 2>/dev/null)
    mem=$(free 2>/dev/null | awk '/Mem:/{printf "%d", $3}')
    err=$(dmesg 2>/dev/null | grep -iE 'error|fail|warn|timeout|hung|oops|panic|BUG|offload' | wc -l)
    lerr=$(logread 2>/dev/null | grep -iE 'error|fail|warn|timeout|hung|oops|panic|BUG|offload' | wc -l)
    echo "t=$ts ct6=$ct6 hw=$hw off=$off bnd=$bnd bnd6=$bnd6 ent=$ent npu=$npu mem=$mem err=$err lerr=$lerr"
    sleep "$INTERVAL"
done
REMOTE_SAMPLER
}

# 路 B：IPv6 TCP 多源并发打流（host 侧）
route_tcp() {
    for round in $(seq 1 "$TCP_ROUNDS"); do
        echo "===== TCP round $round start $(date +%s) ====="
        for id in $TCP_SRC_IDS; do
            curl -6 --interface "$LAN6_PREFIX::$id" --limit-rate "$TCP_RATE" -sS -o /dev/null \
                "http://speed.cloudflare.com/__down?bytes=$TCP_BYTES" 2>&1 &
            curl -6 --interface "$LAN6_PREFIX::$id" --limit-rate "$TCP_RATE" -sS -o /dev/null \
                "https://speed.cloudflare.com/__down?bytes=$TCP_BYTES" 2>&1 &
        done
        wait
        echo "===== TCP round $round end $(date +%s) ====="
    done
}

# 路 C：IPv6 UDP 长流（host 侧多源 DNS over UDP）
route_udp() {
    for id in $UDP_SRC_IDS; do
        python3 - "$LAN6_PREFIX::$id" "$UDP_SECONDS" <<'PY' &
import socket, struct, time, random, sys
src = sys.argv[1]
duration = int(sys.argv[2])
addr = ('2400:3200::1', 53)  # AliDNS IPv6；如不可达可换 2400:da00::6666 或其他
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.bind((src, 0))
s.settimeout(0.5)
names = ['www.taobao.com', 'www.baidu.com', 'www.qq.com', 'www.163.com', 'ipv6.baidu.com']
qid = random.randint(1, 65535)
end = time.time() + duration
sent = recv = 0
while time.time() < end:
    qid = (qid + 1) & 0xffff
    name = names[qid % len(names)]
    q = struct.pack('!HHHHHH', qid, 0x0100, 1, 0, 0, 0)
    for c in name.split('.'):
        q += bytes([len(c)]) + c.encode()
    q += b'\x00\x00\x01\x00\x01'
    try:
        s.sendto(q, addr)
        sent += 1
    except Exception as exc:
        print(src, 'send err', exc, flush=True)
        break
    try:
        data, peer = s.recvfrom(2048)
        if peer[0] == addr[0]:
            recv += 1
    except socket.timeout:
        pass
    time.sleep(0.25)
print('%s duration=%d sent=%d recv=%d' % (src, duration, sent, recv), flush=True)
s.close()
PY
    done
    wait
}

# 路 D：ICMPv6 对照 + 稳定性/错误扫描
route_d() {
    $SSH_CMD 'echo "===== D1 before icmpv6 ====="; grep -E "ipv6.*icmp" /proc/net/nf_conntrack 2>/dev/null | head -3; echo "===== D2 ping6 ====="; ping6 -c 5 -W 2 2400:3200::1 2>&1; echo "===== D3 after icmpv6 ====="; grep -E "ipv6.*icmp" /proc/net/nf_conntrack 2>/dev/null | head -5; echo "icmp_hw=$(grep -E "ipv6.*icmp" /proc/net/nf_conntrack 2>/dev/null | grep -c HW_OFFLOAD)"; echo "===== D4 error scan ====="; dmesg 2>/dev/null | grep -iE "npu|airoha|mt76|mt7996|ppe|offload|error|fail|warn|timeout|hung|oops|panic|BUG" | tail -40; echo "===== D5 npu clock/mem ====="; echo "npu_clk=$(cat /sys/kernel/debug/clk/npu/clk_rate 2>/dev/null) mem=$(free 2>/dev/null | awk "/Mem:/{printf \"%d/%d\", \$3, \$2}")"'
}

( route_a > "$OUT_PREFIX.route_a.log" 2>&1 ) &
pid_a=$!
( route_sampler > "$OUT_PREFIX.sampler.log" 2>&1 ) &
pid_sam=$!
( route_tcp > "$OUT_PREFIX.route_b.log" 2>&1 ) &
pid_b=$!
( route_udp > "$OUT_PREFIX.route_c.log" 2>&1 ) &
pid_c=$!
( route_d > "$OUT_PREFIX.route_d.log" 2>&1 ) &
pid_d=$!

wait $pid_a; echo "route_a done (rc=$?)"
wait $pid_sam; echo "route_sampler done (rc=$?)"
wait $pid_b; echo "route_tcp done (rc=$?)"
wait $pid_c; echo "route_udp done (rc=$?)"
wait $pid_d; echo "route_d done (rc=$?)"

for r in a b c d; do
    echo "===== $OUT_PREFIX.route_$r.log tail ====="
    tail -12 "$OUT_PREFIX.route_$r.log" 2>/dev/null
done
echo "===== $OUT_PREFIX.sampler.log tail ====="
tail -12 "$OUT_PREFIX.sampler.log" 2>/dev/null
