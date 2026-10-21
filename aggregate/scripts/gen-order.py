#!/usr/bin/env python3
"""gen-order.py — 由 patches/MANIFEST 重生成 patches/ORDER（档位评审视图）

新口径（2026-09-14 F164）：ORDER 是 MANIFEST 的**纯投影**——两者 (tier, 路径) 多重集必须相等：
    MANIFEST 无前缀      → default       （stock + experimental 两档都应用）
    MANIFEST `#OC `      → oc            （仅 --oc）
    MANIFEST `#EXP `     → experimental  （仅 --experimental）
    MANIFEST `#DISABLED `→ disabled      （停用留痕）
    `pending`            = 不在 MANIFEST 的原料/备选（按设计只存在于 ORDER）
顺序：档位分节（default → oc → experimental → disabled → pending），节内保持 MANIFEST 行序。
`#` 开头的行只作说明，不再承担「禁用」语义（旧 `# experimental 9037` 写法已废止）。

行尾注释：从**现有 ORDER** 里按路径继承（逐字保留评审结论），新增条目用 NEW_COMMENTS 提供。

用法：
    scripts/gen-order.py [仓库根]            # 就地重写 patches/ORDER（先备份为 ORDER.bak）
    scripts/gen-order.py [仓库根] --check    # 只检查：现有 ORDER 是否已是 MANIFEST 的规范投影
退出码：0 = 已写/已规范；1 = --check 下不规范（打印差异入口）
校验：scripts/audit-order.sh（同一不变式的独立实现，挂在 apply-patches.sh 上）
"""
import collections
import os
import re
import shutil
import sys

REPO = next((a for a in sys.argv[1:] if not a.startswith("--")), ".")
CHECK = "--check" in sys.argv
MANIFEST = os.path.join(REPO, "patches/MANIFEST")
ORDER = os.path.join(REPO, "patches/ORDER")

TIER_ORDER = ("default", "oc", "experimental", "disabled", "pending")
BANNER = {
    "default": "# ── default（MANIFEST 无前缀活动行；stock 与 experimental 两档都应用）──",
    "oc": "# ── oc（MANIFEST `#OC `；仅 --oc 应用）──\n"
          "# OC 本体（OPP/PLL/governor）由 scripts/prepare-oc.sh 做树编辑，不占 MANIFEST。",
    "experimental": "# ── experimental（MANIFEST `#EXP `；仅 --experimental 应用）──",
    "disabled": "# ── disabled（MANIFEST `#DISABLED `；停用留痕，不参与任何档位）──",
    "pending": "# ── pending（**不在 MANIFEST** 的原料/备选；仅评审参考，不参与任何档位）──",
}
HEADER = """\
# 补丁应用顺序表  format: <tier> <相对路径>
#
# 权威应用清单 = patches/MANIFEST（本表是**档位评审视图**；不一致时以 MANIFEST 为准并修正本表）。
#
# ── 档位词汇表（2026-09-14 F164 重写，与 MANIFEST 前缀一一对应）──
#   default        ↔ MANIFEST 无前缀活动行      参与 stock / experimental 两档
#   oc             ↔ MANIFEST `#OC `            仅 --oc（激进档资产）
#   experimental   ↔ MANIFEST `#EXP `           仅 --experimental
#   disabled       ↔ MANIFEST `#DISABLED `      停用（文件保留、留痕，不参与任何档位）
#   pending        ——  不在 MANIFEST 的原料/备选（仅评审参考，不参与任何档位）
#   `#` 开头的行 = 纯说明，**不再**承担「禁用」语义
#     （旧写法 `# experimental root/9037-...` 曾同时被当作"注释"与"未启用条目"，
#      单看前缀无法区分二者 —— F164 起废止，改用具名 `disabled` / `pending` 档）
#
# ── 校验与重生成 ──
#   scripts/audit-order.sh 逐条对账本表 ↔ MANIFEST（集合 + 档位），
#   由 scripts/apply-patches.sh 在每次（含 --dry-run）应用前自动调用。
#   不变式：本表 default/oc/experimental/disabled 四档的 (tier, 路径) 多重集
#           == MANIFEST 同档多重集；pending 条目必须**不在** MANIFEST 中。
#   scripts/gen-order.py 按该不变式重生成本表（行尾评审注释按路径继承）。
#
# ── 历史注记（保留，仅供追溯）──
# 2026-08-17：08 号 regdb 555 已拆净（→ 独立 regdb/0555，#OC 档，与 08 原内容一致）。
# 2026-08-17 F13 评审：11/14 定档 default；16 重建为 root/9010 定档 default；13 否决（fork+hash=skip）；
#   15 与 0006/0007 重复仅备选；08 余项切片完成（2026-08-17）→ root/9011-9016 六项入 default。
# 2026-08-17 F20：regdb/0500 删除——与 OpenWrt 自带 500-world-regd-5GHz.patch 完全一致（重复补丁）。
# 2026-08-31（ci-74 实机）：vendor/05、06、root/9024、9026、mt76/0005、9990/9991/9993、mac80211/411 转 default。
# 2026-09-14 F164：本表按新口径重写（与 MANIFEST 对账，补齐 49 条缺失、废止 `#` 双重语义）。
"""

