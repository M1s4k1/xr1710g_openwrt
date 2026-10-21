#!/usr/bin/env bash
# audit-upstream-watch.sh — 上游基线守护（只读、确定性）
# 用法：audit-upstream-watch.sh <openwrt树目录> [--fail-on-drift]
#
# 背景（2026-09-11 深度调研，2026-09-12 扩面）：
# 本仓多个补丁的**内层补丁基线**是上游的具体文件，上游改动它们时**不会**让 dry-run 变红
# （拷贝类/内层补丁不在 dry-run 覆盖内），却会让补丁在**构建期**才失败。典型两类：
#   ① 上游改 `generic/pending-6.18/742|743`（realtek PHY）→ 本仓 9041/9033 需重基
#      （PR #25092 / #24887 都在改这两个 blob）
#   ② 上游往 generic 加 744/745 与私有驱动目录同址/同号 → 与 `vendor/fanboy/09` 携带的
#      私有 `rtl8261ce/` 驱动**功能重复**。
#      ⚠ 2026-09-12 更正（B3 实证）：#23644 同时落 **两处** ——`generic/hack-6.18/744|745`
#      **和** `generic/pending-6.18/743-01..04`；后者与既有 `743-net-phy-realtek-*` 同前缀，
#      且其 `743-03/04` 与 `743-net` 争改同一 `realtek_main.c` → 两组 glob 都要探。
#      （#25092 = 该系列的 25.12 backport 版；#24887 亦改 `pending-6.18/742|743`。）
#
# 本脚本用 **git blob SHA** 精确比对"本仓补丁所基于的上游文件版本"，并用**路径存在性探测**
# 发现"上游即将/已经引入同址文件"。比"等 dry-run 红"更早、比"人工比对"更确定。
#
# 报告分三类（含义不同，不可混为"漂移"）：
#   [基线]   基线 blob SHA 不一致 → 本仓对应补丁需重基
#   [冲突]   上游已出现与本仓新增文件同址/同前缀的文件 → 需人工判"去重/改号/删除本地"
#   [缺失]   基线路径在上游消失（改名/删除）→ 需重定位
#
# 行为：默认只报告（exit 0）；`--fail-on-drift` 时 缺失/冲突/漂移 任一即 exit 1（CI 用）。
#   例外（F151）：**远端来源 tip 前进不计入失败**——fork 分支 tip 前进是常态（来源对账是
#   择机事项，不影响构建），把它当硬失败会让守护步骤长期常红；而 CI 里守护步骤在 dry-run
#   之前，一旦它红，**真正能拦住补丁链的 dry-run 根本不会执行**。实证：2026-09-13
#   11:49Z 的定时运行（34755445119）就死在两个 fork tip 前进上，同一小时后上游合入
#   PR #24872 造成的 9042 同址冲突（182-v7.4-…patch 已上游自带）遂无人看见，直到手动构建
#   才红。故远端 tip 只报 ⚠（输出里保留 tip 记录/对账提示），不再左右退出码。
set -euo pipefail

TREE=""; FAIL_ON_DRIFT=0
for a in "$@"; do
  case "$a" in
    --fail-on-drift) FAIL_ON_DRIFT=1 ;;
    *) TREE="$a" ;;
  esac
done
[[ -n "$TREE" && -d "$TREE/.git" ]] || { echo "用法：audit-upstream-watch.sh <openwrt树目录> [--fail-on-drift]" >&2; exit 1; }

# 基线锚点：本表建立时所依据的上游 main。仅用于报告可读性（判断"是上游真改了还是基线该刷新"）。
BASELINE_UPSTREAM="7f4f824691fb2258afe9eb9a37da46d3557c4043"   # openwrt main @ 2026-09-15（P17/F171 刷新：0d7bfcb7e → 7f4f82469；8 个监视 blob 全未变，仅新增 hack-6.18/710 不涉监视面）
BASELINE_DATE="2026-09-15"
# 上游 bump 时**有意**更新上面两行 + 下表 SHA（生成方式：`git rev-parse HEAD:<path>`）。

