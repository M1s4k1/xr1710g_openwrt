#!/bin/sh
# device-pcie-aer-probe.sh — XR1710G PCIe AER 只读诊断探针（FIXES 台账 F116）
#
# 目的：MT7996（Wi-Fi7）走 PCIe；社区已有 W1700K V1.1 无线芯片永久失效案例，日志链为
#   14c3:6899 Correctable RxErr → Uncorrectable Fatal [ 5] SDES / [14] CmpltTO
#   → mt7996e_hif AER: can't recover → Root Port link has been reset
#   → device recovery failed → /sys/bus/pci/devices 里设备消失。
#   AER 是唯一能区分"可恢复（Correctable/Non-Fatal）vs 硬件死亡（Fatal + 链路摘除）"的观测面。
#   本脚本默认全程只读（无任何写操作）；F56（hif Gen2 x1 板级上限）与 F95（chip full reset
#   failed）的 AER 视角即由此探针补上：链路层失效与整机复位失败是同一 Root Port 路径的两个面。
#
# 用法：
#   ./scripts/device-pcie-aer-probe.sh                       # 默认只读，输出 /tmp/device-pcie-aer-probe.log
#   AER_BDF=0000:01:00.0 ./scripts/device-pcie-aer-probe.sh  # 指定 BDF（缺省 = 按 driver=mt7996e 自动探测）
#   本机有两个 PCI domain（0000:01:00.0 = mt7996e 主；0002:01:00.0 = hif2）⇒ 不要硬编码旧值
#   0002:00:00.0；先 `ls /sys/bus/pci/devices` 或用本脚本默认的自动探测（F116/坑 42）。
#   AER_DEMOTE=1 ./scripts/device-pcie-aer-probe.sh          # 【写】把 SDES 由 Fatal 降为 Non-Fatal
#   DEVICE_HOST=root@192.168.123.1 OUT_PREFIX=/tmp/aer ./scripts/device-pcie-aer-probe.sh
#
# 只读语义（相对设备 config 起点的 4 字节字；已核实）：
#   seek=129 (0x204) = AER Uncorrectable Error Status
#   seek=131 (0x20C) = AER Uncorrectable Error Severity（1=Fatal / 0=Non-fatal）
#   seek=132 (0x210) = AER Correctable Error Status
#   bit5 = SDES（Surprise Down）↔ 内核日志 `[ 5] SDES (First)`；severity 基线 0x00462030
#   降级写：printf '\x10\x20\x46\x00' | dd of=<config> bs=4 seek=131 count=1（清 bit5，必须显式开关）
#
# 退出码：0=正常；2=SSH 不可达（预检失败）；3=目标 BDF 不在 /sys/bus/pci/devices（已被 AER 摘除）；4=自动探测未找到 mt7996e
set -eu

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
HOST=${DEVICE_HOST:-root@192.168.123.1}
TARGET=${AER_BDF:-auto}
DEMOTE=${AER_DEMOTE:-0}
OUT=${OUT_PREFIX:-/tmp/device-pcie-aer-probe}.log
SSH_CMD=""

if [ -x "$REPO_DIR/.ssh/ssh-device" ]; then
    SSH_CMD="$REPO_DIR/.ssh/ssh-device"
else
    SSH_CMD="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=$REPO_DIR/.ssh/known_hosts -i $REPO_DIR/.ssh/id_ed25519 -o ConnectTimeout=8 -o BatchMode=yes $HOST"
fi

# 预检：设备不可达时清晰报错退出（ConnectTimeout + BatchMode 保证不挂死、不等密码）
if ! $SSH_CMD 'echo __reach__' 2>/dev/null | grep -q __reach__; then
    echo "ERROR: 设备不可达（SSH 预检失败）：$HOST" >&2
    echo "  排查：ping 192.168.123.1；确认 $REPO_DIR/.ssh/id_ed25519 已授权；或用 DEVICE_HOST=<user@host> 覆盖。" >&2
    exit 2
fi

echo "== device-pcie-aer-probe：HOST=$HOST TARGET=$TARGET AER_DEMOTE=$DEMOTE =="
echo "== 输出：$OUT =="
if [ "$DEMOTE" = "1" ]; then
    echo "== ⚠ 写模式已开启：将对 AER Uncorrectable Error Severity 执行降级写 =="
fi

rc=0
$SSH_CMD "AER_DEMOTE=$DEMOTE TARGET=$TARGET sh -s" >"$OUT" 2>&1 <<'REMOTE' || rc=$?
set -eu
TARGET=${TARGET:-auto}
DEMOTE=${AER_DEMOTE:-0}
SYS=/sys/bus/pci/devices

