#!/bin/sh
# device-npu-probe.sh — XR1710G NPU offload / "CLIENTS N offloaded" 深度测试
#
# 用法：
#   ./scripts/device-npu-probe.sh                 # 默认 4 路并行，只读；采样 5 次 × 10s
#   SAMPLES=10 INTERVAL=5 ./scripts/device-npu-probe.sh
#   DEVICE_HOST=root@192.168.123.1 ./scripts/device-npu-probe.sh
#
# 说明：
#   - 全程只读，不做 flow_offloading_hw 等切换（1→0→1 触发过设备重启，见 F34）。
#   - 输出写入 /tmp/device-npu-probe-<route>.log，并打印每路尾部摘要。
#   - 核心判据：CLIENTS offload 计数必须综合 eth= MAC、BND orig/new IP 与
#     conntrack [HW_OFFLOAD] 三路信号——仅看 eth= 会漏报路由型 Wi-Fi 客户端。
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST=${DEVICE_HOST:-root@192.168.123.1}
OUT_PREFIX=${OUT_PREFIX:-/tmp/device-npu-probe}
SAMPLES=${SAMPLES:-5}
INTERVAL=${INTERVAL:-10}
SSH_CMD=""

if [ -x "$REPO_DIR/.ssh/ssh-device" ]; then
    SSH_CMD="$REPO_DIR/.ssh/ssh-device"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$REPO_DIR/.ssh/known_hosts -i $REPO_DIR/.ssh/id_ed25519 $HOST"
fi

route_a() {
    $SSH_CMD '
echo "===== A1 RPC objects ====="
ubus list | grep -E "airoha|npu|flow|mlo"
echo "===== A2 luci.airoha_npu getStatus ====="
ubus call luci.airoha_npu getStatus 2>&1
echo "===== A3 luci.airoha_flowsense getStatus ====="
ubus call luci.airoha_flowsense getStatus 2>&1
echo "===== A4 luci.airoha_npu getPpeEntries (first 500 bytes) ====="
ubus call luci.airoha_npu getPpeEntries 2>&1 | head -c 500; echo
echo "===== A5 luci.airoha_flowsense getPpeEntries summary ====="
ubus call luci.airoha_flowsense getPpeEntries 2>/dev/null | jsonfilter -e "@.bnd.total" -e "@.bnd.ipv4" -e "@.bnd.band_bnd" -e "@.bnd.port_bnd" -e "@.bnd.client_bnd" 2>/dev/null \
  || ubus call luci.airoha_flowsense getPpeEntries 2>&1 | head -c 1200
echo "===== A6 getTokenInfo (both objects) ====="
ubus call luci.airoha_npu getTokenInfo 2>&1
echo
ubus call luci.airoha_flowsense getTokenInfo 2>&1
echo "===== A7 getFrameEngine (both objects) ====="
ubus call luci.airoha_npu getFrameEngine 2>&1
echo
ubus call luci.airoha_flowsense getFrameEngine 2>&1
echo "===== A8 VLAN/Flow offload getters ====="
ubus call luci.airoha_npu getVlanOffload 2>&1
echo
ubus call luci.airoha_npu getPPPoEOffload 2>&1
echo
ubus call luci.airoha_flowsense getVlanOffload 2>&1
echo
ubus call luci.airoha_flowsense getFlowOffload 2>&1
'
}

