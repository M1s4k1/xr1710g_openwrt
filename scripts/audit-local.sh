#!/usr/bin/env bash
# audit-local.sh — 本仓库自检（架构转向后：OpenWrt 主线为基座）
#
# 检查项：
#   [A] 收录清单语法：每行一个补丁文件名，必须带「理由」
#   [B] 清单补丁存在：清单中每个文件都在 local/patches/ 下
#   [C] 收录完整：local/patches/*.patch 都被 func 或 v1-safe 清单收录
#   [D] 配置归属纪律：local/files/ 必须为空（配置改动一律走 patch，不靠 files 覆盖）
#   [E] 端口命名/网段一致性：9501（改名）↔ 9601（同一套名字 + 钉死网段）↔ 9602（LED）
#   [F] 固件不含个人配置：全仓扫描 SSID / 密码 / 自定义 MAC 等 C 类残留
#   [G] git 历史不含个人配置（push 到公开仓库前必查）
#   [H] seed 写法铁律（F164）：活动 CONFIG_* 行不得带尾随注释
#
# 用法：scripts/audit-local.sh
# 退出码：0 全过；1 有红
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RED=0
fail() { echo "  [FAIL] $*" >&2; RED=1; }
ok()   { echo "  [ok]   $*"; }
RULES="$ROOT/local/manifest.rules"
SAFE="$ROOT/local/manifest.rules.v1-safe"

echo "== [A] 收录清单语法与理由 =="
for R in "$RULES" "$SAFE"; do
  [[ -f "$R" ]] || { fail "缺文件 $R"; continue; }
  n_bad=0
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    # 清单行：<补丁文件名>.patch [# 理由]
    if ! [[ "$line" =~ ^[[:space:]]*[^[:space:]#]+\.patch([[:space:]]|#|$) ]]; then
      fail "$(basename "$R"): 非法清单行：$line"; n_bad=$((n_bad+1)); continue
    fi
    [[ "$line" == *"理由"* ]] || { fail "$(basename "$R"): 缺理由：$line"; n_bad=$((n_bad+1)); }
  done < "$R"
  [[ "$n_bad" == 0 ]] && ok "$(basename "$R") 语法与理由齐全"
done

echo "== [B] 清单补丁存在 =="
miss=0
for R in "$RULES" "$SAFE"; do
  [[ -f "$R" ]] || continue
  while IFS= read -r entry; do
    # 兼容复制型行：<file>.patch -> <target-dir>，取 -> 前的文件名
    p="${entry%% -> *}"
    [[ -n "$p" ]] || continue
    [[ -f "$ROOT/local/patches/$p" ]] || { fail "$(basename "$R"): 补丁不存在 local/patches/$p"; miss=$((miss+1)); }
  done < <(grep -vE '^\s*#|^\s*$' "$R" | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//')
done
[[ "$miss" == 0 ]] && ok "清单补丁全部存在"

echo "== [C] 收录完整（local/patches 都被某档收录）=="
if compgen -G "$ROOT/local/patches/*.patch" >/dev/null; then
  unref=0
  for f in "$ROOT/local/patches/"*.patch; do
    b="$(basename "$f")"
    grep -qF "$b" "$RULES" || grep -qF "$b" "$SAFE" \
      || { fail "本地补丁未被任何档位收录：$b"; unref=$((unref+1)); }
  done
  [[ "$unref" == 0 ]] && ok "local/patches 全部被收录"
else
  ok "（无本地补丁）"
fi

echo "== [D] 配置归属纪律（local/files/ 必须为空）=="
if [[ -e "$ROOT/local/files" ]]; then
  if [[ -d "$ROOT/local/files" ]]; then
    leftover=0
    while IFS= read -r f; do
      # ⚠ $f 后紧跟非 ASCII 必须用 ${f} 界定（bash 3.2 UTF-8 变量名坑，见 macos-bash-portability）
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
# 辅助：取补丁里的**新增行**（以 + 开头、排除 +++ 文件头）
_new_lines() { grep -E '^\+' "$1" | grep -vE '^\+\+\+' ; }

if [[ -f "$P9501" && -f "$P9601" && -f "$P9602" ]]; then
  grep -q 'eth2 lan2 lan3' "$P9501" && ok "9501 产出 LAN=eth2 lan2 lan3" \
    || fail "9501 未产出预期 LAN 命名"
  grep -q '"eth1"' "$P9501" && ok "9501 产出 WAN=eth1" \
    || fail "9501 未产出预期 WAN 命名"
  _new_lines "$P9601" | grep -q "list ports 'eth2'" && ok "9601 br-lan 含 eth2（与 9501 一致）" \
    || fail "9601 br-lan 未含 eth2"
  _new_lines "$P9601" | grep -qE "option ipaddr '192\.168\.2\.1'" && ok "9601 LAN 网段钉死 192.168.2.1" \
    || fail "9601 未把 LAN 网段改为 192.168.2.1"
  _new_lines "$P9601" | grep -q "option device 'eth1'" && ok "9601 WAN device = eth1（与 9501 一致）" \
    || fail "9601 WAN device 不是 eth1"
  bad=0
  while IFS= read -r nm; do
    fail "9601 新增行仍引用失效旧名：option device '$nm'（9501 后已不存在）"
    bad=$((bad+1))
  done < <(_new_lines "$P9601" | grep -oE "option device '(wan|lan1)'" | sort -u)
  [[ "$bad" == 0 ]] && ok "9601 无失效的旧 device 名（wan/lan1）"
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
secret=0
# ⚠ macOS 陷阱：BSD grep 的 ERE 不支持 \b / \s（静默零命中 ⇒ 假绿）。
#   用「非 hex 字符边界」：`[^0-9a-fA-F:]` 或行首/行尾，跨平台可靠。
_WB='(^|[^0-9a-fA-F:])'
while IFS= read -r hit; do
  fail "疑似自定义 MAC：$hit"
  secret=$((secret+1))
done < <(grep -rnoE "${_WB}(00:58:28:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2})" \
        "$ROOT/local" 2>/dev/null | head -5)
while IFS= read -r hit; do
  fail "疑似明文口令残留：$hit"
  secret=$((secret+1))
done < <(grep -rnoE "option key '[^']+'" "$ROOT/local" 2>/dev/null | head -5)
while IFS= read -r hit; do
  fail "疑似 SSID 硬编码：$hit"
  secret=$((secret+1))
done < <(grep -rnoE "option ssid '[^']+'" "$ROOT/local" 2>/dev/null | head -5)
[[ "$secret" == 0 ]] && ok "local/ 内无 MAC / 口令 / SSID 等个人配置残留"

echo "== [G] **git 历史**不含个人配置（push 到公开仓库前必查）=="
if [[ ! -d "$ROOT/.git" ]]; then
  ok "（非 git 仓库，跳过）"
else
  hist=0
  PAT_FILE="$(mktemp)"
  # 检测特征串以 base64 存储：避免仓库文件本身含明文泄露值
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

echo "== [H] seed 写法铁律（F164：活动行不得带尾随注释）=="
trail=0
while IFS= read -r hit; do
  fail "seed 行带尾随注释（kconfig 会截断 ⇒ 静默丢符号）：$hit"
  trail=$((trail+1))
done < <(grep -nE '^CONFIG_[A-Za-z0-9_]+=[ym][[:space:]]+#' "$ROOT/local/seed.local.diff" 2>/dev/null | head -5)
[[ "$trail" == 0 ]] && ok "seed 无尾随注释"

echo
if [[ "$RED" == 1 ]]; then
  echo "AUDIT FAILED" >&2
  exit 1
fi
echo "AUDIT PASSED"
