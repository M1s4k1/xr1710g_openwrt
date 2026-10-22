#!/usr/bin/env bash
# verify-source-patches.sh — 补丁的「内核源码级」验证（不编译，分钟级）
#
# 背景：复制型补丁分两层验证——① 树侧可拷贝（apply-patches.sh --dry-run）；
#   ② 源码级可应用（构建期 patch -p1 的真实战场）。历史上只有①，导致补丁漂移
#   要等 CI 编译 40+ 分钟才暴露。本脚本把②自动化：下载/缓存上游源码，按 openwrt
#   的真实应用顺序（kernel-build.mk：GENERIC_BACKPORT → GENERIC_PATCH(pending) →
#   GENERIC_HACK(hack) → PATCH_DIR(平台)，目录内按文件名序）干跑全部补丁。
#
# 覆盖：内核（generic backport/pending/hack + 平台 patches-6.18）、
#   mac80211（backports release + patches/subsys）、mt76、regdb、
#   以及 manifest 复制型条目指向的其他 git 包（firewall4/rpcd/iwinfo）。
#
# 用法：
#   scripts/verify-source-patches.sh --tree <已应用本地补丁集的 OpenWrt 树>
#     [--cache <源码缓存目录，默认 ~/.cache/xr1710g-srcverify>]
#     [--only <kernel|mac80211|mt76|regdb|pkg:名字>]   # 只验某组（可多次）
#     [--keep]                                        # 保留工作目录（调试）
#
# 退出码：0 = 全部干净；1 = 有补丁失败；2 = 用法/环境错误。
#
# 环境坑（macOS 可用）：不用 timeout/mapfile；grep 用 -E 与 [[:space:]]；
#   变量后紧跟非 ASCII 用 ${VAR} 界定；curl 跟随重定向。

set -euo pipefail
export LC_ALL=C LANG=C

die() { echo "::error::$*" >&2; exit 2; }
log() { printf '%s\n' "$*" >&2; }   # 走 stderr：勿污染 $(pkg_workdir) 等命令替换

# ---------- 参数 ----------
TREE=""
CACHE="${XR1710G_SRC_CACHE:-$HOME/.cache/xr1710g-srcverify}"
ONLY=()
KEEP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tree)  TREE="${2:-}"; shift 2 ;;
    --cache) CACHE="${2:-}"; shift 2 ;;
    --only)  ONLY+=("${2:-}"); shift 2 ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ -n "$TREE" ]] || die "--tree 必填（已应用本地补丁集的 OpenWrt 树）"
[[ -d "$TREE/.git" ]] || die "$TREE 不是 git 仓库（openwrt 源码树）"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/config/source-lock.env"
[[ -f "$LOCK" ]] || die "找不到 $LOCK"
PIN="$(grep -E '^OPENWRT_REF=' "$LOCK" | head -1 | cut -d= -f2-)"
KVER="$(grep -E '^LINUX_VERSION=' "$LOCK" | head -1 | cut -d= -f2-)"
[[ -n "$PIN" && -n "$KVER" ]] || die "source-lock.env 解析失败"
log "== 锁：OpenWrt ${PIN:0:12} / Linux $KVER =="