# 不在 MANIFEST、只在 ORDER 的条目（原料/备选）——新增此类条目请在此登记
PENDING = [
    ("vendor/fanboy/01-vermagic-inject-85005e10.patch", "# F14 评估后接 CI"),
    ("vendor/fanboy/08-reliability-compat-36da8e02.patch", "# 切片完成（root/9011-9016 入 default）；本文件保留供对照"),
    ("vendor/fanboy/12-lorenzo-airoha-patches-8d1947c0.patch", "# 实验档候选（调试脚本/npu ser/usb-pcie 杂项）"),
    ("vendor/fanboy/19-w1700k-apps-pack-0a4f2632de.patch", "# 已精简为 root/9017（19-core）；原料保留供对照"),
    ("vendor/fanboy/13-mt76-plus-firmware-612255dd.patch", "# 否决（fork + PKG_MIRROR_HASH=skip，违反锁源铁律）"),
    ("vendor/fanboy/15-txpower-control-d7aa0235.patch", "# 备选对比（与默认档 0006/0007 重复）"),
    ("vendor/fanboy/16-wifi-scripts-txpower-ucode-41b9e3ac.patch", "# 原版参考；重建版 = root/9010（default）"),
    ("vendor/fanboy/20-oc-governor-200mhz-ed7cbc80.patch", "# OC 已由 prepare-oc.sh 实现；本文件为 fanboy 原版参考（6.12 系）"),
    ("root/9037-xr1710g-airoha-ppe-offload-drain.patch",
     "# issue #7 防御的**备选方案 B**（与 default 档 9036 方案 A 二选一，勿同时启用）；文件已入库、未进 MANIFEST"),
]

# MANIFEST 新增条目若 ORDER 里没有同名注释，用这里补齐（可选；留空则只写 tier+路径）
NEW_COMMENTS: dict = {
    "root/9067-xr1710g-mt76-source-01367e60.patch":
        "# F161 mt76 主源换代 → fanboy fork 01367e60（= be5ce791 + 1 个纯固件提交，22 文件全 "
        "firmware/*.bin、0 行源码增删）；PKG_MIRROR_HASH 填官方工具算出的真实 sha256 而非 fanboy "
        "原样的 skip ⇒ 解除 F13 的「fork + skip」否决（锁源铁律）；DoD = 两档 CI + 实机 V7.0–V7.6",
    "mt76/0023-wifi-mt76-mt7996-add-pcie-aer-error-handling.patch":
        "# F172（#EXP）：mt7996 PCIe AER error handling——实机 [14] CmpltTO（Uncorrectable Non-Fatal）"
        "+ mt7996e 缺 error_detected 回调 ⇒ `AER: can't recover`、恢复被放弃；补 err_handler"
        "（perm_failure⇒DISCONNECT，其余含 Non-Fatal⇒NEED_RESET 走 aer_root_reset 的 bus reset）"
        "+ slot_reset 交 reset_work 做 full chip reset；**不**照抄 mt7921 的 uncorrectable⇒DISCONNECT；"
        "同文件 glob 序 0023<0153<0160（已验逐 hunk 全过）",
}


def short(full):
    for v, k in (("patches/root/", "root/"), ("patches/packages/mt76-", "mt76/"),
                 ("patches/packages/regdb-", "regdb/"), ("patches/packages/", "packages/"),
                 ("patches/vendor/fanboy/", "vendor/fanboy/"), ("patches/kernel/", "kernel/"),
                 ("patches/uboot/", "uboot/")):
        if full.startswith(v):
            return k + full[len(v):]
    return full


def read_manifest():
    out = []
    for line in open(MANIFEST, encoding="utf-8"):
        l = line.rstrip("\n")
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
            sys.exit(f"✗ MANIFEST 活动行字段数 != 2：{l.strip()!r}")
        out.append((t, parts[0]))
    return out


def read_comments():
    cmt = {}
    pat = re.compile(r"^\s*#?\s*(?:%s)\s+(\S+\.patch)(.*)$" % "|".join(TIER_ORDER))
    if not os.path.exists(ORDER):
        return cmt
    for line in open(ORDER, encoding="utf-8"):
        m = pat.match(line.rstrip("\n"))
        if m and m.group(2).strip().startswith("#"):
            cmt[m.group(1)] = m.group(2).strip()
    return cmt


def render():
    cmt = read_comments()
    by_tier = collections.defaultdict(list)
    manifest_entries = read_manifest()
    active_paths = {short(p) for _, p in manifest_entries}
    for t, p in manifest_entries:
        by_tier[t].append(short(p))
    lines = [HEADER]
    for tier in TIER_ORDER:
        lines.append("")
        lines.append(BANNER[tier])
        if tier == "pending":
            lines += [f"pending {p}   {c}".rstrip()
                      for p, c in PENDING if p not in active_paths]
            continue
        for p in by_tier[tier]:
            c = cmt.get(p) or NEW_COMMENTS.get(p, "")
            lines.append(f"{tier} {p}   {c}".rstrip())
    return "\n".join(lines) + "\n"


def main():
    new = render()
    old = open(ORDER, encoding="utf-8").read() if os.path.exists(ORDER) else ""
    if new == old:
        print("✓ patches/ORDER 已是 MANIFEST 的规范投影（无需改动）")
        return 0
    if CHECK:
        print("✗ patches/ORDER 不是 MANIFEST 的规范投影（跑不带 --check 即重生成，"
              "或先跑 scripts/audit-order.sh 看逐条差异）", file=sys.stderr)
        return 1
    shutil.copy2(ORDER, ORDER + ".bak")
    open(ORDER, "w", encoding="utf-8").write(new)
    print(f"✓ 已重生成 patches/ORDER（旧版备份为 ORDER.bak；"
          f"{len(read_manifest())} 条 MANIFEST 投影 + {len(PENDING)} 条 pending）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
