#!/usr/bin/env bash
# audit-local.sh — 本仓库 rules / 资源自检
#
# 检查项：
#   [A] rules 语法：三类操作符合法、每条必带「理由」
#   [B] rules 目标存在：- / ^ / + 的补丁路径都能在上游 MANIFEST 或 local/patches 找到
#   [C] 本地补丁文件存在：local/patches/*.patch 都在 rules 里被「+」引用
#   [D] 配置归属纪律：local/files/ 必须为空（配置改动一律走 patch，不靠 files 覆盖）
#       ——历史教训：曾用 local/files/etc/config/{network,wireless} 整文件覆盖上游、
#         并夹带 SSID/密码/自定义 MAC 等**个人配置**，导致固件绑定特定机器。
#         现约定：B 类环境适配一律由 local/patches/96xx-* 改写上游 files/ 源文件。
#   [E] 端口命名/网段一致性：9501（改名）↔ 9601（引用同一套名字 + 钉死网段）↔ 9602（LED）
#   [F] 固件不含个人配置：全仓扫描 SSID / 密码 / 自定义 MAC 等 C 类残留
#
# 用法：scripts/audit-local.sh [--upstream DIR]
# 退出码：0 全过；1 有红
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${UPSTREAM_DIR:-}"
if [[ -z "$UPSTREAM" ]]; then
  for u in "$ROOT/../xr1710g-openwrt" "$ROOT/../../xr1710g-openwrt" "$ROOT/upstream"; do
    [[ -d "$u" && -f "$u/patches/MANIFEST" ]] && UPSTREAM="$u" && break
  done
  UPSTREAM="${UPSTREAM:-$ROOT/../xr1710g-openwrt}"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --upstream) UPSTREAM="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

RED=0
fail() { echo "  [FAIL] $*" >&2; RED=1; }
ok()   { echo "  [ok]   $*"; }

RULES="$ROOT/local/manifest.rules"
SAFE="$ROOT/local/manifest.rules.v1-safe"
MF="$UPSTREAM/patches/MANIFEST"