route_b() {
    $SSH_CMD '
echo "===== B1 reserved-memory DT nodes (reg via hexdump) ====="
for n in /proc/device-tree/reserved-memory/npu-*; do
  [ -d "$n" ] || continue
  name=$(basename "$n")
  reg=$(hexdump -v -e "2/4 \"%08x\" \" \"" "$n/reg" 2>/dev/null | tr -d " ")
  echo "$name reg=$reg"
done
echo "===== B2 NPU driver / clock / interrupts ====="
echo "npu_clk_rate=$(cat /sys/kernel/debug/clk/npu/clk_rate 2>/dev/null)"
ls -la /sys/bus/platform/drivers/airoha-npu 2>/dev/null
grep -i "airoha\|npu" /proc/interrupts 2>/dev/null
echo "===== B3 PPE debugfs counts ====="
echo "bind_BND=$(grep -cE "^[0-9a-fA-F]+ BND" /sys/kernel/debug/ppe/bind 2>/dev/null) bind_rows=$(wc -l < /sys/kernel/debug/ppe/bind 2>/dev/null)"
echo "entries_total=$(grep -cE "^[0-9a-fA-F]+" /sys/kernel/debug/ppe/entries 2>/dev/null) entries_UNB=$(grep -cE "^[0-9a-fA-F]+ UNB" /sys/kernel/debug/ppe/entries 2>/dev/null) entries_BND=$(grep -cE "^[0-9a-fA-F]+ BND" /sys/kernel/debug/ppe/entries 2>/dev/null)"
echo "===== B4 PPE BND sample (packets/bytes always-zero audit) ====="
grep -E "^[0-9a-fA-F]+ BND" /sys/kernel/debug/ppe/bind 2>/dev/null | head -12
echo "===== B4.1 getPpeFlowStats summary (issue #5 conntrack per-flow counters) ====="
ubus call luci.airoha_flowsense getPpeFlowStats 2>/dev/null | jsonfilter -e '@.available' -e '@.summary.bnd_total' -e '@.summary.bnd_ct_matched' -e '@.summary.bnd_hw' -e '@.summary.bnd_hw_packets' -e '@.summary.bnd_hw_bytes' -e '@.summary.unb_total' -e '@.summary.unb_ct_matched' 2>/dev/null || true
echo "===== B5 conntrack offload counts ====="
echo "conntrack_total=$(wc -l < /proc/net/nf_conntrack 2>/dev/null)"
echo "conntrack_HW_OFFLOAD=$(grep -c HW_OFFLOAD /proc/net/nf_conntrack 2>/dev/null)"
echo "conntrack_OFFLOAD=$(grep -cE "\[OFFLOAD\]" /proc/net/nf_conntrack 2>/dev/null)"
echo "===== B6 flowtable settings ====="
for f in /proc/sys/net/netfilter/nf_flowtable_tcp_timeout /proc/sys/net/netfilter/nf_flowtable_udp_timeout; do echo "$f=$(cat $f 2>/dev/null)"; done
nft list flowtable inet fw4 ft 2>/dev/null | head -20
echo "===== B7 diagnostic tool gaps ====="
for t in bridge ethtool devmem opkg iwinfo hexdump od; do printf "%s=%s\n" "$t" "$(command -v $t || echo MISSING)"; done
'
}

route_c() {
    $SSH_CMD '
echo "===== C1 stations per band ====="
for b in 0 1 2; do
  for iface in $(iw dev 2>/dev/null | awk "/Interface phy[0-9]*\\.$b-/{print \$2}"); do
    echo "-- $iface --"
    iw dev "$iface" station dump 2>/dev/null | grep -E "^Station|connected time|tx bitrate|rx bitrate"
  done
done
echo "===== C2 MAC->IP table ====="
ip neigh show 2>/dev/null | grep " lladdr "
cat /tmp/dhcp.leases 2>/dev/null
echo "===== C3 repeated samples ====="
for s in $(seq 1 '"$SAMPLES"'); do
  echo "--- sample $s $(date +%s) ---"
  ubus call luci.airoha_flowsense getPpeEntries 2>/dev/null | jsonfilter -e "@.bnd.client_bnd" 2>/dev/null
  echo "wifi_hw_offload_by_ip:"
  for ip in $(ubus call luci.airoha_flowsense getPpeEntries 2>/dev/null | jsonfilter -e "@.bnd.client_bnd[*].ip" 2>/dev/null | tr -d "\"" ); do
    [ -n "$ip" ] || continue
    echo -n "  $ip: hw=$(grep -E "src=$ip|dst=$ip" /proc/net/nf_conntrack 2>/dev/null | grep -c HW_OFFLOAD) off=$(grep -E "src=$ip|dst=$ip" /proc/net/nf_conntrack 2>/dev/null | grep -cE "\[OFFLOAD\]") "
    echo "bnd_ip=$(grep -E "orig=$ip:|new=.*:$ip->" /sys/kernel/debug/ppe/bind 2>/dev/null | grep -c BND)"
  done
  echo "ppe_BND=$(grep -cE "^[0-9a-fA-F]+ BND" /sys/kernel/debug/ppe/bind) ppe_entries=$(grep -cE "^[0-9a-fA-F]+" /sys/kernel/debug/ppe/entries) conntrack_hw=$(grep -c HW_OFFLOAD /proc/net/nf_conntrack)"
  sleep '"$INTERVAL"'
done
'
}

