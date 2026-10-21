#!/usr/bin/env bash
# stage.sh — 合成「生效仓库」到 .stage/
#
# 做什么：把项目内置 aggregate + 本仓库 local/ 叠加成一个完整的、可被构建脚本
#         接受的仓库（同构：含 patches/ config/ files/ scripts/）。
#
# 流程：
#   [1] rsync aggregate → .stage/（排除 .git / bin / build-*；含 .git 由 --git 控制）
#   [2] merge-manifest.py 应用 local/manifest.rules → .stage/patches/MANIFEST
#   [3] gen-order.py 重生成 .stage/patches/ORDER   ← ⚠ 必需，否则 audit-order 报红
#   [4] 叠加本地补丁 local/patches/*.patch → .stage/patches/local/
#   [5] 叠加 rootfs local/files/ → .stage/files/
#   [6] 追加 local/seed.local.diff → .stage/config/seed-config.diff
#   [7] DISABLE_OC=1（默认）→ sed 改写 .stage/scripts/build.sh，禁用 CPU 超频
#
# 用法：
#   scripts/stage.sh [--upstream DIR|--aggregate-source DIR] [--aggregate-ref REF]
#                    [--out DIR] [--tier v1-safe|func]
#                    [--disable-oc 0|1] [--keep-git]
# 默认：aggregate=<项目内置 aggregate>  out=.stage  tier=func  disable-oc=1
set -euo pipefail

# ⚠ 必须 C locale：上游脚本有 41 处「$VAR 紧跟全角标点」的写法（如 build.sh 的
#   `echo "... （$TIER）"`）。UTF-8 locale 下 bash 会把多字节字符并入变量名，即使变量
#   已定义也报 `<VAR>ï¿½: unbound variable`（实测 LC_ALL=C 正常、C.UTF-8 必崩）。
#   上游 CI 跑在 C locale 所以从未暴露。这里导出可让其下游脚本（gen-order.py 等）同样安全。
export LC_ALL=C
export LANG=C

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 来源解析：项目内置 aggregate 是默认输入；UPSTREAM_DIR 是兼容的显式目录入口。
# shellcheck disable=SC1091
source "$ROOT/scripts/source-resolver.sh"
UPSTREAM="${UPSTREAM_DIR:-}"
AGGREGATE_SOURCE_ARG=""
AGGREGATE_REF_ARG=""
OUT="${STAGE_DIR:-$ROOT/.stage}"
TIER="func"
DISABLE_OC="${DISABLE_OC:-1}"
KEEP_GIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream) UPSTREAM="$2"; shift 2 ;;
    --aggregate-source) AGGREGATE_SOURCE_ARG="$2"; shift 2 ;;
    --aggregate-ref) AGGREGATE_REF_ARG="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --tier)     TIER="$2"; shift 2 ;;
    --disable-oc) DISABLE_OC="$2"; shift 2 ;;
    --keep-git) KEEP_GIT=1; shift ;;
    -h|--help)  sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 1 ;;
  esac
done

case "$TIER" in
  func)    RULES="$ROOT/local/manifest.rules" ;;
  v1-safe) RULES="$ROOT/local/manifest.rules.v1-safe" ;;
  *) echo "错误：--tier ∈ func|v1-safe" >&2; exit 1 ;;
esac

source_resolve "$ROOT" "$AGGREGATE_SOURCE_ARG" "$AGGREGATE_REF_ARG" "$UPSTREAM"
UPSTREAM="$AGGREGATE_DIR_RESOLVED"
echo "  aggregate source: ${AGGREGATE_SOURCE_RESOLVED:-embedded}"
echo "  aggregate ref   : $AGGREGATE_REF_RESOLVED"
[[ -f "$UPSTREAM/patches/MANIFEST" ]] || { echo "✗ aggregate 缺 patches/MANIFEST" >&2; exit 1; }
[[ -f "$RULES" ]] || { echo "✗ 找不到 rules：$RULES" >&2; exit 1; }

