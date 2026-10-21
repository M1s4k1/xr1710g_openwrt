#!/usr/bin/env bash
# source-resolver.sh — 统一解析 aggregate 与 OpenWrt 来源契约
#
# 规范变量：AGGREGATE_DIR / AGGREGATE_SOURCE_ORIGIN / AGGREGATE_SOURCE_COMMIT
#           OPENWRT_SOURCE / OPENWRT_REF
# 兼容变量：UPSTREAM_DIR / upstream_ref / TREE / OPENWRT_DIR
#
# aggregate 默认是项目内置快照；显式传入目录时仍支持旧的外部物化目录。
# 该脚本既可 source，也可直接执行 --print。它不会 clone、fetch 或写状态文件。
set -euo pipefail

source_resolver_root="${SOURCE_RESOLVER_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

source_resolve() {
  local root="${1:-$source_resolver_root}"
  local source_arg="${2:-}"
  local ref_arg="${3:-}"
  local dir_arg="${4:-}"
  local lock="$root/config/source-lock.env"
  local env_aggregate_source="${AGGREGATE_SOURCE:-}"
  local env_aggregate_ref="${AGGREGATE_REF:-}"
  local env_openwrt_source="${OPENWRT_SOURCE:-}"
  local env_openwrt_ref="${OPENWRT_REF:-}"
  local env_legacy_ref="${UPSTREAM_REF:-${upstream_ref:-}}"
  local lock_aggregate_mode="" lock_aggregate_dir="" lock_aggregate_origin="" lock_aggregate_commit=""
  local lock_openwrt_source="" lock_openwrt_ref="" lock_linux_version=""

  if [[ -f "$lock" ]]; then
    # 只读取受控的规范变量，不 source 外部文本，避免覆盖调用方环境。
    lock_aggregate_mode="$(grep -E '^AGGREGATE_MODE=' "$lock" | head -1 | cut -d= -f2- || true)"
    lock_aggregate_dir="$(grep -E '^AGGREGATE_DIR=' "$lock" | head -1 | cut -d= -f2- || true)"
    lock_aggregate_origin="$(grep -E '^AGGREGATE_SOURCE_ORIGIN=' "$lock" | head -1 | cut -d= -f2- || true)"
    lock_aggregate_commit="$(grep -E '^AGGREGATE_SOURCE_COMMIT=' "$lock" | head -1 | cut -d= -f2- || true)"
    # 兼容旧 source-lock.env；这些字段不再作为默认物化来源。
    [[ -n "$lock_aggregate_origin" ]] || lock_aggregate_origin="$(grep -E '^AGGREGATE_SOURCE=' "$lock" | head -1 | cut -d= -f2- || true)"
    [[ -n "$lock_aggregate_commit" ]] || lock_aggregate_commit="$(grep -E '^AGGREGATE_REF=' "$lock" | head -1 | cut -d= -f2- || true)"
    lock_openwrt_source="$(grep -E '^OPENWRT_SOURCE=' "$lock" | head -1 | cut -d= -f2- || true)"
    lock_openwrt_ref="$(grep -E '^OPENWRT_REF=' "$lock" | head -1 | cut -d= -f2- || true)"
    lock_linux_version="$(grep -E '^LINUX_VERSION=' "$lock" | head -1 | cut -d= -f2- || true)"
  fi

  AGGREGATE_SOURCE_RESOLVED="${source_arg:-${env_aggregate_source:-${lock_aggregate_mode:-embedded}}}"
  AGGREGATE_REF_RESOLVED="${ref_arg:-${env_aggregate_ref:-${env_legacy_ref:-${lock_aggregate_commit:-builtin}}}}"
  OPENWRT_SOURCE_RESOLVED="${env_openwrt_source:-$lock_openwrt_source}"
  OPENWRT_REF_RESOLVED="${env_openwrt_ref:-$lock_openwrt_ref}"
  LINUX_VERSION_RESOLVED="${lock_linux_version:-}"

  if [[ -n "$env_aggregate_ref" && -n "$env_legacy_ref" && "$env_aggregate_ref" != "$env_legacy_ref" ]]; then
    echo "✗ AGGREGATE_REF 与 upstream_ref/UPSTREAM_REF 冲突" >&2
    return 1
  fi
  if [[ -n "$source_arg" && -n "$env_aggregate_source" && "$source_arg" != "$env_aggregate_source" ]]; then
    echo "✗ --aggregate-source 与 AGGREGATE_SOURCE 冲突" >&2
    return 1
  fi
  if [[ -n "$ref_arg" && -n "$env_aggregate_ref" && "$ref_arg" != "$env_aggregate_ref" ]]; then
    echo "✗ --aggregate-ref 与 AGGREGATE_REF 冲突" >&2
    return 1
  fi

  AGGREGATE_DIR_RESOLVED="$dir_arg"
  if [[ -z "$AGGREGATE_DIR_RESOLVED" && -d "$source_arg" ]]; then
    AGGREGATE_DIR_RESOLVED="$source_arg"
  fi
  if [[ -z "$AGGREGATE_DIR_RESOLVED" ]]; then
    AGGREGATE_DIR_RESOLVED="${UPSTREAM_DIR:-}"
  fi
  if [[ -z "$AGGREGATE_DIR_RESOLVED" && -n "$lock_aggregate_dir" ]]; then
    if [[ "$lock_aggregate_dir" = /* ]]; then
      AGGREGATE_DIR_RESOLVED="$lock_aggregate_dir"
    else
      AGGREGATE_DIR_RESOLVED="$root/$lock_aggregate_dir"
    fi
  fi
  if [[ -z "$AGGREGATE_DIR_RESOLVED" ]]; then
    # 默认只使用项目内置快照。外部目录必须通过 --upstream、--aggregate-source
    # 或 UPSTREAM_DIR 显式传入，避免构建结果随邻近 checkout 静默漂移。
    for candidate in "$root/aggregate"; do
      if [[ -d "$candidate" && -f "$candidate/patches/MANIFEST" ]]; then
        AGGREGATE_DIR_RESOLVED="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$AGGREGATE_DIR_RESOLVED" ]]; then
    echo "✗ 未找到项目内置 aggregate；请设置 UPSTREAM_DIR 或显式传入 --aggregate-source <目录>" >&2
    return 1
  fi
  [[ -d "$AGGREGATE_DIR_RESOLVED" ]] || { echo "✗ aggregate 目录不存在：$AGGREGATE_DIR_RESOLVED" >&2; return 1; }
  [[ -f "$AGGREGATE_DIR_RESOLVED/patches/MANIFEST" ]] || { echo "✗ aggregate 缺少 patches/MANIFEST：$AGGREGATE_DIR_RESOLVED" >&2; return 1; }
  AGGREGATE_DIR_RESOLVED="$(cd "$AGGREGATE_DIR_RESOLVED" && pwd)"

  if [[ "$AGGREGATE_DIR_RESOLVED" == "$root/aggregate" && -n "$lock_aggregate_commit" ]]; then
    AGGREGATE_COMMIT_RESOLVED="$lock_aggregate_commit"
    AGGREGATE_SOURCE_RESOLVED="${lock_aggregate_mode:-embedded}"
    [[ -n "$ref_arg" || -n "$env_aggregate_ref" || -n "$env_legacy_ref" ]] || \
      AGGREGATE_REF_RESOLVED="${lock_aggregate_commit:-builtin}"
  elif [[ -d "$AGGREGATE_DIR_RESOLVED/.git" ]]; then
    AGGREGATE_COMMIT_RESOLVED="$(git -C "$AGGREGATE_DIR_RESOLVED" rev-parse HEAD)"
    [[ -n "$source_arg" ]] && AGGREGATE_SOURCE_RESOLVED="$source_arg" || AGGREGATE_SOURCE_RESOLVED="external"
  else
    AGGREGATE_COMMIT_RESOLVED="unknown"
    AGGREGATE_SOURCE_RESOLVED="external"
  fi
  if [[ -z "$AGGREGATE_REF_RESOLVED" || "$AGGREGATE_REF_RESOLVED" == "auto" ]]; then
    AGGREGATE_REF_RESOLVED="$AGGREGATE_COMMIT_RESOLVED"
  fi

  export AGGREGATE_DIR_RESOLVED AGGREGATE_SOURCE_RESOLVED AGGREGATE_REF_RESOLVED
  export AGGREGATE_COMMIT_RESOLVED OPENWRT_SOURCE_RESOLVED OPENWRT_REF_RESOLVED LINUX_VERSION_RESOLVED
}

source_print() {
  source_resolve "$@"
  printf 'AGGREGATE_SOURCE=%s\n' "$AGGREGATE_SOURCE_RESOLVED"
  printf 'AGGREGATE_REF=%s\n' "$AGGREGATE_REF_RESOLVED"
  printf 'AGGREGATE_DIR=%s\n' "$AGGREGATE_DIR_RESOLVED"
  printf 'AGGREGATE_COMMIT=%s\n' "$AGGREGATE_COMMIT_RESOLVED"
  printf 'OPENWRT_SOURCE=%s\n' "$OPENWRT_SOURCE_RESOLVED"
  printf 'OPENWRT_REF=%s\n' "$OPENWRT_REF_RESOLVED"
  printf 'LINUX_VERSION=%s\n' "$LINUX_VERSION_RESOLVED"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --print)
      shift
      source_print "$@"
      ;;
    -h|--help)
      sed -n '2,10p' "$0"
      ;;
    *)
      echo "用法：$0 --print" >&2
      exit 1
      ;;
  esac
fi
