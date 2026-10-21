#!/bin/sh
# device-hw-probe.sh — XR1710G 硬件驱动深度测试（灯光 / 网口 / 网口灯光）
#
# 用法：
#   ./scripts/device-hw-probe.sh                 # 默认 5 路并行，只读为主（LED 会写并恢复）
#   TOGGLE_10G=1 ./scripts/device-hw-probe.sh     # 追加 10G 口 admin down/up 循环（注意会污染 lan1 计数器，见 FIXES HD-3）
#   LAN_MAC_PING=1 ./scripts/device-hw-probe.sh   # 追加 route_e 的 lan1/lan2 → 网关 ICMP 连通性探测
#   DEVICE_HOST=root@192.168.123.1 ./scripts/device-hw-probe.sh
#
# 说明：
#   - 测试期间会短暂改写 LED brightness/trigger，每路结束后恢复原状。
#   - 不会 down/up wan 与 lan3（SSH 所在网段），不会破坏 WAN/PPPoE。
#   - route_e 是 br-lan 与 10G 成员口的 MAC 一致性检查（只读，F119）；LAN_MAC_PING=1 才发 ICMP。
#   - 输出写入 /tmp/device-hw-probe-<route>.log，并打印每路尾部摘要。
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST=${DEVICE_HOST:-root@192.168.123.1}
OUT_PREFIX=${OUT_PREFIX:-/tmp/device-hw-probe}
SSH_CMD=""

if [ -x "$REPO_DIR/.ssh/ssh-device" ]; then
    SSH_CMD="$REPO_DIR/.ssh/ssh-device"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$REPO_DIR/.ssh/known_hosts -i $REPO_DIR/.ssh/id_ed25519 $HOST"
fi

