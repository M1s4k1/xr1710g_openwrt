# 补丁应用、构建与 CI（2026-10-21 架构转向后重写）

## 本地验证

```bash
scripts/audit-local.sh                                   # [A]-[H] 自检（只读）
scripts/apply-patches.sh --tree <openwrt-tree> --tier func --dry-run
scripts/apply-patches.sh --tree <openwrt-tree> --tier v1-safe --dry-run
```

`apply-patches.sh` 校验源码树 HEAD == `config/source-lock.env` 的 `OPENWRT_REF`，
按档位清单应用 `local/patches/`；`--dry-run` 只做 `--check`。它**只写用户显式指定的
源码树**；树上未提交改动会先被 `build-mine.sh` 复位（`reset --hard` + `clean -fdx`）。

真实构建：

```bash
scripts/build-mine.sh v1-safe --tree <openwrt-tree> --dry-run
scripts/build-mine.sh func --tree <openwrt-tree>
```

`build-mine.sh` 要求 OpenWrt 树含 `.git` 和 `scripts/feeds`，硬门禁内核版本
（`source-lock.env` 的 `LINUX_VERSION`，当前 6.18.55），并在构建配置阶段审计
seed 符号逐一进 `.config`。产物位于源码树 `bin/targets/airoha/an7581/*.itb`。

## CI 门禁

workflow_dispatch 前必须确认：

- review 文件中没有 pending 或非法字段；
- 来源 URL、完整 SHA 已验证；
- 两档 `apply-patches.sh --dry-run` 与 `audit-local.sh` 均通过；
- OpenWrt ref 与 `config/source-lock.env` 一致，除非用户明确选择其它 ref 并接受风险；
- profile 是 `func` 或 `v1-safe`；
- 是否创建 Release 单独确认。

Actions 实际顺序（`.github/workflows/build.yml`）：

1. checkout 本仓库；
2. clone OpenWrt 并 checkout 完整 ref（内核版本硬门禁）；
3. audit-local；
4. apply-patches（profile 档）；
5. feeds + defconfig + seed + ccache 注入；
6. make 构建；
7. 无论成功失败都上传日志；成功上传 `.itb`/manifest；
8. 仅成功且 release 输入明确为 true 时进入 release job。

artifact 必须记录 OpenWrt 完整 SHA、review commit、profile、Actions run 信息和当前
conversation 提供的 model 字段。不得记录 API key、token、完整环境变量或完整对话。
