# xr1710g_openwrt/ — XR1710G func ·构建骨架

本目录是 **XR1710G（Gemtek / Airoha EN7581 / MT7996 Wi‑Fi7）func 固件** 的
构建骨架仓库。它**不含 OpenWrt 源码**，但内置了冻结的 aggregate 补丁层；aggregate 来自 `genshanxinli/xr1710g-openwrt` 的固定快照，作为本项目内部文件使用，构建时不会 clone、fetch 或自动更新。

- 内置 aggregate：[`aggregate/`](aggregate/)（冻结快照，项目内部文件；来源和复制基线见 `config/source-lock.env`）
- OpenWrt 源码树：单独准备，脚本通过 `--tree` / `OPENWRT_DIR` 指定
- 设计 / 决策文档：置于本仓库内的 `doc/` 与 `upstream-decisions.md`

---

## 档位

| 档位 | 说明 | 活动补丁 |
|------|------|---------|
| `stock`（func 正式档） | 完整选择集 | **104** |
| `v1-safe`（保守档，首次刷机建议） | 最小差异、不提档实验补丁 | **64** |

活动补丁数由 `scripts/merge-manifest.py` 实算（内置 aggregate 快照 `244d433`）。

## 目录结构

```
xr1710g_openwrt/
├── aggregate/        # 内置冻结的补丁聚合层（不作为外部仓库引用）
├── local/            # 本项目唯一事实来源（手工维护）
│   ├── manifest.rules / manifest.rules.v1-safe   # 两档选择集定义
│   ├── patches/       # 本地自研补丁 9501/9601/9602
│   └── seed.local.diff
├── scripts/          # 构建工具链（stage / build / audit / check-upstream / merge-manifest）
├── upstream-decisions.md   # 上游更新裁决账本
└── doc/              # 全部说明 / 介绍类文档（见 doc/README.md 索引）
```

## 文档

详细文档全部集中在 [`doc/`](doc/README.md)：

- [构建与使用](doc/build.md) — 快速开始 / 构建流水线 / GitHub Actions / 环境坑 / 版本锁定
- [rules 语法与选择集](doc/rules.md)
- [自检](doc/audit.md) — `audit-local.sh`
- [配置归属](doc/config-ownership.md) — 哪些进固件、哪些不进
- [长期维护：监控上游](doc/maintenance.md) — 逐条裁决工作流
- [脚本编写约定](doc/scripting.md)

## 快速开始

```bash
# 1) 准备一棵 OpenWrt 源码树（只需一次，建议接近快照日期）
git clone https://github.com/openwrt/openwrt.git <源码树>
cd <源码树> && git checkout <openwrt_ref>   # 默认 7f4f824691… (Kernel 6.18.44 基线)

# 2) 构建（v1-safe 保守档首次刷机建议）
scripts/build-mine.sh v1-safe --tree <源码树>
# 或走 GitHub Actions：gh workflow run build.yml -f profile=v1-safe
```

细节见 [doc/build.md](doc/build.md)。