echo "== [A] rules 语法与理由 =="
for R in "$RULES" "$SAFE"; do
  [[ -f "$R" ]] || { fail "缺文件 $R"; continue; }
  n_bad=0
  while IFS= read -r line; do
    s="${line%%# *}"
    # 跳过注释与空行
    [[ -z "${s// }" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # 规则行必须匹配 "符 路径"
    if ! [[ "$line" =~ ^[[:space:]]*[-^+][[:space:]]+[^[:space:]]+\.patch ]]; then
      fail "$(basename "$R"): 非法规则行：$line"; n_bad=$((n_bad+1)); continue
    fi
    # 必带理由
    if ! [[ "$line" == *"理由"* ]]; then
      fail "$(basename "$R"): 缺理由：$line"; n_bad=$((n_bad+1))
    fi
  done < "$R"
  [[ "$n_bad" == 0 ]] && ok "$(basename "$R") 语法与理由齐全"
done

echo "== [B] rules 目标存在性 =="
[[ -f "$MF" ]] || { fail "找不到上游 MANIFEST：$MF"; echo "（跳过 B/C）"; }
if [[ -f "$MF" ]]; then
  # 注：macOS 自带 bash 3.2 无 mapfile，用 while-read 兼容
  MF_PATHS=()
  while IFS= read -r _p; do [[ -n "$_p" ]] && MF_PATHS+=("$_p"); done \
    < <(grep -oE 'patches/[^[:space:]]+\.patch' "$MF" | sort -u)
  miss=0
  for R in "$RULES" "$SAFE"; do
    [[ -f "$R" ]] || continue
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*([-^+])[[:space:]]+([^[:space:]]+) ]] || continue
      op="${BASH_REMATCH[1]}"; p="${BASH_REMATCH[2]}"
      if [[ "$op" == "+" ]]; then
        # 语义路径 "patches/local/9501-xxx.patch" 对应物理文件 local/patches/9501-xxx.patch
        case "$p" in
          patches/local/*) lp="$ROOT/local/patches/${p#patches/local/}" ;;
          patches/*)       lp="$ROOT/local/patches/${p#patches/}" ;;
          *)               lp="$ROOT/local/$p" ;;
        esac
        [[ -f "$lp" ]] || { fail "$(basename "$R"): 本地补丁不存在 ${lp#$ROOT/}"; miss=$((miss+1)); }
      else
        found=0
        for m in "${MF_PATHS[@]}"; do [[ "$m" == "$p" ]] && { found=1; break; }; done
        [[ "$found" == 1 ]] || { fail "$(basename "$R"): 目标不在 MANIFEST：$p"; miss=$((miss+1)); }
      fi
    done < "$R"
  done
  [[ "$miss" == 0 ]] && ok "全部 rules 目标可解析"
fi

echo "== [C] 本地补丁都被引用 =="
if compgen -G "$ROOT/local/patches/*.patch" >/dev/null; then
  unref=0
  for f in "$ROOT/local/patches/"*.patch; do
    b="patches/local/$(basename "$f")"
    grep -qF "$b" "$RULES" || { fail "本地补丁未被 rules 引用：$b"; unref=$((unref+1)); }
  done
  [[ "$unref" == 0 ]] && ok "local/patches 全部被 rules 引用"
else
  ok "（无本地补丁）"
fi

echo "== [D] 配置归属纪律（local/files/ 必须为空）=="
if [[ -e "$ROOT/local/files" ]]; then
  if [[ -d "$ROOT/local/files" ]]; then
    leftover=0
    while IFS= read -r f; do
      # ⚠ $f 后紧跟非 ASCII 必须用 ${f} 界定：否则 bash 把 UTF-8 首字节并入变量名，
      #   set -u 下报 `f\xef: unbound variable`（本项目已复发多次，见 macos-bash-portability）。
      fail "local/files/ 仍有遗留：${f}（配置改动请改写成 local/patches/96xx-*.patch，勿 Files 覆盖）"
      leftover=$((leftover+1))
    done < <(find "$ROOT/local/files" -type f 2>/dev/null)
    [[ "$leftover" == 0 ]] && ok "local/files/ 为空目录"
  else
    fail "local/files 存在但不是目录"
  fi
else
  ok "local/files/ 不存在（配置改动全部走 patch）"
fi
[[ -f "$ROOT/local/seed.local.diff" ]] && ok "local/seed.local.diff" || fail "缺 local/seed.local.diff"

echo "== [E] 端口命名 / 网段一致性（9501 ↔ 9601 ↔ 9602）=="
P9501="$ROOT/local/patches/9501-xr1710g-netdev-name-yyh-compat.patch"
P9601="$ROOT/local/patches/9601-xr1710g-network-yyh-align.patch"
P9602="$ROOT/local/patches/9602-xr1710g-led-yyh-align.patch"
for p in "$P9501" "$P9601" "$P9602"; do
  [[ -f "$p" ]] || fail "缺本地补丁：$(basename "$p")"
done
# 辅助：取补丁里的**新增行**（以 + 开头、排除 +++ 文件头）。
# 必须只看 + 行：diff 的 - 行是"改前旧值"，把检测误判为仍在使用旧名。
_new_lines() { grep -E '^\+' "$1" | grep -vE '^\+\+\+' ; }

if [[ -f "$P9501" && -f "$P9601" && -f "$P9602" ]]; then
  # 9501 产出：WAN=eth1、LAN=eth2 lan2 lan3
  grep -q 'eth2 lan2 lan3' "$P9501" && ok "9501 产出 LAN=eth2 lan2 lan3" \
    || fail "9501 未产出预期 LAN 命名"
  grep -q '"eth1"' "$P9501" && ok "9501 产出 WAN=eth1" \
    || fail "9501 未产出预期 WAN 命名"
  # 9601 必须与 9501 引用同一套名字（只看新增行，避免被 diff 的旧值 - 行误导）
  _new_lines "$P9601" | grep -q "list ports 'eth2'" && ok "9601 br-lan 含 eth2（与 9501 一致）" \
    || fail "9601 br-lan 未含 eth2"
  _new_lines "$P9601" | grep -qE "option ipaddr '192\.168\.2\.1'" && ok "9601 LAN 网段钉死 192.168.2.1" \
    || fail "9601 未把 LAN 网段改为 192.168.2.1"
  _new_lines "$P9601" | grep -q "option device 'eth1'" && ok "9601 WAN device = eth1（与 9501 一致）" \
    || fail "9601 WAN device 不是 eth1"
  # 9601 新增行不得再引用改名后的失效名（出现即说明 9601 与 9501 脱钩）
  bad=0
  while IFS= read -r nm; do
    fail "9601 新增行仍引用失效旧名：option device '$nm'（9501 后已不存在）"
    bad=$((bad+1))
  done < <(_new_lines "$P9601" | grep -oE "option device '(wan|lan1)'" | sort -u)
  [[ "$bad" == 0 ]] && ok "9601 无失效的旧 device 名（wan/lan1）"
  # 9602 LED dev 必须落在 9501 后的新名字集合里
  bad2=0
  while IFS= read -r d; do
    case "$d" in
      lan2|eth1|eth2|lan3) ;;
      *) fail "9602 LED dev 落在未知端口名：$d"; bad2=$((bad2+1)) ;;
    esac
  done < <(_new_lines "$P9602" | grep -oE "option dev '[^']+'" | sed "s/option dev '//;s/'//" | sort -u)
  [[ "$bad2" == 0 ]] && ok "9602 LED dev 均在 9501 后的合法名集合内"
fi

echo "== [F] 固件不含个人配置（C 类残留扫描）=="
# 扫描范围：local/ 下所有会被打进固件的素材（rules / patches / seed）
# 命中项即"把个人配置编进固件"的高危信号，必须人工确认后才能留。
secret=0
# ⚠ macOS 陷阱（第 4 次复发）：BSD grep 的 ERE **不支持 \b**（也不支持 \s，
#   须写 [[:space:]]）。用 \b 做词锚会**静默零命中** ⇒ 检测假通过。
#   这里改用「非 hex 字符边界」：`[^0-9a-fA-F:]` 或行首/行尾，跨平台可靠。
_WB='(^|[^0-9a-fA-F:])'
# ① 疑似自定义 MAC（Gemtek OUI 00:58:28；排除纯注释里的示例）
while IFS= read -r hit; do
  fail "疑似自定义 MAC：$hit"
  secret=$((secret+1))
done < <(grep -rnoE "${_WB}(00:58:28:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2})" \
          "$ROOT/local" 2>/dev/null | head -5)
# ② wifi key / 潜在明文口令
while IFS= read -r hit; do
  fail "疑似明文口令残留：$hit"
  secret=$((secret+1))
done < <(grep -rnoE "option key '[^']+'" "$ROOT/local" 2>/dev/null | head -5)
# ③ SSID 硬编码
while IFS= read -r hit; do
  fail "疑似 SSID 硬编码：$hit"
  secret=$((secret+1))
done < <(grep -rnoE "option ssid '[^']+'" "$ROOT/local" 2>/dev/null | head -5)
[[ "$secret" == 0 ]] && ok "local/ 内无 MAC / 口令 / SSID 等个人配置残留"

echo "== [G] **git 历史**不含个人配置（push 到公开仓库前必查）=="
# [F] 只扫工作树 ⇒ 删掉文件就"变绿"，但 blob 仍在历史里，push 后照样泄露。
#   （2026-09-17 实证：工作树已清理，但 3e32caf/81c1082 的历史里仍有
#    Wi-Fi 密码 / SSID / WAN MAC；[F] 却报 PASS —— 典型假绿。）
#   这里改为扫全部历史的 diff，确保"曾经出现过"也算命中。
if [[ ! -d "$ROOT/.git" ]]; then
  ok "（非 git 仓库，跳过）"
else
  hist=0
  # 只在历史 diff 里搜；用 -F 固定串，避免正则转义问题
  # 注意：必须排除本脚本自身（scripts/audit-local.sh 末尾就含这些特征串，
  #   否则 [G] 会"自己检自己"永远 FAIL，闸门失效）。pathspec exclude 语法。
  PAT_FILE="$(mktemp)"
  # 检测特征串以 base64 存储：避免仓库文件本身含明文泄露值（否则 push 公开后仍暴露）。
  #   [G] 运行时解码再比对；解码出的串不会落在被 git 跟踪的文件里。
  for b64 in 'MTMtMjAyLm5ldA==' 'b3B0aW9uIHNzaWQgJ1hSMTcxMEcn' 'MDA6NTg6Mjg6ZDc6OWM6N2U='; do
    printf '%s\n' "$(printf '%s' "$b64" | base64 -d)" >> "$PAT_FILE"
  done
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    n="$(git -C "$ROOT" log --all -p -- . ':(exclude)scripts/audit-local.sh' 2>/dev/null | grep -F -c "$pat" || true)"
    if [[ "${n:-0}" != "0" ]]; then
      fail "git 历史中残留个人配置：${pat}（${n} 处）"
      hist=$((hist+1))
    fi
  done < "$PAT_FILE"
  rm -f "$PAT_FILE"
  # 作者身份：只盯"已知的泄露企业域"，不误杀用户正常的 GitHub noreply 邮箱。
  #   （早期版本对非 noreply 一律报红，会把 <id>+user@users.noreply.github.com> 也误判）
  while IFS= read -r au; do
    [[ -z "$au" ]] && continue
    fail "提交作者含泄露邮箱（公开后暴露）：${au}"
    hist=$((hist+1))
  done < <(git -C "$ROOT" log --all --format='%an <%ae>' 2>/dev/null \
           | sort -u | grep -E '@xd\.com' || true)
  if [[ "$hist" == 0 ]]; then
    ok "git 历史中无个人配置与真实邮箱残留"
  else
    echo "       → 清理：新建干净仓库（推荐，本项目历史短）或用 git filter-repo 重写历史；" >&2
    echo "         并在 GitHub 设置「Keep my email addresses private」" >&2
  fi
fi

echo
if [[ "$RED" == 1 ]]; then
  echo "AUDIT FAILED" >&2
  exit 1
fi
echo "AUDIT PASSED"
