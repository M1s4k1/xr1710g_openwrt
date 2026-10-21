# aggregate/ — 退役参考目录（RETIRED REFERENCE）

**状态：退役（2026-10-21 架构转向起，构建不再使用）。**

## 发生了什么

本项目原来以 `genshanxinli/xr1710g-openwrt` 的冻结快照（`244d433`，2026-09-20 复制）
为构建基座：`stage.sh` 把本目录 rsync 进 `.stage/`，`merge-manifest.py` 按
`local/manifest.rules`  curation 其 MANIFEST，再由其 `scripts/build.sh` 完成构建。

2026-10-21 起，基座切换为 **OpenWrt 主线**（pin `63f702f1c`，kernel 6.18.55）：
- 板级使能已移植为本仓库补丁：`local/patches/9401`（Device 条目，原 9000）、
  `9402`（板 DTS，原 9001）、`9403`（uboot，原 9002）；`9501/9601/9602/9603` 原样保留
  （9601/9602 由“修改型”转为“创建型”）。
- 驱动/框架层一律用主线自带的（airoha_eth v7.2 系列、LRO、phylink、DT overlay 等）。
- fanboy/vendor 桶（W1700K 专用料）未移植；rtl8261ce 驱动经 005 裁决确认不需要。

## 本目录现在的用途

1. **移植来源备查**：Phase 2 移植 NPU offload 栈（`patches/packages/mt76-*`、
   `patches/root/9018-9099` 中的 NPU/flowsense/PPE 系）时的参考原文。
2. ** provenance 查证**：本地补丁头部标注的“原体”路径指向本目录。

## 不要做什么

- 不要把它加回构建链路（stage.sh / merge-manifest.py 已随转向退役）。
- 不要手工编辑本目录——它是冻结快照；要改内容应改本地补丁并在头部记录。
- 更新它没有意义（它是历史快照，不是跟踪中的上游）。

## 关键坐标（便于检索）

| 内容 | 位置 |
|---|---|
| 补丁总清单（含档位注释与决策记录） | `patches/MANIFEST`、`patches/ORDER` |
| 板级使能（已移植） | `patches/root/9000-9002-*.patch` |
| NPU offload 栈（Phase 2 候选） | `patches/packages/mt76-*.patch`、`patches/root/90{18-23,32,35-39,47,48}-*.patch` |
| W1700K 专用料（未移植） | `patches/vendor/fanboy/*` |
| 构建脚本（已退役，机制参考） | `scripts/build.sh`、`scripts/apply-patches.sh` |
| seed 符号（已合并进 local/seed.local.diff） | `config/seed-config.diff` |
| 包 feed 数据（Phase 2 候选） | `packages-xr1710g/` |
