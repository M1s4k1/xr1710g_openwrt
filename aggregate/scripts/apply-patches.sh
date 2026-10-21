#!/usr/bin/env bash
# apply-patches.sh — 把 patches/ 补丁层应用到 openwrt 树
# 用法：apply-patches.sh <openwrt树目录> [--dry-run] [--experimental] [--oc]
# 说明：
#   - ROOT 补丁在树根 git apply（跨目录）；其余拷贝到 MANIFEST 指定目录（OpenWrt 构建时应用）。
#   - 冲突即报错退出（修复而不是降级）：人工处理冲突补丁后重跑。
#   - --dry-run：ROOT 补丁按序真实应用（--index）后 git reset --hard 回滚——累计校验，
#     正确反映补丁间依赖；要求工作区相对 HEAD 干净（CI 全新克隆满足）。
#     拷贝项（packages 等）除目标目录存在性外，另由 scripts/verify-copy-patches.sh 做
#     真实应用校验（F20：下载包源码→patch -p1→逐包校验，失败即红）；派生包补丁
#     （ROOT 补丁生成，如 9002→uboot 9990-…，F21）同法校验——避免上下文漂移/命名排序/
#     生成物残缺漏检到构建期。verify 在回滚前调用（派生文件依赖 ROOT 应用后的树状态）。
#   - --experimental：应用 #EXP 前缀条目（实验档）。
#   - --oc：应用 #OC 前缀条目（OC 档，激进资产如 regdb 555）。
set -euo pipefail

TREE=""
DRY=0
EXP=0
OC=0
NODL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --experimental) EXP=1 ;;
    --oc) OC=1 ;;
    --no-download) NODL=1 ;;
    *) TREE="$a" ;;
  esac
done

[[ -n "$TREE" && -d "$TREE/.git" ]] || { echo "错误：需要 openwrt 树目录（含 .git），如 ../openwrt" >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/patches/MANIFEST"
[[ -f "$MANIFEST" ]] || { echo "错误：找不到 $MANIFEST" >&2; exit 1; }

# F21③/9001 教训制度化：hunk 行数一致性审计（git apply 对声明行数≠实际行数的包裹补丁会
# 静默截断创建文件——9001 丢 97 行致内核 DTS 语法错误，构建期才暴露）。dry 与真实模式都先审计。
OC_FLAG_AUDIT=""; (( OC )) && OC_FLAG_AUDIT="--oc"
EXP_FLAG_AUDIT=""; (( EXP )) && EXP_FLAG_AUDIT="--experimental"
"$ROOT/scripts/audit-patches.sh" $OC_FLAG_AUDIT $EXP_FLAG_AUDIT

# F164（2026-09-14）制度化：档位视图一致性审计（ORDER ↔ MANIFEST）。dry 与真实模式都先审计。
# 背景：ORDER 曾长期不同步（实测 96 条 vs MANIFEST 136 条，MANIFEST-only 49 条），且 `#` 前缀
#   同时被当作"注释"与"未启用条目"（双重语义，旧写法 `# experimental 9037`）。现在 ORDER 被定义
#   为 MANIFEST 的**投影**，每次应用前逐条对账（集合 + 档位）；不一致即红 —— 改 MANIFEST 必须同步 ORDER。
"$ROOT/scripts/audit-order.sh" "$ROOT"

applied=0; skipped=0; missing=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%"${line##*[![:space:]]}"}"   # rtrim
  [[ -z "$line" ]] && continue
  if [[ "${line:0:4}" == "#OC " ]]; then
    (( OC )) || { skipped=$((skipped+1)); continue; }
    line="${line:4}"
  fi
  if [[ "${line:0:5}" == "#EXP " ]]; then
    (( EXP )) || { skipped=$((skipped+1)); continue; }
    line="${line:5}"
  fi
  [[ "$line" =~ ^[[:space:]]*# ]] && continue   # 其它注释/停用行（含前导空白）
  src="${line%%[[:space:]]*}"
  dest="${line##*[[:space:]]}"
  pf="$ROOT/$src"
  if [[ ! -f "$pf" ]]; then
    echo "⚠ 缺失补丁文件（未取源？）：$src" >&2
    missing=$((missing+1)); continue
  fi
  if [[ "$dest" == "ROOT" ]]; then
    if (( DRY )); then
      # 累计校验：按序真实应用并暂存（--index），补丁间依赖正确反映；
      # 结束后 git reset --hard 回滚（仅动 git 跟踪内容，不影响未跟踪的叠加层文件）
      if (cd "$TREE" && git apply --index "$pf" 2>/tmp/apply-err); then
        echo "✓ [dry-run] $src"
      else
        echo "✗ 冲突：$src"; sed 's/^/    /' /tmp/apply-err
        (cd "$TREE" && git reset --hard -q); exit 1
      fi
    else
      (cd "$TREE" && git apply "$pf")
      echo "✓ applied  $src"
    fi
  else
    dt="$TREE/$dest"
    if (( DRY )); then
      [[ -d "$dt" ]] && echo "✓ [dry-run] $src -> $dest（目录存在）" || { echo "⚠ [dry-run] 目标目录不存在：$dest（上游树没有该目录？）" >&2; }
    else
      mkdir -p "$dt"
      cp -f "$pf" "$dt/"
      echo "✓ copied   $src -> $dest"
    fi
  fi
  applied=$((applied+1))
done < "$MANIFEST"

echo "----"
echo "处理：$applied  实验档跳过：$skipped  缺失文件：$missing"
if (( DRY )); then
  if (( missing > 0 )); then
    echo "✗ 存在缺失补丁文件（$missing 个）——先运行 scripts/fetch-sources.sh 或按 patches/specs 取源。" >&2
    (cd "$TREE" && git reset --hard -q)
    exit 1
  fi
  # F20/F21 制度化：拷贝类/派生包补丁真实应用校验（失败即红；下载失败=⚠ 未校验不红，构建兜底）。
  # 必须在 git reset 之前调用：派生目标（如 9002 → uboot patches/9990-…）由 ROOT 补丁生成，
  # 回滚后文件即消失。始终回滚工作区，以 verify 的退出码为准。
  OC_FLAG=""; (( OC )) && OC_FLAG="--oc"
  EXP_FLAG=""; (( EXP )) && EXP_FLAG="--experimental"
  NODL_FLAG=""; (( NODL )) && NODL_FLAG="--no-download"
  # F25（2026-08-18）：set -e 下 verify 失败会中止脚本、跳过下方 git reset——本地二次
  # dry-run 时树残留已应用状态（git apply 一次性语义）致误报冲突。verify 退出码仍传播，
  # 但回滚必须无条件执行（CI 全新克隆不受影响，本地工作流必须可重复）。
  set +e
  "$ROOT/scripts/verify-copy-patches.sh" "$TREE" $OC_FLAG $EXP_FLAG $NODL_FLAG
  vrc=$?
  set -e
  (cd "$TREE" && git reset --hard -q)
  echo "（dry-run 完成，工作区已回滚；未跟踪文件不受影响）"
  exit $vrc
fi
[[ "$missing" -gt 0 ]] && { echo "存在缺失补丁——先运行 scripts/fetch-sources.sh 或按 patches/specs 取源。" >&2; exit 1; }
exit 0