# [基线] <blob-sha|-> <上游路径> <受影响的本仓补丁>
#   `-` = 该路径当前**不应存在**；一旦出现即视为上游已引入（等价 [冲突]）。
BASELINE=(
  "b7ace2329055f96346036579f329ef2f06dc19e4 target/linux/generic/pending-6.18/742-net-phy-realtek-add-5G-and-10G-PHY-support.patch    root/9041(内层742/743/744)、root/9033(LED hack)"
  "379da970e4c8b6c5329c9f0e1c8fe30ff9a784f3 target/linux/generic/pending-6.18/743-net-phy-realtek-reset-RTL8261N-USXGMII-SerDes-on-lin.patch  root/9041(内层742/743/744)"
  "b379ad09a5740990b3722cfbe6b20232db970767 package/kernel/mt76/Makefile    mt76 包补丁族（0001-0014/9990-9993）与 pin 跟踪"
  "a154aa9b7c8ecd6345476a0c08e11dcc44ec0b09 target/linux/airoha/an7581/config-6.18    root/9001、root/602-04 系列（airoha 目标 Kconfig/config 联动）"
  "efc1b44a58e61fe10891ea6fe604ac057706ce77  target/linux/airoha/image/an7581.mk    root/9001(DTS/image)、root/9000(device 段)、上游 #24926(DT overlay)"
  # F167（2026-09-14）：下面两条本不在监视面内，而 9000 的 platform.sh hunk 恰因上游
  #   `0d7bfcb7e（airoha: add support for Quantum Fiber Q1000K）`改动其上下文而**真冲突**——
  #   漂移守护没预警，是 dry-run 硬门才拦住的。凡被本仓补丁修改的 airoha base-files 文件都应登记。
  "d8cf5e2586159a2ea49381051c1abb1807dc36c1  target/linux/airoha/an7581/base-files/lib/upgrade/platform.sh    root/9000(platform_do_upgrade 的 board case)"
  "b0d0fd85907ba7e22593cf8eb60e00061809d0af  target/linux/airoha/an7581/base-files/etc/board.d/02_network    root/9000(an7581_setup_interfaces 的 board case)"
  "5db35c03e2d08d634eeebf963d2cbdc1dcde15b4 package/boot/uboot-airoha/Makefile    root/9002(U-Boot 锁版)、上游 #24926"
)

# [冲突] 路径存在性探测（glob）：上游一旦命中，说明与"本仓自带的新文件"同址/同前缀。
# 格式：<glob 模式> <本仓对应物> <处置提示>
COLLISION_PROBES=(
  "target/linux/generic/hack-6.18/744-*|vendor/fanboy/09(hack-6.18/999-net-phy-realtek-rtl8261ce.patch)|#23644 的 744 已进上游 → 与本地 999 同号同目录，需改号或删除本地"
  "target/linux/generic/hack-6.18/745-*|vendor/fanboy/09(hack-6.18/999-net-phy-realtek-rtl8261ce.patch)|#23644 的 745 已进上游 → 主线 realtek 驱动已含 RTL8261CE，进入'私有驱动去留'二选一"
  "target/linux/generic/pending-6.18/743-0*|root/9041(内层742/743/744)、vendor/fanboy/09|#23644 的 743-01..04(c45 soft_reset/master_slave + RTL8261C-CG) 已进上游"
  "target/linux/generic/pending-6.18/744-*|root/9041(内层742/743/744)、root/9033|#25092 的 744 已进上游"
  "target/linux/generic/pending-6.18/745-*|root/9041(内层742/743/744)、root/9033|#25092 的 745 已进上游"
  "target/linux/generic/files/drivers/net/phy/rtl8261ce/*|vendor/fanboy/09(私有 rtl8261ce/ 驱动 4 文件)|上游已占用 rtl8261ce/ 目录 → 本地私有驱动与主线重复"
  "target/linux/airoha/dts/*.dtso|root/9001(DTS)|上游 #24926 引入 DT overlay 设备树 → 复核 9001 的 DTS 引用方式"
)

