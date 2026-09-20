#!/usr/bin/env bash
# check-upstream.sh — 上游 genshanxinli 更新感知（只读、零副作用）
#
# 目的：回答两个问题
#   ④ 上游更新了吗？更新了什么？
#   ⑤ 这些更新对我（本 fork）意味着什么？逐条该接受还是拒绝？
#
# 用法：
#   scripts/check-upstream.sh                 # fetch + 完整报告
#   scripts/check-upstream.sh --no-fetch      # 用已有 origin/main 引用，不联网
#   scripts/check-upstream.sh --quiet         # 仅有更新时输出摘要（适合定时任务）
#   scripts/check-upstream.sh --patch-only    # 只看补丁文件变动（过滤文档/调试脚本杂音）
#   scripts/check-upstream.sh --baseline      # 记录当前上游 tip 为「已裁决基线」
#
# 退出码：
#   0 = 无更新，或所有更新均无影响
#   1 = 有新提交（需人工裁决）—— 便于在 automation 里当告警信号
#   2 = 检出**直接影响本 fork** 的变化（撞号 / 改了我停用或提档的补丁）—— 最高优先级
#
# 设计原则：
#   - **只读**：只做 git fetch / diff / show，绝不修改工作区或上游仓库
#   - **可离线**：--no-fetch 时纯本地比对；联网失败降级为告警而非崩溃
#   - **不猜测**：只呈现事实（增删了什么、碰了哪些行），裁决由人做，记进 upstream-decisions.md
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${UPSTREAM_DIR:-}"
if [[ -z "$UPSTREAM" ]]; then
  for u in "$ROOT/../xr1710g-openwrt" "$ROOT/../../xr1710g-openwrt" "$ROOT/upstream"; do
    [[ -d "$u" && -d "$u/.git" ]] && UPSTREAM="$u" && break
  done
  UPSTREAM="${UPSTREAM:-$ROOT/../xr1710g-openwrt}"
fi
RULES="$ROOT/local/manifest.rules"
DECISIONS="$ROOT/upstream-decisions.md"
# ⚠ 不要放在 .stage/ 下：stage.sh 用 `rsync -a --delete` 重建 .stage/，
#   会把这里的基线文件一并删掉 ⇒ 每次 stage 后都退化成"全部待裁决"（假警报）。
#   放仓库根的隐藏文件（已登记 .gitignore），与 .stage 生命周期解耦。
STAMP="$ROOT/.upstream-baseline"   # 上次裁决过的上游 tip

DO_FETCH=1; QUIET=0; SET_BASELINE=0; PATCH_ONLY=0
for a in "$@"; do
  case "$a" in
    --no-fetch)     DO_FETCH=0 ;;
    --quiet|-q)     QUIET=1 ;;
    --baseline)     SET_BASELINE=1 ;;
    --patch-only|-p) PATCH_ONLY=1 ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 1 ;;
  esac
done

[[ -d "$UPSTREAM/.git" ]] || { echo "错误：上游仓库不存在：$UPSTREAM" >&2; exit 1; }
cd "$UPSTREAM"

# ── 0. fetch ────────────────────────────────────────────────────────────
if [[ "$DO_FETCH" == 1 ]]; then
  command -v timeout >/dev/null 2>&1 \
    && timeout 60 git fetch origin main --quiet 2>/dev/null \
    || git fetch origin main --quiet 2>/dev/null \
    || echo "  (fetch 失败，回退到本地已有引用)" >&2
fi

UPSTREAM_URL="$(git remote get-url origin 2>/dev/null || echo '?')"
LOCAL_TIP="$(git rev-parse HEAD)"
REMOTE_TIP="$(git rev-parse origin/main 2>/dev/null)" || { echo "错误：无 origin/main 引用" >&2; exit 1; }

# ── --baseline：记录当前 tip 为已裁决基线 ────────────────────────────────
if [[ "$SET_BASELINE" == 1 ]]; then
  mkdir -p "$(dirname "$STAMP")"
  echo "$REMOTE_TIP" > "$STAMP"
  echo "已记录上游裁决基线：${REMOTE_TIP:0:9}"
  echo " - 写入 ${STAMP}（仓库根隐藏文件，不随 .stage 重建而丢失）"
  exit 0
fi

# 基线优先取裁决标记；没有则从 rules 头部提取；再没有则退回本地快照 HEAD
if [[ -f "$STAMP" ]]; then
  BASE_TIP="$(cat "$STAMP")"; BASE_SRC="裁决基线"
elif RULES_BASE="$(grep -oE '上游基线[[:space:]]+[0-9a-f]{7,}' "$RULES" 2>/dev/null | awk '{print $2}')" && [[ -n "$RULES_BASE" ]] && git rev-parse "$RULES_BASE" >/dev/null 2>&1; then
  BASE_TIP="$(git rev-parse "$RULES_BASE")"; BASE_SRC="规则基线"
else
  BASE_TIP="$LOCAL_TIP"; BASE_SRC="本地快照"
fi

