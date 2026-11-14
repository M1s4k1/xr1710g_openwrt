# 来源快照（只读参考，不参与构建）

- **来源**：`YYH2913/openwrt` 分支 `xr1710g-6.18-integration`
- **取快照时间**：2026-11-14
- **分支最后 push**：2026-11-07T11:20:35Z
- **关键 commit**：
  - `d45019449` (2026-10-11) `airoha: recover completed USXGMII speed transitions`
    —— 引入 630/631/632/633/634、744-03/04、9999-30..36
  - `d3bd756a3` (2026-11-07) `airoha: expose GDM counters through ethtool -S` → 9999-40
  - `d6473ac01` (2026-11-07) `airoha: pass resolved pause to PCS link-up completion` → 9999-41
  - `9e44788d7` (2026-11-07) `airoha: apply resolved pause settings on AN7581` → 9999-42
- **原始路径**：`target/linux/airoha/patches-6.18/<文件名>`

本目录仅作来源固化与离线对比，**不参与构建**。真正合入时按
`doc/yyh-usxgmii-porting.md` 的重编号与重锚方案，把补丁放进
`target/linux/airoha/patches-6.18/`（或对 phylink 的部分放进
`target/linux/generic/backport-6.18/`）。

注意：YYH 的 `9999-30..35` 是 USXGMII replay 系列，与本仓库同编号的
**NPU 恢复系列完全不同**，切勿直接覆盖。
