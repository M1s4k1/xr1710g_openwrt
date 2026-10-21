#!/usr/bin/env python3
"""tests/test_review_upstreams.py — 本地离线 fixture 测试 for scripts/review-upstreams.py

不依赖网络、不依赖 pytest。直接运行：
    python3 tests/test_review_upstreams.py

在临时目录里构建"远端"git 仓库（模拟 GitHub），用 --host-map + --no-network 让
巡检器离线访问。覆盖：
  - no-update        基线即 tip
  - advance          正常快进（新增提交/文件）
  - multi-file       多文件 增/改/删/重命名
  - force-push       远端 tip 非基线后代（force-push/分流；检出即总判定 partial、退出非 0）
  - baseline-orphaned  基线不在远端可达历史中（孤儿/不存在；全历史拿到后仍解析失败）
  - ref-missing      登记的远端 ref 不存在
  - network-disabled  --no-network 全部网络类来源跳过
  - partial-fail     部分来源失败，其余仍出报告，总判定 non-success
  - bad-url / bad-path / bad-config  配置校验失败
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCANNER = os.path.join(ROOT, "scripts", "review-upstreams.py")

PASS = 0
FAIL = 0


def run_ok(*argv):
    """断言退出码为 0。"""
    global PASS, FAIL
    proc = subprocess.run([sys.executable, SCANNER] + list(argv),
                          capture_output=True, text=True, cwd=ROOT)
    if proc.returncode != 0:
        FAIL += 1
        print(f"✗ 期望退出 0，实际 {proc.returncode}")
        print(proc.stdout)
        print(proc.stderr, file=sys.stderr)
        return None
    PASS += 1
    return proc.stdout


def run_fail(*argv):
    """断言退出码非 0。"""
    global PASS, FAIL
    proc = subprocess.run([sys.executable, SCANNER] + list(argv),
                          capture_output=True, text=True, cwd=ROOT)
    if proc.returncode == 0:
        FAIL += 1
        print("✗ 期望退出非 0，实际 0")
        print(proc.stdout)
        return None
    PASS += 1
    return proc.stdout


def git(repo, *args):
    p = subprocess.run(["git", "-C", repo] + list(args),
                       capture_output=True, text=True, check=True)
    return p.stdout.strip()


def new_repo(tmp, name):
    """新建一个空 git 仓库（裸，模拟远端）。路径带 .git 后缀对齐克隆 URL。"""
    path = os.path.join(tmp, name + ".git")
    os.makedirs(path, exist_ok=True)
    git(path, "init", "-q", "--bare")
    return path


def commit_to(work, repo, files, msg, author="tester <t@x>", force=False):
    """在非裸工作区提交文件，push 到裸仓库。"""
    for rel, content in files.items():
        full = os.path.join(work, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(content)
    git(work, "add", "-A")
    git(work, "-c", "user.name=tester", "-c", "user.email=t@x",
        "commit", "-q", "-m", msg)
    push = ["push", "-q"]
    if force:
        push += ["-f"]
    git(work, *push, repo, "HEAD:refs/heads/main")
    return git(work, "rev-parse", "HEAD")


def make_work(tmp, name="work"):
    """创建非裸工作区并连到裸远端。"""
    work = os.path.join(tmp, name)
    os.makedirs(work, exist_ok=True)
    git(work, "init", "-q")
    git(work, "config", "user.name", "tester")
    git(work, "config", "user.email", "t@x")
    return work


def write_cfg(tmp, sources):
    cfg = os.path.join(tmp, "sources.json")
    with open(cfg, "w", encoding="utf-8") as f:
        json.dump({"schema": "xr1710g-upstream-sources/v1", "sources": sources}, f)
    return cfg


def write_hostmap(tmp, mapping):
    hm = os.path.join(tmp, "hostmap.json")
    with open(hm, "w", encoding="utf-8") as f:
        json.dump(mapping, f)
    return hm


def run_with(tmp, sources, hm, expect0=True):
    cfg = write_cfg(tmp, sources)
    hmp = write_hostmap(tmp, hm)
    argv = ["--config", cfg, "--host-map", hmp, "--no-network", "--limit", "5"]
    out = run_ok(*argv) if expect0 else run_fail(*argv)
    return out


def main():
    global PASS, FAIL
    tmp = tempfile.mkdtemp(prefix="xr1710g-test-")
    try:
        # ── 1. no-update：基线即远端 tip ──────────────────────────
        repo = new_repo(tmp, "r1")
        work = make_work(tmp,"w5")
        tip = commit_to(work, repo, {"a.txt": "one"}, "first")
        cfg = write_cfg(tmp, [{
            "id": "r1", "url": "https://github.com/r1.git",
            "ref": "refs/heads/main", "baseline": tip, "baseline_is_exact": True,
            "purpose": "no-update", "focus_paths": ["a.txt"]}])
        hmp = write_hostmap(tmp, {"github.com": tmp})
        out = run_ok("--config", cfg, "--host-map", hmp, "--no-network")
        assert "[NO-UPDATE] r1" in out and "no-update" in out, out
        assert "总判定   : success" in out, out

        # ── 2. advance：正常快进 ─────────────────────────────────
        repo = new_repo(tmp, "r2")
        work = make_work(tmp,"w2")
        base = commit_to(work, repo, {"a.txt": "one"}, "first")
        tip = commit_to(work, repo, {"a.txt": "one\nmore", "b.txt": "bee"}, "second")
        cfg = write_cfg(tmp, [{
            "id": "r2", "url": "https://github.com/r2.git",
            "ref": "refs/heads/main", "baseline": base, "baseline_is_exact": True,
            "purpose": "advance", "focus_paths": []}])
        hmp = write_hostmap(tmp, {"github.com": tmp})
        out = run_ok("--config", cfg, "--host-map", hmp, "--no-network")
        assert "[ADVANCE] r2" in out and "1 个新提交" in out, out
        assert "b.txt" in out, out

        # ── 3. multi-file：增/改/删/重命名 ───────────────────────
        repo = new_repo(tmp, "r3")
        work = make_work(tmp,"w3")
        base = commit_to(work, repo, {"old.txt": "x", "keep.txt": "k"}, "first")
        # 删 old.txt，改 keep.txt，新增 new.txt，重命名 del.txt→moved.txt
        os.remove(os.path.join(work, "old.txt"))
        with open(os.path.join(work, "del.txt"), "w") as f:
            f.write("d")
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", "stage delete")
        git(work, "push", "-q", repo, "HEAD:refs/heads/main")
        with open(os.path.join(work, "keep.txt"), "w") as f:
            f.write("k2")
        with open(os.path.join(work, "new.txt"), "w") as f:
            f.write("n")
        git(work, "mv", "del.txt", "moved.txt")
        git(work, "add", "-A")
        git(work, "commit", "-q", "-m", "modify add rename")
        git(work, "push", "-q", repo, "HEAD:refs/heads/main")
        tip = git(work, "rev-parse", "HEAD")
        cfg = write_cfg(tmp, [{
            "id": "r3", "url": "https://github.com/r3.git",
            "ref": "refs/heads/main", "baseline": base, "baseline_is_exact": True,
            "purpose": "multi-file", "focus_paths": []}])
        hmp = write_hostmap(tmp, {"github.com": tmp})
        out = run_ok("--config", cfg, "--host-map", hmp, "--no-network")
        assert "new.txt" in out and "moved.txt" in out and "old.txt" in out, out

        # ── 4. force-push / 分流（检出即总判定 partial，退出非 0）────
        repo = new_repo(tmp, "r4")
        work = make_work(tmp,"w4")
        base = commit_to(work, repo, {"a.txt": "one"}, "v1")
        # 重写历史：新 root，不含 base；旧 base 保留在 tag 上（仍可达），触发 true force-push/分流
        work2 = make_work(tmp, "w4b")
        newroot = commit_to(work2, repo, {"z.txt": "zz"}, "rebase root", force=True)
        # 把旧 base 推到 tag，令其仍可从远端解析但不再是 main 的祖先
        git(work, "push", "-q", repo, base + ":refs/tags/old")
        cfg = write_cfg(tmp, [{
            "id": "r4", "url": "https://github.com/r4.git",
            "ref": "refs/heads/main", "baseline": base, "baseline_is_exact": True,
            "purpose": "force-push", "focus_paths": []}])
        hmp = write_hostmap(tmp, {"github.com": tmp})
        out = run_fail("--config", cfg, "--host-map", hmp, "--no-network")
        assert "[FORCE-PUSH] r4" in out, out

        # ── 5. 基线不在远端可达历史（孤儿/不存在）→ baseline-orphaned ──
        repo = new_repo(tmp, "r5")
        work = make_work(tmp,"w5b")
        tip = commit_to(work, repo, {"a.txt": "one"}, "first")
        cfg = write_cfg(tmp, [{
            "id": "r5", "url": "https://github.com/r5.git",
            "ref": "refs/heads/main", "baseline": "9999999", "baseline_is_exact": False,
            "purpose": "bad-base", "focus_paths": []}])
        hmp = write_hostmap(tmp, {"github.com": tmp})
        out = run_fail("--config", cfg, "--host-map", hmp, "--no-network")
        assert "baseline-orphaned" in out, out

        # ── 6. ref 不存在 → ref-missing ─────────────────────────
        repo = new_repo(tmp, "r6")
        work = make_work(tmp,"w2")
        base = commit_to(work, repo, {"a.txt": "one"}, "first")
        cfg = write_cfg(tmp, [{
            "id": "r6", "url": "https://github.com/r6.git",
            "ref": "refs/heads/nope", "baseline": base, "baseline_is_exact": True,
            "purpose": "bad-ref", "focus_paths": []}])
        hmp = write_hostmap(tmp, {"github.com": tmp})
        out = run_fail("--config", cfg, "--host-map", hmp, "--no-network")
        assert "ref-missing" in out, out

        # ── 7. 部分来源失败 → 总判定 partial，仍出其它报告 ───────
        repo = new_repo(tmp, "r7a")
        work = make_work(tmp,"w7")
        tip = commit_to(work, repo, {"a.txt": "one"}, "first")
        # r7b：仓库存在、main 有提交，但登记的基线不在其历史中 ⇒ baseline-orphaned
        repo7b = new_repo(tmp, "r7b")
        commit_to(work, repo7b, {"b.txt": "bee"}, "r7b first")
        cfg = write_cfg(tmp, [
            {"id": "r7a", "url": "https://github.com/r7a.git",
             "ref": "refs/heads/main", "baseline": tip, "baseline_is_exact": True,
             "purpose": "ok-src", "focus_paths": []},
            {"id": "r7b", "url": "https://github.com/r7b.git",
             "ref": "refs/heads/main", "baseline": "9999999", "baseline_is_exact": False,
             "purpose": "bad-src", "focus_paths": []}])
        hmp = write_hostmap(tmp, {"github.com": tmp})
        out = run_fail("--config", cfg, "--host-map", hmp, "--no-network")
        assert "[NO-UPDATE] r7a" in out, out
        assert "[BASELINE-ORPHANED] r7b" in out, out
        assert "总判定   : partial" in out, out

        # ── 7b. --no-network（无 host_map）→ 全部来源 network-disabled ──
        # 注意：不传 host_map；allow_network=False 时 clone_source 在任何 git
        # 调用前直接返回，不会真的联网。
        cfg = write_cfg(tmp, [{
            "id": "r9", "url": "https://github.com/r9.git",
            "ref": "refs/heads/main", "baseline": "abcdef1", "baseline_is_exact": True,
            "purpose": "offline", "focus_paths": []}])
        out = run_fail("--config", cfg, "--no-network")
        assert "[NETWORK-DISABLED] r9" in out and "network-disabled" in out, out

        # ── 8. 配置校验失败 → 退出非 0 ───────────────────────────
        cfg = write_cfg(tmp, [{
            "id": "bad", "url": "ftp://github.com/x/bad.git",  # 非 https
            "ref": "refs/heads/main", "baseline": "abc123", "baseline_is_exact": True,
            "purpose": "bad-url", "focus_paths": []}])
        hmp = write_hostmap(tmp, {"github.com": tmp})
        run_fail("--config", cfg, "--host-map", hmp, "--no-network")
        # 非法 path（..）
        cfg = write_cfg(tmp, [{
            "id": "bad2", "url": "https://github.com/bad2.git",
            "ref": "refs/heads/main", "baseline": "abc12345", "baseline_is_exact": True,
            "purpose": "bad-path", "focus_paths": ["../escape"]}])
        run_fail("--config", cfg, "--host-map", hmp, "--no-network")

    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"\n通过 {PASS}，失败 {FAIL}")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()