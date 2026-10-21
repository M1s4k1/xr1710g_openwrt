#!/usr/bin/env bash
# prepare-oc.sh — 对 openwrt 树应用/撤销 CPU 超频（确定性编辑，失败即报错）
# 用法：prepare-oc.sh <oc|stock> <openwrt树目录>
#   oc：OPP 500–1200MHz → 650–1350MHz（PLL base 650）——唯一 CPU 档
#       （2026-09-08 决策：取消 oc-1.3/oc-1.4 分档；1350 的稳性兜底不在构建侧，
#        由运行时 files/etc/init.d/oc-auto 承担：1350 不稳自动退档 1300，崩溃退档 1200）。
#   stock：撤销（git restore 涉及文件）。
# 前置依赖：cpufreq / PM domain 修复可用（patches/vendor/fanboy/03-cpufreq-pmdomain，
#           见 docs/FIXES.md #22029）——无修复时 OC 不稳定，本脚本会提示。
# 参考：OpenW1700k ubi2-oc commit 80096373b5（patches/specs/original-oc-80096373b5-6.12-reference.patch）
set -euo pipefail

TIER="${1:-oc}"
TREE="${2:-${OPENWRT_DIR:-}}"
[[ -n "$TREE" && -d "$TREE/.git" ]] || { echo "用法：prepare-oc.sh <oc|stock> <openwrt树目录>" >&2; exit 1; }

case "$TIER" in
  oc) BASE=650 ;;
  stock) ;;
  *) echo "错误：档位必须是 oc / stock" >&2; exit 1 ;;
esac

DTS="$TREE/target/linux/airoha/dts/an7581.dtsi"
CFG="$TREE/target/linux/airoha/an7581/config-6.18"

# 记录会被修改的文件（stock 时 git restore）
TOUCHED=()
touched() { TOUCHED+=("$1"); }

revert_stock() {
  echo "撤销 OC…"
  local f
  # 只恢复 tracked 文件；未跟踪的生成文件（如 apply-patches 展开的 patches-6.18/940-*.patch）
  # 由 build.sh 的 `git clean -fdq -- target package` 统一清理——这里删除会误删 stock 基线补丁本身。
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if (cd "$TREE" && git ls-files --error-unmatch -- "$f" >/dev/null 2>&1); then
      (cd "$TREE" && git restore -- "$f" && echo "restored $f") || echo "  跳过（无改动）：$f"
    else
      echo "  跳过未跟踪文件（留给 build.sh git clean）：$f"
    fi
  done < <(cd "$TREE" && { grep -rl -E 'freq_mhz = [0-9]+ \+ state \* 50' target/linux/airoha 2>/dev/null || true; printf '%s\n' target/linux/airoha/dts/an7581.dtsi target/linux/airoha/an7581/config-6.18; } | sort -u)
}

if [[ "$TIER" == "stock" ]]; then revert_stock; exit 0; fi

echo "== OC 唯一档（OPP base=$BASE MHz → 上限 1350MHz，稳性退档由 oc-auto 运行时兜底）=="
[[ -f "$DTS" ]] || { echo "错误：无 $DTS——#22397 板级补丁未应用？先跑 apply-patches.sh" >&2; exit 1; }
touched "$DTS"

# 1) OPP 表整体平移：hz + (BASE-500)*1e6；opp-<label> 同步改名（保留 { 花括号）
python3 - "$DTS" "$BASE" <<'PY'
import re, sys
path, base = sys.argv[1], int(sys.argv[2])
delta_mhz = base - 500
delta_hz = delta_mhz * 1000000
s = open(path, encoding="utf-8").read()
def shift_hz(m):
    hz = int(m.group(1)) + delta_hz
    return f"opp-hz = /bits/ 64 <{hz}>;"
def shift_label(m):
    hz = int(m.group(1)) + delta_hz
    return f"opp-{hz} {{"
n_hz = len(re.findall(r"opp-hz = /bits/ 64 <(\d+)>;", s))
s = re.sub(r"opp-hz = /bits/ 64 <(\d+)>;", shift_hz, s)
s = re.sub(r"\bopp-(\d+)\s*\{", shift_label, s)
open(path, "w", encoding="utf-8").write(s)
print(f"  dts OPP：平移 {n_hz} 个频率点 +{delta_mhz}MHz")
PY
touched "$DTS"

# 2) PM domain PLL 公式：freq_mhz = <old> + state * 50 → <BASE> + state * 50
#    断言式（2026-09-11 加固，范式取自 yahuisme/w1700k-openwrt）：
#      - 公式所在 patch 存在（vendor/fanboy/03 的 940-pmdomain-* 已随 apply-patches 落到树内）；
#      - 公式确实匹配预期基线模式。
#    旧版"找不到只告警"会让 OC 静默不完整（OPP 平移了、PLL 公式没跟上 → 频率语义错），
#    故此处改为硬失败（修复而不是降级）：patch 在、公式不在 = 上游/补丁结构变了，必须人工定位。
PLL_FOUND=0
PLL_PATCHES=$(grep -rl -E 'freq_mhz = [0-9]+ \+ state \* 50' "$TREE/target/linux/airoha" 2>/dev/null || true)
if [[ -n "$PLL_PATCHES" ]]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sed -i -E "s/freq_mhz = [0-9]+ \+ state \* 50/freq_mhz = $BASE + state * 50/" "$f"
    echo "  PLL 公式更新：$f（base=$BASE）"
    touched "$f"
    PLL_FOUND=$((PLL_FOUND+1))
  done <<< "$PLL_PATCHES"
else
  # 树内没有可改的公式：区分两种情况，避免误红也可避免静默
  PMDOMAIN_PATCH=$(find "$TREE/target/linux/airoha" -name '*pmdomain*' -type f 2>/dev/null | head -1)
  if [[ -n "$PMDOMAIN_PATCH" ]]; then
    echo "✗ 错误：找到 PM domain 补丁 $PMDOMAIN_PATCH，但其中没有预期的 'freq_mhz = <n> + state * 50'。" >&2
    echo "  含义：上游/该补丁的 PLL 频率基线结构已变化——OC 若继续会在频率语义错误下运行（危险）。" >&2
    echo "  处理（修复而非降级）：定位新的基线写法并同步为 $BASE + state * 50，然后更新本脚本的断言模式；" >&2
    echo "  参考基线：vendor/fanboy/03 的内层 940-pmdomain-airoha-Add-Airoha-CPU-PM-Domain-support.patch。" >&2
    exit 1
  fi
  echo "⚠ 树内没有 PM domain 补丁（target/linux/airoha 下无 *pmdomain*）：OC 前置补丁未应用。" >&2
  echo "  处理：先跑 scripts/apply-patches.sh <树>（MANIFEST 含 vendor/fanboy/03），再跑本脚本。" >&2
  exit 1
fi
[[ "$PLL_FOUND" -ge 1 ]] || { echo "✗ 错误：PLL 公式断言失败（未更新任何文件）" >&2; exit 1; }

# 3) 默认 governor → performance
if [[ -f "$CFG" ]]; then
  sed -i 's/^CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y$/# CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND is not set/; s/^# CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE is not set$/CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y/' "$CFG"
  echo "  governor 默认 → performance（$CFG）"
  touched "$CFG"
else
  echo "⚠ 无 $CFG——上游可能换配置文件名，请定位后补本步骤（见 FIXES.md OC 条目）。" >&2
fi

echo "---- 变更摘要："
(cd "$TREE" && git status --short -- "${TOUCHED[@]}" 2>/dev/null | sed 's/^/  /')
echo "完成。构建后请核对：cat /sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq（应为 1350000）"