# 上游 realtek 主驱动内是否出现 RTL8261CE 支持（文本级探测；#23644 的实质落点）
REALTEK_MAIN_PATCH="target/linux/generic/pending-6.18/742-net-phy-realtek-add-5G-and-10G-PHY-support.patch"
REALTEK_CE_MARKERS="RTL_8261CE|8261CE_REV_C|0x001cc899"

# ── 远端 tip 守护（2026-09-12 P3-F 新增）──────────────────────────────────
# 本仓补丁来源是多个 fork 分支（不只上游 main），分支 tip 变化时需重新对账"已覆盖/新增"。
# 格式：<记录 tip|-> <仓库 URL> <ref> <用途/监视理由>
# 行为：默认联网探测；**离线/超时则跳过不计**（`ⓘ`）；tip 变化计为 drift（`--fail-on-drift` 时 exit 1）。
# 记录 tip 取自 2026-09-12（P3/P4 handoff 的对账快照）。
REMOTE_TIPS=(
  "c82129e734|https://github.com/YYH2913/openwrt.git|refs/heads/xr1710g-6.18-integration|YYH 补丁集真源（P3 对账对象；suntyrael 只是其重传载体）"
  "2dd6e4c8|https://github.com/YYH2913/mt76.git|HEAD|YYH mt76 分支（MTK/YYH 专有 mt76 补丁的来源）"
  "53b73174c|https://github.com/YYH2913/http-uboot.git|HEAD|U-Boot 锁版参考（FLASHING 升级前核对）"
  "ca46e0a4e|https://github.com/OpenWRT-fanboy/OpenW1700k.git|refs/heads/ubi2-oc|vendor/fanboy/01..21 原料桶（F154 对账第三次 force-push 49d20d02e；F157 重锚 ac975aa94 并按最后一次变更 9604ab5a 重取 05；F168 复核 ac975aa94→37aa0bcd3b：22 个自有提交 patch-id 全等 = 纯重基；**F174/P23 复核 37aa0bcd3b→ca46e0a4e**：又是 force-push 重基（compare=diverged，新线自有 54 提交/238 文件），21 份原料**逐一按内容不按 SHA**核对 ⇒ **20 份零变化**（01/02/03/06/09/10/11/12/14/15/17/20/21 本仓文件 patch-id 与新线提交全等；04/05/08/18/19 本仓含本地编辑故 patch-id 不等，但 API 逐文件比对证明 fanboy 新旧提交内容**完全一致**——08 仅少一个文件 wifi-scripts/…/mac80211.sh）⇒ **无重取**；**07（mt76 HW_RRO release）在新线消失**（无同 subject 提交、其 in-tree package/kernel/mt76/patches/0014-… 亦不在新 tip）⇒ **待评估**（本仓材料仍自洽：dry-run 全绿、目标 mt76 源 pin 无该修复）；**观察项**：13 的 package/kernel/mt76/Makefile（mt76 源 pin）与 16 的 wifi-scripts/…/mac80211.sh 确有真内容变化（本仓 13 未采用、16 已自行重 diff 为 root/9010）；**F175/P24 收口**：07 在当前 ubi2-oc 缺席 = 重基线未搬回（**非上游已修**：新线 mt76 pin 与本仓同一提交 01367e60，且该 pin 的 mt7996/mcu.c 与 openwrt/mt76 master 逐字节相同，均无 rro_id、无 BA teardown 释放、无亚 64 guard；**非弃用**：ubi2-oc-archive-260830 的 tree 仍带 0014-…release-HW_RRO-sessions-on-teardown.patch，且与本仓 07 内层补丁逐行等同；**非换法**：当前线 5 份 patch 无等价物、07 的 patch-id 零命中）⇒ 本仓**保留 default 档 07**（stock 档唯一 RRO 缓解），删除门槛见 F175 行；另注：compare/behind_by 对 force-push 孤儿不可判祖先（自证 15 料=15、21 料=245），判「料是否还在某条线」只能查 tree/contents + patch-id；**F176/P25 评估 archive-260818 的 0015-…avoid-stale-npu-wcid-reuse**：与 07 机制不同路（0015 在 wcid 分配器/WTBL 生命周期面，不重写 07 的 RX_STOP 分支、不动 hwrro/ba_rdd_rro），两料对 pin 01367e60 单跑均干净、但双跑**上下文耦合必冲突**（正反序同），'--fuzz=3' 双应用成功且两处防复用点并存 ⇒ **互补不替代**（详见 F176 行）；因假设依赖未公开 NPU 固件内部状态、副作用面不可控 ⇒ **本仓不吸收**、07 保持 default、不新增 0015）"
  "38806db2d|https://github.com/Gilly1970/Gemtek-W1700K-6.18.git|HEAD|Gilly openwrt-patches/（F90/F101 对账源；a57615652=Bump Kernel-6.18.51 and rebase + 新补丁 048，048 已吸收为 mt76-0022/F153；F171/P17 复核 a57615652→3d4ff76d3：快进 1 提交「Bump Kernel-6.18.52 and rebase」，960/961/982 三个 patch 从 openwrt-patches/ **移除**（随 6.18.52 上游化），本仓 9045 内层 960/961、9042 内层 982 因 pin 仍 6.18.44 不受影响（内核 bump ≥6.18.52 时须删这三份内层）⇒ 无 Gilly 来料重取；**F176/P25 初判 → F178/P26 完整对账**：tip 又前进 '3d4ff76d3→38806db2d'（「Update Kernel-6.18.52 SSH and rebase」，+2 文件 'openwrt-patches/985-PCI-mediatek-gen3-request-port-IRQ-for-affinity-control.patch'（端口 IRQ 取代 chained handler ⇒ 可调 smp_affinity；**pin/上游 master 仍是 chained+NO_AFFINITY**，本仓不携带该文件）与 'netifd-hotplug-20-packet-steering'（Wi-Fi 接口 'add' 后重跑 packet_steering）；另 'Openwrt_Gemtek_w1700k.sh' ±1 行 + 一个 itb 产物；目录 81 份新增 2 删 0；同目录 '033-…release-hwrro-sessions-on-teardown' 经逐 op 比对 = 本仓 07 的逐行等同体、'037-…fix-hwrro-delete-event-struct-size' 的 4 字节布局修正 pin 已有 ⇒ **均非新料**。**F178/P26 完整对账（逐 blob sha 核 81 份）：79 份零变化、+2 新料（985 PCIe 端口 IRQ 亲和性 / netifd-hotplug-20-packet-steering）经设备实测：985 判不吸收（CPU0 无饱和症状）、netifd-hotplug-20-packet-steering 初判被推翻改暂缓（netdev 重建后 rps_cpus 真会漂回 0 且不自愈，见 F178）⇒ 锚点重锚 38806db2d；'033' hunk 体逐行等同本仓 07、'037' 的 4 字节修正 pin 已有 ⇒ 均非新料**）"
  "5a71e6a53|https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G.git|HEAD|naoki66 分支（411/628/622/743/744/mt76-0010/0012 来源；F168 复核 38148509→bb34bbe6e：快进 19 提交/29 文件，全为自有 LuCI 应用 + 自有内核补丁副本 + config.seed，本仓所取的 622/625/743/744 源文件未变且仍在 ⇒ 无重取；F171/P17 复核 bb34bbe6e→c31b73423：快进 1 提交/4 文件（仅 package/luci-app-mesh-conf，本仓不携带）⇒ 无重取；**F174/P23 复核 c31b73423→5a71e6a53**：快进 10 提交/37 文件，全为自有 LuCI 应用（mesh-conf/mlo/netmode）+ feed 补丁脚本（scripts/apply-feed-patches.sh 等）+ airoha board.d/02_network 与 uci-defaults/22_airoha-network-migrate-v4（本仓均不携带）；本仓实取的 7 个文件 blob 在两侧全等且仍在（mac80211 subsys-411、622/625/628/743/744）、mt76-0012 源提交 2d3aa30 仍是新 tip 祖先、luci-app-airoha-recovery（F12 来源）未被触碰 ⇒ **无重取**）"
  "73c3ab308|https://github.com/hurryman2212/OpenW1700k-test.git|refs/heads/offload-oc|SOE/xfrm/EIP93 来源（F115/F122）"
)
REMOTE_TIMEOUT="${AUDIT_REMOTE_TIMEOUT:-20}"

