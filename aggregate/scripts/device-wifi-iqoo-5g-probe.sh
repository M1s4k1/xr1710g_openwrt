#!/bin/sh
# device-wifi-iqoo-5g-probe.sh — iQOO Neo9 Pro 无法连接 5G WiFi 的只读取证脚本
#
# 用法：
#   ./scripts/device-wifi-iqoo-5g-probe.sh
#   IQOO_MAC=e2:0d:5e:29:67:6d ./scripts/device-wifi-iqoo-5g-probe.sh
#   DEVICE_HOST=root@192.168.123.1 ./scripts/device-wifi-iqoo-5g-probe.sh
#
# 只做只读诊断（不写 UCI、不 reload），输出到 /tmp/device-wifi-iqoo-5g-probe.log
# 并在 stdout 打印尾部摘要。
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST=${DEVICE_HOST:-root@192.168.123.1}
IQOO_MAC=${IQOO_MAC:-e2:0d:5e:29:67:6d}
OUT=${OUT_FILE:-/tmp/device-wifi-iqoo-5g-probe.log}

if [ -x "$REPO_DIR/.ssh/ssh-device" ]; then
    SSH_CMD="$REPO_DIR/.ssh/ssh-device"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$REPO_DIR/.ssh/known_hosts -i $REPO_DIR/.ssh/id_ed25519 $HOST"
fi

$SSH_CMD "
set -eu
MAC='$IQOO_MAC'
echo '===== A1: UCI wireless ====='
uci show wireless
echo
echo '===== A2: iw dev ====='
iw dev
echo
echo '===== A3: iwinfo ====='
iwinfo 2>/dev/null || true
echo
echo '===== A4: hostapd 5G conf ====='
cat /var/run/hostapd-phy0.1.conf 2>/dev/null || true
echo
echo '===== A5: hostapd 2G conf (security fields) ====='
grep -E 'ssid|wpa|sae|ieee80211w|beacon_prot|okc|channel|htmode|he_oper|vht_oper' /var/run/hostapd-phy0.0.conf 2>/dev/null || true
echo
echo '===== B1: hostapd get_clients 2.4G ====='
ubus call hostapd.phy0.0-ap0 get_clients 2>/dev/null || true
echo
echo '===== B2: hostapd get_clients 5G ====='
ubus call hostapd.phy0.1-ap0 get_clients 2>/dev/null || true
echo
echo '===== B3: logread for iQOO MAC ====='
logread | grep -i \"\$MAC\" || echo '(no log lines for MAC)'
echo
echo '===== B4: hostapd get_status 5G ====='
ubus call hostapd.phy0.1-ap0 get_status 2>/dev/null || true
echo
echo '===== C1: iw phy 5G band capabilities / frequencies ====='
iw phy phy0 info | sed -n '/Band 2:/,/Band 4:/p'
echo
echo '===== C2: wifi status up flags ====='
ubus call network.wireless status 2>/dev/null | grep -E '\"up\"|\"retry_setup_failed\"|\"ifname\"' || true
echo
echo '===== D1: installed wireless diagnostics packages ====='
apk list -I 2>/dev/null | grep -Ei 'dawn|usteer|wpad|hostapd|tcpdump|iperf3|wpa-cli' || true
echo
echo '===== D2: band steering / k-v-r config presence ====='
uci show wireless | grep -Ei 'ieee80211k|ieee80211v|ieee80211r|bss_transition|steer|rssi' || echo '(none)'
" > "$OUT" 2>&1 || true

echo "===== probe summary ($OUT) ====="
grep -E '=====|e2:0d|signal|freq|channel|width|retry_setup_failed|\(none\)|no log' "$OUT" | tail -80
