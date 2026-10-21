#!/usr/bin/env bash
# build-npu-fdk.sh — 构建 NPU FDK（hurryman2212/airoha-npu-fdk）成对固件
#
# 用法：
#   scripts/build-npu-fdk.sh
#   可选环境变量：
#     NPU_FDK_OUTPUT_DIR  输出目录（默认 tmp/npu-fdk-dist）
#     NPU_FDK_CACHE_DIR   下载缓存目录（默认 tmp/npu-fdk-cache）
#     LLVM_CC / LLVM_OBJCOPY / LD_LIBRARY_PATH / PATH 按标准语义覆盖
#
# 锁源铁律：pin 文件里的 commit + tarball_sha256 必须匹配；改 pin 必须重算 hash。
# 构建修复补丁只允许来自 patches/vendor/hurryman/npu-fdk/（当前为
#   0001 volatile->const void cast（xrci 同款修复）+ 0002 memmove libcall wrapper）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$ROOT/config/npu-fdk.pin"
PATCH_DIR="$ROOT/patches/vendor/hurryman/npu-fdk"
OUT_DIR="${NPU_FDK_OUTPUT_DIR:-$ROOT/tmp/npu-fdk-dist}"
CACHE_DIR="${NPU_FDK_CACHE_DIR:-$ROOT/tmp/npu-fdk-cache}"
mkdir -p "$OUT_DIR" "$CACHE_DIR"
OUT_DIR="$(readlink -f "$OUT_DIR")"
CACHE_DIR="$(readlink -f "$CACHE_DIR")"

[[ -f "$PIN" ]] || { echo "错误：找不到 $PIN" >&2; exit 1; }
# shellcheck disable=SC1090
source "$PIN"

PIN_REPO="${repo:-}"
PIN_COMMIT="${commit:-}"
PIN_SHA256="${tarball_sha256:-}"
[[ -n "$PIN_REPO" && -n "$PIN_COMMIT" && -n "$PIN_SHA256" ]] || {
  echo "错误：$PIN 必须包含 repo/commit/tarball_sha256" >&2; exit 1; }

log() { echo "== $*"; }
die() { echo "错误：$*" >&2; exit 1; }

log "NPU FDK 锁源：$PIN_REPO @ $PIN_COMMIT"

# ---------- LLVM/Clang 工具链 ----------
# 优先使用 LLVM_CC / LLVM_OBJCOPY；否则在 PATH 中探测支持 RV32 zicsr 的 clang。
ARCH_FLAGS=(--target=riscv32-unknown-elf -march=rv32imc_zicsr_zifencei -mabi=ilp32)
TEST_C="$(mktemp --suffix=.c)"
TEST_O="$(mktemp --suffix=.o)"
cat > "$TEST_C" <<'C'
int npu_fdk_arch_probe(void) { return 0; }
C

TOOL_BIN_DIR=""
cleanup_probe() {
  rm -f "$TEST_C" "$TEST_O"
  if [[ -n "$TOOL_BIN_DIR" && -L "$TOOL_BIN_DIR/ld.lld" ]]; then rm -f "$TOOL_BIN_DIR/ld.lld"; fi
  if [[ -n "$TOOL_BIN_DIR" ]]; then rmdir "$TOOL_BIN_DIR" 2>/dev/null || true; fi
}
trap cleanup_probe EXIT

clang_ok() {
  local c="$1"
  [[ -n "$c" ]] || return 1
  command -v "$c" >/dev/null 2>&1 || return 1
  "$c" "${ARCH_FLAGS[@]}" -c "$TEST_C" -o "$TEST_O" >/dev/null 2>&1
}

if [[ -n "${LLVM_CC:-}" ]]; then
  clang_ok "$LLVM_CC" || die "LLVM_CC=$LLVM_CC 无法编译 ${ARCH_FLAGS[*]}"
  CLANG="$LLVM_CC"
else
  CLANG=""
  for c in clang clang-19 clang-18 clang-17 clang-16; do
    if clang_ok "$c"; then CLANG="$c"; break; fi
  done
  [[ -n "$CLANG" ]] || die "未找到支持 'rv32imc_zicsr_zifencei' 的 clang（需要 clang>=17）。可先安装：apt-get install clang lld llvm"
fi
rm -f "$TEST_O"

# 让 clang 所在目录进入 PATH（clang-19 等版本化工具目录通常包含 ld.lld / llvm-objcopy）
CLANG_DIR="$(cd "$(dirname "$(command -v "$CLANG")")" && pwd)"
export PATH="$CLANG_DIR:$PATH"

if [[ -n "${LLVM_OBJCOPY:-}" ]]; then
  OBJCOPY="$LLVM_OBJCOPY"
else
  OBJCOPY="${LLVM_OBJCOPY:-llvm-objcopy}"
  if ! command -v "$OBJCOPY" >/dev/null 2>&1; then
    # 版本化 fallback：clang-19 -> llvm-objcopy-19
    CLANG_BASE="$(basename "$CLANG")"
    VER="${CLANG_BASE#clang-}"
    if [[ "$VER" != "$CLANG_BASE" ]] && command -v "llvm-objcopy-$VER" >/dev/null 2>&1; then
      OBJCOPY="llvm-objcopy-$VER"
    fi
  fi
