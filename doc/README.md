# 文档索引（doc/）

本目录集中存放仓库的**全部说明 / 介绍类文档**。仓库根 `README.md` 已精简为项目说明，
详细内容在此处按主题拆分，便于长期维护。

## 运营文档（构建与维护）

| 文档 | 内容 |
|------|------|
| [build.md](build.md) | 快速开始、构建流水线、GitHub Actions、已定位的环境坑、版本锁定 |
| [rules.md](rules.md) | `local/manifest.rules*` 语法与选择集（停用 `-` / 提档 `^` / 追加 `+`） |
| [audit.md](audit.md) | `audit-local.sh` 自检：rules 语法、端口命名一致性、无个人配置残留 |
| [config-ownership.md](config-ownership.md) | 配置归属铁律：A/B 类进固件，C 类（SSID/密码/自定义 MAC）不进 |
| [maintenance.md](maintenance.md) | 长期维护：监控上游更新 + 逐条裁决工作流（check-upstream.sh） |
| [scripting.md](scripting.md) | 脚本编写约定（C locale、grep 跨平台等血泪教训） |

## 设计 / 决策文档（仓库外归档）

> 以下设计 / 决策类文档置于**本仓库外**的本地工作目录，**不随本仓库发布**，
> 仅作历史决策记录，便于长期维护时回溯：
> kickoff、配置兼容层、补丁清单、下游构建计划、下游操作手册、func 档评审、刷机前清单、
> WAN TX 卡住排查、代码复审报告（REVIEW-2026-09-17）。
> 其中个人配置（无线密码 / WAN MAC / 个人 SSID）均已脱敏为 `<REDACTED:…>`，固件本身从不携带这些信息。
