#!/usr/bin/env python3
"""merge-manifest.py — 把 local/manifest.rules 应用到上游 patches/MANIFEST

用途：生成本仓库的「func 选择集」。上游 MANIFEST 是唯一权威的补丁应用清单，
本脚本在其上做三类操作，输出到 stdout（或 -o 指定文件）。

rules 语法（每行一条；`#` 开头为注释；行尾 `# 理由: …` 必填）：
    - <path>                            停用 → 改写为 `#DISABLED <path> <dest>`
    ^ <path>                            提档 → 删 `#EXP `/`#OC ` 前缀，变活动行
    + <path> <dest> [after <anchor>]    追加本地补丁（dest = ROOT | 目标目录）

语义对齐（与上游 apply-patches.sh / gen-order.py 严格一致）：
    MANIFEST 无前缀        → default（stock/experimental 两档都应用）
    MANIFEST `#EXP `       → experimental（仅 --experimental）
    MANIFEST `#OC `        → oc（仅 --oc）
    MANIFEST `#DISABLED `  → disabled（停用留痕，不参与任何档位）
    `#` 开头的其它行        → 纯注释（不承担禁用语义）

⚠ 硬约束：活动行**不允许尾随注释**（`patches/x.patch ROOT  # 说明` 会破坏 dest 解析）。
   提档时删掉原行尾注释，理由以上一行注释形式补回（保留可追溯性）。

用法：
    scripts/merge-manifest.py <MANIFEST路径> [--rules local/manifest.rules]
                              [-o 输出路径] [--check] [--stats]

退出码：0 成功；1 失败（rules 语法错误 / 目标不存在 / 冲突）
"""
import argparse
import os
import re
import sys

PREFIX = (("#DISABLED ", "disabled"), ("#EXP ", "experimental"), ("#OC ", "oc"))

RULE_RE = re.compile(r"^\s*([\-\^\+])\s+(\S+\.patch)\s*(.*)$")
REASON_RE = re.compile(r"#\s*理由\s*[:：]\s*(.*)$")


def classify(raw):
    """返回 (tier, path, dest) 或 None（纯注释/空行）。"""
    s = raw.rstrip()
    if not s.strip():
        return None
    if s.lstrip().startswith("#"):
        for pre, t in PREFIX:
            if s.startswith(pre):
                parts = s[len(pre):].strip().split()
                if len(parts) != 2:
                    sys.exit(f"✗ MANIFEST 具名行字段数 != 2：{s!r}")
                return (t, parts[0], parts[1])
        return None  # 纯注释
    parts = s.split()
    if len(parts) != 2:
        sys.exit(f"✗ MANIFEST 活动行字段数 != 2：{s!r}")
    return ("default", parts[0], parts[1])


