#!/usr/bin/env bash
# audit-order.sh — 档位视图一致性审计：patches/ORDER ↔ patches/MANIFEST（只读、确定性）
#
# 背景（2026-09-14 F164）：ORDER 是「档位评审视图」，MANIFEST 是「权威应用清单」。
#   历史上 ORDER 长期不同步：2026-09-14 实测 ORDER 96 条 vs MANIFEST 136 条，
#   MANIFEST-only 高达 49 条（整条 SOE 10..28、9044/9045/9050..9066、mt76 0013..0022、
#   firewall4/rpcd/iwinfo 三个包补丁…），且 ORDER 用 `# experimental xxx` 这种
#   「`#` 既是注释又是未启用条目」的双重语义，单看前缀无法区分。
#   本脚本把不变式机器化，ORDER 从此不能再悄悄腐烂。
#
# 不变式：
#   ① MANIFEST 的每条 default/oc/experimental/disabled 条目，在 ORDER 中有且仅有一条
#      同档位条目（路径按桶前缀展开后逐字符相等）；
#   ② ORDER 的 pending 条目必须**不在** MANIFEST 中（原料/备选，按设计只存在于 ORDER）；
#   ③ 两侧都不允许重复条目。
#
# 用法：audit-order.sh [仓库根]（缺省 = 本脚本所在目录的上一级）
# 退出码：0 = 一致；1 = 不一致（打印逐条差异）
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
MANIFEST="$ROOT/patches/MANIFEST"
ORDER="$ROOT/patches/ORDER"
[[ -f "$MANIFEST" ]] || { echo "错误：找不到 $MANIFEST" >&2; exit 1; }
[[ -f "$ORDER" ]] || { echo "错误：找不到 $ORDER" >&2; exit 1; }
command -v python3 >/dev/null || { echo "错误：缺 python3" >&2; exit 1; }

python3 - "$ROOT" <<'PY'
import re, sys, collections

root = sys.argv[1]
MANIFEST = f"{root}/patches/MANIFEST"
ORDER = f"{root}/patches/ORDER"

# ORDER 短路径 → MANIFEST 全路径（桶前缀映射；已写全 paths/ 的原样保留）
BUCKETS = (
    ("root/", "patches/root/"),
    ("mt76/", "patches/packages/mt76-"),
    ("regdb/", "patches/packages/regdb-"),
    ("packages/", "patches/packages/"),
    ("vendor/fanboy/", "patches/vendor/fanboy/"),
    ("kernel/", "patches/kernel/"),
    ("uboot/", "patches/uboot/"),
)
TIERS = ("default", "oc", "experimental", "pending", "disabled")
# MANIFEST 前缀 → ORDER 档位
MAP = {"default": "default", "oc": "oc", "experimental": "experimental", "disabled": "disabled"}


def expand(p):
    if p.startswith("patches/"):
        return p
    for k, v in BUCKETS:
        if p.startswith(k):
            return v + p[len(k):]
    return p


def read_manifest():
    out = []
    for i, l in enumerate(open(MANIFEST, encoding="utf-8"), 1):
        l = l.rstrip("\n")
        if not l.strip():
            continue
        if l.startswith("#OC "):
            t, body = "oc", l[4:]
        elif l.startswith("#EXP "):
            t, body = "experimental", l[5:]
        elif l.startswith("#DISABLED "):
            t, body = "disabled", l[10:]
        elif l.lstrip().startswith("#"):
            continue
        else:
            t, body = "default", l
        parts = body.strip().split()
        if len(parts) != 2:
            print(f"✗ MANIFEST:{i} 字段数 != 2（活动行不允许尾随注释）：{l.strip()!r}", file=sys.stderr)
            sys.exit(1)
        out.append((i, t, parts[0]))
    return out


def read_order():
    # 只认 <tier> <xxx.patch>，且路径必须以 .patch 结尾 ——
    # 借此跳过文件头的档位词汇表等说明行（它们形如 `#   default  ↔ MANIFEST ...`）
    pat = re.compile(r"^(#\s*)?(%s)\s+(\S+\.patch)\s*(#.*)?$" % "|".join(TIERS))
    out, junk = [], []
    for i, l in enumerate(open(ORDER, encoding="utf-8"), 1):
        s = l.rstrip("\n")
        if not s.strip():
            continue
        m = pat.match(s)
        if m:
            out.append((i, m.group(2), m.group(3)))
        elif not s.lstrip().startswith("#"):
            junk.append((i, s))
    return out, junk


man = read_manifest()
ords, junk = read_order()

if junk:
    for i, s in junk:
        print(f"✗ ORDER:{i} 无法解析（非注释行必须形如 `<tier> <xxx.patch>`）：{s!r}", file=sys.stderr)
    sys.exit(1)

man_by = collections.defaultdict(list)
for i, t, p in man:
    man_by[expand(p)].append((i, t))
ord_by = collections.defaultdict(list)
for i, t, p in ords:
    ord_by[expand(p)].append((i, t))

errs = []

# ① MANIFEST → ORDER（含档位一致性）
for path, lst in man_by.items():
    if len(lst) > 1:
        errs.append(f"MANIFEST 重复条目：{path}（行 {[i for i, _ in lst]}）")
    i, t = lst[0]
    want = MAP[t]
    got = ord_by.get(path)
    if not got:
        errs.append(f"MANIFEST-only（ORDER 缺）：M{i} [{want}] {path}")
    elif len(got) > 1:
        errs.append(f"ORDER 重复条目：{path}（行 {[j for j, _ in got]}）")
    elif got[0][1] != want:
        errs.append(f"档位不一致：{path}  MANIFEST={want} vs ORDER={got[0][1]}（ORDER 行 {got[0][0]}）")

# ② ORDER → MANIFEST：非 pending 必须在 MANIFEST；pending 必须不在
for path, lst in ord_by.items():
    present = path in man_by
    for j, t in lst:
        if t == "pending":
            if present:
                errs.append(f"ORDER:{j} 标为 pending 但存在于 MANIFEST：{path}（应改为对应档位或从 MANIFEST 删除）")
        elif not present:
            errs.append(f"ORDER-only（MANIFEST 无此条）：L{j} [{t}] {path}")

if errs:
    for e in errs:
        print(f"✗ ORDER 与 MANIFEST 不一致：{e}", file=sys.stderr)
    print(f"✗ 共 {len(errs)} 处不一致 —— ORDER 是 MANIFEST 的投影，必须逐条对齐"
          f"（改完 MANIFEST 必须同步 ORDER；档位词汇见 ORDER 头部）", file=sys.stderr)
    sys.exit(1)

cnt = collections.Counter(t for _, t, _ in man)
pcnt = collections.Counter(t for _, t, _ in ords)
print(f"✓ ORDER ↔ MANIFEST 一致：MANIFEST {len(man)} 条"
      f"（default {cnt['default']} / oc {cnt['oc']} / experimental {cnt['experimental']} / disabled {cnt['disabled']}）"
      f"；ORDER pending {pcnt['pending']} 条（原料/备选，按设计不在 MANIFEST）")
PY
