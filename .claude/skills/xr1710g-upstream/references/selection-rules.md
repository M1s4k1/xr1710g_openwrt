# Review schema 与 rules 约束

## Markdown 记录格式

`doc/patch-review.md` 使用固定字段块，字段名独占一行，值不跨字段。推荐：

````markdown
# Patch Review

<!-- generator-schema: xr1710g-patch-review/v1 -->

## Candidate: mt76-20261020-001

```text
id: mt76-20261020-001
source: mt76
source_url: https://github.com/example/project
source_commit: 0123456789abcdef0123456789abcdef01234567
compare_base: 89abcdef0123456789abcdef0123456789abcdef
source_date: 2026-10-20
candidate_patch: updates/mt76/mt76-20261020-001/candidate.patch
patch_sha256: <sha256>
files: package/kernel/mac802acme/foo.c
hardware: MT7996; XR1710G applicability pending
openwrt_dependency: 7f4f824691fb2258afe9eb9a37da46d3557c4043
linux_dependency: 6.18.44
ai-summary: <fact-based summary>
ai-overlap: none
ai-conflict: none
ai-recommended-tier: v1-safe
ai-risk: medium
ai-confidence: medium
ai-validation: <commands or evidence>
ai-open-questions: <questions>
absorb-stock: n
absorb-v1-safe: n
status: pending
reason: 
reviewer: 
reviewed_at: 
```
````
示例中的 URL、SHA 和 patch 路径是 schema 示例，不代表真实来源。提交真实 review 时必须替换为实际固定值。

## 合法值

- `absorb-stock`、`absorb-v1-safe`：仅 `y` 或 `n`，小写；
- `status`：`pending`、`accept`、`reject`；
- `ai-recommended-tier`：`stock`、`v1-safe`、`experimental`、`reject`；
- `ai-overlap`：`none`、`duplicate`、`partial`；
- `ai-conflict`：`none`、`HIT`、`HIT-CFG`、`COLLIDE`、`ordering`、`dependency`、`unknown`。

`pending`、缺字段、空 `reason`、非法 y/n、来源 SHA 非完整 40 位或 patch 文件缺失时，生成器必须失败。

## rules 语义

`local/manifest.rules*` 每行规则必须带 `# 理由: ...`：

- `- <path>`：停用，上游活动行改为 `#DISABLED`；
- `^ <path>`：提档，删除 `#EXP`/`#OC` 前缀；
- `+ <path> <dest> [after <anchor>]`：追加本地补丁；
- `! <old> <new>`：用新补丁替换旧补丁并继承档位、目标目录和位置。

活动 MANIFEST 行必须精确两个字段 `<path> <dest>`，不可带行尾注释。提档、停用、替换或追加后必须重生成 `patches/ORDER`。`9036` 和 `9037` 互斥；`9037` 是上游 pending 项，不得通过普通 `+` 追加。

## 生成策略

生成器必须先读取人工字段，再验证 patch 文件和来源 pin，最后生成两个临时选择集：

- stock：`absorb-stock: y` 的候选；
- v1-safe：`absorb-v1-safe: y` 的候选。

默认不改正式文件。`--apply` 只在所有校验通过、用户明确确认且 unified diff 已展示后执行。输出 `doc/selected-patches.md` 时保留生成时间、输入文件 Git SHA、aggregate/OpenWrt SHA、候选 ID、人工理由和验证状态。
