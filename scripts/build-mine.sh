#!/usr/bin/env bash
# build-mine.sh — 构建本仓库固件（stage + 调上游 build.sh）
#
# 流程：先跑 stage.sh 合成 .stage/，再在上游 build.sh 的语义下构建。
#       上游 build.sh 是「树内构建」：build.sh <stock|experimental> [树目录]
#
# 用法：
#   scripts/build-mine.sh [stock|experimental|v1-safe] [--jobs N]
#                         [--stage-only] [--dry-run] [--disable-oc 0|1]
#
# 档位说明：
#   stock        = 正式 func 选择集（103 条活动：上游提档 40 + 本地 9501/9601/9602）
#   v1-safe      = 保守档（63 条活动：上游 default 原样 + 本地 9501/9601/9602，不提档）
#                  ——**建议首次刷机用这个**
#   experimental = 上游实验档语义（本仓库提档后 experimental 为空 ⇒ 等价 stock）
#
#   活动数以 `stage.sh --tier <tier>` 的实际输出为准（随 rules 增删而变，此处仅作速查）。
#
# ⚠ 必须提供 OpenWrt **源码树**（本仓库与上游都只是"叠加层"，不是源码树）：
#   --tree DIR   /  $OPENWRT_DIR  /  自动探测（如 ../openwrt、../source_openwrt/openwrt 等）
#   源码树必须含 .git 与 scripts/feeds（build.sh 第 25 行硬校验）。
#
# 产物：<源码树>/bin/targets/airoha/an7581/*.itb（**不在 .stage/ 下**，见文末提示）
set -euo pipefail

# ⚠ 必须 C locale：上游脚本有 41 处「$VAR 紧跟全角标点」的写法（如 build.sh 的
#   `echo "... （$TIER）"`）。在 UTF-8 locale 下 bash 会把多字节字符并入变量名，
#   即使变量已定义也报 `<VAR>ï¿½: unbound variable` 并退出（实测：LC_ALL=C 正常，
#   C.UTF-8 必崩）。上游 CI 跑在 C locale 所以从未暴露。导出 C locale 可一次性规避全部。
export LC_ALL=C
export LANG=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TIER_ARG="stock"
JOBS="${JOBS:-}"
STAGE_ONLY=0
DRY_RUN=0
DISABLE_OC="${DISABLE_OC:-1}"
TREE="${OPENWRT_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    stock|experimental|v1-safe) TIER_ARG="$1"; shift ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --tree) TREE="$2"; shift 2 ;;
    --stage-only) STAGE_ONLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --disable-oc) DISABLE_OC="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# 档位 → (stage tier, 上游 build.sh tier)
if [[ "$TIER_ARG" == "v1-safe" ]]; then
  STAGE_TIER="v1-safe"; UP_TIER="stock"
else
  STAGE_TIER="func"; UP_TIER="$TIER_ARG"
fi

echo "########################################################"
echo "# build-mine  stage=$STAGE_TIER  upstream=$UP_TIER  OC=$( [[ $DISABLE_OC == 1 ]] && echo off || echo ON )"
echo "########################################################"

echo
echo ">>> [1/3] stage"
"$ROOT/scripts/stage.sh" --tier "$STAGE_TIER" --disable-oc "$DISABLE_OC"

[[ "$STAGE_ONLY" == "1" ]] && { echo "  --stage-only 模式，停止。"; exit 0; }

echo
echo ">>> [2/3] rules 审计"
"$ROOT/scripts/audit-local.sh" || exit 1

echo
echo ">>> [3/3] 构建 - 上游 build.sh $UP_TIER"
STAGE="$ROOT/.stage"
[[ -f "$STAGE/scripts/build.sh" ]] || { echo "FATAL: $STAGE/scripts/build.sh 不存在" >&2; exit 1; }

# ── 定位 OpenWrt 源码树 ────────────────────────────────────────────────
# 本仓库（及上游 xr1710g-openwrt）都只是**叠加层**：不含 package/ target/ scripts/feeds，
# 不能当构建树。build.sh 第 25 行硬校验 $TREE/.git 与 $TREE/scripts/feeds，
# 传 .stage 必崩 ⇒ 这里先定位并校验，失败就给可操作的错误而不是让它崩在深处。
if [[ -z "$TREE" ]]; then
  for c in "$ROOT/../source_openwrt/openwrt" "$ROOT/../../source_openwrt/openwrt" \
           "$ROOT/../openwrt" "$ROOT/../../openwrt" "$ROOT/openwrt"; do
    [[ -d "$c" && -d "$c/.git" && -f "$c/scripts/feeds" ]] && TREE="$c" && break
  done
