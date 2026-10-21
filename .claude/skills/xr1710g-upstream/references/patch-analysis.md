# 补丁分析

## 必填事实

每个候选必须包含：

```text
id: <稳定唯一 ID>
source: <config/upstream-sources.yml 中的 id>
source_url: <HTTPS URL>
source_commit: <完整 SHA>
compare_base: <完整 SHA>
source_date: <ISO-8601>
candidate_patch: <隔离目录内相对路径>
patch_sha256: <hash>
files: <变更文件列表>
hardware: <硬件范围或 unknown>
openwrt_dependency: <ref/version 或 unknown>
linux_dependency: <版本或 unknown>
```

事实必须能回到 Git 元数据、diff 或现有仓库文件。没有证据的硬件兼容性、性能收益和稳定性结论写 `unknown`，不得用模型记忆补齐。

## AI 字段

```text
ai-summary:
ai-overlap: none|duplicate|partial
ai-conflict: none|HIT|HIT-CFG|COLLIDE|ordering|dependency|unknown
ai-recommended-tier: stock|v1-safe|experimental|reject
ai-risk: low|medium|high|unknown
ai-confidence: low|medium|high
ai-validation:
ai-open-questions:
```

`HIT` 表示候选修改 `local/manifest.rules` 中停用或提档的补丁；`HIT-CFG` 表示候选修改本地 ROOT 补丁所依赖的 `files/` 配置；`COLLIDE` 表示上游编号与本地补丁编号或路径命名冲突。重复与部分重叠必须列出双方 patch 路径和 hunks，不能只写“类似”。

## 人工字段

```text
absorb-stock: y|n
absorb-v1-safe: y|n
status: pending|accept|reject
reason: <人工理由；reject 也必须说明>
reviewer: <人工填写>
reviewed_at: <ISO-8601>
```

AI 不得填写或推断人工字段。`status: accept` 不等于两个档位都吸收；两个 `absorb-*` 字段分别决定档位。

## 分析顺序

1. 核对来源 SHA、patch hash 和 diff 范围。
2. 对照 aggregate/MANIFEST/ORDER 识别新增、删除、改档和顺序变化。
3. 对照两份 rules 和本地 `patches/` 识别重复、HIT、HIT-CFG、COLLIDE。
4. 检查目标目录、ROOT/copy 语义、依赖顺序和互斥补丁。
5. 核对 OpenWrt 与 Linux 基线，标出超出 `6.18.44` 的风险。
6. 只输出建议和验证命令，等待人工决定。