rskip=0
remote_report() {
  echo
echo "-- 远端来源 tip 守护（分支 tip 变化 → 需重新对账）--"
  local row want rest url rest2 ref note live
  for row in "${REMOTE_TIPS[@]}"; do
    want="${row%%|*}"; rest="${row#*|}"
    url="${rest%%|*}"; rest2="${rest#*|}"
    ref="${rest2%%|*}"; note="${rest2#*|}"
    if ! command -v timeout >/dev/null 2>&1; then rskip=$((rskip+1)); continue; fi
    live=$(timeout "$REMOTE_TIMEOUT" git ls-remote "$url" "$ref" 2>/dev/null | awk 'NR==1{print $1}') || live=""
    if [[ -z "$live" ]]; then
      echo "  ⓘ [远端] 未检查（离线/超时）：$(basename "$url") $ref"
      rskip=$((rskip+1)); continue
    fi
    if [[ "$want" == "-" ]]; then
      echo "  · [远端] $(basename "$url") $ref = ${live:0:9}（记录 tip 未固定）"
    elif [[ "$live" == "$want"* ]]; then
      echo "  ✓ [远端] 未变：$(basename "$url") $ref = ${live:0:9}"
    else
      echo "  ⚠ [远端] tip 前进：$(basename "$url") $ref"
      echo "      记录 $want"
      echo "      实际 ${live:0:9}"
      echo "      → 需重新对账（非失败项，F151）：$note"
      rdrift=$((rdrift+1))
    fi
  done
}