want() { # want <组名>
  [[ ${#ONLY[@]} -eq 0 ]] && return 0
  local g; for g in "${ONLY[@]}"; do [[ "$g" == "$1" ]] && return 0; done
  return 1
}

mkdir -p "$CACHE"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vsrc.XXXXXX")"
[[ $KEEP -eq 1 ]] && log "工作目录：$WORK"
cleanup() { [[ $KEEP -eq 1 ]] || rm -rf "$WORK"; }
trap cleanup EXIT

# ---------- 工具 ----------
# 收集一组补丁文件的所有目标路径（--- a/ 行；排除 /dev/null）
collect_targets() { # <patch文件...>
  { grep -hE '^--- a/' "$@" 2>/dev/null || true; } | sed 's|^--- a/||' | sort -u
}

# 从 tar 包按需抽取目标文件（不存在于包中的跳过——新建文件无需抽取）
# 单次 tar -T 批量抽取（勿用逐文件循环：每个大包一次全扫描，O(n²) 会超时）
extract_needed() { # <tar包> <带前缀的目标列表文件> <目标根目录>
  local tarball="$1" list="$2" dest="$3"
  [[ -s "$list" ]] || return 0
  mkdir -p "$dest"
  if [[ "$tarball" == *.zst ]]; then
    tar --zstd -xf "$tarball" -C "$dest" -T "$list" 2>/dev/null || true
  else
    tar -xJf "$tarball" -C "$dest" -T "$list" 2>/dev/null || \
    tar -xzf "$tarball" -C "$dest" -T "$list" 2>/dev/null || true
  fi
}

# 提取 Makefile 变量值（兼容 := 与 =；bash 参数展开免 sed 转义）
mkvar() { # <Makefile> <变量名>
  local raw
  raw="$( { grep -E "^$2[[:space:]]*:?=" "$1" || true; } | head -1)"
  raw="${raw#*=}"        # 剥到第一个 =
  raw="${raw#:}"         # := 形式残留的前导冒号
  raw="${raw#"${raw%%[![:space:]]*}"}"   # 去前导空白
  raw="${raw%"${raw##*[![:space:]]}"}"   # 去尾随空白
  printf '%s' "$raw"
}

# 解析 openwrt make 变量与镜像宏
resolve_url() {
  local u="$1"
  u="${u//\$(PROJECT_GIT)/https://git.openwrt.org}"           # openwrt 定义：PROJECT_GIT = https://git.openwrt.org
  u="${u//\$(PROJECT_GIT_MIRROR)/https://git.openwrt.org}"
  # git.openwrt.org/project/<n>.git → GitHub 镜像（更易达、支持按 SHA fetch）
  u="${u/https:\/\/git.openwrt.org\/project\//https://github.com/openwrt/}"
  u="${u//@KERNEL\//https://cdn.kernel.org/}"
  echo "$u"
}

# 包源码工作副本：git 包（PKG_SOURCE_VERSION）或 tarball 包（PKG_SOURCE）
pkg_workdir() { # <包相对目录> <显示名> → 输出工作副本路径
  local pkgdir="$1" name="$2"
  local mk="$TREE/$pkgdir/Makefile"
  [[ -f "$mk" ]] || die "找不到 Makefile：$mk"
  local url ver srcfile
  url="$(mkvar "$mk" PKG_SOURCE_URL)"
  ver="$(mkvar "$mk" PKG_SOURCE_VERSION)"
  srcfile="$(mkvar "$mk" PKG_SOURCE)"
  # 展开 PKG_SOURCE 里的 make 变量（$(PKG_NAME)/$(PKG_VERSION)）
  local pkgname pkgver
  pkgname="$(mkvar "$mk" PKG_NAME)"
  pkgver="$(mkvar "$mk" PKG_VERSION)"
  srcfile="${srcfile//\$(PKG_NAME)/$pkgname}"
  srcfile="${srcfile//\$(PKG_VERSION)/$pkgver}"
  url="$(resolve_url "$url")"

  # --- git 包 ---
  if [[ -n "$ver" ]]; then
    [[ -n "$url" ]] || die "$name：Makefile 无 PKG_SOURCE_URL"
    local cachedir="$CACHE/git-$name-$ver"
    if [[ ! -d "$cachedir/.git" ]]; then
      log "  克隆 $name @ ${ver:0:12}（首次，入缓存）"
      rm -rf "$cachedir"
      git init -q "$cachedir"
      git -C "$cachedir" remote add origin "$url"
      git -C "$cachedir" fetch -q --depth 1 origin "$ver" 2>/dev/null         || git -C "$cachedir" fetch -q origin "$ver" 2>/dev/null         || git -C "$cachedir" fetch -q origin 2>/dev/null         || die "$name：fetch $ver 失败（$url）"
      git -C "$cachedir" checkout -q FETCH_HEAD 2>/dev/null || true
    fi
    # 校验缓存/HEAD 确实在目标 commit
    local head_sha
    head_sha="$(git -C "$cachedir" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$head_sha" != "$ver" ]]; then
      git -C "$cachedir" fetch -q origin "$ver" 2>/dev/null || true
      git -C "$cachedir" checkout -q "$ver" 2>/dev/null         || die "$name：无法 checkout $ver（缓存 HEAD=${head_sha:0:12}）"
    fi
    local wd="$WORK/git-$name"
    rm -rf "$wd"
    git clone -q --shared "$cachedir" "$wd" 2>/dev/null || cp -a "$cachedir" "$wd"
    git -C "$wd" checkout -q "$ver" 2>/dev/null || true
    echo "$wd"
    return 0
  fi

  # --- tarball 包 ---
  [[ -n "$srcfile" ]] || die "$name：Makefile 无 PKG_SOURCE_VERSION 也无 PKG_SOURCE"
  local tarball="$CACHE/$srcfile"
  if [[ ! -s "$tarball" ]] || ! { tar -tf "$tarball" > /dev/null 2>&1 || tar --zstd -tf "$tarball" > /dev/null 2>&1; }; then
    log "  下载 $name 源码（首次）"
    rm -f "$tarball"
    # openwrt 镜像优先（构建同源），退解析后的上游 URL
    curl -fsSL --retry 3 -o "$tarball" "https://sources.cdn.openwrt.org/$srcfile" 2>/dev/null || true
    if [[ ! -s "$tarball" && -n "$url" ]]; then
      curl -fsSL --retry 3 -o "$tarball" "$url$srcfile" 2>/dev/null || true
    fi
    { tar -tf "$tarball" > /dev/null 2>&1 || tar --zstd -tf "$tarball" > /dev/null 2>&1; }       || die "$name 源码下载失败/损坏：$tarball"
  fi
  local wd="$WORK/tar-$name"
  mkdir -p "$wd"
  # 按需抽取（补丁目标文件）；tarball 恒带 <name>-<ver>/ 顶层目录，须补前缀
  local list="$WORK/${name}-files.txt"
  collect_targets "$TREE/$pkgdir/patches"/*.patch > "$list"
  local tprefix="${srcfile%.tar.xz}"; tprefix="${tprefix%.tar.zst}"; tprefix="${tprefix%.tar.gz}"
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    mkdir -p "$wd/$(dirname "$f")"
    { tar -xf "$tarball" -C "$wd" -- "$tprefix/$f" 2>/dev/null || tar --zstd -xf "$tarball" -C "$wd" -- "$tprefix/$f" 2>/dev/null; } || true
  done < "$list"
  # 顶层目录存在则应用根目录随之调整（与 kernel/backports 组同款）
  [[ -d "$wd/$tprefix" ]] && wd="$wd/$tprefix"
  echo "$wd"
}

relpath() { # 把 $TREE 相对路径输出（参数可能是绝对或相对）
  case "$1" in /*) echo "${1#$TREE/}" ;; *) echo "$1" ;; esac
}

# 应用一组补丁（目录内按文件名序），报告失败
apply_set() { # <组标签> <工作副本根> <补丁目录（相对树）...>
  local label="$1" wd="$2"; shift 2
  [[ -d "$wd" ]] || die "[$label] 工作目录不存在：$wd（源码获取失败或被污染）"
  local patches=() d
  for d in "$@"; do
    local pd="$TREE/$d"
    [[ -d "$pd" ]] || continue
    while IFS= read -r f; do patches+=("$f"); done < <(ls "$pd"/*.patch 2>/dev/null | sort)
  done
  [[ ${#patches[@]} -gt 0 ]] || { log "  [$label] 无补丁，跳过"; return 0; }
  log "  [$label] ${#patches[@]} 个补丁"
  local failed=0 p out
  for p in "${patches[@]}"; do
    out="$(cd "$wd" && patch -p1 --batch --no-backup-if-mismatch < "$p" 2>&1)" || true
    if printf '%s' "$out" | grep -qE 'FAILED|malformed|No file to patch'; then
      echo "  ✗ $(basename "$p")"
      printf '%s\n' "$out" | grep -E 'FAILED|malformed|No file to patch' | head -3 | sed 's/^/      /'
      failed=$((failed+1))
    fi
  done
  [[ $failed -eq 0 ]] && log "  [$label] 全部干净 ✓" || log "  [$label] $failed 个失败 ✗"
  return $((failed > 0 ? 1 : 0))
}

# ---------- 各组验证 ----------
FAILED_TOTAL=0

# 我们的补丁在树里创建的「内核侧补丁文件」（target/linux/*/patches-*/ 下、
# 由本地 apply 型补丁生成）——与主线自身补丁区分开（模拟时绝不能再应用它们）
our_kernel_patch_files() {
  local f p
  for f in "$ROOT"/local/patches/*.patch; do
    [[ -f "$f" ]] || continue
    { grep -oE '^diff --git a/target/linux/[A-Za-z0-9_-]+/(patches|pending|hack|backport)-[^/ ]+/[^ ]+\.patch' "$f" 2>/dev/null || true; } \
      | sed 's|^diff --git a/||; s| b/.*$||'
  done | sort -u
}

# ===== 内核：靶型验证（只应用碰我们目标文件的主线补丁 + 我们自己的）=====
verify_kernel() {
  log "-- 内核（Linux $KVER）--"
  local tarball="$CACHE/linux-$KVER.tar.xz"
  # 完整性校验：缓存恢复或下载后都可能是坏包（CI 曾下载到不完整文件）。
  # tar -t 全量列目录一次（约 6s）；坏包必须响亮失败，否则后续 patch 全部
  # "No file to patch" 被忽略 ⇒ 假干净（比响亮的失败更危险）。
  verify_tarball() { # <包> <最小字节>
    local sz
    sz="$(wc -c < "$1" 2>/dev/null || echo 0)"
    [[ "$sz" -gt "${2:-1000000}" ]] || return 1
    { tar -tJf "$1" > /dev/null 2>&1 || tar -tzf "$1" > /dev/null 2>&1; }
  }
  if [[ ! -s "$tarball" ]] || ! verify_tarball "$tarball" 50000000; then
    log "  下载内核源码包（缓存缺失或损坏：$( [[ -s "$tarball" ]] && echo 损坏 || echo 缺失 )）"
    rm -f "$tarball"
    # 双源：kernel.org 优先，失败/损坏则退 openwrt 镜像（CI 曾从 kernel.org
    # 下载到不完整文件；坏包会被上面的完整性校验抓住并重下）
    curl -fsSL --retry 3 -o "$tarball" \
      "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz" || true
    if ! verify_tarball "$tarball" 50000000; then
      log "  kernel.org 源不可用或损坏，退 openwrt 镜像"
      rm -f "$tarball"
      curl -fsSL --retry 3 -o "$tarball" \
        "https://sources.cdn.openwrt.org/linux-$KVER.tar.xz" || true
    fi
    verify_tarball "$tarball" 50000000 || die "内核包下载失败/损坏（可手动放置于 $tarball）"
  fi
  local wd="$WORK/linux"
  mkdir -p "$wd"

  # 我们的内核侧补丁文件（树内路径）
  local ours=() rel
  while IFS= read -r rel; do
    [[ -n "$rel" && -f "$TREE/$rel" ]] && ours+=("$TREE/$rel")
  done < <(our_kernel_patch_files)
  [[ ${#ours[@]} -gt 0 ]] || { log "  无我方内核补丁，跳过"; return 0; }
  log "  我方内核补丁 ${#ours[@]} 个"

  # 目标文件全集（我方补丁的 --- a/ 路径，排除 /dev/null）
  local list="$WORK/kfiles.txt"
  collect_targets "${ours[@]}" > "$list"
  local prefix="linux-$KVER"   # kernel.org tarball 恒解包到 linux-<ver>/（勿用 tar|head 探测：pipefail+坏包双坑）
  sed "s|^|$prefix/|" "$list" > "$list.prefixed"
  log "  抽取 $(( $(wc -l < "$list") )) 个目标文件"
  extract_needed "$tarball" "$list.prefixed" "$wd"
  # tar 内路径带顶层目录（linux-<ver>/）——应用根目录随之调整，否则 patch
  # 会在错误位置找文件（"No file to patch" 被忽略 ⇒ 假干净！）
  [[ -d "$wd/$prefix" ]] && wd="$wd/$prefix"

  # 按目录（openwrt 顺序：generic backport → pending → hack → 平台）应用：
  #   该目录全部补丁按文件名序（树内版本已含我方对主线补丁的 patch-of-patch 修改）；
  #   只抽取了我方目标文件 ⇒ 碰未抽取文件的补丁会 "No file to patch"（正常，忽略），
  #   只对已抽取文件上的 FAILED 计失败（hunk 按文件独立，级联安全）。
  local failed=0 d pd f
  for d in target/linux/generic/backport-6.18 target/linux/generic/pending-6.18 \
           target/linux/generic/hack-6.18 "$(our_kernel_platform_dir)"; do
    pd="$TREE/$d"
    [[ -d "$pd" ]] || continue
    log "  目录 $d"
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      local out
      out="$(cd "$wd" && patch -p1 --batch --no-backup-if-mismatch < "$pd/$f" 2>&1)" || true
      if printf '%s' "$out" | grep -qE 'FAILED|malformed'; then
        local tag="主线"
        case "$f" in 675-*|961-*|976-*|980-*|9999-*) tag="我方" ;; esac
        echo "  ✗ [$tag] $f"
        printf '%s\n' "$out" | grep -E 'FAILED|malformed' | head -3 | sed 's/^/      /'
        failed=$((failed+1))
      elif printf '%s' "$out" | grep -qiE 'ignored|reversed'; then
        # BSD patch 对"已应用/反向"只提示 ignored；GNU patch（CI）会报 FAILED。
        # 只对我方补丁警示（主线补丁的 ignored 多为部分抽取下的 BSD 假警报，
        # 且主线补丁由 openwrt 自身 CI 背书，以我方 ✗ 与 CI 结论为准）。
        case "$f" in
          675-*|961-*|976-*|980-*|9999-*)
            echo "  ⚠ [我方] $f — patch 提示 ignored/reversed（疑似已应用/superseded，CI 的 GNU patch 会直接判失败）"
            ;;
        esac
      fi
    done < <(cd "$pd" && ls ./*.patch 2>/dev/null | xargs -n1 basename | sort)
  done
  [[ $failed -eq 0 ]] && log "  [kernel] 全部干净 ✓" || log "  [kernel] $failed 个失败 ✗"
  [[ $failed -eq 0 ]] || FAILED_TOTAL=$((FAILED_TOTAL+1))
}

our_kernel_platform_dir() {
  ls -d "$TREE"/target/linux/airoha/patches-* 2>/dev/null | head -1 | sed "s|$TREE/||"
}

# ===== mac80211：backports release + patches/subsys =====
verify_mac80211() {
  log "-- mac80211（backports）--"
  local mk="$TREE/package/kernel/mac80211/Makefile"
  local ver
  ver="$(mkvar "$mk" PKG_SOURCE_VERSION)"
  [[ -n "$ver" ]] || die "mac80211 PKG_SOURCE_VERSION 解析失败"
  local tarball="$CACHE/backports-$ver.tar.zst"
  if [[ ! -s "$tarball" ]] || ! { tar --zstd -tf "$tarball" > /dev/null 2>&1; }; then
    log "  下载 backports-$ver（缓存缺失或损坏）"
    rm -f "$tarball"
    local url
    url="$(curl -fsSL --retry 3 "https://api.github.com/repos/openwrt/backports/releases/tags/backports-v$ver" \
      | grep -oE 'https://[^"]*backports-[^"]*\.tar\.zst' | head -1 || true)"
    [[ -n "$url" ]] || die "取不到 backports-v$ver 资产 URL"
    curl -fsSL --retry 3 -o "$tarball" "$url" || die "backports 下载失败"
    { tar --zstd -tf "$tarball" > /dev/null 2>&1; } || die "backports 包损坏：$tarball"
  fi
  local wd="$WORK/backports"
  mkdir -p "$wd"
  local list="$WORK/bpfiles.txt"
  collect_targets "$TREE/package/kernel/mac80211/patches/subsys"/*.patch > "$list"
  # tar 内路径可能带顶层目录（如 backports-7.2/）——探测并补前缀
  local bprefix="backports-$ver"   # release 资产恒解包到 backports-<ver>/
  sed "s|^|$bprefix/|" "$list" > "$list.prefixed"
  log "  抽取 $(( $(wc -l < "$list") )) 个目标文件"
  extract_needed "$tarball" "$list.prefixed" "$wd"
  # 抽取结果带顶层目录前缀时，应用根目录随之调整（同 kernel 组）
  [[ -d "$wd/$bprefix" ]] && wd="$wd/$bprefix"
  apply_set "mac80211" "$wd" package/kernel/mac80211/patches/subsys || FAILED_TOTAL=$((FAILED_TOTAL+1))
}

# ===== git 包（mt76/regdb/firewall4/rpcd/iwinfo）：Makefile 版本 + 克隆 =====
verify_pkg() { # <包相对目录> <显示名>
  local pkgdir="$1" name="$2"
  log "-- $name --"
  local wd
  wd="$(pkg_workdir "$pkgdir" "$name")"
  apply_set "$name" "$wd" "$pkgdir/patches" || FAILED_TOTAL=$((FAILED_TOTAL+1))
}

want kernel    && verify_kernel
want mac80211  && verify_mac80211
want mt76      && verify_pkg package/kernel/mt76 mt76
want regdb     && verify_pkg package/firmware/wireless-regdb regdb
want firewall4 && verify_pkg package/network/config/firewall4 firewall4
want rpcd      && verify_pkg package/system/rpcd rpcd
want iwinfo    && verify_pkg package/network/utils/iwinfo iwinfo

log ""
if [[ $FAILED_TOTAL -eq 0 ]]; then
  log "== 全部源码级验证通过 =="
else
  log "== $FAILED_TOTAL 组存在失败 =="
fi
exit $((FAILED_TOTAL > 0 ? 1 : 0))