if [[ "$BASE_TIP" == "$REMOTE_TIP" ]]; then
  [[ "$QUIET" == 0 ]] && {
    echo "== 上游更新检查 =="
    echo "   仓库   : $UPSTREAM_URL"
    echo "   基线   : ${BASE_TIP:0:9} - $BASE_SRC"
    echo "   远端   : ${REMOTE_TIP:0:9}"
    echo
    echo "无更新。"
  }
  exit 0
fi

# ── 1. 提交清单 ─────────────────────────────────────────────────────────
N_COMMITS="$(git rev-list --count "$BASE_TIP..$REMOTE_TIP" 2>/dev/null || echo '?')"

echo "== 上游更新检查 =="
echo "   仓库   : $UPSTREAM_URL"
echo "   基线   : ${BASE_TIP:0:9} - $BASE_SRC"
echo "   远端   : ${REMOTE_TIP:0:9}"
echo "   增量   : $N_COMMITS 个提交"
echo

if [[ "$PATCH_ONLY" == 1 ]]; then
  echo "-- 补丁文件变动（已过滤纯文档/调试脚本提交）--"
  git diff --name-status "$BASE_TIP..$REMOTE_TIP" -- 'patches/*.patch' 'patches/*/*.patch' 'patches/*/*/*.patch' 2>/dev/null | sed 's/^/   /' || echo "   无补丁文件变动"
  echo
else
  echo "-- 提交清单 - $BASE_SRC → 远端--"
  git log --oneline --no-decorate "$BASE_TIP..$REMOTE_TIP" 2>/dev/null | sed 's/^/   /'
  echo
fi

# ── 2. 补丁层变化：上游 MANIFEST 增删 ───────────────────────────────────
# 这是「逐条裁决」的核心原料：上游新增/删除/改档了哪些补丁。
MANIFEST_DIFF="$(git diff "$BASE_TIP..$REMOTE_TIP" -- patches/MANIFEST 2>/dev/null)"

# 提取活动行（无前缀两字段行）的增删
collect_added() {  # <档位前缀>  输出该档位新增的补丁路径
  local pre="$1"
  echo "$MANIFEST_DIFF" | grep -E "^\+${pre}patches/" | sed "s/^+${pre}//" | awk '{print $1}' | sort
}
collect_removed() {
  local pre="$1"
  echo "$MANIFEST_DIFF" | grep -E "^-${pre}patches/" | sed "s/^-${pre}//" | awk '{print $1}' | sort
}

ADDED_DEFAULT="$(collect_added '')"
ADDED_EXP="$(collect_added '#EXP ')"
ADDED_OC="$(collect_added '#OC ')"
REMOVED_DEFAULT="$(collect_removed '')"
REMOVED_EXP="$(collect_removed '#EXP ')"
REMOVED_DIS="$(collect_removed '#DISABLED ')"

# 活动行的档位迁移：同一路径既在 + 又在 - （前缀不同）= 改档
echo "-- 上游补丁层变化（MANIFEST 视角）--"
CHANGED=0
emit() { # <标签> <内容> <是否重要>
  [[ -z "$2" ]] && return 0
  echo "   [$1]"
  echo "$2" | sed 's/^/       /'
  CHANGED=1
}
emit "新增·默认档"    "$ADDED_DEFAULT"
emit "新增·实验档"    "$ADDED_EXP"
emit "新增·OC 档"     "$ADDED_OC"
emit "移除·原默认档"  "$REMOVED_DEFAULT"
emit "移除·原实验档"  "$REMOVED_EXP"
emit "移除·原停用"    "$REMOVED_DIS"
[[ "$CHANGED" == 0 ]] && echo " - MANIFEST 无增删"
echo

# ── 3. §4 影响判定：与我的 rules 是否冲突 ───────────────────────────────
# 三类判定：
#   HIT-DISABLE  上游改动了我 `-`（停用）的补丁 → 我的停用意图可能失效
#   HIT-PROMOTE  上游改动了我 `^`（提档）的补丁 → 我提档的内容可能被改
#   COLLIDE      上游新增补丁号与我 `+`（本地补丁）撞号
IMPACT=0

# 3a. 我停用/提档的目标（从 rules 提取，去掉 patches/ 前缀便于比对）
# 注：用 [[:space:]] 而非 \s —— BSD/GNU grep -E 对 \s 支持不一致
MY_TARGETS="$(grep -E '^[[:space:]]*[-^][[:space:]]+patches/' "$RULES" 2>/dev/null | sed -E 's/^[[:space:]]*[-^][[:space:]]+(patches\/[^[:space:]]+).*/\1/' | sort -u)"
MY_ADDED="$(grep -E '^[[:space:]]*\+[[:space:]]+patches/' "$RULES" 2>/dev/null | sed -E 's/^[[:space:]]*\+[[:space:]]+(patches\/[^[:space:]]+).*/\1/' | sort -u)"

# 上游这次动了哪些补丁**文件**（不只是 MANIFEST 条目）
# 覆盖 patches/ 下全部子目录（root/packages/vendor/specs），避免漏掉 vendor 里被我
# 停用/提档的补丁（如 v1-safe 停用的 patches/vendor/fanboy/21-hsuart-* 被上游改动时本应报 HIT）
TOUCHED_FILES="$(git diff --name-only "$BASE_TIP..$REMOTE_TIP" -- 'patches/' 2>/dev/null | sort -u)"

