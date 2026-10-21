# Stage、构建与 CI

## 本地验证

```bash
python3 scripts/merge-manifest.py aggregate/patches/MANIFEST \
  --rules local/manifest.rules --check --stats
python3 scripts/merge-manifest.py aggregate/patches/MANIFEST \
  --rules local/manifest.rules.v1-safe --check --stats
scripts/stage.sh --tier func
scripts/stage.sh --tier v1-safe
scripts/audit-local.sh
```

`stage.sh` 本身就是纯 stage（合成 `.stage/` 后退出，不构建）；`--stage-only` 参数在
`build-mine.sh` 上（`build-mine.sh v1-safe --stage-only` = stage + rules 审计后停止）。
stage 不是无副作用命令：执行前报告 `.stage/` 将被 rsync `--delete` 重建，且可能改写构建脚本。`audit-local.sh` 检查 rules、目标、本地补丁引用、配置一致性和个人配置残留。

真实构建：

```bash
scripts/build-mine.sh v1-safe --tree <openwrt-tree> --dry-run
scripts/build-mine.sh stock --tree <openwrt-tree>
```

`build-mine.sh` 要求 OpenWrt 树含 `.git` 和 `scripts/feeds`，并检查 Linux `6.18.44`。上游构建可能对源码树执行 `git reset --hard` 和 `git clean -fd`；未提交改动必须先报告并获得确认。产物位于源码树 `bin/targets/airoha/an7581/`，不在 `.stage/`。

## CI 门禁

workflow_dispatch 前必须确认：

- review 文件中没有 pending 或非法字段；
- 来源 URL、完整 SHA 和 patch hash 已验证；
- `generate-selection.py --apply` 的输入与当前 commit 一致；
- 两档 MANIFEST/ORDER/audit 均通过；
- OpenWrt ref 与 `config/source-lock.env` 一致，除非用户明确选择其它 ref 并接受风险；
- profile 是 `stock` 或 `v1-safe`；
- 是否创建 Release 单独确认。

Actions 建议顺序：

1. checkout 本仓库；
2. 校验 `patch-review.md`、来源 pin 和选择集生成记录；
3. clone OpenWrt 并 checkout 完整 ref；
4. 运行 `generate-selection.py --apply`、`audit-local.sh` 和两档 ORDER 检查；
5. 运行 stage；
6. 执行现有 build；
7. 无论成功失败都上传 review、selected-patches、MANIFEST、ORDER、source-lock 和日志；
8. 仅成功且 release 输入明确为 true 时进入 release job。

artifact 必须记录 aggregate/OpenWrt 完整 SHA、review commit、生成器版本、profile、Actions run 信息和当前 conversation 提供的 model 字段。不得记录 API key、token、完整环境变量或完整对话。
