# YYH USXGMII 修复移植评估（2026-11-14）

> 目标：把 `YYH2913/openwrt` 的 `xr1710g-6.18-integration` 分支中针对
> **"carrier 正常但 TX 死"** 的补丁集合入本 fork（`new_main`）。
> 本文档是**评估与方案**，尚未改仓库；执行前需逐阶段验证。

## 1. 问题与来源

现场（2026-11-14，设备 `r0-44198f7`，运行 12 天）：

- WAN `eth1`（GDM2 / USXGMII / RTL8261BE @ MDIO 0x08）carrier=1、10G、Link detected: yes
- RX 活（收到对端 ARP 请求、有 RA/ULA/GUA IPv6）；**TX 死**（DHCP Discover 发出但无 Offer，ping 192.168.1.1 全丢）
- `ifstatus wan` = `up:false, pending:true`，无 IPv4、无默认路由 → 从上游网络"消失"
- `ifdown wan; ifup wan` 无效；`ip link set eth1 down/up` 触发完整 AN + flow_s pulse + Link Up 10G（carrier_changes 11→13）**仍不恢复**
- GDM 硬件 TX 计数冻结；dmesg 无 `No FBCK Lock`

来源定位：YYH 的 `d45019449`（2026-10-11）commit message 逐字对应：

> "renegotiating the LAN copper link from 2.5G to 1G can leave **return traffic unusable
> even though PHY speed, PCS negotiation and rate adaptation registers have converged.
> Restoring 2.5G does not recover traffic, while a complete interface stop/open does**"
>
> "The normal PCS link-down path only stops the MAC interfaces. **Unlike pre_config,
> it does not reset port MAC logic.**"

`9999-41` 补充软件层根因："**phylink can publish carrier after completion fails**"。

## 2. 补丁全集（17 个，约 480 行新增）

来源分支 `xr1710g-6.18-integration`（最后 push 2026-11-07），
本地副本 `/tmp/yyh-patches/`（临时，需固化）。

| 编号 | 作用文件 | 作用 |
|---|---|---|
| `630` | pcs-airoha-common.c | in-band USXGMII 状态门控在 AN 完成 |
| `631` | pcs-airoha-common.c/.h | 完成的 live 链路速率变化时强制 relink |
| `632` | pcs-airoha-common.c | **link down 后复位 port MAC logic**（保留 stop 态至 link up） |
| `633` | pcs-airoha-common.c/.h | 把该复位推迟到 link up |
| `634` | **phylink.c/.h** + pcs-airoha-common.c/.h | **新增 `pcs_link_up_complete` 回调**；MAC fragment 就绪后才清 STOP 放数据 |
| `744-03` | realtek_main.c | flow_s 恢复独占（避免与通用路径竞争） |
| `744-04` | realtek_main.c | 上报 RTL826x 实际协商速率 |
| `9999-30` | airoha_eth.c/.h | USXGMII 速率变化后 paired PHY/PCS replay（workqueue） |
| `9999-31..35` | airoha_eth.c | replay 的收口：限 port0、失败 fail-closed、PHY down/up 同步、重启 PHY 状态机 |
| `9999-36` | realtek_main.c | 缩短板级 SerDes 重试宽限 |
| `9999-40` | airoha_eth.c | **补 `ethtool -S` 私有统计**（我方现场撞到 "no stats available"） |
| `9999-41` | **phylink.c/.h** + pcs-airoha-common.c | 给 completion 传最终 TX/RX pause，错误在 carrier 发布前上抛、拆链路让 in-band poll 重试 |
| `9999-42` | airoha_eth.c + pcs-airoha-common.c | AN7581 应用 resolved pause，completion 里清 `RXMPI_STOP/RXMBI_STOP` |

另有 11-07 三个 commit：`9e44788d7`/`d6473ac01`/`d3bd756a3`，对应 9999-40/41/42。

## 3. 依赖链（必须按序，不能挑着合）

```
703-02 (我方已有, generic/backport-6.18)  ── 提供 phylink_replay_link_begin/end
        │
        ├── 630 → 631 → 632 → 633 → 634      （PCS 侧机制链，634 引入 completion hook）
        │                                    │
        │                                    └── 9999-41 → 9999-42 （pause 传递与应用，RFC）
        │
        ├── 9999-30 → 31 → 32 → 33 → 34 → 35 （MAC 侧 paired replay，依赖 703-02）
        │
        ├── 744-03 / 744-04 / 9999-36        （Realtek PHY 侧，依赖 743/744 系列）
        │
        └── 9999-40                          （独立：ethtool -S 统计）
```

**关键结论**：我方基线**没有** `mac_link_up_pending` / `pcs_link_up_complete` 这套机制
（由 634 引入，632/633/9999-41/42 全部依赖）。所以这不是"贴几个补丁"，
而是引入一整条 phylink↔PCS↔MAC 的完成回调链。

## 4. 兼容性核验结果（已实测）

