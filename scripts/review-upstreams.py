#!/usr/bin/env python3
"""review-upstreams.py — 只读巡检本仓库登记的上游来源，输出逐来源更新报告。

定位（与 check-upstream.sh 区分）：
  - check-upstream.sh     面向"内置/外部 aggregate"，做 blob 漂移、同址冲突、远端 tip 打点。
  - review-upstreams.py   面向 config/upstream-sources.yml 登记的多个异构来源，逐来源抓取
    基线→远端 tip 之间的提交与文件变更，生成可人工裁决的逐项报告。

只读约束：
  - 不写任何正式文件（aggregate/、config/source-lock.env、local/manifest.rules*、
    MANIFEST、ORDER、OpenWrt 树、upstream-decisions.md 一律不动）。
  - clone/fetch 只放进新建的隔离临时目录，退出时清理。
  - 只用 git 读取元数据/diff，绝不执行来源仓库里的 shell/Makefile/hook/解释器。
  - 不做任何"吸收/合并/补丁生成"，AI 建议由调用方（skill）基于本报告给出。

失败状态（不得混为"无更新"）：
  - baseline-orphaned    基线不在远端分支/tag 可达历史中（force-push 孤立 / 不存在 /
                         仅在 PR 等未合并 ref 上）→ 需人工重锚或核对登记值。
  - baseline-unresolved  拿不到完整历史（超时等）或基线无法唯一解析 → 无法比较。
  - ref-missing          登记的远端 ref 不存在（clone --branch 失败也归入此类）。
  - network-fail         网络/超时/git 远端失败。
  - force-push / 非祖先  远端 tip 不在基线历史之后（force-push 或分流）→ 不能当作快进。
  - partial-fail         多个来源时部分失败，其余仍出报告，总状态非 success。

用法：
  python3 scripts/review-upstreams.py [--config config/upstream-sources.yml]
                                      [--out updates/reports/review-YYYYmmdd-HHMMSS.txt]
                                      [--limit N] [--no-network]
                                      [--clone-timeout SEC] [--fetch-timeout SEC]
  默认输出到 stdout，不写文件；--out 才写报告（写前展示目标路径并确认）。
  clone/fetch 用 --filter=blob:none 部分克隆减负；不支持的服务端自动降级。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

CONFIG_DEFAULT = "config/upstream-sources.yml"
SHA_FULL = re.compile(r"^[0-9a-f]{40}$")
SHA_ABBREV = re.compile(r"^[0-9a-f]{4,39}$")
NET_TIMEOUT = 20    # 秒，仓库内只读 git 操作超时
CLONE_TIMEOUT = 120  # 秒，clone 超时（openwrt 体量仓库 20s 必超时，2026-10-21 实测）
FETCH_TIMEOUT = 300  # 秒，unshallow / 按 SHA fetch 超时（全历史 + blob 过滤）

# 允许的远端 host（与仓库既有 fetch 来源一致；host 前缀含 *.）
ALLOWED_HOST_SUFFIXES = ("github.com", "gitlab.com", "codeberg.org", "gitee.com")


class SourceCfg:
    def __init__(self, raw, index, host_map=None):
        self.raw = raw
        self.index = index
        self.id = raw.get("id")
        self.url = raw.get("url")
        self.ref = raw.get("ref")
        self.baseline = raw.get("baseline")
        self.baseline_is_exact = raw.get("baseline_is_exact", True)
        self.purpose = raw.get("purpose", "")
        self.focus_paths = raw.get("focus_paths", [])
        self.enabled = raw.get("enabled", True)
        # 测试钩子：host_map={host: local_dir} 把 URL host 替换为本地目录，离线跑 fixture。
        self._host_map = host_map or {}
        if self._host_map:
            self.url = self._map_url(self.url)

    def _map_url(self, url):
        # 仅测试用：https://<host>/...  → <local_dir>/...
        for host, local in self._host_map.items():
            prefix = "https://" + host
            if url.startswith(prefix + "/") or url == prefix:
                rest = url[len(prefix):]
                return local + rest
        return url

    def validate(self, errors):
        """校验配置字段；返回 True 表示本来源可继续。"""
        if not self.id or not isinstance(self.id, str):
            errors.append(f"[{self.index}] 缺 id")
            return False
        if not self.url or not isinstance(self.url, str):
            errors.append(f"[{self.id}] 缺 url")
            return False
        if not self._host_map and not self._url_ok(self.url):
            # 测试模式（host_map）下 url 已被映射为本地路径，跳过 HTTPS/allowlist 校验。
            errors.append(f"[{self.id}] url 非 HTTPS 或 host 不在 allowlist：{self.url}")
            return False
        if not self.ref or not isinstance(self.ref, str):
            errors.append(f"[{self.id}] 缺 ref")
            return False
        if not self.baseline or not isinstance(self.baseline, str):
            errors.append(f"[{self.id}] 缺 baseline")
            return False
        if not (SHA_FULL.match(self.baseline) or SHA_ABBREV.match(self.baseline)):
            errors.append(f"[{self.id}] baseline 非法（非十六进制 SHA）：{self.baseline!r}")
            return False
        # ref 只允许三种形态：完整 SHA / HEAD / refs/* 引用名
        if not (self.ref == "HEAD"
                or SHA_FULL.match(self.ref)
                or self.ref.startswith("refs/")):
            errors.append(f"[{self.id}] ref 非法：{self.ref!r}")
            return False
        for p in self.focus_paths:
            if not isinstance(p, str):
                errors.append(f"[{self.id}] focus_paths 含非字符串项")
                return False
            if not self._path_ok(p):
                errors.append(f"[{self.id}] focus_paths 非法（禁止 .. / 绝对 / 空）：{p!r}")
                return False
        return True

    @staticmethod
    def _url_ok(url):
        if not url.startswith("https://"):
            return False
        rest = url[len("https://"):]
        host = rest.split("/", 1)[0].lower()
        return any(host == s or host.endswith("." + s) for s in ALLOWED_HOST_SUFFIXES)

    @staticmethod
    def _path_ok(p):
        if not p or p.startswith("/") or ".." in p.split("/"):
            return False
        return True


def run_git(repo, args, timeout=NET_TIMEOUT):
    """在隔离仓库里跑 git 命令；返回 (stdout | None, err | None)。

    err 非空 ⇔ 命令失败（非零退出 / 超时）——调用方一律据此判断，
    **不看退出码**。（历史 bug：曾用 check=False 实现"失败也返回 err=None"，
    导致 merge-base --is-ancestor 失败被当成成功，force-push 检测失效。）
    """
    cmd = ["git", "-C", repo] + args
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return None, "timeout"
    if proc.returncode != 0:
        return None, (proc.stderr or proc.stdout).strip()
    return proc.stdout, None


def clone_source(cfg, tmpdir, errors, allow_network):
    """把 cfg 对应远端 clone/fetch 进隔离 tmpdir/<id>。返回 (repo_path, err)。

    策略：默认浅 clone 单一 ref（--filter=blob:none 部分克隆减负，服务端不支持时
    自动降级）；ref 为完整 SHA 或 HEAD 时浅 clone 默认分支，之后
    resolve_tip/resolve_baseline 需要时再 unshallow 或按需 fetch。
    err 为 None 或 "<状态>: <详情>"（状态 ∈ ref-missing / network-fail），由调用方分类。
    """
    repo = os.path.join(tmpdir, cfg.id)
    if not allow_network:
        return None, "network-disabled"
    # 本地路径（测试 fixture）统一转 file://，让 --depth/--branch 语义与远端一致。
    url = cfg.url
    if not url.startswith(("https://", "http://", "git@", "ssh://", "git://")):
        url = "file://" + os.path.abspath(url)
    # blob:none 部分克隆：真实远端（GitHub 等）大幅减少传输量；不支持过滤的
    # 服务端（如本地 file:// fixture）会告警并自动降级为普通 clone，不影响正确性。
    cmd = ["git", "clone", "--quiet", "--no-checkout", "--depth", "1",
           "--filter=blob:none"]
    # ref 为分支引用时提取分支名（git clone --branch 要名字，不是 refs/heads/...）。
    branch_name = None
    if cfg.ref != "HEAD" and not SHA_FULL.match(cfg.ref):
        if cfg.ref.startswith("refs/heads/"):
            branch_name = cfg.ref[len("refs/heads/"):]
        else:
            branch_name = cfg.ref
        cmd += ["--branch", branch_name]
    cmd += [url, repo]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=CLONE_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, "network-fail(timeout)"
    if proc.returncode != 0:
        msg = (proc.stderr or proc.stdout).strip()
        # clone --branch <名字> 失败 = 登记的远端 ref 不存在（区别于网络故障）。
        low = msg.lower()
        if branch_name and ("not found" in low or "couldn't find remote ref" in low
                            or "could not find remote branch" in low):
            return None, f"ref-missing: 远端无分支 {branch_name}：{msg[:160]}"
        return None, f"network-fail: {msg[:200]}"
    return repo, None


def resolve_baseline(cfg, repo, errors):
    """把 baseline 解析为唯一完整 SHA。

    返回 (full_sha | None, status, detail)
      status: ok / baseline-orphaned / baseline-unresolved
    完整 40 位 SHA：先直接按 SHA fetch（GitHub 支持可达 SHA 拉取，一步到位）；
      被拒（疑似孤儿）或服务端不支持时，退到 unshallow 全历史（heads + tags）重试。
    短 SHA：只能等全历史后 rev-parse 唯一解析。
    已拿到全历史仍找不到 ⇒ baseline-orphaned（被 force-push 孤立 / 不存在）；
      全历史都没拿到（超时等）⇒ baseline-unresolved（无法比较，不得当作无更新）。
    """
    b = cfg.baseline

    def _try_parse():
        out, err = run_git(repo, ["rev-parse", "--verify", b + "^{commit}"])
        if err is None:
            full = out.strip()
            if SHA_FULL.match(full):
                return full
        return None

    full = _try_parse()
    if full:
        return full, "ok", ""
    # 完整 SHA：直接按 SHA fetch（真实远端通常允许；本地 fixture 服务端会拒，属正常降级）
    if SHA_FULL.match(b):
        _fout, ferr = run_git(
            repo,
            ["fetch", "--quiet", "--depth", "1", "--filter=blob:none", "origin", b],
            timeout=FETCH_TIMEOUT,
        )
        if ferr is None:
            full = _try_parse()
            if full:
                return full, "ok", ""
            return None, "baseline-orphaned", (
                f"{b} 按 SHA fetch 成功但不是可达 commit——需人工核对登记值")
    # 对象不在浅仓库：拉全历史（heads + tags，blob 过滤）后重试。
    _out2, err2 = run_git(
        repo,
        ["fetch", "--unshallow", "--filter=blob:none", "origin",
         "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:refs/tags/*"],
        timeout=FETCH_TIMEOUT,
    )
    if err2 is not None:
        return None, "baseline-unresolved", (
            f"{b} 无法解析：拿不到完整历史（{err2[:120]}）→ 无法比较，勿当作无更新")
    full = _try_parse()
    if full:
        return full, "ok", ""
    return None, "baseline-orphaned", (
        f"{b} 不在远端分支/tag 可达历史中（force-push 孤立 / 不存在 / 仅在 PR 等未合并 ref 上）"
        "→ 需人工重锚或核对登记值")


def resolve_tip(cfg, repo, errors):
    """解析远端 ref 的实际 tip。返回 (full_sha | None, status)。

    浅 clone 后 ref 若指向不可达对象（如完整 SHA 非默认分支 tip），按需 fetch 再解析。
    """
    spec = cfg.ref
    out, err = run_git(repo, ["rev-parse", "--verify", spec + "^{commit}"])
    if err is None:
        full = out.strip()
        if SHA_FULL.match(full):
            return full, "ok"
        return None, f"ref-missing({spec})"
    # 可能因浅 clone 缺对象；尝试按需 fetch 该 ref（完整 SHA 需用 allow-reachable-sha1-in-want）。
    if SHA_FULL.match(spec):
        fout, ferr = run_git(
            repo, ["fetch", "--depth", "1", "origin", spec],
            timeout=FETCH_TIMEOUT,
        )
    else:
        fout, ferr = run_git(
            repo, ["fetch", "origin", "+" + spec + ":" + "refs/remotes/origin/tip"],
            timeout=FETCH_TIMEOUT,
        )
    if ferr is not None:
        return None, f"ref-missing({spec})"
    out, err = run_git(repo, ["rev-parse", "--verify", spec + "^{commit}"])
    if err is None:
        full = out.strip()
        if SHA_FULL.match(full):
            return full, "ok"
    return None, f"ref-missing({spec})"


def commit_log(repo, base, tip, limit):
    """返回 base..tip 的提交列表（新→旧），及总条数。"""
    out, err = run_git(
        repo,
        ["log", "--pretty=%H|%at|%an|%s", "--first-parent", f"{base}..{tip}"],
    )
    if err:
        return [], 0
    lines = [ln for ln in out.splitlines() if ln.strip()]
    return lines, len(lines)


def file_changes(repo, base, tip, limit):
    """返回 base..tip 的文件变更摘要（按提交），受 limit 截断。"""
    out, err = run_git(
        repo,
        ["log", "--first-parent", "--name-status",
         "--pretty=::|%H|%s", f"{base}..{tip}"],
    )
    if err:
        return []
    blocks = []
    cur = None
    for ln in out.splitlines():
        if ln.startswith("::|"):
            if cur:
                blocks.append(cur)
            _, sha, subj = ln.split("|", 2)
            cur = {"sha": sha, "subject": subj, "files": []}
        elif cur and ln.strip():
            # 形如 "M\tpath" / "A\tpath" / "R100\told\tnew"
            parts = ln.split("\t")
            st = parts[0] if parts else ""
            path = parts[-1] if len(parts) > 1 else ""
            cur["files"].append((st, path))
    if cur:
        blocks.append(cur)
    return blocks[:limit]


def ancestry_check(repo, base, tip):
    """判断 tip 是否为 base 的后代（快进）。

    返回 'fast-forward' | 'force-push' | 'unknown'
    """
    # check=False 时，成功返回 (stdout, None)，失败返回 (None, stderr)
    out, err = run_git(repo, ["merge-base", "--is-ancestor", base, tip])
    if err is None:
        # exit 0 → base 是 tip 祖先
        return "fast-forward"
    return "force-push"


def ensure_full_history(repo):
    """若仓库是浅 clone，转成完整历史（供 ancestry/log 使用）。幂等。"""
    # 判断是否浅：.git/shallow 存在即浅。
    shallow = os.path.join(repo, ".git", "shallow")
    if not os.path.exists(shallow):
        return None
    out, err = run_git(
        repo,
        ["fetch", "--unshallow", "--filter=blob:none", "origin",
         "+refs/heads/*:refs/remotes/origin/*", "+refs/tags/*:refs/tags/*"],
        timeout=FETCH_TIMEOUT,
    )
    return err


def report_one(cfg, repo, tmpdir, errors, allow_network, limit):
    """对单个来源生成报告条目（dict），状态归入 status 字段。"""
    entry = {
        "id": cfg.id,
        "url": cfg.url,
        "ref": cfg.ref,
        "baseline": cfg.baseline,
        "baseline_is_exact": cfg.baseline_is_exact,
        "purpose": cfg.purpose,
        "focus_paths": cfg.focus_paths,
        "status": "ok",
        "detail": "",
        "tip": None,
        "commits": [],
        "commit_count": 0,
        "file_summary": [],
    }
    if repo is None:
        entry["status"] = "network-disabled" if not allow_network else "network-fail"
        entry["detail"] = "未联网（--no-network）" if not allow_network else "clone 失败"
        return entry

    # 1) 解析基线
    base, bstatus, bdetail = resolve_baseline(cfg, repo, errors)
    if bstatus != "ok":
        entry["status"] = bstatus
        entry["detail"] = bdetail
        return entry

    # 2) 解析 tip
    tip, tstatus = resolve_tip(cfg, repo, errors)
    if tstatus != "ok":
        entry["status"] = "ref-missing"
        entry["detail"] = tstatus
        return entry
    entry["tip"] = tip

    # 3) 无更新？
    if base == tip:
        entry["status"] = "no-update"
        entry["detail"] = "baseline 即远端 tip，无新提交"
        return entry

    # 3.5) 浅 clone → 补全历史，供 ancestry 与差异列表使用。
    herr = ensure_full_history(repo)
    if herr is not None:
        entry["status"] = "network-fail"
        entry["detail"] = f"补全历史失败：{herr[:200]}"
        return entry

    # 4) 祖先关系
    rel = ancestry_check(repo, base, tip)
    if rel == "force-push":
        # 基线不是 tip 祖先 → 无法当作快进；仍尽量列出差异提交但标 force-push。
        entry["status"] = "force-push"
        entry["detail"] = "远端 tip 不是基线后代（force-push / 分流），不能当作快进；差异列表仅供参考"

    # 5) 提交与文件变更
    commits, total = commit_log(repo, base, tip, limit)
    entry["commit_count"] = total
    entry["commits"] = commits[:limit]
    entry["file_summary"] = file_changes(repo, base, tip, limit)
    if entry["status"] == "ok":
        entry["status"] = "advance"
        entry["detail"] = f"基线 → tip：{base[:9]} → {tip[:9]}，{total} 个新提交"
    return entry


def render_report(repo_root, cfg, entries, allow_network, limit, elapsed):
    """渲染人类可读的逐来源报告文本。"""
    L = []
    L.append("=" * 72)
    L.append("XR1710G 上游来源巡检报告")
    L.append(f"仓库      : {repo_root}")
    L.append(f"配置      : {cfg}")
    L.append(f"生成时间  : {time.strftime('%Y-%m-%d %H:%M:%S %Z')}")
    L.append(f"网络      : {'联网' if allow_network else '仅离线(--no-network)'}")
    L.append(f"提交上限  : {limit}（超过则截断，count 为实际总数）")
    L.append(f"耗时      : {elapsed:.1f}s")
    L.append("=" * 72)

    ok_count = 0
    for e in entries:
        L.append("")
        L.append(f"[{e['status'].upper()}] {e['id']}")
        L.append(f"  url      : {e['url']}")
        L.append(f"  ref      : {e['ref']}")
        L.append(f"  baseline : {e['baseline']}  (exact={e['baseline_is_exact']})")
        L.append(f"  purpose  : {e['purpose']}")
        if e.get("tip"):
            L.append(f"  tip      : {e['tip']}")
        if e["status"] != "advance":
            L.append(f"  detail   : {e['detail']}")
            continue
        ok_count += 1
        L.append(f"  detail   : {e['detail']}")
        if e["commits"]:
            L.append(f"  commits  : ({e['commit_count']} 个，列表最多 {limit})")
            for c in e["commits"]:
                sha, at, who, subj = c.split("|", 3)
                L.append(f"      {sha[:9]}  {time.strftime('%Y-%m-%d', time.localtime(int(at)))}  {who[:18]:<18}  {subj[:70]}")
        if e["file_summary"]:
            L.append("  files    :")
            for blk in e["file_summary"]:
                L.append(f"      [{blk['sha'][:9]}] {blk['subject'][:50]}")
                for st, path in blk["files"][:8]:
                    L.append(f"          {st:<6} {path}")
                if len(blk["files"]) > 8:
                    L.append(f"          … 另有 {len(blk['files']) - 8} 个文件")
        L.append(f"  focus    : {e['focus_paths'] or '(全部路径)'}")

    # 汇总
    L.append("")
    L.append("=" * 72)
    total = len(entries)
    statuses = {}
    for e in entries:
        statuses[e["status"]] = statuses.get(e["status"], 0) + 1
    L.append("汇总状态：")
    for s, n in sorted(statuses.items()):
        L.append(f"  {s:<22} {n}")
    L.append(f"  {'total':<22} {total}")
    overall = "success" if all(e["status"] in ("no-update", "advance") for e in entries) else "partial"
    if not entries:
        overall = "no-sources"
    L.append(f"总判定   : {overall}（no-update/advance 视为成功；其余即部分失败）")
    L.append("提示     : 本报告只供人工裁决；吸收/合并/补丁生成需另行人工选择，本脚本不做。")
    L.append("=" * 72)
    return "\n".join(L)


def main():
    global CLONE_TIMEOUT, FETCH_TIMEOUT
    ap = argparse.ArgumentParser(description="只读巡检上游来源并生成报告")
    ap.add_argument("--config", default=CONFIG_DEFAULT, help="来源配置（JSON/YAML 兼容子集）")
    ap.add_argument("--out", default=None, help="写报告到指定路径（默认仅 stdout）")
    ap.add_argument("--limit", type=int, default=20, help="每来源提交/文件变更截断上限")
    ap.add_argument("--no-network", action="store_true", help="不联网（离线模式，全部来源报 network-disabled）")
    ap.add_argument("--host-map", default=None,
                    help="测试钩子：JSON {host: 本地目录}，把 URL host 替换为本地路径以便离线跑 fixture")
    ap.add_argument("--clone-timeout", type=int, default=CLONE_TIMEOUT,
                    help=f"clone 超时秒数（默认 {CLONE_TIMEOUT}；openwrt 体量仓库需较大值）")
    ap.add_argument("--fetch-timeout", type=int, default=FETCH_TIMEOUT,
                    help=f"unshallow / 按 SHA fetch 超时秒数（默认 {FETCH_TIMEOUT}）")
    args = ap.parse_args()

    CLONE_TIMEOUT = max(10, args.clone_timeout)
    FETCH_TIMEOUT = max(30, args.fetch_timeout)

    repo_root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    cfg_path = os.path.join(repo_root, args.config) if not os.path.isabs(args.config) else args.config

    if not os.path.isfile(cfg_path):
        print(f"错误：来源配置不存在：{cfg_path}", file=sys.stderr)
        sys.exit(2)

    with open(cfg_path, "r", encoding="utf-8") as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError as e:
            # 兼容真 YAML 块（极简子集）：尝试缩进转成 JSON 的代价太高，直接报错并提示。
            print(f"错误：{cfg_path} 不是合法 JSON：{e}", file=sys.stderr)
            print("      本脚本读取 JSON 格式（合法 YAML 子集）。若要 YAML 需另加解析器。", file=sys.stderr)
            sys.exit(2)

    raw_sources = data.get("sources", []) if isinstance(data, dict) else []
    if not raw_sources:
        print("错误：配置里没有 sources 列表", file=sys.stderr)
        sys.exit(2)

    host_map = {}
    if args.host_map:
        try:
            with open(args.host_map, "r", encoding="utf-8") as hf:
                host_map = json.load(hf)
        except (OSError, json.JSONDecodeError) as e:
            print(f"错误：无法读取 --host-map：{e}", file=sys.stderr)
            sys.exit(2)

    cfgs = []
    errors = []
    for i, raw in enumerate(raw_sources):
        c = SourceCfg(raw, i, host_map=host_map)
        if c.validate(errors):
            cfgs.append(c)
    if errors:
        for e in errors:
            print(f"配置错误：{e}", file=sys.stderr)
        # 有来源配置错误时，若仍有可用来源则继续并标 partial，否则退出。
        if not cfgs:
            sys.exit(2)

    if args.out:
        out_abs = os.path.abspath(args.out)
        print(f"将写入报告到：{out_abs}", file=sys.stderr)
        # 仅确认目录可写；实际文件在 report 渲染后写入（写入即副作用，调用方需先确认）。

    # host_map 存在即测试模式：clone 目标是本地路径，不算网络操作。
    # 因此 --no-network 只禁止真正的远端 git 操作，不禁止本地 fixture clone。
    allow_network = (not args.no_network) or bool(host_map)

    t0 = time.time()
    tmpdir = tempfile.mkdtemp(prefix="xr1710g-review-")
    entries = []
    try:
        for c in cfgs:
            if not c.enabled:
                entries.append({
                    "id": c.id, "url": c.url, "ref": c.ref, "baseline": c.baseline,
                    "baseline_is_exact": c.baseline_is_exact, "purpose": c.purpose,
                    "focus_paths": c.focus_paths, "status": "disabled", "detail": "配置中 enabled=false",
                    "tip": None, "commits": [], "commit_count": 0, "file_summary": [],
                })
                continue
            repo, err = clone_source(c, tmpdir, errors, allow_network=allow_network)
            if err:
                # err 形如 "<状态>: <详情>"；无前缀/未知前缀按 network-fail 处理。
                # 注意 network-disabled / network-fail(timeout) 无 ": " 分隔符，
                # 此时详情即原文（历史 bug：曾硬编码 network-fail，把 offline 误报成故障）。
                status, sep, detail = err.partition(": ")
                if status not in ("ref-missing", "network-fail", "network-disabled"):
                    status, detail = "network-fail", err
                elif not sep:
                    detail = err
                entries.append({
                    "id": c.id, "url": c.url, "ref": c.ref, "baseline": c.baseline,
                    "baseline_is_exact": c.baseline_is_exact, "purpose": c.purpose,
                    "focus_paths": c.focus_paths, "status": status, "detail": detail,
                    "tip": None, "commits": [], "commit_count": 0, "file_summary": [],
                })
                continue
            entries.append(report_one(c, repo, tmpdir, errors, allow_network=allow_network, limit=args.limit))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    elapsed = time.time() - t0
    report = render_report(repo_root, args.config, entries, allow_network, args.limit, elapsed)

    if args.out:
        os.makedirs(os.path.dirname(out_abs), exist_ok=True)
        with open(out_abs, "w", encoding="utf-8") as f:
            f.write(report)
        print(f"报告已写入：{out_abs}", file=sys.stderr)
    else:
        print(report)

    overall = all(e["status"] in ("no-update", "advance", "disabled") for e in entries) and bool(entries)
    if not entries:
        sys.exit(2)
    sys.exit(0 if overall else 1)


if __name__ == "__main__":
    main()