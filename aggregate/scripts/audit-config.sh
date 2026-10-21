#!/usr/bin/env bash
# audit-config.sh — seed 符号审计：核对 seed 的活动 CONFIG_* 是否**按要求的取值**进入 .config
# 用法：audit-config.sh <seed.diff> <.config>
#
# 背景（FIXES F15）：kconfig 对未知符号静默忽略 —— 拼错的符号不会报错，只是不被选中。
# 本脚本把所有活动 seed 符号逐一在 .config 中核对（=y / =m / "..." / 顶层 = 均算命中），
# 缺任何一个即列出并退出 1（修复而不是降级：符号写错就修，不让核心能力静默丢失）。
#
# 背景（FIXES F164，2026-09-14）——**取值盲区**：
#   旧版判据是 `grep -q "^${sym}="`，只查**存在性**、不查**取值**。于是：
#     ① seed 写 `CONFIG_PACKAGE_x=y`，kconfig 因依赖/冲突把它解析成 `=m`（只编成模块、
#        **不装进镜像**）时，旧版照样打 ✓ —— 能力静默丢失。活例：seed 的 wpad-openssl=y
#        实际被解析为 =m（镜像里装的是 DEFAULT_VARIANT 的 wpad-basic-mbedtls，丢 802.11s mesh）；
#     ② 字符串/整数符号被改成别的值时同样查不出来。
#   新版逐符号比对**取值**：
#     want=y 且 got=m ⇒ **✗ 失败**（构建出来但不装 = 静默能力丢失）；
#                       唯一豁免：seed 该行注释里带 `F164-ALLOW-RESOLVED-M:` 标记
#                       （显式登记的降级：输出 ⚠ 并计数，绝不静默）；
#     want=y 且 got≠y ⇒ ✗；want=m 且 got∈{m,y} ⇒ ✓（y 比要求更强，无损失）；
#     want=n 且 got≠n ⇒ ✗（被依赖强制打开）；其它（字符串/整数）⇒ 逐字符比对。
#   另：seed 行若带**尾随注释**（kconfig 实测容忍但属脆弱写法，见 F164）→ 截断后比对并打 ⚠。
set -euo pipefail

SEED="${1:-config/seed-config.diff}"
CFG="${2:-.config}"
[[ -f "$SEED" ]] || { echo "错误：无 $SEED" >&2; exit 1; }
[[ -f "$CFG" ]] || { echo "错误：无 $CFG（先 make defconfig）" >&2; exit 1; }

missing=0        # 符号完全没进 .config（旧版已覆盖的用例）
mismatch=0       # 进了但取值不符（F164 新覆盖）
allowed=0        # 已登记豁免（F164-ALLOW-RESOLVED-M）
fragile=0        # 尾随注释等脆弱写法
checked=0
blocknote=""     # 紧邻上一行的注释块（承载 F164-ALLOW-RESOLVED-M 标记）