echo "-- 影响判定（我的 rules ↔ 上游改动）--"
if [[ -n "$MY_TARGETS" && -n "$TOUCHED_FILES" ]]; then
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    if echo "$TOUCHED_FILES" | grep -qxF "$t"; then
      echo "   ⚠ HIT  $t"
      echo "          → 该补丁属于我的停用/提档面，但上游改了它 ⇒ 需复核我的规则是否仍然成立"
      IMPACT=2
    fi
  done <<< "$MY_TARGETS"
fi

# 3a-2. 本地补丁所依赖的**上游 files/ 配置**是否被改（监控盲区补齐，2026-09-17）
#   背景：本地 9601/9602 是 ROOT 补丁，改的是上游 files/etc/config/{network,system}。
#   上游一旦改这些文件 ⇒ 补丁上下文漂移、构建时 fuzz/冲突失败，
#   而上面的 TOUCHED_FILES 只看 patches/*.patch，不会报 ⇒ 补这一段。
LOCAL_FILE_DEPS="files/etc/config/network files/etc/config/system"
TOUCHED_CFG="$(git diff --name-only "$BASE_TIP..$REMOTE_TIP" -- $LOCAL_FILE_DEPS 2>/dev/null | sort -u)"
if [[ -n "$TOUCHED_CFG" ]]; then
  while IFS= read -r cf; do
    [[ -z "$cf" ]] && continue
    case "$cf" in
      files/etc/config/network) p="9601-xr1710g-network-yyh-align.patch" ;;
      files/etc/config/system)  p="9602-xr1710g-led-yyh-align.patch" ;;
      *) p="（未知）" ;;
    esac
    echo "   ⚠ HIT-CFG  $cf"
    echo "          → 本地补丁 ${p} 改的正是这个文件 ⇒ 需重做补丁（重新 diff 生成）后再构建"
    IMPACT=2
  done <<< "$TOUCHED_CFG"
fi

# 3b. 撞号检测：上游新增补丁的编号段 vs 我的本地补丁编号段
if [[ -n "$MY_ADDED" && ( -n "$ADDED_DEFAULT" || -n "$ADDED_EXP" || -n "$ADDED_OC" ) ]]; then
  ALL_ADDED="$(printf '%s\n%s\n%s\n' "$ADDED_DEFAULT" "$ADDED_EXP" "$ADDED_OC" | grep -v '^$' | sort -u)"
  while IFS= read -r mine; do
    [[ -z "$mine" ]] && continue
    mnum="$(basename "$mine" | grep -oE '^[0-9]+' || echo '')"
    [[ -z "$mnum" ]] && continue
    while IFS= read -r theirs; do
      [[ -z "$theirs" ]] && continue
      tnum="$(basename "$theirs" | grep -oE '^[0-9]+' || echo '')"
      [[ "$mnum" == "$tnum" ]] && {
        echo "   ⚠ COLLIDE  编号 $mnum 撞号"
        echo "          我的：$mine"
        echo "          上游：$theirs"
        echo "          → 需改号（我的 9501+ 命名空间）或改址"
        IMPACT=2
      }
    done <<< "$ALL_ADDED"
  done <<< "$MY_ADDED"
fi

[[ "$IMPACT" == 0 ]] && echo "   ✓ 未检出直接冲突 - 无撞号、未触碰我的停用/提档面"
echo

# ── 4. 裁决账本状态 ─────────────────────────────────────────────────────
echo "-- 裁决账本 --"
if [[ -f "$DECISIONS" ]]; then
  # 统计账本里已裁决的提交数
  N_DECIDED="$(grep -cE '^[[:space:]]*\|?[[:space:]]*`?[0-9a-f]{7,}`?[[:space:]]*\|' "$DECISIONS" 2>/dev/null || echo 0)"
  echo "   $DECISIONS"
  echo "   已登记裁决：$N_DECIDED 条"
  # 列出远端 tip 是否已在账本中出现（= 是否已裁决到最新）
  if grep -qF "${REMOTE_TIP:0:9}" "$DECISIONS" 2>/dev/null; then
    echo "   ✓ 远端 tip ${REMOTE_TIP:0:9} 已在账本中登记"
  else
    echo "   ⚠ 远端 tip ${REMOTE_TIP:0:9} 尚未登记 ⇒ 这 $N_COMMITS 个提交待裁决"
    echo "     裁决后执行：scripts/check-upstream.sh --baseline"
  fi
else
  echo "   ⚠ 账本不存在：$DECISIONS"
  echo "     模板见 upstream-decisions.md（本仓库应自带）"
fi
echo

# ── 5. 结论 ─────────────────────────────────────────────────────────────
if [[ "$IMPACT" == 2 ]]; then
  echo "结论：检出**直接影响本 fork** 的变化，需优先人工裁决。"
  exit 2
fi
echo "结论：有 $N_COMMITS 个新提交待裁决 - 无直接冲突。"
exit 1