drift=0; miss=0; collide=0; rdrift=0; samefile=0
# 取上游"提交"与"工作区"两个视图：
#   · 提交视图（ls-tree）用于 CI 的干净检出 + 本仓 overlay 场景
#   · 工作区视图（ls-files --cached --others）用于本地树/被 rsync 修改过的树
# 两者取并集，避免"文件在磁盘上但未提交"被误判为未出现。
UPSTREAM_HEAD=$( (cd "$TREE" && git rev-parse HEAD 2>/dev/null) || echo UNKNOWN )
PATH_LIST=$(
  {
    (cd "$TREE" && git ls-tree -r --name-only HEAD 2>/dev/null) || true
    (cd "$TREE" && git ls-files --cached --others --exclude-standard 2>/dev/null) || true
  } | sort -u
)

echo "== 上游基线守护（blob SHA 精确比对 + 同址冲突探测）=="
echo "   上游 HEAD   : ${UPSTREAM_HEAD:0:9}"
echo "   基线锚点    : ${BASELINE_UPSTREAM:0:9}（${BASELINE_DATE} 建立）"
if [[ "$UPSTREAM_HEAD" != "$BASELINE_UPSTREAM" ]]; then
  echo "   ⓘ 上游已前进（${BASELINE_UPSTREAM:0:9} → ${UPSTREAM_HEAD:0:9}）：若下方全 ✓，说明本次前进未触碰被监视面，基线可择机刷新"
