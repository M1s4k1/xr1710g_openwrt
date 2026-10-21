#!/usr/bin/env bash
# build-mine.sh — 构建本仓库固件（OpenWrt 主线为基座 + 本地补丁集）
#
# 架构（2026-10-21 转向后）：
#   1) apply-patches.sh：校验树在 pin（OPENWRT_REF）→ 按档位应用 local/patches/
#   2) feeds：官方默认 + 本仓库自定义（config/feeds.custom.conf）
#   3) 配置：make defconfig → 追加 local/seed.local.diff → make defconfig → 符号审计
#   4) make 构建，产物在源码树 bin/targets/airoha/an7581/*.itb
#
# 用法：
#   scripts/build-mine.sh [func|v1-safe] [--jobs N] [--tree DIR]
#                         [--apply-only] [--dry-run] [--allow-drift]
#
# 档位：func = 正式档（当前与 v1-safe 同集；Phase 2 起追加 NPU 栈）；
#       v1-safe = 保守档（首次刷机建议）。
#
# ⚠ 必须提供 OpenWrt 源码树（--tree / OPENWRT_DIR / 自动探测 ../openwrt 等），
#   树须含 .git 与 scripts/feeds；构建前会对树 git reset --hard + clean（见下）。
set -euo pipefail
export LC_ALL=C LANG=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
get_lock() { grep -E "^$1=" "$ROOT/config/source-lock.env" | head -1 | cut -d= -f2- || true; }
OPENWRT_REF="$(get_lock OPENWRT_REF)"
LINUX_VER="$(get_lock LINUX_VERSION)"

TIER="func"; JOBS=""; TREE="${OPENWRT_DIR:-${TREE:-}}"
APPLY_ONLY=0; DRY_RUN=0; ALLOW_DRIFT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    func|v1-safe) TIER="$1"; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --tree) TREE="$2"; shift 2 ;;
    --apply-only) APPLY_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-drift) ALLOW_DRIFT=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

echo "########################################################"
echo "# build-mine  tier=$TIER  pin=${OPENWRT_REF:0:12}  kernel=$LINUX_VER"
echo "########################################################"

# ── 定位源码树 ────────────────────────────────────────────────────────
if [[ -z "$TREE" ]]; then
  for c in "$ROOT/../openwrt" "$ROOT/../../openwrt" "$ROOT/openwrt" "$ROOT/../source_openwrt/openwrt"; do
    [[ -d "$c/.git" && -f "$c/scripts/feeds" ]] && TREE="$c" && break
  done
fi
[[ -n "$TREE" && -d "$TREE/.git" && -f "$TREE/scripts/feeds" ]] || {
  echo "FATAL: 未找到合法 OpenWrt 源码树（需 .git + scripts/feeds）。" >&2
  echo "  用 --tree <路径> 指定；建议 clone 后 checkout 到 pin $OPENWRT_REF。" >&2
  exit 2; }
TREE="$(cd "$TREE" && pwd)"
echo "  源码树：$TREE（HEAD $(git -C "$TREE" rev-parse --short HEAD)）"

# ── 树复位警告（apply-patches 的 git apply 是一次性语义）──
if [[ -n "$(git -C "$TREE" status --porcelain 2>/dev/null)" ]]; then
  echo "  ⚠ 源码树有未提交改动——补丁应用前需 git reset --hard + clean -fdx（会丢失）。" >&2
  git -C "$TREE" status --short | head -5 | sed 's/^/      /' >&2
  echo "      确认无需保留则继续；本脚本现在执行复位。"
fi
git -C "$TREE" reset --hard -q HEAD
git -C "$TREE" clean -fdxq

# ── 1) 应用本地补丁集 ─────────────────────────────────────────────────
APARGS=(--tree "$TREE" --tier "$TIER")
[[ "$ALLOW_DRIFT" == 1 ]] && APARGS+=(--allow-drift)
[[ "$DRY_RUN" == 1 ]] && APARGS+=(--dry-run)
"$ROOT/scripts/apply-patches.sh" "${APARGS[@]}"
[[ "$APPLY_ONLY" == 1 ]] && { echo "--apply-only 模式，停止。"; exit 0; }
[[ "$DRY_RUN" == 1 ]] && { echo "--dry-run 到此为止，未真正构建。"; exit 0; }

cd "$TREE"

# ── 2) feeds ──────────────────────────────────────────────────────────
cp -f feeds.conf.default feeds.conf
cat "$ROOT/config/feeds.custom.conf" >> feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a

# ── 3) 配置 + seed + 符号审计 ─────────────────────────────────────────
[[ -f .config ]] || make defconfig
# 保证前一段以换行结尾，避免两段 seed 粘连
[[ -n "$(tail -c1 .config 2>/dev/null)" ]] && printf '\n' >> .config
cat "$ROOT/local/seed.local.diff" >> .config
make defconfig

# 3.1) 内核版本门禁（补丁集锁定 LINUX_VERSION）
if [[ -f target/linux/generic/kernel-6.18 ]]; then
  if grep -q "LINUX_VERSION-6.18.*=.*\.${LINUX_VER#6.18.}" target/linux/generic/kernel-6.18 2>/dev/null; then
    echo "  ✓ 内核版本 Linux $LINUX_VER"
  else
    echo "✗ 内核版本非 $LINUX_VER——补丁上下文可能不匹配，终止。" >&2
    grep 'LINUX_VERSION-6.18' target/linux/generic/kernel-6.18 >&2 || true
    exit 1
  fi
fi
# 3.2) 目标选中 + seed 符号逐一进 .config（F15 教训：kconfig 静默忽略未知符号）
grep -q "CONFIG_TARGET_airoha_an7581_DEVICE_gemtek_xr1710g-ubi=y" .config \
  && echo "  ✓ XR1710G 目标已选中" \
  || { echo "✗ .config 未选中 gemtek_xr1710g-ubi" >&2; exit 1; }
missing=0
while IFS= read -r sym; do
  grep -q "^${sym}=y$" .config || { echo "  ✗ seed 符号未进 .config：$sym"; missing=1; }
done < <(grep -E '^CONFIG_[A-Za-z0-9_]+=y$' "$ROOT/local/seed.local.diff" | cut -d= -f1)
[[ "$missing" == 0 ]] && echo "  ✓ seed 符号全部进 .config" || { echo "✗ 有 seed 符号丢失（见上）" >&2; exit 1; }

# ── 4) 构建 ───────────────────────────────────────────────────────────
[[ -n "$JOBS" ]] || JOBS="$(nproc 2>/dev/null || echo 4)"
make -j"$JOBS" V=s CONFIG_VERSION_DIST="OpenWrt $TIER" 2>&1 | tee "$ROOT/build-$TIER.log"
if ! ls bin/targets/airoha/an7581/*.itb >/dev/null 2>&1; then
  echo "错误：构建完成但未找到 .itb 产物" >&2; exit 1
fi
echo "产物（源码树内）："
ls -la bin/targets/airoha/an7581/*.itb
