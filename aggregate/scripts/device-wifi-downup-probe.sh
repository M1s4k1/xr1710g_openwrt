#!/bin/sh
# device-wifi-downup-probe.sh — wifi down/up 后 AP 拒绝关联的只读取证脚本（F31/issue #10）
#
# 用法：
#   ./scripts/device-wifi-downup-probe.sh
#   DEVICE_HOST=root@192.168.123.1 ./scripts/device-wifi-downup-probe.sh
#   OUT_FILE=/tmp/downup.log ./scripts/device-wifi-downup-probe.sh
#   ROUNDS=5 SETTLE=10 DEVICE_HOST=root@192.168.123.1 ./scripts/device-wifi-downup-probe.sh
#
# 设计：
#   - 先采集正常基线（wifi reload 路径），再循环执行 wifi down/up 复现；
#   - 每轮 up 后立即采集接口/STA 表/debugfs/hostapd/logread，用于二分
#     netifd 销毁重建（down/up） vs hostapd 重配（reload）两条路径；
#   - 若基线存在已关联客户端、但 up 后客户端数为 0，则打印 issue #10 特征
#     （ap-ENABLED 但 STA 无法重新关联）告警；
#   - 本脚本只做只读诊断与标准的 wifi reload/down/up（会短暂中断无线），
#     不修改任何 UCI 配置；崩溃级复现请接串口后运行。
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST=${DEVICE_HOST:-root@192.168.123.1}
OUT=${OUT_FILE:-/tmp/device-wifi-downup-probe.log}
ROUNDS=${ROUNDS:-1}
SETTLE=${SETTLE:-10}

if [ -x "$REPO_DIR/.ssh/ssh-device" ]; then
    SSH_CMD="$REPO_DIR/.ssh/ssh-device"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$REPO_DIR/.ssh/known_hosts -i $REPO_DIR/.ssh/id_ed25519 $HOST"
fi

$SSH_CMD "
set -eu
ROUNDS='$ROUNDS'
SETTLE='$SETTLE'

echo '===== W1: wifi reload baseline ====='
wifi reload
sleep 5
echo '--- W1.1 iw dev ---'; iw dev
echo '--- W1.2 ubus wireless status (up/ifname) ---'
ubus call network.wireless status 2>/dev/null | grep -E '\"up\"|\"ifname\"|\"retry_setup_failed\"' || true
echo '--- W1.3 hostapd clients baseline ---'
baseline_clients=0
for i in 0 1 2; do
  echo \"--- phy0.\$i-ap0 get_clients ---\"
  c=\$(ubus call hostapd.phy0.\$i-ap0 get_clients 2>/dev/null | grep -oE '[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]' | sort -u | wc -l)
  echo \"phy0.\$i-ap0 baseline client count: \$c\"
  baseline_clients=\$((baseline_clients + c))
done
echo \"baseline total client count: \$baseline_clients\"

round=1
while [ \"\$round\" -le \"\$ROUNDS\" ]; do
  echo \"===== W2: round \$round/\$ROUNDS wifi down =====\"
  wifi down
  sleep 3
  echo '--- W2.1 iw dev after down ---'; iw dev

  echo \"===== W3: round \$round/\$ROUNDS wifi up (reproduce) =====\"
  wifi up
  sleep \"\$SETTLE\"
  echo '--- W3.1 iw dev after up ---'; iw dev
  echo '--- W3.2 ps hostapd ---'; ps w | grep hostapd | grep -v grep || true
  echo '--- W3.3 ubus wireless status after up ---'
  ubus call network.wireless status 2>/dev/null | grep -E '\"up\"|\"ifname\"|\"retry_setup_failed\"' || true

  echo \"===== W4: round \$round/\$ROUNDS hostapd STA view after up =====\"
  after_clients=0
  for i in 0 1 2; do
    echo \"--- phy0.\$i-ap0 get_status ---\"
    ubus call hostapd.phy0.\$i-ap0 get_status 2>/dev/null || true
    echo \"--- phy0.\$i-ap0 get_clients ---\"
    c=\$(ubus call hostapd.phy0.\$i-ap0 get_clients 2>/dev/null | grep -oE '[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]' | sort -u | wc -l)
    echo \"phy0.\$i-ap0 after-up client count: \$c\"
    after_clients=\$((after_clients + c))
  done
  echo \"round \$round after-up total client count: \$after_clients (baseline \$baseline_clients)\"
  if [ \"\$baseline_clients\" -gt 0 ] && [ \"\$after_clients\" -eq 0 ]; then
    echo '!!! issue #10 signature: AP-ENABLED but no client reassociated after wifi up'
  fi

  round=\$((round + 1))
done

echo '===== W5: kernel STA table debugfs (last round state) ====='
find /sys/kernel/debug/ieee80211/phy0/netdev:phy0.*-ap0/stations -maxdepth 1 -type d 2>/dev/null | head -50 || true

echo '===== W6: logread / dmesg mt76 & hostapd errors ====='
logread 2>/dev/null | grep -E 'Could not (set|add) STA|handle_assoc_cb|mt79|hostapd' | tail -120 || true
dmesg 2>/dev/null | grep -iE 'mt79|wifi|mac80211|airoha' | tail -80 || true

echo '===== W7: radio/phy info ====='
iw phy phy0 info | sed -n '/Wiphy/,/Band 1:/p' | head -80
" > "$OUT" 2>&1 || true

echo "probe log: $OUT"
tail -60 "$OUT"