while IFS= read -r raw; do
  line="${raw%$'\r'}"                       # 容忍 CRLF

  # ── 注释行：若带 F164-ALLOW-RESOLVED-M 标记，记给**紧随其后的**符号行 ──
  # 标记注释必须紧邻符号行（中间不能有空行）；标记也可以写在符号行的尾随注释里。
  if [[ "$line" =~ ^[[:space:]]*# ]]; then
    if [[ "$line" == *F164-ALLOW-RESOLVED-M* ]]; then
      blocknote="$line"           # 保留标记原文，供后面 `*F164-ALLOW-RESOLVED-M*` 判定
    fi
    continue
  fi
  [[ -z "${line//[[:space:]]/}" ]] && { blocknote=""; continue; }   # 空行：切断注释块
  [[ -n "${line//[[:space:]]/}" ]] || continue

  sym="${line%%=*}"
  case "$sym" in
    ''|\#*) blocknote=""; continue ;;       # 注释 / `# CONFIG_x is not set`
    CONFIG_*) ;;
    *) blocknote=""; continue ;;
  esac
  checked=$((checked+1))

  # ── 取 seed 要求的取值 ──
  if [[ "$line" == *=* ]]; then
    want="${line#*=}"
  else
    want="y"                                # 裸 CONFIG_X：kconfig 习惯视作 =y
    echo "⚠ seed 行缺 '='（按 =y 解析，建议补全）：$sym" >&2
    fragile=$((fragile+1))
  fi

  note=""
  if [[ "$want" == *[[:space:]]#* ]]; then
    # 尾随注释：kconfig 实测在空白/`#` 前截断取值（F164 实测 9 行均按此解析），
    # 但属脆弱写法（kconfig/上游行为一变就会静默丢符号）—— 截断后比对 + 警告。
    note="${want#*#}"
    want="${want%%[[:space:]]#*}"
    echo "⚠ seed 行带尾随注释（脆弱写法，建议独占一行）：$sym" >&2
    fragile=$((fragile+1))
  fi
  want="${want%"${want##*[![:space:]]}"}"   # 去尾空白
  note="$blocknote $note"                   # 紧邻注释块的标记 + 行尾标记，合并
  blocknote=""

  # ── 取 .config 实际取值 ──
  if grep -q "^${sym}=" "$CFG"; then
    got="$(grep -m1 "^${sym}=" "$CFG")"; got="${got#*=}"
  elif grep -q "^# ${sym} is not set\$" "$CFG"; then
    got="n"
  else
    got=""                                  # 完全无此行
  fi

  # ── 逐取值比对（F164） ──
  case "$want" in
    y)
      case "$got" in
        y) ;;
        m)
          if [[ "$note" == *F164-ALLOW-RESOLVED-M* ]]; then
            echo "⚠ seed 要求 =y 但 .config 解析为 =m（**已登记降级**，不静默）：$sym" >&2
            echo "    登记理由：${note#*F164-ALLOW-RESOLVED-M:}" >&2
            allowed=$((allowed+1))
          else
            echo "✗ seed 要求 =y 但 .config 为 =m（**构建成模块但不装进镜像** = 能力静默丢失；" >&2
            echo "  查依赖/冲突为何把它压到 m，修 seed 或补齐依赖；确属已知降级则在 seed 该行注释里写 F164-ALLOW-RESOLVED-M: <理由>）：$sym" >&2
            mismatch=$((mismatch+1))
          fi ;;
        n) echo "✗ seed 要求 =y 但 .config 为 n（依赖未满足/被禁用）：$sym" >&2
           mismatch=$((mismatch+1)) ;;
        *) echo "✗ seed 符号未进 .config：$sym（seed 拼写或上游包名已变？——查证后修 seed，勿跳过）" >&2
           missing=$((missing+1)) ;;
      esac ;;
    m)
      case "$got" in
        m|y) ;;                             # y 比要求更强：无能力损失
        *) echo "✗ seed 要求 =m 但 .config 为 ${got:-<无此行>}：$sym" >&2
           mismatch=$((mismatch+1)) ;;
      esac ;;
    n)
      case "$got" in
        n) ;;
        *) echo "✗ seed 要求 =n 但 .config 为 ${got:-<无此行>}（被依赖强制打开）：$sym" >&2
           mismatch=$((mismatch+1)) ;;
      esac ;;
    *)
      if [[ "$got" != "$want" ]]; then
        echo "✗ seed 要求 =$want 但 .config 为 ${got:-<无此行>}：$sym" >&2
        mismatch=$((mismatch+1))
      fi ;;
  esac
done < "$SEED"   # 必须喂**整份文件**：注释行要参与（承载 F164-ALLOW-RESOLVED-M 标记）

if (( missing > 0 || mismatch > 0 )); then
  echo "seed 符号审计失败：缺失 $missing 个、取值不符 $mismatch 个（共审 $checked 个活动符号）" >&2
  exit 1
fi
echo "✓ seed 符号审计通过（$checked 个活动符号取值全部命中；已登记降级 $allowed，脆弱写法警告 $fragile）"
