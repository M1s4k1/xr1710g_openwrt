#!/usr/bin/env bash
# build.sh — 本地一键构建（完整源码构建，OpenWrt 官方流程）
# 用法：build.sh <stock|experimental> [openwrt树目录]
#   TIER 缺省 = stock（唯一 CPU 档：OPP 650–1350 + oc-auto 自动退档 1350→1300→1200，见 FIXES F89）
#   experimental = 默认档 + 实验档（MANIFEST #EXP 条目；F25 起可本地构建验证）
#   树目录缺省 = ./openwrt（或 $OPENWRT_DIR）
#
# 前置（首次）：
#   git clone https://github.com/openwrt/openwrt.git openwrt
#     # 或直接：本仓库就是 openwrt 的 fork（含此文件），TREE=.
#   ./scripts/feeds update -a && ./scripts/feeds install -a
#
# 本脚本在树内执行：应用补丁层 → （oc 档）prepare-oc → feeds → defconfig(+seed) → make
set -euo pipefail

TIER="${1:-stock}"
case "$TIER" in stock|experimental) ;; *) echo "错误：TIER ∈ stock|experimental" >&2; exit 1 ;; esac
TREE="${2:-${OPENWRT_DIR:-./openwrt}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${JOBS:-$(nproc)}"

[[ -d "$TREE/.git" && -f "$TREE/scripts/feeds" ]] || { echo "错误：$TREE 不是 openwrt 源码树（缺 scripts/feeds）" >&2; exit 1; }

echo "== [0/6] 树复位 + 叠加本仓库（叠加层模型：可重复构建；fork 模型下自动跳过）=="
if [[ "$(readlink -f "$TREE")" != "$(readlink -f "$ROOT")" ]]; then
  # 叠加层模型下树是 disposable 的 master 克隆：先撤销上次构建/补丁的残留再叠加，
  # 否则 apply-patches 的 git apply 一次性语义会让第二次 build.sh 直接失败。
  (cd "$TREE" && git reset --hard -q HEAD)
  # 清除上次 apply-patches 生成但未跟踪的文件（package/ target/ 内；顶层叠加层文件不受影响）
  (cd "$TREE" && git clean -fdq -- target package) || echo "  ⚠ 生成文件清理失败（继续）"
  echo "  已复位：tracked 改动物还原 + package/target 未跟踪生成物清除"
  rsync -a --exclude='.git' --exclude='audit-ubi2oc' --exclude='.github' --exclude='openwrt' --exclude='build-*.log' "$ROOT/" "$TREE/"
  echo "  已叠加：$ROOT → $TREE"
fi

echo "== [1/6] 同步补丁层（$TIER）=="
EXP_FLAG=""; [[ "$TIER" == "experimental" ]] && EXP_FLAG="--experimental"
"$ROOT/scripts/apply-patches.sh" "$TREE" $EXP_FLAG

echo "== [2/6] CPU OC（唯一档：OPP 650–1350；稳性退档由 files/etc/init.d/oc-auto 运行时兜底）=="
"$ROOT/scripts/prepare-oc.sh" oc "$TREE"

echo "== [3/6] feeds（官方默认 + 本仓库自定义）=="
cd "$TREE"
cp -f feeds.conf.default feeds.conf
cat "$ROOT/config/feeds.custom.conf" >> feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a

echo "== [4/6] 配置 =="
# 首次需先建 .config；之后每次用 seed 差量刷新（决策：可复现、显式）
if [[ ! -f .config ]]; then
  make defconfig
fi
# 应用 seed diff（见 config/seed-config.diff 内注释：依赖外部 feed 的包先 TODO）
cat "$ROOT/config/seed-config.diff" >> .config
# 实验档增量 seed：MANIFEST #EXP 补丁提供的包不在共享 seed 中（否则 stock 会引用不存在的包）。
# 必须在第二次 defconfig 前追加，且共享 seed 末尾保持换行（否则两段 seed 会粘成一行）。
if [[ "$TIER" == "experimental" ]]; then
  cat "$ROOT/config/seed-config.experimental.diff" >> .config
fi
make defconfig
grep -q "CONFIG_TARGET_airoha_an7581_DEVICE_gemtek_xr1710g-ubi=y" .config \
  && echo "✓ XR1710G 目标已选中" \
  || { echo "⚠ .config 中未选中 gemtek_xr1710g-ubi——检查 seed-config.diff 与 #22397 补丁" >&2; }
if [[ "$TIER" == "experimental" ]]; then
  grep -q '^CONFIG_PACKAGE_bridge-hw-offload=y$' .config \
    && echo "✓ 实验档 bridge-hw-offload 已选入 .config（issue #1 E1）" \
    || { echo "✗ 实验档 bridge-hw-offload 未选入 .config（issue #1 E1）" >&2; exit 1; }
fi
# seed 符号审计（F15 教训：kconfig 静默忽略未知符号——所有 seed 符号必须逐一进 .config）
"$ROOT/scripts/audit-config.sh" "$ROOT/config/seed-config.diff" .config
if [[ "$TIER" == "experimental" ]]; then
  "$ROOT/scripts/audit-config.sh" "$ROOT/config/seed-config.experimental.diff" .config
fi

echo "== [5/6] 构建（-j$JOBS, 日志 build.log）=="
# E2：DISTRIB_DESCRIPTION 注入档位标识（CONFIG_VERSION_DIST 经 include/version.mk 进入 /etc/openwrt_release）
make -j"$JOBS" V=s CONFIG_VERSION_DIST="OpenWrt $TIER" 2>&1 | tee "$ROOT/build-$TIER.log"
if ! ls bin/targets/airoha/an7581/*.itb >/dev/null 2>&1; then
  echo "错误：构建完成但未找到 .itb 产物（目标未生成/打包异常？）" >&2
  exit 1
fi
echo "产物："
ls -la bin/targets/airoha/an7581/*.itb 2>/dev/null || find bin/targets -name '*.itb' -exec ls -la {} \;
echo "完成：$TIER"
echo "刷机：见 docs/FLASHING.md（HTTP U-Boot 主路径）"