| 检查 | 结果 |
|---|---|
| 5 个 PCS 基础补丁（`310-02/06/07/09/10`）YYH vs 我方 | **逐字节相同** ✓ |
| `703-02`（phylink replay helpers）YYH vs 我方 | **逐字节相同** ✓（我方在 `generic/backport-6.18/`，YYH 同路径） |
| `phylink_replay_link_begin/end` 我方是否具备 | ✓ 有（703-02 提供） |
| `634` 的 phylink.c/.h 部分 `git apply --check` 到 6.18.55 | **✗ 不通过**（上下文不匹配） |
| 应用 702/703-01/703-02 后再测 634 | **仍 ✗** → 确认需重锚，非缺前置补丁 |
| 我方 6.18.55 phylink.c 与 YYH 基线差 | 约 55 行（YYH 有 `phylink_pcs_link_down` 静态辅助函数，我方无）；但 `phylink_link_up` 中 `mac_link_up` → `activate_lpi` 的插入点语义一致 |

**判断**：634/9999-41 对 phylink 的改动属**可重锚**（插入点语义一致、周边行号不同），
不是语义不兼容。但必须人工重做 hunk，不能原样合。

## 5. 冲突点

1. **编号撞车（严重）**：`9999-30..35` 我方是 **NPU 恢复**系列，YYH 是 **USXGMII replay** 系列，
   同名不同内容。直接复制会覆盖我方 NPU 补丁。
   → 建议 YYH 系列重编号为 `9999-50..`（或按性质分 `9998-*`），并保留来源注释。
2. **`625` 同号不同内容**：我方 `625-…-update-USXGMII-rate-adaptation-on-link-up`；
   YYH `625-…-align-link-modes-with-SDK`。YYH 的 630/631 可能隐含其 625 的语义，
   需确认是否影响速率适配逻辑，必要时二选一或合并。
3. **`744` 系列**：我方 `742/743/744`（RTK SerDes），YYH `743`、`744-01`、`744-03/04`。
   两边编号体系已分叉，744-03/04 依赖的 `patch_rtk_serdes`/`flow_s` 私有字段我方
   （由 743/744 提供）具备，但上下文需逐个验证。
4. **RFC 状态**：`9999-41/42` 是 RFC（YYH 注明"pending agreement with phylink/PCS maintainers"）。
   自用 fork 不受上游评审限制，但意味着未来上游 API 可能变化，rebase 时要重新评估。
5. **补丁集差异**：YYH 分支 232 个 patches-6.18 vs 我方 176 个；YYH 有而我没有的
   `742/980/939/940/998/9991/9992/9994/9996` 等可能改变同一文件的上下文。

## 6. 建议的分阶段执行方案

**阶段 0 · 固化资产**：把 17 个补丁原文存入仓库（`doc/upstream/yyh-usxgmii/` 或
`local/reference/`），并记录来源分支 + commit SHA，避免上游变动后失联。

**阶段 1 · 独立低风险项先行**（不动 phylink 核心）
- `9999-40`（ethtool -S）→ 重编号 `9999-50`，验证编译 + 设备上 `ethtool -S eth1` 出数
- `744-03`、`744-04`、`9999-36`（Realtek PHY 侧）→ 重编号 `745-*`，逐个 apply dry-run

**阶段 2 · 核心机制链**（需重锚，风险最高）
- 重做 `634` 的 phylink.c/.h hunk 到 6.18.55 上下文
- 按序 `630 → 631 → 632 → 633 → 634'`，每个都做 `git apply --check` + 编译
- 再 `9999-41' → 9999-42'`

**阶段 3 · MAC 侧 replay**
- `9999-30..35` 重编号 `9999-60..65`，依赖 703-02（已具备）
- 与我方 `9991`/`9996`（airoha_eth.c）逐个验上下文

**阶段 4 · 验证**
- CI 构建（约 50 分钟）→ 解包 rootfs 核对 → 刷机
- **受控复现测试**（YYH 的验证法）：WAN 侧 10G↔5G↔2.5G 速率往返 3 次，
  观察 DHCP 是否保地址、双向流量是否都通
- 现场回归：`ifdown wan; ifup wan` / `ip link down/up` 后 TX 是否恢复

**回滚**：整套改动都在 `target/linux/*/patches-6.18/` 与 `generic/backport-6.18/`，
以 commit 为单位可整批 revert；不动板级 DTS / feed / seed。

## 7. 风险与提醒

- 634/9999-41 改的是 **通用 phylink 核心**，影响所有用 phylink 的目标（虽然只在
  `airoha/patches-6.18` 目录里应用，但补丁作用于内核通用文件）——重锚时必须确保
  `pcs_link_up_complete` 为**可选回调**，其他 PCS 驱动行为不变（YYH 已这样设计）。
- 阶段 2 前不要碰设备现场；当前设备重启后即恢复，故障可再复现。
- 不建议自己另写 9999-36：YYH 已完整实现并做受控验证，重复造轮子且覆盖不全。
- 上游动态：PR #26296（akorshun，11-13 rebase，仍 open）只有板级支持，
  不含任何 PCS 修复；YYH 明说这批改动"merging into mainline may be complicated"，
  **等上游合入不现实**，自用 fork 需自行移植。

## 8. 待用户决策

1. 是否按上述 4 阶段执行（我倾向先做**阶段 0 + 阶段 1**，验证编译后再推进核心链）
2. 补丁固化位置（`doc/upstream/` vs `local/reference/`）
3. 重编号方案（`9999-50+` / `9998-*`）确认
4. `625` 语义冲突：保留我方版本 / 换成 YYH 版 / 合并
