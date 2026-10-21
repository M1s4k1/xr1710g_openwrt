#!/usr/bin/env bash
# check-upstream.sh — 基座（OpenWrt 主线）更新感知
#
# 架构转向后（2026-10-21）：基座 = OpenWrt 主线；本脚本回答：
#   ① 我们的 pin 落后主线多少？
#   ② 落后区间里有哪些**与本项目相关**的提交（focus 路径）？
#   ③ 上游是否有影响我们本地补丁的变动（补丁上下文漂移预警）？
#
# 用法：
#   scripts/check-upstream.sh            # 只读本地状态（pin、树 HEAD，不联网）
#   scripts/check-upstream.sh --fetch    # fetch openwrt 后对比 pin..origin/main
#   scripts/check-upstream.sh --focus    # 只列 focus 路径相关提交（需 --fetch）
#   scripts/check-upstream.sh --quiet    # 仅有更新时输出摘要（适合定时任务）
#
# 退出码：0=无更新或无相关更新；1=有相关更新；2=错误
set -uo pipefail
export LC_ALL=C LANG=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
get_lock() { grep -E "^$1=" "$ROOT/config/source-lock.env" | head -1 | cut -d= -f2- || true; }
OPENWRT_REF="$(get_lock OPENWRT_REF)"
[[ -n "$OPENWRT_REF" ]] || { echo "✗ source-lock.env 缺 OPENWRT_REF" >&2; exit 2; }

# focus 路径：与本项目相关的上游区域（与 config/upstream-sources.yml 的 openwrt 条目一致）
FOCUS=(target/linux/airoha target/linux/generic package/kernel/mt76 package/kernel/mac80211)

DO_FETCH=0; FOCUS_ONLY=0; QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fetch) DO_FETCH=1; shift ;;
    --focus) FOCUS_ONLY=1; shift ;;
    --quiet|-q) QUIET=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

echo "== 基座锁定 =="
echo "  pin: ${OPENWRT_REF:0:12}（$(get_lock LINUX_VERSION)）"

# ── 本地源码树状态（如有）──
for c in "$ROOT/../openwrt" "$ROOT/../../openwrt" "$ROOT/openwrt"; do
  if [[ -d "$c/.git" ]]; then
    h="$(git -C "$c" rev-parse HEAD 2>/dev/null)"
    if [[ "$h" == "$OPENWRT_REF" ]]; then echo "  本地树：$(cd "$c" && pwd) 在 pin ✓"
    else echo "  本地树：$(cd "$c" && pwd) HEAD=${h:0:12} ≠ pin（漂移）"; fi
    break
  fi
done

[[ "$DO_FETCH" == 1 ]] || { echo "（未 --fetch，仅本地状态。加 --fetch 联网对比主线）"; exit 0; }

# ── fetch 并对比 ───────────────────────────────────────────────────────
TREE=""
for c in "$ROOT/../openwrt" "$ROOT/../../openwrt" "$ROOT/openwrt"; do
  [[ -d "$c/.git" ]] && TREE="$(cd "$c" && pwd)" && break
done
[[ -n "$TREE" ]] || { echo "✗ 找不到本地 openwrt 树用于 fetch" >&2; exit 2; }
echo "== fetch openwrt（$TREE）=="
git -C "$TREE" fetch -q origin 2>/dev/null || { echo "✗ fetch 失败" >&2; exit 2; }
TIP="$(git -C "$TREE" rev-parse origin/main 2>/dev/null)" || { echo "✗ 无 origin/main" >&2; exit 2; }
if [[ "$TIP" == "$OPENWRT_REF" ]]; then
  echo "  pin 即主线 tip，无更新"
  exit 0
fi
TOTAL="$(git -C "$TREE" rev-list --count "$OPENWRT_REF..$TIP" 2>/dev/null || echo '?')"
echo "  pin → tip：${OPENWRT_REF:0:12} → ${TIP:0:12}，共 $TOTAL 个新提交"
if [[ "$FOCUS_ONLY" == 1 || "$QUIET" == 0 ]]; then
  echo "  focus 路径相关提交（${FOCUS[*]}）："
  n=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "      $line"; n=$((n+1))
    [[ $n -ge 30 ]] && { echo "      …（截断，共见上）"; break; }
  done < <(git -C "$TREE" log --oneline --no-merges "$OPENWRT_REF..$TIP" -- "${FOCUS[@]}" 2>/dev/null | head -30)
  [[ "$n" == 0 ]] && echo "      （无）"
fi
if [[ "$QUIET" == 1 ]]; then echo "总判定：基座有更新（$TOTAL 提交，focus 相关见完整模式）"; fi
echo "提示：focus 相关提交需逐条评审（doc/patch-review.md 流程）；pin 推进是显式决策。"
exit 1
