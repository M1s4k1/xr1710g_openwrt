#!/bin/bash
# build.sh — XR1710G fork 本地构建入口（func 档）
#
# 流程（与 CI 一致）：feeds update/install → defconfig → 追加 xr1710g-seed.config
#   → defconfig → 符号门禁 → make
#
# 用法：
#   scripts/build.sh                 # 全量构建（默认 -j$(nproc)）
#   scripts/build.sh -j8             # 指定并行度
#   scripts/build.sh --menuconfig    # 第二次 defconfig 前插菜单配置
set -euo pipefail
cd "$(dirname "$0")/.."

JOBS="$(( $(nproc 2>/dev/null || echo 4) + 1 ))"
MENUCFG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -j*) JOBS="${1#-j}"; shift ;;
    --menuconfig) MENUCFG=1; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

echo "== feeds =="
./scripts/feeds update -a
./scripts/feeds install -a

echo "== defconfig + seed =="
make defconfig
[[ -n "$(tail -c1 .config 2>/dev/null)" ]] && printf '\n' >> .config   # 防两段粘连
cat xr1710g-seed.config >> .config
if [[ $MENUCFG -eq 1 ]]; then
  make menuconfig
else
  make defconfig
fi

echo "== 符号门禁 =="
grep -q '^CONFIG_TARGET_airoha_an7581_DEVICE_gemtek_xr1710g-ubi=y$' .config \
  || { echo "✗ .config 未选中 gemtek_xr1710g-ubi（kconfig 静默忽略未知符号？）" >&2; exit 1; }
echo "✓ gemtek_xr1710g-ubi 已选中"

echo "== make（-j$JOBS）=="
make -j"$JOBS"

echo "== 产物 =="
ls -lh bin/targets/airoha/an7581/*.itb 2>/dev/null || {
  echo "✗ 未找到 .itb 产物" >&2; exit 1; }