echo "== [1/7] rsync aggregate → $OUT =="
EXCLUDES=(--exclude='.git' --exclude='bin' --exclude='build-*.log'
          --exclude='.config' --exclude='.config.old'
          --exclude='tmp' --exclude='staging_dir' --exclude='build_dir')
[[ "$KEEP_GIT" == "1" ]] && EXCLUDES=(--exclude='bin' --exclude='build-*.log')
mkdir -p "$OUT"
rsync -a --delete "${EXCLUDES[@]}" "$UPSTREAM/" "$OUT/"
echo "  完成（aggregate $AGGREGATE_COMMIT_RESOLVED）"

echo "== [2/7] 应用 rules：$TIER → patches/MANIFEST =="
python3 "$ROOT/scripts/merge-manifest.py" "$OUT/patches/MANIFEST" \
        --rules "$RULES" -o "$OUT/patches/MANIFEST" --stats

echo "== [3/7] 重生成 patches/ORDER（audit-order 必需）=="
python3 "$OUT/scripts/gen-order.py" "$OUT"

echo "== [4/7] 叠加本地补丁 → patches/local/ =="
if compgen -G "$ROOT/local/patches/*.patch" >/dev/null; then
  mkdir -p "$OUT/patches/local"
  cp -f "$ROOT/local/patches/"*.patch "$OUT/patches/local/"
  echo "  已叠加 $(ls -1 "$ROOT/local/patches/"*.patch | wc -l | tr -d ' ') 个补丁"
else
  echo "  （无本地补丁）"
fi

echo "== [5/7] 叠加 rootfs → files/ =="
if [[ -d "$ROOT/local/files" ]]; then
  cp -rf "$ROOT/local/files/." "$OUT/files/"
  echo "  已叠加 $(find "$ROOT/local/files" -type f | wc -l | tr -d ' ') 个文件"
else
  echo "  （无 files 叠加）"
fi

echo "== [6/7] 追加 seed → config/seed-config.diff =="
if [[ -s "$ROOT/local/seed.local.diff" ]]; then
  # 保证前一段以换行结尾，避免两段 seed 粘连
  [[ -n "$(tail -c1 "$OUT/config/seed-config.diff" 2>/dev/null)" ]] && \
    printf '\n' >> "$OUT/config/seed-config.diff"
  printf '\n# ── 本仓库增量（local/seed.local.diff）──\n' >> "$OUT/config/seed-config.diff"
  cat "$ROOT/local/seed.local.diff" >> "$OUT/config/seed-config.diff"
  echo "  已追加 $(grep -cE '^CONFIG_' "$ROOT/local/seed.local.diff") 个符号"
else
  echo "  （无 seed 增量）"
fi

echo "== [7/7] CPU OC: DISABLE_OC=$DISABLE_OC =="
if [[ "$DISABLE_OC" == "1" ]]; then
  BF="$OUT/scripts/build.sh"
  # 上游 build.sh 硬编码 `"$ROOT/scripts/prepare-oc.sh" oc "$TREE"`（与 TIER 无关）
  MARK='OC disabled by DISABLE_OC=1'
  sed -i.bak 's|^\("\$ROOT/scripts/prepare-oc\.sh" oc "\$TREE"\)$|echo "  ('"$MARK"': CPU stays at stock 1200MHz)"|' "$BF"
  if ! grep -q "$MARK" "$BF"; then
    echo "FATAL: failed to disable OC - build.sh structure changed upstream" >&2
    echo "  check the prepare-oc call in $BF" >&2
    exit 1
  fi
  rm -f "$BF.bak"
  echo "  OK: OC disabled (sed hit + guard passed)"
else
  echo "  WARN: keeping upstream default (will overclock to 1350MHz)"
fi

ACTIVE="$(grep -cE '^[a-z]' "$OUT/patches/MANIFEST" 2>/dev/null || echo '?')"
echo
echo "STAGED OK: $OUT"
echo "  aggregate: $AGGREGATE_COMMIT_RESOLVED"
echo "  tier     : $TIER ($ACTIVE active patches)"
echo "  build    : $OUT/scripts/build.sh stock \"$OUT\""