route_d() {
    $SSH_CMD '
echo "===== D1 stability sample ====="
for s in $(seq 1 '"$SAMPLES"'); do
  ts=$(date +%s)
  bnd=$(grep -cE "^[0-9a-fA-F]+ BND" /sys/kernel/debug/ppe/bind 2>/dev/null)
  ent=$(grep -cE "^[0-9a-fA-F]+" /sys/kernel/debug/ppe/entries 2>/dev/null)
  unb=$(grep -cE "^[0-9a-fA-F]+ UNB" /sys/kernel/debug/ppe/entries 2>/dev/null)
  hw=$(grep -c HW_OFFLOAD /proc/net/nf_conntrack 2>/dev/null)
  off=$(grep -cE "\[OFFLOAD\]" /proc/net/nf_conntrack 2>/dev/null)
  ct=$(wc -l < /proc/net/nf_conntrack 2>/dev/null)
  cpu=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)
  npuclk=$(cat /sys/kernel/debug/clk/npu/clk_rate 2>/dev/null)
  mem=$(free 2>/dev/null | awk "/Mem:/{print \$3\"/\"\$2}")
  echo "t=$ts bnd=$bnd ent=$ent unb=$unb hwct=$hw offct=$off ct=$ct cpu=$cpu npu=$npuclk mem=$mem"
  sleep '"$INTERVAL"'
done
echo "===== D2 error log scan ====="
dmesg | grep -i -E "npu|airoha|mt76|mt7996|ppe|offload|error|fail|warn|timeout|hung|oops|panic|BUG|deferred" | tail -80
echo "===== D3 recent logread npu/mt76 ====="
logread 2>/dev/null | grep -i -E "npu|mt76|mt7996|offload|error|fail|warn|timeout" | tail -80
'
}

# 多路齐发：4 条路由同时执行
: > "$OUT_PREFIX.route_a.log"
: > "$OUT_PREFIX.route_b.log"
: > "$OUT_PREFIX.route_c.log"
: > "$OUT_PREFIX.route_d.log"

( route_a > "$OUT_PREFIX.route_a.log" 2>&1 ) &
pid_a=$!
( route_b > "$OUT_PREFIX.route_b.log" 2>&1 ) &
pid_b=$!
( route_c > "$OUT_PREFIX.route_c.log" 2>&1 ) &
pid_c=$!
( route_d > "$OUT_PREFIX.route_d.log" 2>&1 ) &
pid_d=$!

wait $pid_a; echo "route_a done (rc=$?)"
wait $pid_b; echo "route_b done (rc=$?)"
wait $pid_c; echo "route_c done (rc=$?)"
wait $pid_d; echo "route_d done (rc=$?)"

for r in a b c d; do
  echo "===== $OUT_PREFIX.route_$r.log tail ====="
  tail -10 "$OUT_PREFIX.route_$r.log"
done
