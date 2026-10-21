#!/usr/bin/env bash
# sync-upstream.sh — 本地：同步 openwrt master 到工作树 + 补丁层 dry-run 校验
# 决策：2h 自动同步（CI 用 .github/workflows/sync-upstream.yml 每 2h 跑等价流程；冲突面保持最小）
# 用法：sync-upstream.sh [openwrt树目录] [--oc]
set -euo pipefail
TREE="${1:-${OPENWRT_DIR:-./openwrt}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTRA="${2:-}"
[[ -d "$TREE/.git" && -f "$TREE/scripts/feeds" ]] || { echo "错误：$TREE 不是 openwrt 树（缺 scripts/feeds）" >&2; exit 1; }

cd "$TREE"
git remote add upstream https://github.com/openwrt/openwrt.git 2>/dev/null || true
git fetch upstream main
git merge upstream/main --no-edit || { echo "上游同步冲突——修复而不是降级：处理冲突后重跑" >&2; exit 1; }

# 叠加层刷新（本仓库内容 → 树内）
rsync -a --exclude='.git' --exclude='audit-ubi2oc' --exclude='.github' --exclude='openwrt' "$ROOT/" ./

# 补丁层 dry-run（含 oc 档），冲突尽早暴露
chmod +x scripts/*.sh
./scripts/apply-patches.sh . --dry-run $EXTRA
echo "== 同步完成：openwrt HEAD=$(git rev-parse --short HEAD) =="