# F116/坑 42：本机 mt7996e = 0000:01:00.0（两个 PCI domain：0000:01:00.0 主 + 0002:01:00.0 hif2），
# 旧默认 0002:00:00.0 不是目标。默认按 driver 名自动探测；AER_BDF=<BDF> 可显式覆盖。
if [ "$TARGET" = "auto" ] || [ -z "$TARGET" ]; then
    TARGET=""
    for d in "$SYS"/*; do
        drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null) || drv=""
        if [ "$drv" = "mt7996e" ]; then TARGET=$(basename "$d"); break; fi
    done
    if [ -z "$TARGET" ] || [ ! -d "$SYS/$TARGET" ]; then
        echo "ERROR: 自动探测未找到 driver=mt7996e 的设备；请用 AER_BDF=<BDF> 显式指定。" >&2
        echo "  现存 PCI 设备（BDF driver）：" >&2
        for d in "$SYS"/*; do
            drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null) || drv="-"
            echo "    $(basename "$d")  $drv" >&2
        done
        exit 4
    fi
    echo "== 自动探测：TARGET=$TARGET（driver=mt7996e）=="
fi
CFG="$SYS/$TARGET/config"

echo "===== XR1710G PCIe AER 只读诊断探针（FIXES F116）====="
echo "host=$(hostname 2>/dev/null || echo '?')  kernel=$(uname -r 2>/dev/null || echo '?')  date=$(date 2>/dev/null || echo '?')"
echo

# ---------- helpers ----------
le32() { dd if="$1" bs=4 skip="$2" count=1 2>/dev/null | hexdump -v -e '1/4 "%u"' | awk '{printf "%u", $1}'; }
dump4() { out=$(if command -v hexdump >/dev/null 2>&1; then dd if="$1" bs=4 skip="$2" count=1 2>/dev/null | hexdump -C; else dd if="$1" bs=4 skip="$2" count=1 2>/dev/null | od -An -tx1; fi)
    if [ -n "$out" ]; then echo "$out"; else echo "(读取失败：无扩展配置空间，或设备已被摘除)"; fi; }
readable() { [ "$(dd if="$1" bs=4 skip="$2" count=1 2>/dev/null | wc -c | tr -d ' ')" = "4" ] && echo 1 || echo 0; }
num() { case "${1:-}" in ''|*[!0-9]*) echo 0;; *) echo "$1";; esac; }

# 位名取自本仓内核树 drivers/pci/pcie/aer.c 的 aer_uncorrectable_error_string / aer_correctable_error_string
uncorr_name() { case "$1" in 0) echo "Undefined";; 4) echo "DLP";; 5) echo "SDES";; 12) echo "TLP";; 13) echo "FCP";; 14) echo "CmpltTO";; 15) echo "CmpltAbrt";; 16) echo "UnxCmplt";; 17) echo "RxOF";; 18) echo "MalfTLP";; 19) echo "ECRC";; 20) echo "UnsupReq";; 21) echo "ACSViol";; 22) echo "UncorrIntErr";; 23) echo "BlockedTLP";; 24) echo "AtomicOpBlocked";; 25) echo "TLPBlockedErr";; 26) echo "PoisonTLPBlocked";; 27) echo "DMWrReqBlocked";; 28) echo "IDECheck";; 29) echo "MisIDETLP";; 30) echo "PCRC_CHECK";; 31) echo "TLPXlatBlocked";; *) echo "bit$1";; esac; }
corr_name() { case "$1" in 0) echo "RxErr";; 6) echo "BadTLP";; 7) echo "BadDLLP";; 8) echo "Rollover";; 12) echo "Timeout";; 13) echo "NonFatalErr";; 14) echo "CorrIntErr";; 15) echo "HeaderOF";; *) echo "bit$1";; esac; }
annotate() { v=$1; kind=$2; i=0
  while [ "$i" -le 31 ]; do
    if [ $(( v & (1 << i) )) -ne 0 ]; then
      if [ "$kind" = "uncorr" ]; then n=$(uncorr_name "$i"); else n=$(corr_name "$i"); fi
      printf "        bit%-2d = 1  %s\n" "$i" "$n"
    fi
    i=$((i+1))
  done; }

# ---------- W0 目标设备存在性（设备被 AER 摘除是"硬件死亡"的直接证据）----------
if [ ! -d "$SYS/$TARGET" ]; then
    echo "===== W0 目标设备存在性 ====="
    echo "\$ test -d $SYS/$TARGET   → 不存在"
    echo "!!! 目标设备已从 sysfs 消失：AER Fatal 的后续态（Root Port 摘除设备）"
    echo "--- 现存 PCI 设备（对照）---"
    ls "$SYS" 2>/dev/null | sed 's/^/  /' || true
    echo "--- dmesg 关键链（末 40 行）---"
    dmesg 2>/dev/null | grep -iE "aer|pcieport|mt7996e_hif|mt7996|can.t recover|link has been reset|recovery failed" | tail -40 | sed 's/^/  /' || true
    echo
    echo "AER 判读：目标设备不在 /sys/bus/pci/devices ⇒ 设备已被 Root Port/AER 摘除（Fatal 后续态），非软件可修"
    exit 3
fi

# ---------- W1 设备枚举 + lspci 形态 ----------
echo "===== W1 PCI 设备枚举 ====="
echo "\$ ls $SYS"
ls "$SYS" 2>/dev/null | sed 's/^/  /'
echo "\$ cat {vendor,device,class,current_link_*}"
for d in "$SYS"/*; do
    bdf=$(basename "$d")
    drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null) || drv=""
    [ -n "$drv" ] || drv="-"
    printf "  %-14s %s:%s class=%s drv=%s\n" "$bdf" "$(cat "$d/vendor" 2>/dev/null)" "$(cat "$d/device" 2>/dev/null)" "$(cat "$d/class" 2>/dev/null)" "$drv"
    for f in current_link_speed current_link_width max_link_speed max_link_width; do
        if [ -f "$d/$f" ]; then printf "      %-20s %s\n" "$f" "$(cat "$d/$f")"; fi
    done
done
echo "\$ lspci -nn"
command -v lspci >/dev/null 2>&1 && lspci -nn 2>/dev/null | sed 's/^/  /' || echo "  (lspci 不可用)"

# ---------- W2 config 三元寄存器只读（每个设备）----------
echo
echo "===== W2 AER 寄存器只读（seek=131/129/132，每设备）====="
echo "  基线：Uncorrectable Error Severity = 0x00462030（小端 30 20 46 00，bit5 SDES=Fatal）"
usev=0; ues=0; ces=0   # 仅作为目标设备取值的初值（下方按 BDF 采集，避免被其它设备覆盖）
usev_t=0; ues_t=0; ces_t=0; ok_t=0
for d in "$SYS"/*; do
    bdf=$(basename "$d"); c="$d/config"
    [ -r "$c" ] || continue
    echo "-- $bdf --"
    # 目标设备的扩展配置可读性：读不到 4 字节时，"全 0"不代表链路健康（可能无 AER 能力/已摘除）
    if [ "$bdf" = "$TARGET" ]; then ok_t=$(readable "$c" 131); fi
    echo "   \$ dd if=$c bs=4 skip=131 count=1 | hexdump -C   # 0x20C Uncorrectable Error Severity"
    dump4 "$c" 131 | sed 's/^/   /'
    usev=$(num "$(le32 "$c" 131)"); printf "   → Severity  = 0x%08x\n" "$usev"; annotate "$usev" uncorr
    echo "   \$ dd if=$c bs=4 skip=129 count=1 | hexdump -C   # 0x204 Uncorrectable Error Status"
    dump4 "$c" 129 | sed 's/^/   /'
    ues=$(num "$(le32 "$c" 129)"); printf "   → UncorrSts = 0x%08x\n" "$ues"; annotate "$ues" uncorr
    echo "   \$ dd if=$c bs=4 skip=132 count=1 | hexdump -C   # 0x210 Correctable Error Status"
    dump4 "$c" 132 | sed 's/^/   /'
    ces=$(num "$(le32 "$c" 132)"); printf "   → CorrSts   = 0x%08x\n" "$ces"; annotate "$ces" corr
    # 汇总只认目标 BDF 的读数（循环里最后一个设备不一定是目标）
    if [ "$bdf" = "$TARGET" ]; then usev_t=$usev; ues_t=$ues; ces_t=$ces; fi
done
usev=$usev_t; ues=$ues_t; ces=$ces_t

# ---------- W3 lspci -vv 的 AER capability 段 ----------
echo
echo "===== W3 lspci -vv -s $TARGET 的 AER capability 段 ====="
if command -v lspci >/dev/null 2>&1; then
    lspci -vv -s "$TARGET" 2>/dev/null | awk '
        /Advanced Error Reporting/ { f=1 }
        f && /^[ \t]*$/ { exit }
        f && /^[^ \t]/ && !/Advanced Error Reporting/ { exit }
        f { print }' | sed 's/^/  /'
else
    echo "  (lspci 不可用，跳过；寄存器读数为准)"
fi

# ---------- W4 dmesg 关键链（行数上限）----------
echo
echo "===== W4 dmesg AER/链路关键链（末 60 行）====="
echo "\$ dmesg | grep -iE 'aer|pcieport|mt7996e_hif|can.t recover' | tail -60"
dmesg 2>/dev/null | grep -iE "aer|pcieport|mt7996e_hif|can.t recover" | tail -60 | sed 's/^/  /' || true

# ---------- W5 降级写（仅 AER_DEMOTE=1）----------
echo
echo "===== W5 SDES Fatal→Non-Fatal 降级写 ====="
if [ "$DEMOTE" = "1" ]; then
    echo "  目标设备 config：$CFG"
    echo "  将写入字节    ：10 20 46 00（小端 0x00462010，清 bit5 SDES 的 severity 位）"
    echo "  等价命令      ：printf '\\x10\\x20\\x46\\x00' | dd of=$CFG bs=4 seek=131 count=1"
    echo "  ⚠ 需 reboot 或重新 enable 才能完全还原；仅在确认硬件仍可枚举时使用"
    printf '\x10\x20\x46\x00' | dd of="$CFG" bs=4 seek=131 count=1 2>&1 | sed 's/^/  /'
    echo "  回读："
    dump4 "$CFG" 131 | sed 's/^/   /'
    v=$(num "$(le32 "$CFG" 131)"); printf "   → Severity  = 0x%08x\n" "$v"; annotate "$v" uncorr
else
    echo "  已跳过（默认只读）——AER_DEMOTE=1 才执行；本脚本默认路径无任何 dd of= 写操作"
fi

# ---------- W6 汇总（可贴进 issue）----------
echo
echo "===== W6 汇总（可贴进 issue）====="
echo "  kernel            : $(uname -r 2>/dev/null || echo '?')"
echo "  target            : $TARGET"
echo "  severity(0x20C)   : 0x$(printf '%08x' "$usev")"
echo "  uncorr_status     : 0x$(printf '%08x' "$ues")"
echo "  corr_status       : 0x$(printf '%08x' "$ces")"
echo "  SDES severity bit5: $(( (usev >> 5) & 1 ))"
echo "  SDES status   bit5: $(( (ues >> 5) & 1 ))"
echo "  fatal bits(ues&usev): 0x$(printf '%08x' "$(( ues & usev ))")"
echo "  扩展配置可读(0x20C): $ok_t  (0=读不到 4 字节：无 AER 能力或已被摘除，全 0 不可当'健康')"
dm=$(dmesg 2>/dev/null | grep -icE "can.t recover|link has been reset|device recovery failed" || true)
echo "  dmesg 失效链命中行 : $(num "$dm")（can't recover / link has been reset / recovery failed）"

fatal=$(( ues & usev )); sdes_sev=$(( (usev >> 5) & 1 )); sdes_sts=$(( (ues >> 5) & 1 ))
echo
echo "--- 判读 ---"
echo "  SDES=Fatal ⇒ 链路对端消失（Surprise Down），不是软件可修的错误；降级写只把该位由"
echo "  Fatal 改 Non-Fatal（0x00462030→0x00462010），用于让链路层走可恢复流程继续观测，"
echo "  不修复 PHY/对端。"
if [ "$ok_t" -ne 1 ]; then
    echo "AER 判读：目标设备扩展配置空间读不到 4 字节（0x204/0x20C）⇒ 无 AER 能力或已被摘除，不能用全 0 判'链路健康'；需先确认 BDF/是否已从 sysfs 消失"
elif [ "$(num "$dm")" -gt 0 ] && [ "$fatal" -ne 0 ]; then
    echo "AER 判读：Fatal + Root Port link reset + device recovery failed ⇒ 硬件/PHY 层失效，非软件可修"
elif [ "$sdes_sts" -eq 1 ] && [ "$sdes_sev" -eq 1 ]; then
    echo "AER 判读：SDES 状态=1 且 Severity=Fatal ⇒ Surprise Down 已发生（对端消失），硬件/PHY 层失效，非软件可修"
elif [ "$fatal" -ne 0 ]; then
    echo "AER 判读：存在 Fatal 未纠正错误但无 root port link reset/recovery failed ⇒ 需降级观测（AER_DEMOTE=1）复核后定性"
elif [ "$ces" -ne 0 ] || [ "$ues" -ne 0 ]; then
    echo "AER 判读：仅 Correctable/Non-Fatal 记录 ⇒ 链路劣化早期信号，可恢复，需持续观测（AER 计数增速）"
else
    echo "AER 判读：AER 状态寄存器全 0 ⇒ 当前无 AER 记录（链路健康或本次启动未触发）"
fi
echo "  建议：复现「芯片永久失效」时，先用本脚本（只读）留证，再决定是否 AER_DEMOTE=1 降级观测。"
REMOTE

cat "$OUT"
echo "== 输出已保存：$OUT（远程退出码 rc=$rc）=="
exit "$rc"
