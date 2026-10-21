# 工作流与来源

## 阶段

| 阶段 | 默认行为 | 允许写入 | 失败处理 |
|---|---|---|---|
| inspect | 读取锁、清单、rules、脚本和工作树 | 无 | 停止并报告漂移 |
| collect | 在隔离临时目录读取固定来源 | `updates/` 或临时 review，需确认 | 标记 blocked |
| analyze | 当前对话逐候选分析 | 候选报告字段，需确认 | 保留证据，不猜测 |
| review | 人工编辑 Markdown | `doc/patch-review.md` | 缺字段则停止 |
| select | 确定性生成器 dry-run | 临时文件；`--apply` 才可正式写入 | 不覆盖手工规则 |
| validate | review/schema、merge、stage、audit、ORDER | stage 输出，需确认 | 不进入 build |
| build | `build-mine.sh` | `.stage/`、源码树和产物 | 报告源码树清理风险 |
| ci | workflow_dispatch | GitHub artifact/release | release 单独确认 |

**批准门**：每个阶段完成后都要停下来向用户报告并取得批准，不得连续推进
（见 SKILL.md「单步执行与批准门」与 safety.md「阶段批准门」）。

## inspect 命令

```bash
scripts/source-resolver.sh --print
scripts/check-upstream.sh
git status --short
```

记录 `config/source-lock.env` 中的完整 SHA，不只记录短 SHA。当前默认 aggregate 为 `244d433374b5a49904d6ca107f078553b37c6111`，OpenWrt 为 `7f4f824691fb2258afe9eb9a37da46d3557c4043`，Linux 为 `6.18.44`。这些值必须从文件重新读取后再报告。

## 来源配置

`config/upstream-sources.yml` 每项至少包含：

```yaml
sources:
  - id: openwrt
    type: git
    url: https://github.com/openwrt/openwrt.git
    ref: <完整 SHA>
    compare_ref: <完整 SHA>
    paths: [target/linux/airoha, package/kernel/mac80211]
    patch_bucket: upstream/openwrt
    enabled: true
```

允许的 `type` 为 `git`、`github-pr`、`patch-bundle`。`url` 必须 HTTPS 且与配置的 host allowlist 匹配；`ref` 和 `compare_ref` 必须是完整 40 位十六进制 SHA。`paths` 必须是相对路径，禁止 `..`、绝对路径和符号链接逃逸。未知来源保持禁用，不凭空补 URL。

来源至少按 OpenWrt、mt76/mac80211、Airoha/fanboy 和其它明确 pin 的补丁源区分。采集器必须把 clone/fetch 目标放在新建临时目录中，checkout 固定 SHA 后只做 Git 读取和 diff，不运行来源仓库文件。

## 候选目录

推荐以下布局：

```text
updates/<source-id>/<candidate-id>/
  metadata.yml
  candidate.patch
  analysis.md
review/patches/<candidate-id>.patch
```

`updates/` 与 `review/` 是隔离区，候选 patch 必须记录来源 SHA 和 hash，供人工复核；它们不得直接进入 `local/patches/` 或改动源码树。