fi
command -v "$CLANG" >/dev/null 2>&1 || die "clang 不可执行：$CLANG"
command -v "$OBJCOPY" >/dev/null 2>&1 || die "llvm-objcopy 不可执行：$OBJCOPY"
if ! command -v ld.lld >/dev/null 2>&1; then
  # 允许 ld.lld-<ver>，建临时符号链接；clang -fuse-ld=lld 只找 PATH 里的 ld.lld
  TOOL_BIN_DIR="$(mktemp -d)"
  LLVM_LD_LINK=""
  CLANG_BASE="$(basename "$CLANG")"
  VER="${CLANG_BASE#clang-}"
  if [[ "$VER" != "$CLANG_BASE" ]] && command -v "ld.lld-$VER" >/dev/null 2>&1; then
    LLVM_LD_LINK="$(command -v "ld.lld-$VER")"
  fi
  if [[ -z "$LLVM_LD_LINK" && -x "$CLANG_DIR/ld.lld" ]]; then
    LLVM_LD_LINK="$CLANG_DIR/ld.lld"
  fi
  [[ -n "$LLVM_LD_LINK" ]] || die "未找到 ld.lld（请安装 lld）"
  ln -s "$LLVM_LD_LINK" "$TOOL_BIN_DIR/ld.lld"
  export PATH="$TOOL_BIN_DIR:$PATH"
fi

command -v python3 >/dev/null 2>&1 || die "python3 不可执行"
log "工具链：CLANG=$CLANG OBJCOPY=$OBJCOPY"
export LLVM_CC="$CLANG"
export LLVM_OBJCOPY="$OBJCOPY"

# ---------- 下载与校验 ----------
mkdir -p "$CACHE_DIR" "$OUT_DIR"
TARBALL="$CACHE_DIR/npu-fdk-${PIN_COMMIT}.tar.gz"
REPO_PATH="$PIN_REPO"
if [[ "$PIN_REPO" == https://github.com/* ]]; then
  REPO_PATH="${PIN_REPO#https://github.com/}"
fi
REPO_PATH="${REPO_PATH%/}"
URL="https://codeload.github.com/$REPO_PATH/tar.gz/$PIN_COMMIT"

fetch_and_verify() {
  local tmp_tar="$TARBALL.tmp"
  if [[ -f "$TARBALL" ]] && echo "$PIN_SHA256  $TARBALL" | sha256sum -c - >/dev/null 2>&1; then
    log "tarball 命中缓存且 sha256 校验通过"
    return 0
  fi
  log "下载 $URL"
  rm -f "$TARBALL" "$tmp_tar"
  curl -fsSL --retry 3 -o "$tmp_tar" "$URL" || die "下载失败：$URL"
  echo "$PIN_SHA256  $tmp_tar" | sha256sum -c - >/dev/null 2>&1 || {
    echo "  ✗ tarball sha256 校验失败" >&2
    echo "    期望 $PIN_SHA256" >&2
    echo "    实际 $(sha256sum < "$tmp_tar" | awk '{print $1}')" >&2
    rm -f "$tmp_tar"
    exit 1
  }
  mv "$tmp_tar" "$TARBALL"
  log "tarball sha256 校验通过"
}
fetch_and_verify

# ---------- 解包与应用构建修复 ----------
SRC_DIR="$OUT_DIR/src"
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"
log "解包 $TARBALL -> $SRC_DIR"
tar xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1

log "应用 vendored 构建修复（patches/vendor/hurryman/npu-fdk/）"
for pf in "$PATCH_DIR"/*.patch; do
  [[ -e "$pf" ]] || continue
  echo "  应用 $(basename "$pf")"
  (cd "$SRC_DIR" && patch -p1 --no-backup-if-mismatch) < "$pf" || {
    echo "  ✗ 补丁应用失败：$pf" >&2
    echo "    请重新从上游提取补丁并重算（修复而非降级）" >&2
    exit 1
  }
done

# ---------- 构建 ----------
log "构建 FDK（python3 airoha-npu-fdk-build --platform an7581）"
(cd "$SRC_DIR" && python3 airoha-npu-fdk-build --platform an7581 \
    -o "$OUT_DIR/en7581_MT7996_npu" \
    --debug-directory "$OUT_DIR/debug")

RV32="$OUT_DIR/en7581_MT7996_npu_rv32.bin"
DATA="$OUT_DIR/en7581_MT7996_npu_data.bin"
[[ -f "$RV32" && -f "$DATA" ]] || die "构建未生成成对固件"

log "构建产物"
ls -la "$RV32" "$DATA"
sha256sum "$RV32" "$DATA"
log "完成：$RV32 与 $DATA（成对替换，不可混用官方 data/自编 rv32）"
