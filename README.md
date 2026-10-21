# xr1710g_openwrt/ — XR1710G 固件仓库（OpenWrt 主线为基座）

本目录是 **XR1710G（Gemtek / Airoha EN7581 / MT7996 Wi‑Fi7）固件**的差异仓库。
它**不含 OpenWrt 源码**：构建时把 `local/patches/` 的补丁集应用到一棵
pinned 的 OpenWrt 源码树（`config/source-lock.env` 的 `OPENWRT_REF`）。

**架构沿革（重要）**：2026-10-21 前本项目基于 `genshanxinli/xr1710g-openwrt`
的冻结 aggregate 快照；当日起基座切换为 **OpenWrt 主线**，aggregate 退役为参考目录
（`aggregate/REFERENCE.md`），板级使能移植为本地补丁。未来的更新一律向 OpenWrt
主线靠拢：驱动/框架用主线自带，本项目只保留板级差异与确有必要的能力增强。

- 基座：OpenWrt 主线，pin 与内核版本见 [`config/source-lock.env`](config/source-lock.env)
- 本项目差异：[`local/patches/`](local/patches/)（应用顺序 = 文件名字典序）
- 运营文档：[`doc/`](doc/README.md)（构建 / rules / 自检 / 维护 / 脚本约定索引）
- 设计 / 决策文档：置于本仓库外的本地工作目录，不随本仓库发布

---

## 档位

| 档位 | 说明 | 活动补丁 |
|------|------|---------|
| `v1-safe`（保守档，首次刷机建议） | 板级使能 + 命名 + 初始配置 + 主题 | **7** |
| `func`（正式档） | Phase 1 与 v1-safe 同集；Phase 2 起追加 NPU offload 栈 | **7**（Phase 2 后增加） |

## 目录结构

```
xr1710g_openwrt/
├── local/            # 本项目唯一事实来源（手工维护）
│   ├── manifest.rules / manifest.rules.v1-safe   # 两档补丁收录清单（新语义）
│   ├── patches/       # 本地补丁：9401-9403（板级使能，移植自 aggregate）+ 9501/9601/9602/9603
│   └── seed.local.diff   # 设备与预装包选择（.config seed）
├── config/
│   ├── source-lock.env    # 三重锁定：OpenWrt pin / 内核版本
│   ├── feeds.custom.conf  # 自定义 feed（packages-xr1710g，由 9603 补丁创建）
│   └── upstream-sources.yml  # 参考来源登记（openwrt=基座；fanboy 已废弃）
├── scripts/          # apply-patches / build-mine / audit-local / check-upstream / review-upstreams
├── aggregate/        # 退役参考目录（构建不再使用；见 REFERENCE.md）
├── doc/              # 全部说明 / 介绍类文档（见 doc/README.md 索引）
└── upstream-decisions.md   # 多来源巡检评审账本（历史轮次）
```

## 文档

详细文档全部集中在 [`doc/`](doc/README.md)：

- [构建与使用](doc/build.md) — 快速开始 / 构建流水线 / GitHub Actions / 版本锁定
- [收录清单语法](doc/rules.md) — `local/manifest.rules*` 新语义（转向后）
- [自检](doc/audit.md) — `audit-local.sh`
- [配置归属](doc/config-ownership.md) — 哪些进固件、哪些不进
- [长期维护](doc/maintenance.md) — 基座更新跟踪（check-upstream.sh）与评审流程

## 快速开始

```bash
# 1) 准备 OpenWrt 源码树（只需一次），checkout 到 pin
git clone https://github.com/openwrt/openwrt.git <源码树>
cd <源码树> && git checkout 63f702f1c0cebe2587aac10b63a02e964fc2a558

# 2) 构建（v1-safe 保守档首次刷机建议）
scripts/build-mine.sh v1-safe --tree <源码树>
# 或走 GitHub Actions：gh workflow run build.yml -f profile=v1-safe
```

细节见 [doc/build.md](doc/build.md)。