fi
echo

for row in "${BASELINE[@]}"; do
  want=$(echo "$row" | awk '{print $1}')
  path=$(echo "$row" | awk '{print $2}')
  who=$(echo "$row" | awk '{print $3}')
  # 注意：必须**先判存在性**。在已删除（但可能仍被引用）的工作区文件上，
  # `git rev-parse HEAD:<path>` 仍会返回 blob 而不报错 → 会把"文件不在树上"误判为"未变"。
  if [[ ! -e "$TREE/$path" ]]; then
    ref="MISSING"; got="MISSING"
  else
    ref=$( (cd "$TREE" && git rev-parse "HEAD:$path" 2>/dev/null) || echo MISSING )
    # 工作区优先：文件在磁盘上被改动（含本仓 overlay rsync 覆盖）时以磁盘内容为准，
    # 否则"改了文件但没 git add"会被漏报为未漂移。
    got=$( (cd "$TREE" && git hash-object -- "$path" 2>/dev/null) || echo MISSING )
  fi
  if [[ "$want" == "-" ]]; then
    if [[ "$got" != "MISSING" && "$ref" != "MISSING" ]]; then
      echo "  ⚠ [冲突] 上游已出现：$path（受影响：$who）"
      collide=$((collide+1))
    else
      echo "  ✓ [基线] 未出现（预期）：$path"
    fi
  elif [[ "$got" == "MISSING" || "$ref" == "MISSING" ]]; then
    # 区分两件事：
    #   · HEAD 里也没有 → 上游真的删了/改名了（需重定位，硬失败）
    #   · HEAD 里有、只是磁盘没有 → 本仓 overlay 未落位 / 树上缺文件（同样要处理）
    echo "  ✗ [缺失] $path（HEAD=${ref:0:9}，工作区=缺失：上游删除/改名，或本仓 overlay 未落位。受影响：$who）" >&2
    miss=$((miss+1))
  elif [[ "$got" != "$want" ]]; then
    echo "  ⚠ [基线] 漂移：$path"
    echo "      期望 $want"
    echo "      实际 $got"
    echo "      → 受影响补丁需重基：$who"
    drift=$((drift+1))
  else
    echo "  ✓ [基线] 未变：$path"
  fi
done

echo
echo "-- 同址冲突探测（上游是否已引入与本仓自带新文件重复的东西）--"
for row in "${COLLISION_PROBES[@]}"; do
  pat="${row%%|*}"; rest="${row#*|}"; who="${rest%%|*}"; hint="${rest#*|}"
  hits=$(printf '%s\n' "$PATH_LIST" | grep -E "$(printf '%s' "$pat" | sed 's/[.[\*^$]/\\&/g; s/\\\*/.*/g')" || true)
  if [[ -n "$hits" ]]; then
    echo "  ⚠ [冲突] 上游命中 $pat"
    echo "$hits" | sed 's/^/        /'
    echo "      本仓对应物：$who"
    echo "      处置：$hint"
    collide=$((collide+1))
  else
    echo "  ✓ [冲突] 上游未出现：$pat"
  fi
done