# shellcheck disable=SC2029
# (ssh quoting is intentionally explicit per route)
route_a() {
    $SSH_CMD '
set -e
echo "===== ROUTE A: STATUS LED SUBSYSTEM DEEP TEST ====="
echo "--- A1 inventory ---"
for l in /sys/class/leds/*; do
  n=$(basename "$l")
  printf "%-32s brightness=%-2s max=%-2s trigger=%s\n" "$n" "$(cat "$l/brightness")" "$(cat "$l/max_brightness")" "$(sed -n "s/^.*\[\(.*\)\].*$/\1/p" "$l/trigger")"
done
echo "--- A2 brightness write/readback/restore (all status LEDs) ---"
for l in /sys/class/leds/*status*; do
  [ -e "$l/brightness" ] || continue
  n=$(basename "$l"); orig=$(cat "$l/brightness")
  echo 1 > "$l/brightness"; one=$(cat "$l/brightness")
  echo 0 > "$l/brightness"; zero=$(cat "$l/brightness")
  echo "$orig" > "$l/brightness"; rest=$(cat "$l/brightness")
  printf "%-32s orig=%s one=%s zero=%s restored=%s\n" "$n" "$orig" "$one" "$zero" "$rest"
done
echo "--- A3 trigger cycle on blue:status (safe) ---"
l=/sys/class/leds/blue:status
orig_b=$(cat "$l/brightness")
for trg in none default-on heartbeat timer; do
  echo "$trg" > "$l/trigger"; sleep 1
  printf "trigger=%-10s brightness=%s\n" "$trg" "$(cat "$l/brightness")"
done
echo none > "$l/trigger"; echo "$orig_b" > "$l/brightness"
echo "--- A4 timer sampling on red:status ---"
l=/sys/class/leds/red:status
orig_b=$(cat "$l/brightness")
echo timer > "$l/trigger"
i=1; while [ "$i" -le 6 ]; do printf "t=%s brightness=%s\n" "$i" "$(cat "$l/brightness")"; i=$((i+1)); sleep 1; done
echo none > "$l/trigger"; echo "$orig_b" > "$l/brightness"
echo "--- A5 netdev trigger probe on blue:status with wan/lan3 ---"
l=/sys/class/leds/blue:status
orig_b=$(cat "$l/brightness")
echo netdev > "$l/trigger"; sleep 1
for dev in wan lan3 eth0; do
  echo "$dev" > "$l/device_name" 2>/dev/null || continue
  echo 1 > "$l/link" 2>/dev/null || true
  sleep 1
  printf "dev=%-6s brightness=%s link=%s rx=%s tx=%s\n" "$dev" "$(cat "$l/brightness")" "$(cat "$l/link" 2>/dev/null)" "$(cat "$l/rx" 2>/dev/null)" "$(cat "$l/tx" 2>/dev/null)"
  echo 0 > "$l/link" 2>/dev/null || true
done
echo none > "$l/trigger"; echo "$orig_b" > "$l/brightness"
echo "--- A6 final restore inventory ---"
for l in /sys/class/leds/*; do
  n=$(basename "$l")
  printf "%-32s brightness=%s trigger=%s\n" "$n" "$(cat "$l/brightness")" "$(sed -n "s/^.*\[\(.*\)\].*$/\1/p" "$l/trigger")"
done
'
}

route_b() {
    $SSH_CMD '
echo "===== ROUTE B: ETHERNET PORT DRIVER DEEP TEST ====="
echo "--- B1 netdev sysfs electrical ---"
for i in eth0 lan1 lan2 wan lan3 br-lan; do
  echo "== $i =="
  for f in speed duplex carrier operstate link_mode carrier_changes carrier_up_count carrier_down_count mtu flags ifindex iflink addr_len; do
    [ -e "/sys/class/net/$i/$f" ] && printf "  %-20s %s\n" "$f" "$(cat "/sys/class/net/$i/$f" 2>/dev/null)"
  done
  echo "  address=$(cat "/sys/class/net/$i/address" 2>/dev/null)"
  echo "  of_node=$(readlink "/sys/class/net/$i/of_node" 2>/dev/null)"
  echo "  phys_port_name=$(cat "/sys/class/net/$i/phys_port_name" 2>/dev/null)"
  echo "  phys_switch_id=$(cat "/sys/class/net/$i/phys_switch_id" 2>/dev/null)"
done
echo "--- B2 PHY device inventory ---"
MDIO_DIR="/sys/devices/platform/soc/1fb58000.switch/mdio_bus"
MDIO_BUS="mt7530_dsa-0"
[ -d "$MDIO_DIR/$MDIO_BUS" ] || MDIO_BUS="mt7530-0"
for p in 05 08 09 0a; do
  d="$MDIO_DIR/$MDIO_BUS/$MDIO_BUS:$p"
  echo "== phy $p =="
  for f in phy_id phy_interface phy_dev_flags phy_has_fixups; do
    [ -f "$d/$f" ] && printf "  %-16s %s\n" "$f" "$(cat "$d/$f" 2>/dev/null)"
  done
  printf "  %-16s %s\n" "driver" "$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)"
  echo "  c45:"
  for f in "$d"/c45_phy_ids/*; do
    [ -f "$f" ] && printf "    %-16s %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
  done
  echo "  hwmon:"
  for f in "$d"/hwmon/*; do
    [ -f "$f" ] && case "$(basename "$f")" in temp*|name) printf "    %-16s %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)";; esac
  done
  echo "  statistics:"
  for f in "$d"/statistics/*; do
    [ -f "$f" ] && printf "    %-16s %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
  done
done
echo "--- B2.1 10G PHY VEND1 0x103/0x104 (RTL8261BE vs RTL8261N) ---"
if command -v phytool >/dev/null 2>&1; then
  # 10G PHY 挂在 mt7530_dsa-0 MDIO 总线上（PHYAD 5=lan2、8=lan1）。
  # 经 lan1/lan2 的 Airoha GDM ioctl 会返回 -95，必须借道 DSA 用户口
  # （wan/lan3）用 C45 MMD30(VEND1) 读：IFACE/<phy>:30/<reg>。
  for pair in "0x08 lan1" "0x05 lan2"; do
    set -- $pair
    phy=$1; port=$2
    echo "== $port (phy $phy) =="
    for reg in 0x103 0x104; do
      val=$(phytool read "wan/$phy:30/$reg" 2>/dev/null || true)
      [ -z "$val" ] && val=$(phytool read "lan3/$phy:30/$reg" 2>/dev/null || true)
      [ -z "$val" ] && val="read failed"
      printf "  VEND1 %-6s %s\n" "$reg" "$val"
    done
  done
  echo "  PHY ID (C22 reg 2/3, wan as MDIO path):"
  for pair in "0x08 lan1" "0x05 lan2"; do
    set -- $pair
    phy=$1; port=$2
    id2=$(phytool read "wan/$phy/0x02" 2>/dev/null || true)
    id3=$(phytool read "wan/$phy/0x03" 2>/dev/null || true)
    [ -z "$id2" ] && id2=$(phytool read "lan3/$phy/0x02" 2>/dev/null || true)
    [ -z "$id3" ] && id3=$(phytool read "lan3/$phy/0x03" 2>/dev/null || true)
    printf "  %-6s 0x%s 0x%s\n" "$port" "${id2#0x}" "${id3#0x}"
  done
else
  # F99（2026-09-11）：无 phytool 时的**只读回退**——用内核绑定信息 + C45 寄存器镜像判定 PHY 变体。
  # 实测（本机 2026-09-11，固件 r0-f36067d）：dmesg 明确 "RTL8261BE 10Gbps PHY"；
  # /sys/class/mdio_bus/*/*/phy_id 对 C45-only PHY 返回 0x00000000（C22 reg2/3 读不到），
  # 故不能只看 phy_id —— 必须结合 driver 名与 c45_phy_ids。
  echo "phytool 未安装 —— 走只读回退判定（driver 绑定 + C45 sysfs 镜像 + dmesg）："
  for bus in /sys/class/mdio_bus/*/; do
    bname=$(basename "$bus")
    case "$bname" in mt7530*) ;; *) continue ;; esac
    for dev in "$bus"*/; do
      [ -e "$dev/phy_id" ] || continue
      addr=$(basename "$dev")
      drv=$(basename "$(readlink -f "$dev/driver" 2>/dev/null)" 2>/dev/null)
      c22=$(cat "$dev/phy_id" 2>/dev/null)
      c45=""
      if [ -d "$dev/c45_phy_ids" ]; then
        c45=$(cat "$dev"/c45_phy_ids/* 2>/dev/null | sort -u | tr '\n' ' ')
      fi
      # C45 器件族判定（2026-09-11 实机基线：RTL8261BE => 0x001ccaf3）
      fam=""
      case "$c45" in
        *001ccaf3*) fam="RTL8261BE/N" ;;
        *001cc898*|*001cc899*) fam="RTL8261C/CG(CE 专属路径)" ;;
        "") fam="-" ;;
        *) fam="unrecognized" ;;
      esac
      printf "  %-14s %-12s drv=%-20s c22=%s c45=%s [%s]\n" "$bname" "$addr" "${drv:-<none>}" "$c22" "${c45:-<none>}" "$fam"
    done
  done
  echo "  dmesg 识别（最具判据力，驱动 probe 自带型号）："
  dmesg 2>/dev/null | grep -iE "RTL8261|RTL8264|rtl826x" | tail -6 | sed 's/^/    /' || true
  echo "  → 判定口径：drv/dmesg 含 'RTL8261BE' = BE 变体（<0x001cc899> CE 专属补丁不适用）；"
  echo "    含 'RTL8261N'/'RTL8261CE' 则需按 FIXES F75 与 #25092 适用性复核。"
  echo "  如需 VEND1 0x103/0x104 原始值：apk add phytool 后重跑（本段自动切换为直接读寄存器）。"
fi
echo "--- B3 baseline counters ---"
for i in eth0 lan1 lan2 wan lan3; do
  echo "$i rx_bytes=$(cat "/sys/class/net/$i/statistics/rx_bytes") tx_bytes=$(cat "/sys/class/net/$i/statistics/tx_bytes") rx_errors=$(cat "/sys/class/net/$i/statistics/rx_errors") tx_errors=$(cat "/sys/class/net/$i/statistics/tx_errors") rx_dropped=$(cat "/sys/class/net/$i/statistics/rx_dropped") tx_dropped=$(cat "/sys/class/net/$i/statistics/tx_dropped")"
done
if [ "${TOGGLE_10G:-0}" = "1" ]; then
  echo "--- B4 lan1/lan2 admin down/up cycle (explicitly enabled) ---"
  for i in lan1 lan2; do
    before_err=$(cat "/sys/class/net/$i/statistics/rx_errors")
    echo "$i before: rx_errors=$before_err"
    ip link set "$i" down; sleep 2
    echo "$i after down: flags=$(cat "/sys/class/net/$i/flags") operstate=$(cat "/sys/class/net/$i/operstate")"
    ip link set "$i" up; sleep 3
    after_err=$(cat "/sys/class/net/$i/statistics/rx_errors")
    echo "$i after up: rx_errors=$after_err delta=$((after_err-before_err))"
  done
else
  echo "--- B4 10G admin toggle skipped (set TOGGLE_10G=1 to enable; pollutes lan1 rx_errors) ---"
fi
echo "--- B5 disabled switch ports / phys ---"
for p in /proc/device-tree/soc/switch@1fb58000/ports/port@3 /proc/device-tree/soc/switch@1fb58000/ports/port@4 /proc/device-tree/soc/switch@1fb58000/mdio/ethernet-phy@b /proc/device-tree/soc/switch@1fb58000/mdio/ethernet-phy@c; do
  echo "$p status=$(cat "$p/status" 2>/dev/null)"
done
echo "--- B6 MDIO bus statistics/errors ---"
d="$MDIO_DIR/$MDIO_BUS/statistics"
for f in "$d"/errors "$d"/errors_*; do
  [ -f "$f" ] && printf "%s=%s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
done
echo "--- B7 board identity: EFR32 absence (XR1710G vs W1700K) ---"
for n in uart2 hsuart3; do
  if find /proc/device-tree -maxdepth 4 -name "$n" 2>/dev/null | grep -q .; then
    echo "FAIL: $n device-tree node present (W1700K EFR32 asset leaked?)"
  else
    echo "OK: $n absent"
  fi
done
'
}

route_c() {
    $SSH_CMD '
echo "===== ROUTE C: ETHERNET PORT LED SUBSYSTEM DEEP TEST ====="
for pfx in mt7530_dsa-0 mt7530-0; do
  if [ -e "/sys/class/leds/${pfx}:09:green:lan" ]; then
    LED_PFX="$pfx"
    break
  fi
done
echo "--- C1 port LED inventory ---"
for l in /sys/class/leds/${LED_PFX}:*; do
  n=$(basename "$l")
  printf "%-32s brightness=%s max=%s trigger=%s\n" "$n" "$(cat "$l/brightness")" "$(cat "$l/max_brightness")" "$(sed -n "s/^.*\[\(.*\)\].*$/\1/p" "$l/trigger")"
done
echo "--- C2 brightness write/readback/restore ---"
for l in /sys/class/leds/${LED_PFX}:*; do
  n=$(basename "$l"); orig=$(cat "$l/brightness")
  echo 1 > "$l/brightness"; one=$(cat "$l/brightness")
  echo 0 > "$l/brightness"; zero=$(cat "$l/brightness")
  echo "$orig" > "$l/brightness"
  printf "%-32s orig=%s one=%s zero=%s restored=%s\n" "$n" "$orig" "$one" "$zero" "$(cat "$l/brightness")"
done
echo "--- C3 netdev offload probe (wan then lan3) ---"
w=/sys/class/leds/${LED_PFX}:09:green:lan
l=/sys/class/leds/${LED_PFX}:0a:green:lan
echo none > "$w/trigger"; echo 0 > "$w/brightness"; echo none > "$l/trigger"; echo 0 > "$l/brightness"
echo netdev > "$w/trigger"; echo wan > "$w/device_name"
echo 1 > "$w/link" 2>/dev/null; echo 1 > "$w/rx" 2>/dev/null; echo 1 > "$w/tx" 2>/dev/null
echo "wan after mode: link=$(cat "$w/link") rx=$(cat "$w/rx") tx=$(cat "$w/tx") offloaded=$(cat "$w/offloaded" 2>/dev/null)"
echo netdev > "$l/trigger"; echo lan3 > "$l/device_name"
echo 1 > "$l/link" 2>/dev/null; echo 1 > "$l/rx" 2>/dev/null; echo 1 > "$l/tx" 2>/dev/null
echo "lan3 after mode: link=$(cat "$l/link") rx=$(cat "$l/rx") tx=$(cat "$l/tx") offloaded=$(cat "$l/offloaded" 2>/dev/null)"
echo "--- C4 10G port LED gap audit ---"
echo "sysfs 10G-port LED count: $(ls /sys/class/leds | grep -c "${LED_PFX}:0[58]:" || true)"
for p in 5 8 9 a; do
  d="/proc/device-tree/soc/switch@1fb58000/mdio/ethernet-phy@$p"
  echo "ethernet-phy@$p leds-dir-count: $(ls "$d" 2>/dev/null | grep -c leds || true)"
done
echo "--- C5 restore and final inventory ---"
for l in /sys/class/leds/${LED_PFX}:*; do
  echo none > "$l/trigger" 2>/dev/null || true
  echo 0 > "$l/brightness" 2>/dev/null || true
done
for l in /sys/class/leds/${LED_PFX}:*; do
  n=$(basename "$l")
  printf "%-32s brightness=%s trigger=%s\n" "$n" "$(cat "$l/brightness")" "$(sed -n "s/^.*\[\(.*\)\].*$/\1/p" "$l/trigger")"
done
'
}

route_d() {
    $SSH_CMD '
echo "===== ROUTE D: THERMAL / HWMON / FAN / ERROR-LOG AUDIT ====="
echo "--- D1 hwmon devices ---"
for d in /sys/class/hwmon/hwmon*; do
  echo "== $(basename "$d") name=$(cat "$d/name" 2>/dev/null) =="
  for f in "$d"/temp*_input "$d"/temp*_max "$d"/fan*_input "$d"/pwm*; do
    [ -f "$f" ] && printf "  %-16s %s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
  done
done
echo "--- D2 thermal zones ---"
for t in /sys/class/thermal/thermal_zone*; do
  echo "== $(basename "$t") type=$(cat "$t/type" 2>/dev/null) temp=$(cat "$t/temp" 2>/dev/null) =="
done
echo "--- D3 fan service ---"
ps w | grep -E "fan|nct" | grep -v grep || echo "no fan process visible"
/etc/init.d/fan status 2>&1 || true
echo "--- D4 error log audit ---"
dmesg | grep -i -E "error|fail|warn|timeout|deferred|unable|call trace|hung|oops|panic|BUG" | head -200 || echo "no matching kernel errors"
echo "--- D5 network carrier flap audit ---"
for i in eth0 lan1 lan2 wan lan3 br-lan; do
  printf "%-8s carrier_changes=%s up=%s down=%s rx_errors=%s tx_errors=%s\n" "$i" "$(cat "/sys/class/net/$i/carrier_changes" 2>/dev/null)" "$(cat "/sys/class/net/$i/carrier_up_count" 2>/dev/null)" "$(cat "/sys/class/net/$i/carrier_down_count" 2>/dev/null)" "$(cat "/sys/class/net/$i/statistics/rx_errors" 2>/dev/null)" "$(cat "/sys/class/net/$i/statistics/tx_errors" 2>/dev/null)"
done
echo "--- D6 devices_deferred ---"
cat /sys/kernel/debug/devices_deferred 2>/dev/null || echo "none"
echo "--- D7 relevant modules ---"
lsmod | grep -E "mt76|mt7996|realtek|nct7802|mt7530|airoha_eth"
'
}

route_e() {
    $SSH_CMD '
echo "===== ROUTE E: br-lan vs 10G PORT MAC CONSISTENCY (read-only) ====="
echo "--- E1 ip -br link (fallback: ip -o link) ---"
ip -br link 2>/dev/null || ip -o link 2>/dev/null || echo "ip link unavailable"
echo "--- E2 br-lan vs lan1/lan2/lan3/wan/eth0 MAC ---"
m() { cat "/sys/class/net/$1/address" 2>/dev/null || echo "<absent>"; }
br=$(m br-lan)
printf "%-8s %s\n" br-lan "$br"
for i in lan1 lan2 lan3 wan eth0; do
  printf "%-8s %s\n" "$i" "$(m "$i")"
done
echo "--- E3 conflict verdict (F119: br-lan must NOT share a MAC with a 10G member port) ---"
if [ "$br" = "<absent>" ]; then
  echo "SKIP: br-lan absent (interface not up) -> cannot judge; re-run after network start"
else
  bad=0
  for i in lan1 lan2; do
    v=$(m "$i")
    if [ "$v" = "$br" ]; then
      printf "  10G %-5s %s == br-lan %s  => CONFLICT (shared MAC)\n" "$i" "$v" "$br"; bad=1
    else
      printf "  10G %-5s %s != br-lan %s  => unique\n" "$i" "$v" "$br"
    fi
  done
  for i in lan3 wan; do
    v=$(m "$i")
    if [ "$v" = "$br" ]; then
      printf "  1G  %-5s %s == br-lan %s  => CONFLICT (shared MAC)\n" "$i" "$v" "$br"; bad=1
    else
      printf "  1G  %-5s %s != br-lan %s  => unique\n" "$i" "$v" "$br"
    fi
  done
  if [ "$bad" = "1" ]; then
    echo "VERDICT: CONFLICT — br-lan shares a MAC with a member port (management-plane loss risk under bridge/PPE offload)."
    echo "         Expected: unique MAC. Migration 98-xr1710g-brlan-mac-unique sets one only on conflict and keeps user values."
  else
    echo "VERDICT: UNIQUE — br-lan MAC is distinct from every member port (F119 OK)."
  fi
  uci -q get network.@device[0].macaddr 2>/dev/null | sed "s/^/  uci network.@device[0].macaddr = /" || true
  uci -q show network 2>/dev/null | grep -E "\.macaddr=|\.name=.br-lan|\.ports=" | sed "s/^/  uci: /" || true
fi
echo "--- E4 lan2 DHCP reachability precondition (which port is bridged) ---"
ip -br link show lan2 2>/dev/null || true
echo "  br-lan members (sysfs):"
ls /sys/class/net/br-lan/brif 2>/dev/null | sed "s/^/    /" || echo "    <br-lan absent or no brif>"
echo "--- E5 LAN L2 reachability probe (opt-in; pings the default gateway from each port) ---"
if [ "${LAN_MAC_PING:-0}" = "1" ]; then
  for i in lan1 lan2; do
    echo "$i: $(ping -I "$i" -c 3 -W 1 192.168.123.1 2>&1 | tail -2 | tr "\n" " ")"
  done
else
  echo "skipped (set LAN_MAC_PING=1 to enable; pings 192.168.123.1 via lan1/lan2)"
fi
echo "--- E6 ethtool link/MAC (best effort) ---"
if command -v ethtool >/dev/null 2>&1; then
  for i in lan1 lan2 br-lan; do
    echo "== $i =="
    ethtool "$i" 2>/dev/null | grep -E "Speed|Duplex|Link detected|Permanent address|Current message level" | sed "s/^/  /" || true
  done
else
  echo "ethtool not installed"
fi
echo "--- E7 MAC byte map (human diff aid) ---"
for i in br-lan lan1 lan2 lan3 wan; do
  v=$(m "$i")
  case "$v" in
  "<absent>") printf "  %-7s <absent>\n" "$i" ;;
  *) printf "  %-7s %s  (oui=%s last=%s)\n" "$i" "$v" "${v%:*:*:*}" "${v##*:}" ;;
  esac
done
'
}

# 多路齐发：5 条路由同时执行（route_e 为只读 MAC 一致性检查，F119）
for r in a b c d e; do : > "$OUT_PREFIX.route_$r.log"; done

( route_a > "$OUT_PREFIX.route_a.log" 2>&1 ) &
pid_a=$!
( route_b > "$OUT_PREFIX.route_b.log" 2>&1 ) &
pid_b=$!
( route_c > "$OUT_PREFIX.route_c.log" 2>&1 ) &
pid_c=$!
( route_d > "$OUT_PREFIX.route_d.log" 2>&1 ) &
pid_d=$!
( route_e > "$OUT_PREFIX.route_e.log" 2>&1 ) &
pid_e=$!

wait $pid_a; echo "route_a done (rc=$?)"
wait $pid_b; echo "route_b done (rc=$?)"
wait $pid_c; echo "route_c done (rc=$?)"
wait $pid_d; echo "route_d done (rc=$?)"
wait $pid_e; echo "route_e done (rc=$?)"

for r in a b c d e; do
  echo "===== $OUT_PREFIX.route_$r.log tail ====="
  tail -8 "$OUT_PREFIX.route_$r.log"
done
