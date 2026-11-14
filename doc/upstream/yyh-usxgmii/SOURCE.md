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

**状态（2026-11-14）：已合入 `target/linux/airoha/patches-6.18/`，编号方案见
`doc/yyh-usxgmii-porting.md` §9.1。** 本目录仍保留原文快照用于离线对比。

除上表 17 个补丁外，2026-11-14 追加固化了 7 个 PCS 基础层补丁
（`620`/`621`/`622`/`623`/`624`/`628`/`629`）——它们是我方原先缺失、
但 625 与 630–634 依赖的前置状态。

`REPLACED-our-625.patch` / `REPLACED-our-9994.patch` 是被 YYH 等价版替换掉的
我方旧补丁，留作审计凭证。

注意：YYH 的 `9999-30..35` 是 USXGMII replay 系列，与本仓库同编号的
**NPU 恢复系列完全不同**，切勿直接覆盖。
