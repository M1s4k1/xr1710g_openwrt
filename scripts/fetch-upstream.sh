#!/bin/bash
# fetch-upstream.sh — 拉取 OpenWrt 上游更新并 rebase 我方分支
#
# 语义（2026-10-23 架构转向：fork 模式）：
#   上游 = git remote "upstream"（openwrt/openwrt）
#   我方 = new_main 分支上的 XR1710G commit（板级支持/NPU 栈/mt76/杂项）
#   更新 = git rebase upstream/main ⇒ 冲突即"需适配的 patch"
#
# 为什么 rebase 而不是 merge：保持我方 commit 紧跟上游线性历史，
#   每次冲突范围就是本次需要手工适配的补丁（可逐条处理、可 bisect）。
#
# 用法：
#   scripts/fetch-upstream.sh              # fetch + 显示落后量 + rebase
#   scripts/fetch-upstream.sh --no-rebase  # 只 fetch + 显示状态
#   scripts/fetch-upstream.sh --abort      # rebase 冲突时放弃
set -euo pipefail
cd "$(dirname "$0")/.."

BR="${XR1710G_BRANCH:-new_main}"
DO_REBASE=1
[[ "${1:-}" == "--no-rebase" ]] && DO_REBASE=0
[[ "${1:-}" == "--abort" ]] && { git rebase --abort; echo "已放弃本次 rebase"; exit 0; }

echo "== fetch upstream =="
git fetch --quiet upstream
BASE=$(git rev-parse upstream/main)
HEAD_SHA=$(git rev-parse HEAD)
MERGE_BASE=$(git merge-base HEAD upstream/main)

if [[ "$HEAD_SHA" == "$BASE" ]]; then
  echo "已与上游同步（upstream/main == HEAD）"
  exit 0
fi

if [[ "$MERGE_BASE" == "$BASE" ]]; then
  echo "领先上游（无新上游提交）"
  exit 0
fi

BEHIND=$(git rev-list --count HEAD..upstream/main)
AHEAD=$(git rev-list --count upstream/main..HEAD)
echo "上游新提交：$BEHIND ｜ 我方提交：$AHEAD"
echo "--- 上游新提交（近 20 条）---"
git log --oneline HEAD..upstream/main | head -20

if [[ $DO_REBASE -eq 0 ]]; then
  echo "（--no-rebase：未执行 rebase）"
  exit 0
fi

echo "== rebase onto upstream/main =="
if git rebase upstream/main; then
  echo "✓ rebase 干净完成"
  echo "下一步：scripts/build.sh 验证构建；或 push 触发 CI"
else
  echo "✗ rebase 有冲突。冲突文件即需适配点："
  git diff --name-only --diff-filter=U | sed 's/^/    /'
  echo
  echo "处理流程：逐个解决冲突 → git add → git rebase --continue"
  echo "放弃：scripts/fetch-upstream.sh --abort"
  echo "适配参考：doc/maintenance.md §7（补丁重锚方法论）"
  exit 1
fi