def parse_rules(path):
    rules = {"disable": [], "promote": [], "append": []}
    with open(path, encoding="utf-8") as f:
        for ln, raw in enumerate(f, 1):
            s = raw.rstrip("\n")
            if not s.strip() or s.lstrip().startswith("#"):
                continue
            m = RULE_RE.match(s)
            if not m:
                sys.exit(f"✗ rules 语法错误（{path}:{ln}）：{s!r}")
            op, patch, rest = m.group(1), m.group(2), m.group(3).strip()
            if "理由" not in rest:
                sys.exit(f"✗ rules 缺「理由」（{path}:{ln}）：{s!r}")
            r = REASON_RE.search(rest)
            reason = r.group(1).strip() if r else rest
            if op == "-":
                rules["disable"].append((patch, reason))
            elif op == "^":
                rules["promote"].append((patch, reason))
            else:
                body = rest.split("#")[0].strip()
                toks = body.split()
                if not toks:
                    sys.exit(f"✗ 追加规则缺目标（{path}:{ln}）：{s!r}")
                dest, after = toks[0], None
                if "after" in toks:
                    k = toks.index("after")
                    if k + 1 >= len(toks):
                        sys.exit(f"✗ after 缺锚点（{path}:{ln}）：{s!r}")
                    after = toks[k + 1]
                rules["append"].append((patch, dest, after, reason))
    return rules


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest", help="基准 MANIFEST 路径")
    ap.add_argument("--rules", default="local/manifest.rules")
    ap.add_argument("-o", "--output", default=None, help="输出路径（默认 stdout）")
    ap.add_argument("--check", action="store_true", help="只校验，不写出")
    ap.add_argument("--stats", action="store_true", help="打印统计")
    args = ap.parse_args()

    with open(args.manifest, encoding="utf-8") as f:
        lines = f.read().split("\n")

    # 建立 path -> 行号 / 档位 索引
    info = {}
    for i, raw in enumerate(lines):
        c = classify(raw)
        if c:
            info[c[1]] = {"idx": i, "tier": c[0], "dest": c[2]}

    base = {}
    for v in info.values():
        base[v["tier"]] = base.get(v["tier"], 0) + 1

    rules = parse_rules(args.rules)
    errors = []
    out = list(lines)

    # ① 停用：改写为 #DISABLED（**行必须干净无尾随注释**，理由放上一行）
    for patch, reason in rules["disable"]:
        if patch not in info:
            errors.append(f"停用目标不在 MANIFEST：{patch}")
            continue
        e = info[patch]
        if e["tier"] == "disabled":
            continue
        out[e["idx"]] = f"#DISABLED {patch} {e['dest']}"
        e["tier"] = "disabled"
        e["_promote_note"] = f"# [local] 停用：{reason}"

    # ② 提档（删前缀 + 删尾随注释；理由前置一行注释）
    for patch, reason in rules["promote"]:
        if patch not in info:
            errors.append(f"提档目标不在 MANIFEST：{patch}")
            continue
        e = info[patch]
        if e["tier"] == "default":
            continue
        if e["tier"] == "disabled":
            errors.append(f"提档的是已停用项（rules 自相矛盾）：{patch}")
            continue
        old = e["tier"]
        out[e["idx"]] = f"{patch} {e['dest']}"
        e["tier"] = "default"
        e["_promote_note"] = f"# [local] 提档 {old}→default：{reason}"

    if errors:
        for x in errors:
            print(f"✗ {x}", file=sys.stderr)
        return 1

    # ③ 追加（先收集，最后统一插入，避免索引漂移）
    adds = []  # (插入位置, 注释行, 条目行)
    for patch, dest, after, reason in rules["append"]:
        if patch in info:
            errors.append(f"追加项已在 MANIFEST 中：{patch}")
            continue
        if after:
            if after not in info:
                errors.append(f"after 锚点不在 MANIFEST：{after}")
                continue
            at = info[after]["idx"] + 1
        else:
            at = len(out)
        adds.append((at, f"# [local] 追加：{reason}", f"{patch} {dest}"))

    if errors:
        for x in errors:
            print(f"✗ {x}", file=sys.stderr)
        return 1

    # 组装：按行遍历原 out，在提档行的**前一行**插入注释；追加条目按位置插
    final = []
    tail_adds = []          # 位置 == len(out) 的追加
    for at, note, entry in sorted(adds, key=lambda t: t[0]):
        if at >= len(out):
            tail_adds.append((note, entry))

    pending = {}             # 位置 -> [(note, entry), ...]
    for at, note, entry in sorted(adds, key=lambda t: t[0]):
        if at < len(out):
            pending.setdefault(at, []).append((note, entry))

    for i, raw in enumerate(out):
        for note, entry in pending.get(i, []):
            final.append(note)
            final.append(entry)
        c = classify(raw)
        note = info.get(c[1], {}).pop("_promote_note", None) if c else None
        if note:
            final.append(note)
        final.append(raw)

    for note, entry in tail_adds:
        final.append(note)
        final.append(entry)

    text = "\n".join(final)
    if not text.endswith("\n"):
        text += "\n"

    # 统计
    res = {}
    for raw in final:
        c = classify(raw)
        if c:
            res[c[0]] = res.get(c[0], 0) + 1

    if args.stats or args.check:
        print(f"  基准：{ {k: base.get(k, 0) for k in ('default','experimental','oc','disabled')} }", file=sys.stderr)
        print(f"  结果：{ {k: res.get(k, 0) for k in ('default','experimental','oc','disabled')} }", file=sys.stderr)
        print(f"  rules：停用 {len(rules['disable'])} / 提档 {len(rules['promote'])} "
              f"/ 追加 {len(rules['append'])}", file=sys.stderr)

    if args.check:
        print("✓ rules 可应用（--check，未写出）", file=sys.stderr)
        return 0

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(text)
        print(f"✓ 已写出 {args.output}（活动 {res.get('default',0)} 条）", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