fi

if [[ -z "$TREE" || ! -d "$TREE" ]]; then
  echo "FATAL: 未找到 OpenWrt 源码树。" >&2
  echo "  本仓库只是叠加层（补丁+配置），需要一个真正的 openwrt 源码树来构建。" >&2
  echo "  请用 --tree <路径> 指定，或设置 OPENWRT_DIR 环境变量。" >&2
  echo "  例：git clone https://github.com/openwrt/openwrt.git <路径>" >&2
  exit 1
fi

if [[ ! -d "$TREE/.git" || ! -f "$TREE/scripts/feeds" ]]; then
  echo "FATAL: $TREE 不是合法的 openwrt 源码树（需要 .git 与 scripts/feeds）。" >&2
  echo "  注意：不要把 .stage/ 或本仓库当源码树 —— 它们是叠加层。" >&2
  exit 1
fi
TREE="$(cd "$TREE" && pwd)"
echo "  源码树：$TREE"
echo "  源码树 HEAD：$(git -C "$TREE" rev-parse --short HEAD)（$(git -C "$TREE" log -1 --format=%ad --date=short)）"

# ── 校验内核版本（必须 6.18.44）─────────────────────────────────────
# 补丁集对齐 Linux 6.18.44；6.18.52+ 会因 netfilter/flowtable 上下文变动导致补丁 reject
if [[ -f "$TREE/target/linux/generic/kernel-6.18" ]]; then
  if ! grep -q 'LINUX_VERSION-6.18.*=.*\.44' "$TREE/target/linux/generic/kernel-6.18"; then
    echo "FATAL: $TREE 的内核版本非 6.18.44！" >&2
    echo "  当前定义：" >&2
    grep 'LINUX_VERSION-6.18' "$TREE/target/linux/generic/kernel-6.18" >&2 || true
    echo "  本叠加层补丁集（如 675-02 bridge offload）严格锁定 Linux 6.18.44。" >&2
    echo "  请将源码树 checkout 到稳定基线 commit：7f4f824691fb2258afe9eb9a37da46d3557c4043" >&2
    exit 1
  fi
  echo "  内核版本：Linux 6.18.44 (OK)"
fi

# ⚠ 上游 build.sh 第 0 步会对源码树执行 `git reset --hard` + `git clean -fd`，
#   这是"叠加层模型"的设计（树被视为可丢弃品），但会**丢掉源码树里未提交的改动**。
#   这里只提示不阻断：多数情况源码树本就该是干净的，但避免静默丢工作。
if [[ -n "$(git -C "$TREE" status --porcelain 2>/dev/null)" ]]; then
  echo
  echo "  ⚠ 警告：源码树有未提交的改动，构建前会被 build.sh 的 git reset --hard 清除！"
  git -C "$TREE" status --short | head -5 | sed 's/^/      /'
  echo "      （如需保留请先 commit 或备份；确认无需保留则忽略本提示）"
fi

JOBS_ENV=""
[[ -n "$JOBS" ]] && JOBS_ENV="$JOBS"
cd "$STAGE"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "  --dry-run 模式，将执行："
  echo "    JOBS=${JOBS_ENV:-nproc} ./scripts/build.sh $UP_TIER \"$TREE\""
  echo "  --dry-run 到此为止，未真正构建。"
  exit 0
fi

# 上游 build.sh：ROOT 仍是 .stage（叠加层来源），TREE 是真正的源码树。
# 因 TREE != ROOT，build.sh 第 0 步会 git reset --hard 树并把 .stage/ rsync 进去。
JOBS="$JOBS_ENV" ./scripts/build.sh "$UP_TIER" "$TREE"

echo
echo ">>> 产物（在源码树内，不在 .stage/）："
ls -la "$TREE"/bin/targets/airoha/an7581/*.itb 2>/dev/null || \
  find "$TREE/bin/targets" -name '*.itb' -exec ls -la {} \; 2>/dev/null || \
  echo "  未找到 .itb，请查 build-$UP_TIER.log 或 $TREE/logs/"
echo
echo "刷机：见上游仓库 docs/FLASHING.md"
