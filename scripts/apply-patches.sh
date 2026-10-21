#!/usr/bin/env bash
# apply-patches.sh — 把本项目本地补丁集应用到一棵 pinned OpenWrt 源码树
#
# 架构背景（2026-10-21 转向）：本仓库不再基于 genshanxinli/xr1710g-openwrt aggregate，
# 改为以 OpenWrt 主线（config/source-lock.env 的 OPENWRT_REF）为基座；
# 本项目的一切定制 = local/patches/ 下的补丁集（按文件名字典序应用）。
#
# 用法：
#   scripts/apply-patches.sh --tree <dir> [--tier func|v1-safe] [--dry-run] [--allow-drift]
#
# 行为：
#   1) 校验源码树 HEAD == source-lock.env 的 OPENWRT_REF（不一致即退出；--allow-drift 放行）
#   2) 按档位收录清单（local/manifest.rules 或 .v1-safe）取补丁列表
#   3) 按文件名字典序逐个 git apply（任一失败即停止，报告已应用/待应用）
#   4) --dry-run 只做 --check，不落盘
#
# 退出码：0=全部应用成功；1=有补丁应用失败；2=用法/前置校验错误
set -euo pipefail
export LC_ALL=C LANG=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/config/source-lock.env"

# ── 读取锁（只取受控键，不 source 外部文本）──
get_lock() { grep -E "^$1=" "$LOCK" | head -1 | cut -d= -f2- || true; }
OPENWRT_REF="$(get_lock OPENWRT_REF)"
[[ -n "$OPENWRT_REF" ]] || { echo "✗ source-lock.env 缺 OPENWRT_REF" >&2; exit 2; }

TREE=""; TIER="func"; DRY=0; ALLOW_DRIFT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree) TREE="$2"; shift 2 ;;
    --tier) TIER="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --allow-drift) ALLOW_DRIFT=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$TREE" && -d "$TREE/.git" ]] || { echo "✗ --tree 不是 git 仓库：$TREE" >&2; exit 2; }
TREE="$(cd "$TREE" && pwd)"

# ── 1) pin 校验 ────────────────────────────────────────────────────────
HEAD_SHA="$(git -C "$TREE" rev-parse HEAD)"
if [[ "$HEAD_SHA" != "$OPENWRT_REF" ]]; then
  if [[ "$ALLOW_DRIFT" == 1 ]]; then
    echo "⚠ 树 HEAD ($HEAD_SHA) != pin ($OPENWRT_REF)——--allow-drift 放行" >&2
  else
    echo "✗ 树 HEAD ($HEAD_SHA) != pin ($OPENWRT_REF)。" >&2
    echo "  请 checkout 到 pin，或显式 --allow-drift（后果自负：补丁上下文可能不匹配）。" >&2
    exit 2
  fi
fi

# ── 2) 取档位清单 ──────────────────────────────────────────────────────
case "$TIER" in
  func)    LIST="$ROOT/local/manifest.rules" ;;
  v1-safe) LIST="$ROOT/local/manifest.rules.v1-safe" ;;
  *) echo "✗ --tier ∈ func|v1-safe" >&2; exit 2 ;;
esac
[[ -f "$LIST" ]] || { echo "✗ 找不到清单：$LIST" >&2; exit 2; }

# 清单行两种形态：
#   <file>.patch                    # git apply 到树
#   <file>.patch -> <target-dir>    # 复制到树的 <target-dir>/（OpenWrt 包补丁机制：
#                                   包源码 patch，如 package/kernel/mt76/patches/）
# ⚠ macOS bash 3.2 无 mapfile——用 while-read（本项目血泪教训，见 macos-bash-portability）
PATCHES=()
while IFS= read -r entry; do [[ -n "$entry" ]] && PATCHES+=("$entry"); done < <(
  grep -vE '^\s*#|^\s*$' "$LIST" | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//')
[[ ${#PATCHES[@]} -gt 0 ]] || { echo "✗ 清单为空：$LIST" >&2; exit 2; }
echo "档位 $TIER：${#PATCHES[@]} 个补丁（$(basename "$LIST")）"

# ── 3) 按序应用 ────────────────────────────────────────────────────────
# dry-run 语义：补丁间有依赖（如 9501 需 9402 先建 DTS），逐补丁 --check 会假红。
#   正确做法 = 在临时 git worktree（共享对象库，几秒建成）里真顺序应用，主树零接触。
applied=0
CHECK_TREE="$TREE"
CLEANUP_WT=""
if [[ "$DRY" == 1 ]]; then
  CHECK_TREE="$(mktemp -d)/apply-check"
  git -C "$TREE" worktree add -q --detach "$CHECK_TREE" HEAD 2>/dev/null || {
    echo "✗ 无法创建临时 worktree（dry-run 中止）" >&2; exit 2; }
  CLEANUP_WT="$CHECK_TREE"
fi
_cleanup() {
  [[ -n "$CLEANUP_WT" ]] && git -C "$TREE" worktree remove --force "$CLEANUP_WT" 2>/dev/null
  [[ -n "$CLEANUP_WT" ]] && rm -rf "$(dirname "$CLEANUP_WT")" 2>/dev/null
  return 0
}
trap _cleanup EXIT
for entry in "${PATCHES[@]}"; do
  if [[ "$entry" == *" -> "* ]]; then
    p="${entry%% -> *}"; dest="${entry#* -> }"
    f="$ROOT/local/patches/$p"
    [[ -f "$f" ]] || { echo "✗ 补丁不存在：$f" >&2; exit 1; }
    if [[ "$DRY" == 1 ]]; then
      echo "  [dry-run ✓] $p -> $dest（复制型）"
    else
      mkdir -p "$CHECK_TREE/$dest"
      cp -f "$f" "$CHECK_TREE/$dest/"
      echo "  [✓ copy] $p -> $dest/"; applied=$((applied+1))
    fi
    continue
  fi
  p="$entry"
  f="$ROOT/local/patches/$p"
  [[ -f "$f" ]] || { echo "✗ 补丁不存在：$f" >&2; exit 1; }
  # dry-run 在临时 worktree 里**真应用**（补丁有依赖，只 --check 会假红）；
  # 主树零接触，worktree 退出即焚。
  if git -C "$CHECK_TREE" apply "$f" 2>/tmp/apply-err.$$; then
    echo "  [✓] $p"; applied=$((applied+1))
  else
    echo "  [✗] $p 应用失败："; grep -v 'trailing whitespace\|^There are' /tmp/apply-err.$$ | head -5 >&2
    rm -f /tmp/apply-err.$$
    if [[ "$DRY" == 1 ]]; then
      echo "dry-run 失败于 $p（主树未动；共验 $applied 个）" >&2
    else
      echo "已应用 $applied 个后停止。回滚：cd $TREE && git reset --hard && git clean -fdx" >&2
    fi
    exit 1
  fi
done
rm -f /tmp/apply-err.$$
if [[ "$DRY" == 1 ]]; then
  echo "dry-run 完成：全部 $applied 个可顺序应用（临时 worktree 已验证，主树未动）"
else
  echo "完成：$applied 个补丁已应用到 $TREE"
fi