# ── 本仓新增文件 × 上游同址探测（自动生成，F151）──────────────────────────
# 9042 实证：上游合入 PR #24872 后自带 target/linux/airoha/patches-6.18/182-v7.4-…patch，
# 与本仓 9042 内嵌的新文件同址 → 补丁链在 9042 处 `already exists in working directory` 断链。
# 该类的另一面更隐蔽：拷贝类条目（`<src> <dest>/`）用 `cp -f` 落位，上游同名文件被**静默覆盖**，
# 只有语义重复、不报错。此处不手写清单——直接扫 MANIFEST 全部启用条目的 `new file mode`
# 段并取其 `+++ b/<path>`，逐一比对上游树，命中即报 [冲突]（硬失败）。
echo
echo "-- 本仓新增文件 × 上游同址探测（自动扫描 MANIFEST 的 new file mode 段）--"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
newfile_hits=0; newfile_scanned=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  [[ -z "$line" ]] && continue
  line="${line#"${line%%[![:space:]]*}"}"           # ltrim
  [[ "${line:0:4}" == "#OC " ]] && line="${line:4}"
  [[ "${line:0:5}" == "#EXP " ]] && line="${line:5}"
  [[ "${line:0:1}" == "#" ]] && continue
  src="${line%%[[:space:]]*}"
  pf="$ROOT_DIR/$src"
  [[ -f "$pf" ]] || continue
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    newfile_scanned=$((newfile_scanned+1))
    if [[ -e "$TREE/$path" ]]; then
      echo "  ⚠ [冲突] 上游已有同名文件：$path"
      echo "      本仓新增者：$src"
      echo "      处置：判'删除本地/改号/改为修改型 hunk'——同址新增必然断链或静默覆盖"
      newfile_hits=$((newfile_hits+1)); collide=$((collide+1))
    fi
  done < <(awk '/^new file mode/{f=1;next} f&&/^\+\+\+ /{sub(/^\+\+\+ b\//,"");print;f=0} /^diff --git/{f=0}' "$pf")
done < "$ROOT_DIR/patches/MANIFEST"
(( newfile_hits == 0 )) && echo "  ✓ [冲突] 扫描 $newfile_scanned 个新增文件：上游均无同址"
samefile=$newfile_hits

# 文本级：主线 realtek 驱动是否已含 RTL8261CE（#23644 实质）
echo
echo "-- 主线 realtek 驱动 CE 支持探测（文本级）--"
if [[ -f "$TREE/$REALTEK_MAIN_PATCH" ]]; then
  # 工作区优先（overlay/本地树内容可能已被改动）
  if grep -qE "$REALTEK_CE_MARKERS" "$TREE/$REALTEK_MAIN_PATCH" 2>/dev/null; then
    echo "  ⚠ [冲突] $REALTEK_MAIN_PATCH 已含 RTL8261CE 标记（$REALTEK_CE_MARKERS）"
    echo "      → 主线已覆盖 RTL8261CE；本仓 vendor/fanboy/09 私有 rtl8261ce/ 驱动进入去留决策"
    echo "      → 参考：本机 10G PHY 实测 c45 0x001ccaf3 = RTL_8261N，主线 742 已支持（rtl8261be/n match）"
    collide=$((collide+1))
  else
    echo "  ✓ [冲突] $REALTEK_MAIN_PATCH 尚不含 RTL8261CE 标记"
  fi
else
  echo "  ⓘ [基线] $REALTEK_MAIN_PATCH 不在上游（已被上游改写/合并？）"
fi

remote_report

echo "----"
echo "汇总：基线漂移 $drift，路径缺失 $miss，同址冲突 $collide（含新增文件同址 $samefile），远端 tip 前进 $rdrift（不计失败），远端跳过 $rskip（基线锚点 ${BASELINE_UPSTREAM:0:9}）"
if (( miss > 0 || collide > 0 || (FAIL_ON_DRIFT && drift > 0) )); then
  echo "处理（修复而非降级）：" >&2
  echo "  · 基线漂移 → 按 docs/absorptions/ 最新吸收计划重基本仓补丁" >&2
  echo "  · 同址冲突 → 进入'去重/改号/删除本地'判据（RTL8261CE 见 2026-09-12 调研报告 §五）" >&2
  echo "  · 复跑验证：./scripts/apply-patches.sh . --dry-run --oc --experimental" >&2
  exit 1
fi
(( rdrift > 0 )) && echo "ⓘ 远端 tip 前进 $rdrift 处：择机对账来源（不阻塞构建，F151）"
exit 0
