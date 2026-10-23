# Patch Review

<!-- generator-schema: xr1710g-patch-review/v1 -->

> **本轮次**：2026-10-21（首次多来源巡检）
> **规则**：AI 只写事实字段与 `ai-*` 建议；`absorb-stock` / `absorb-v1-safe` / `status` / `reason` /
> `reviewer` / `reviewed_at` 由人工填写。所有条目初始为 `status: pending`（待裁决），
> 未填写前不得进入选择集。
> **原始数据**：`scripts/review-upstreams.py` 巡检报告 + 人工补采日志（见文末「采集与验证记录」）。

---

## 本轮事实总览

| 来源 | 基线 → tip | 新提交 | 焦点路径相关 | 采集状态 |
|---|---|---|---|---|
| openwrt | `7f4f824691` → `63f702f1` | 1303 | 内核 bump×5、airoha×8、mt76×1、generic×25 | advance |
| yyh-openwrt | `c82129e734` → 同点 | 0 | — | no-update |
| yyh-mt76 | `2dd6e4c8` → 同点 | 0 | — | no-update |
| yyh-http-uboot | `53b73174c` → 同点 | 0 | — | no-update |
| fanboy-openw1700k | `ca46e0a4e` → `f81b8b3` | **无法计算** | — | **baseline-orphaned：基线被 force-push 孤立** |
| gilly-w1700k | `38806db2d` → `8f4812bb` | 25 | 内核 bump 串、mt76 bump、应用层 | advance |
| naoki-xr1710g | `5a71e6a53` → `c15760c7` | 150 | airoha×~20、kernel rebase、config | advance |
| hurryman-openw1700k-test | `73c3ab308` → 同点 | 0 | — | no-update |

> 注：4 个 `baseline-unresolved` / `network-fail` 来源已用部分克隆（`--filter=blob:none` + deepen）
> 人工补采，**不是无更新**。openwrt 的登记基线即本项目的构建 pin（Linux 6.18.44 锚点）。

---

## 候选条目

### Candidate: openwrt-20261021-001

```text
id: openwrt-20261021-001
source: openwrt
source_url: https://github.com/openwrt/openwrt.git
source_commit: 63f702f1c0cebe2587aac10b63a02e964fc2a558
compare_base: 7f4f824691fb2258afe9eb9a37da46d3557c4043
source_date: 2026-10-03
candidate_patch: n/a（本轮未落 patch 文件，以提交 SHA 清单为事实载体）
patch_sha256: n/a
files: target/linux/generic/kernel-6.18（LINUX_VERSION-6.18 = .44 → .55）
hardware: 全平台（内核基线）
openwrt_dependency: 7f4f824691fb2258afe9eb9a37da46d3557c4043
linux_dependency: 6.18.44 → 6.18.55
ai-summary: 6.18.45/51/52/53/55 五次 bump（5edc3c1 08-19、829a6e6 09-11、ddbf9c8 09-14、411a811 09-22、db9616b 10-03）。本项目整套补丁集锚定 6.18.44，CI 有内核版本硬门禁。
ai-overlap: none
ai-conflict: dependency
ai-recommended-tier: reject
ai-risk: high
ai-confidence: high
ai-validation: 若未来跟进：两档 stage --stage-only + audit-local.sh + audit-order + 完整构建；预期大量补丁需 rebase
ai-open-questions: 何时启动 6.18.5x rebase 专项（需与 aggregate 快照推进协同）
absorb-stock: n
absorb-v1-safe: n
status: reject
reason: 维持 6.18.44 pin；rebase 留待与 aggregate 快照推进协同的专项
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: openwrt-20261021-002

```text
id: openwrt-20261021-002
source: openwrt
source_url: https://github.com/openwrt/openwrt.git
source_commit: 63f702f1c0cebe2587aac10b63a02e964fc2a558
compare_base: 7f4f824691fb2258afe9eb9a37da46d3557c4043
source_date: 2026-10-14
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/airoha/patches-6.18（airoha_eth LRO offload）
hardware: Airoha EN7581 系（AN7581/XR1710G 同 SoC 家族）
openwrt_dependency: 7f4f824691fb2258afe9eb9a37da46d3557c4043
linux_dependency: 6.18.44+
ai-summary: e1bd479「airoha: backport LRO offload patch」（10-14）。
ai-overlap: duplicate
ai-conflict: none
ai-recommended-tier: reject
ai-risk: low
ai-confidence: high
ai-validation: diff e1bd479 与 aggregate/patches/vendor/fanboy/11-airoha-lro-default-0e90a420.patch（default 档，HW GRO/LRO 能力载体）及其后续 "enable LRO by default" 提交
ai-open-questions: 上游版本是否比 fanboy 线更新（若仅是同一内容的不同封装则确认 reject）——已 diff 取证：非重复，为 v7.2 换代实现
absorb-stock: y
absorb-v1-safe: n
status: accept
reason: 接受上游 v7.2 LRO 换代实现（原生多设备互斥 + 8 LRO 硬件队列 + 官方 8.2Gbps 实测），替换 fanboy/11 + 9990 血统；rebase 到 6.18.5x 与其余补丁裁决完成后统一实施（本次仅登记决定，未动 rules）；v1-safe 不进（首刷保守档最小差异）
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: openwrt-20261021-003

```text
id: openwrt-20261021-003
source: openwrt
source_url: https://github.com/openwrt/openwrt.git
source_commit: 63f702f1c0cebe2587aac10b63a02e964fc2a558
compare_base: 7f4f824691fb2258afe9eb9a37da46d3557c4043
source_date: 2026-10-14
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/airoha/patches-6.18（GDM3/GDM4 QoS；additional airoha_eth）
hardware: Airoha EN7581 系
openwrt_dependency: 7f4f824691fb2258afe9eb9a37da46d3557c4043
linux_dependency: 6.18.44+
ai-summary: d4083ed「on-demand GDM3/GDM4 QoS configuration」（10-14）+ 059895c「additional airoha_eth patches」（10-13）。aggregate 无对应物（仅 9050 GDM MIB 为 #EXP，主题不同）。
ai-overlap: none
ai-conflict: unknown
ai-recommended-tier: pending
ai-risk: medium
ai-confidence: medium
ai-validation: 取两个提交的 patch 内容，对照 9501 网口命名补丁（gdm2→eth1 / gdm4→eth2）检查是否引用 GDM 节点名；在一次性 OpenWrt 树 dry-run
ai-open-questions: QoS 补丁是否按设备名寻址 GDM 节点（若是则与 9501 冲突需适配）；059895c 的完整文件清单未逐项核对——已核对（2026-10-21）：d4083ed 为驱动层补丁（airoha_eth.c/.h），与 9501 的 DTS netdev-name / board.d 两层不相交、零冲突；059895c 实为 18 文件 +1559/−571 大刷新：8 个新驱动修复（MODULE_LICENSE GPL-2.0 修正、BQL underflow、MIB 无损化等）+ 对 916-02 的 129 行修改（将随 002 的 v7.2 换血作废）
absorb-stock: y
absorb-v1-safe: n
status: accept
reason: 挂起实施，与 002 同批归入 6.18.5x rebase 专项；实施时对 059895c 的 18 文件逐项甄别——8 个新驱动修复评估吸收，对 916-02/defer-GDM3/MTU 的修改预计随 v7.2 作废剔除；GDM 与 9501 无冲突已证实；v1-safe 不进
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: openwrt-20261021-004

```text
id: openwrt-20261021-004
source: openwrt
source_url: https://github.com/openwrt/openwrt.git
source_commit: 63f702f1c0cebe2587aac10b63a02e964fc2a558
compare_base: 7f4f824691fb2258afe9eb9a37da46d3557c4043
source_date: 2026-10-09
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/airoha/（image/DT overlay 构建机制）
hardware: AN7581 / AN7583
openwrt_dependency: 7f4f824691fb2258afe9eb9a37da46d3557c4043
linux_dependency: 6.18.44+
ai-summary: 599d105 启用 DT overlay 支持（09-18）、04499f8 AN7581 overlay（09-21）、7287a40 AN7583 overlay（10-09）。属构建机制变更；本项目经 aggregate 使用直接 DTS 补丁。
ai-overlap: none
ai-conflict: ordering
ai-recommended-tier: reject
ai-risk: medium
ai-confidence: medium
ai-validation: 随下次 aggregate 快照推进时整体评估（机制切换影响 image 生成与 FIT 产物）
ai-open-questions: overlay 机制与上游 image-commands 改动的耦合范围未评估——已对比取证（2026-10-21）：上游三个提交只重构 EVB 参考板（an7581-evb-emmc*.dts/.dtsi、an7581-evb.dts→multievb）与 an7581-npu-wlan.dtsi；我们的板文件 an7581-xr1710g-ubi.dts 及其 include 的 an7581-npu-mt7996.dtsi、9501 改的 netdev-name/board.d **均不在提交清单，零文件级冲突**；唯一间接接触点为 an7581.mk image 配方（需核对 xr1710g-ubi 条目上下文）
absorb-stock: y
absorb-v1-safe: n
status: accept
reason: 挂起实施，与 002/003 同批归入 6.18.5x rebase 专项；与我们的 DTS 体系零文件级冲突已证实；overlay 是板级主线化方向（9501 头部声明走社区 PR #22397），顺势接受成本近零；实施时核对 an7581.mk 中 xr1710g-ubi 条目；v1-safe 不进
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: openwrt-20261021-005

```text
id: openwrt-20261021-005
source: openwrt
source_url: https://github.com/openwrt/openwrt.git
source_commit: 63f702f1c0cebe2587aac10b63a02e964fc2a558
compare_base: 7f4f824691fb2258afe9eb9a37da46d3557c4043
source_date: 2026-09-15
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/airoha/（an7581 DTS：PHY LEDs、rtl8261c-firmware）
hardware: Gemtek W1700K（AN7581）；XR1710G 适用性未确认
openwrt_dependency: 7f4f824691fb2258afe9eb9a37da46d3557c4043
linux_dependency: 6.18.44+
ai-summary: 18304dd「an7581: add PHY LEDs for the Gemtek W1700K」（09-15）+ 5d0c434「add rtl8261c-firmware to the Gemtek W1700K」（09-09）。提交自述仅覆盖 W1700K。
ai-overlap: none
ai-conflict: unknown
ai-recommended-tier: pending
ai-risk: low
ai-confidence: low
ai-validation: 核对 XR1710G DTS 是否含 rtl8261c 节点 / PHY LED 定义（对照 aggregate DTS 补丁与 naoki RTL826x SerDes 提交 45bd32397）
ai-open-questions: XR1710G 的 10G SerDes 器件是否为 rtl8261c（若是则 firmware 补丁可能适用）——已取证（2026-10-21）：上游两提交仅覆盖 W1700K（18304dd 只改 an7581-w1700k-ubi.dts 与 01_leds 的 w1700k 分支；5d0c434 只改 an7581.mk 的 Device/gemtek_w1700k-ubi）；我们板镜像条目（aggregate 9000，真机验证）DEVICE_PACKAGES 仅 rtl826x-firmware，而同源 fanboy/09（default 活动档）给 W1700K 额外配 kmod-phy-rtl8261ce——两块板待遇分明，形成对照
absorb-stock: n
absorb-v1-safe: n
status: reject
reason: 上游两提交仅覆盖 W1700K；aggregate 作者按真机验证给 XR1710G 只配 rtl826x-firmware（同源 fanboy/09 给 W1700K 额外配 rtl8261ce kmod+固件，形成对照）；若将来实机 10G 口异常定位到 PHY 固件缺失，补一行 DEVICE_PACKAGES 成本极低，届时翻本条
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: openwrt-20261021-006

```text
id: openwrt-20261021-006
source: openwrt
source_url: https://github.com/openwrt/openwrt.git
source_commit: 63f702f1c0cebe2587aac10b63a02e964fc2a558
compare_base: 7f4f824691fb2258afe9eb9a37da46d3557c4043
source_date: 2026-10-08
candidate_patch: n/a
patch_sha256: n/a
files: package/kernel/mt76/Makefile（update to Git HEAD 2026-10-08）
hardware: MT7996（Wi-Fi7）
openwrt_dependency: 7f4f824691fb2258afe9eb9a37da46d3557c4043
linux_dependency: 6.18.44+
ai-summary: 98b1185 mt76 包更新（10-08）。aggregate 的 mt76 pin 与 mt76-00xx 系列补丁绑定特定上游提交（fanboy 新线 pin 01367e60），换 pin 需连带 rebase。
ai-overlap: partial
ai-conflict: dependency
ai-recommended-tier: pending
ai-risk: medium
ai-confidence: medium
ai-validation: 与 aggregate 快照推进同步评估；rebase 后跑 audit-patches / patch dry-run
ai-open-questions: 新 pin 与 mt76-0001/0003/0023 等补丁的兼容性未验证——已对比取证（2026-10-21）：现 pin 01367e60 实为 fanboy fork = 上游 be5ce791(08-13) + 1 个纯固件提交，驱动源码与上游一致；新 pin 467ae2e(10-08) = 89 提交 / 61 文件 / +2322−583，主体为 MT7996 MLO link 生命周期功能开发（非重构）；靶点重合：main.c(+804/我方5)、mcu.c(168/7)、npu.c(12/11)、mt7996.h(52/4)、pci.c(12/3)
absorb-stock: y
absorb-v1-safe: n
status: accept
reason: 挂起归入 6.18.5x rebase 批次（与 002/003/004 同批，一次做完省一轮 apply+验证）。实施要点：① 批次内技术风险最高项——default 档 NPU offload/MLO/radar/hwrro 均在射程内，完成后须 Wi-Fi 专项验证（不能只 boot test）；② 9067 固件 pin 需把 fanboy 固件提交重新嫁接到新 pin；③ mt76-0023（PCIe AER）随 pci.c 改动重评；v1-safe 不进
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: openwrt-20261021-007

```text
id: openwrt-20261021-007
source: openwrt
source_url: https://github.com/openwrt/openwrt.git
source_commit: 63f702f1c0cebe2587aac10b63a02e964fc2a558
compare_base: 7f4f824691fb2258afe9eb9a37da46d3557c4043
source_date: 2026-10-18
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/generic/（约 25 个 6.18 backport/config 提交）
hardware: 绝大多数与 XR1710G 无关（SFP、V4L2 ISP、MHI/Quectel、mt7530、rtl8365mb、rockchip、Aquantia 等）
openwrt_dependency: 7f4f824691fb2258afe9eb9a37da46d3557c4043
linux_dependency: 6.18.44+
ai-summary: generic 6.18 批次：SFP quirks、flow_action_police（DSA policer）、MTK WED 2.0 WDMA TX hang 修复（3d33804）、mt7530 修复、drop 6.12 支持（32c7a13）等。仅 3d33804（MTK WED）与无线栈间接相关。
ai-overlap: none
ai-conflict: none
ai-recommended-tier: reject
ai-risk: low
ai-confidence: high
ai-validation: 随内核 rebase 专项整体继承，无需单独跟进
ai-open-questions: 无
absorb-stock: n
absorb-v1-safe: n
status: reject
reason: 约 25 个 generic backport 绝大多数与 XR1710G 无关（SFP/V4L2/MHI/mt7530/rtl8365mb/rockchip/Aquantia）；且它们是 openwrt 树自身补丁，rebase 到 6.18.5x 时随树自动继承，不作为独立候选合入，无独立动作
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: gilly-20261021-001

```text
id: gilly-20261021-001
source: gilly-w1700k
source_url: https://github.com/Gilly1970/Gemtek-W1700K-6.18.git
source_commit: 8f4812bb4dea5fb7ea86b1d1c0479b88ad26bed9
compare_base: 38806db2d5cef464536f8ab6fd400eff3acefa7b
source_date: 2026-10-07
candidate_patch: n/a
patch_sha256: n/a
files: 内核 bump 6.18.52→.54→.55（多次）、mt76 bump to 2026-10-07（e27a290）
hardware: Gemtek W1700K
openwrt_dependency: n/a（派生于 openwrt）
linux_dependency: 6.18.55
ai-summary: 25 个新提交中以内核/mt76 bump 与 "Update repo"/"Update image" 为主。bump 内容为 openwrt 上游派生物，无独有补丁。
ai-overlap: duplicate
ai-conflict: none
ai-recommended-tier: reject
ai-risk: low
ai-confidence: high
ai-validation: 与 openwrt-20261021-001/006 联动裁决即可；gilly 侧无独立信息
ai-open-questions: 无（轻微信息差备查：gilly mt76 bump 日期 10-07 比 openwrt 10-08 早一天，可能 pin 提交不同，无实质影响）
absorb-stock: n
absorb-v1-safe: n
status: reject
reason: 内容为 openwrt 上游派生物（bump 数值与上游一致：6.18.55 / mt76 10-07≈10-08），无独有内容；版本决策已由 openwrt 侧 001（维持 pin）/006（随 rebase 批次）承载，gilly 侧无需平行决策
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: gilly-20261021-002

```text
id: gilly-20261021-002
source: gilly-w1700k
source_url: https://github.com/Gilly1970/Gemtek-W1700K-6.18.git
source_commit: 8f4812bb4dea5fb7ea86b1d1c0479b88ad26bed9
compare_base: 38806db2d5cef464536f8ab6fd400eff3acefa7b
source_date: 2026-10-07
candidate_patch: n/a
patch_sha256: n/a
files: fan control（c996e90/5491e61/f729395）、FlowSense 1.1.9-r7（4a1e357，rpcd ucode 插件）、README/镜像更新
hardware: Gemtek W1700K（风扇控制与机箱形态绑定）
openwrt_dependency: n/a
linux_dependency: 6.18.55
ai-summary: 应用层改动：风扇控制脚本与 FlowSense 流量监控（RPC 后端重写为 ucode rpcd 插件）。与 XR1710G 固件无关。
ai-overlap: none
ai-conflict: none
ai-recommended-tier: reject
ai-risk: low
ai-confidence: medium
ai-validation: 无（若日后想在 XR1710G 上用 FlowSense，可单独评估其 rpcd 插件兼容性）
ai-open-questions: FlowSense 是否值得作为 LuCI 应用单独引入（非本固件流程）
absorb-stock: n
absorb-v1-safe: n
status: reject
reason: 风扇控制与 W1700K 机箱/传感器绑定（本板走 9602 系统配置线）；FlowSense 为独立应用、与固件构建无耦合；若个人有兴趣可作独立事项另行评估（ucode rpcd 插件形态），不走上游合入流程
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: naoki-20261021-001

```text
id: naoki-20261021-001
source: naoki-xr1710g
source_url: https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G.git
source_commit: c15760c70b7ceeb85fd852d081b06c4bcac1cf5c
compare_base: 5a71e6a53
source_date: 2026-09-28
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/airoha/（XR1710G PCIe x2 DTS、DT tuning、retrain workaround 替换）
hardware: XR1710G（直接同名设备）
openwrt_dependency: n/a（ImmortalWrt fork）
linux_dependency: 6.18.5x（该 fork 基线）
ai-summary: 2b7a50298「update XR1710G PCIe x2 DTS」+ d3a36a94e「preserve XR1710G PCIe DT tuning」+ 5c35b53bf「replace PCIe x2 retrain workaround」（均 09-28）。与本项目挂起的 PCIe AER 议题（aggregate mt76-0023，晚于快照未纳入）同域。
ai-overlap: unknown
ai-conflict: unknown
ai-recommended-tier: pending
ai-risk: medium
ai-confidence: medium
ai-validation: 取三个提交 diff，对照 aggregate 的 XR1710G DTS/PCIe 补丁与 mt76-0023 修法；确认 retrain workaround 与 mt76-0023 的 fail-fast 方案是否互斥
ai-open-questions: naoki 的 PCIe 调参与 genshanxinli mt76-0023 的方案哪个更接近根因；是否可在我们 DTS 补丁中吸收 tuning 部分
absorb-stock: y
absorb-v1-safe: n
status: accept
reason: 挂起实施。与挂起的 PCIe AER 议题（aggregate mt76-0023，晚于快照未纳入；上游 mt76-0014 已被 F170 实机否证）同域，两条技术路线互证价值高；同名设备 DTS 级改动、落地形态清晰。实施时：diff 对照 aggregate 现有 XR1710G DTS/PCIe 补丁与 mt76-0023 修法，确认 retrain workaround 替换与 fail-fast 方案是否互斥，再决定吸收形态；v1-safe 不进
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: naoki-20261021-002

```text
id: naoki-20261021-002
source: naoki-xr1710g
source_url: https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G.git
source_commit: c15760c70b7ceeb85fd852d081b06c4bcac1cf5c
compare_base: 5a71e6a53
source_date: 2026-09-28
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/airoha/（XR1710G RTL826x SerDes setup 对齐）
hardware: XR1710G（10G 口 SerDes）
openwrt_dependency: n/a
linux_dependency: 6.18.5x
ai-summary: 45bd32397「align XR1710G RTL826x SerDes setup」（09-28）。直接关系 10G-1/10G-2 端口（本项目 WAN/LAN 10G 口）。
ai-overlap: unknown
ai-conflict: unknown
ai-recommended-tier: pending
ai-risk: medium
ai-confidence: medium
ai-validation: diff 对照 aggregate 的 SerDes/PHY 相关补丁；确认与 9501 网口命名（gdm2/phy8、gdm4/phy5）无冲突
ai-open-questions: 该提交是"对齐"（修复既有偏差）还是新能力；我们的 DTS 是否已含等价配置
absorb-stock: y
absorb-v1-safe: n
status: accept
reason: 挂起实施（与 010 同批，均为 naoki 09-28 的 XR1710G DTS 线）。直接同名设备、直接关系 10G-1/10G-2；与 005 取证互洽（本板 phy5/phy8 确为 RTL826x SerDes，9033 LED 补丁在 default 档）。实施时 diff 对照 aggregate 9001 的 SerDes 配置，确认"修复偏差"还是"新能力"，并验证与 9501 的 gdm2/phy8、gdm4/phy5 映射无冲突（节点名不变只改属性值则不冲突）；v1-safe 不进
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: naoki-20261021-003

```text
id: naoki-20261021-003
source: naoki-xr1710g
source_url: https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G.git
source_commit: c15760c70b7ceeb85fd852d081b06c4bcac1cf5c
compare_base: 5a71e6a53
source_date: 2026-10-08
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/airoha/（fraglist GRO for routed IPTV multicast，opt-in）
hardware: XR1710G
openwrt_dependency: n/a
linux_dependency: 6.18.5x
ai-summary: 6419547c0「restore opt-in fraglist GRO for routed IPTV multicast」（10-08）。组播转发性能；默认 opt-in，不影响普通路径。
ai-overlap: none
ai-conflict: none
ai-recommended-tier: pending
ai-risk: low
ai-confidence: medium
ai-validation: 确认使用场景是否涉及 IPTV 组播（chroutes/mosdns 旁路由场景下大概率无关）；若无关可 reject
ai-open-questions: 用户是否在本机跑 IPTV 组播接收/转发
absorb-stock: y
absorb-v1-safe: n
status: accept
reason: 挂起实施。opt-in 能力、默认关闭不影响普通路径，风险低；用户确认接受（组播 GRO 能力留用）。实施时随 rebase 批次或 aggregate 快照推进吸收；v1-safe 不进（首刷保守档最小差异）
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: naoki-20261021-004

```text
id: naoki-20261021-004
source: naoki-xr1710g
source_url: https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G.git
source_commit: c15760c70b7ceeb85fd852d081b06c4bcac1cf5c
compare_base: 5a71e6a53
source_date: 2026-10-08
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/airoha/patches-6.18（737-02 v15 恢复、737-05 verbatim、743 hunk 修复、BBRv3 hack 裁剪）
hardware: XR1710G
openwrt_dependency: n/a
linux_dependency: 6.18.54
ai-summary: 015715e2e / a341162c7 / 3fc77f263 / e29028481（均 10-08）——该 fork 面向 6.18.54 的内核补丁 rebase 记录。本项目当前 6.18.44，不适用；作为未来 rebase 的方法论参考。
ai-overlap: n/a
ai-conflict: n/a
ai-recommended-tier: reject
ai-risk: low
ai-confidence: high
ai-validation: 无（留档：启动 6.18.5x rebase 专项时参考其 737 系列处理顺序）
ai-open-questions: 无
absorb-stock: n
absorb-v1-safe: n
status: reject
reason: 当前 6.18.44 不适用；reject 的是"现在合入"，其价值在留档查阅——rebase 批次（002 等）启动时，737 系列处理顺序与 BBRv3 裁剪决策可作现成参考，账本记录即完成该目的
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: naoki-20261021-005

```text
id: naoki-20261021-005
source: naoki-xr1710g
source_url: https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G.git
source_commit: c15760c70b7ceeb85fd852d081b06c4bcac1cf5c
compare_base: 5a71e6a53
source_date: 2026-10-13
candidate_patch: n/a
patch_sha256: n/a
files: configs/airoha/1710.config（airoha-an7581-mt7996-board build-in；MODULE_DEFAULT/PACKAGE 对齐）
hardware: XR1710G
openwrt_dependency: n/a
linux_dependency: 6.18.5x
ai-summary: 4e118f54b「build airoha-an7581-mt7996-board in, not as a module, for XR1710G」+ 92d1d5ad2「make the remaining MODULE_DEFAULT/PACKAGE pairs agree」（均 10-13）。构建配置层面，低风险。
ai-overlap: none
ai-conflict: none
ai-recommended-tier: pending
ai-risk: low
ai-confidence: medium
ai-validation: 对照本项目 seed.local.diff / stage 后的 .config，评估是否吸收 board build-in（影响首启可用性）
ai-open-questions: build-in 是否会拖慢启动或与我们的最小镜像策略冲突
absorb-stock: y
absorb-v1-safe: n
status: accept
reason: 挂起实施。同名设备、同款 board 文件的构建决策，naoki 真机验证过；落地形态明确（seed 链加 CONFIG 符号，与 9603 同类）。实施时对照 stage 后的 .config/seed 链确认 airoha-an7581-mt7996-board 当前档位与连带影响；v1-safe 不进
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: naoki-20261021-006

```text
id: naoki-20261021-006
source: naoki-xr1710g
source_url: https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G.git
source_commit: c15760c70b7ceeb85fd852d081b06c4bcac1cf5c
compare_base: 5a71e6a53
source_date: 2026-10-14
candidate_patch: n/a
patch_sha256: n/a
files: target/linux/airoha/、package/（XG2010G 2GiB 变体、Nokia XG-040G(-TF) 设备支持、PON/语音栈，约 20 提交）
hardware: Gemtek XG2010G / Nokia XG-040G（非 XR1710G）
openwrt_dependency: n/a
linux_dependency: 6.18.5x
ai-summary: 该 fork 近半工作量在新设备支持（ee0ec6c09、22c1ada6a、ecbe6f4b6 等）与启动优化（aa2f0d9af）。与 XR1710G 无关，但证明 fork 活跃、XR1710G 相关内容仍在维护。
ai-overlap: none
ai-conflict: none
ai-recommended-tier: reject
ai-risk: low
ai-confidence: high
ai-validation: 无
ai-open-questions: 无
absorb-stock: n
absorb-v1-safe: n
status: reject
reason: 不同硬件（XG2010G/Nokia XG-040G），与 XR1710G 无交集；唯一意义（fork 活跃度佐证）已由 010/011 的存在本身证明
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

### Candidate: naoki-20261021-007

```text
id: naoki-20261021-007
source: naoki-xr1710g
source_url: https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G.git
source_commit: c15760c70b7ceeb85fd852d081b06c4bcac1cf5c
compare_base: 5a71e6a53
source_date: 2026-10-14
candidate_patch: n/a
patch_sha256: n/a
files: net/airoha（PPE subflow prepare 签名 22f13f07e、phylink stats lock hunks fe6bff4c4）、generic（bridge offload exports 14509f158）、9994 hunk ordering（80e060f0e）、AN7583 1G-EPON rate table（04cc62e89）
hardware: XR1710G / AN7583
openwrt_dependency: n/a
linux_dependency: 6.18.5x
ai-summary: 五个 net/airoha 修复与补丁维护提交（09-28 ~ 10-14）。PPE/phylink/bridge-offload 与本项目 flow-offload 能力域相邻；9994 hunk 排序经验可借鉴。
ai-overlap: unknown
ai-conflict: unknown
ai-recommended-tier: pending
ai-risk: medium
ai-confidence: medium
ai-validation: 逐提交 diff 对照 aggregate 对应补丁（PPE/flow-offload/9994 系）；AN7583 部分确认不适用
ai-open-questions: PPE subflow 签名修复是否对应我们某个 default 补丁的同一 bug
absorb-stock: n
absorb-v1-safe: n
status: reject
reason: 5 个子项逐一对照均不适用于当前树：① 22f13f07e 针对 8 参签名形态（我们栈为 6 参、全树无 egress_dev，9039 调用正确且在编）——留作 airoha 栈前进时的适配备忘；② 我们 pin 的 310-10 无 stats_lock 痕迹（该区域上游 10-13 已另行重构）；③ 675-01 我们已内联于 fanboy/06（0 内容差异）；④ 9994 为 fork 私有；⑤ AN7583 PON 与 XR1710G 无关
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

---

## Blocked（无法比较，需先处理）

### fanboy-20261021-000

```text
id: fanboy-20261021-000
source: fanboy-openw1700k
source_url: https://github.com/OpenWRT-fanboy/OpenW1700k.git
source_commit: f81b8b3ebc96f0707fa60ce62802580ec43434c3
compare_base: ca46e0a4e（登记基线，已被 force-push 孤立）
source_date: 2026-10-21
candidate_patch: n/a
patch_sha256: n/a
files: n/a（无法计算 base..tip）
hardware: Gemtek W1700K
openwrt_dependency: n/a
linux_dependency: 6.18.5x
ai-summary: 登记基线 ca46e0a4e 与 aggregate 注释中的备用锚 9604ab5a（09-14 F157 重取线）均不在远端可达历史中——ubi2-oc 分支至少第三次 force-push。已 vendor 的 21 个 commit 与当前 tip 的差异无法用基线方式计算。
ai-overlap: n/a
ai-conflict: n/a
ai-recommended-tier: pending
ai-risk: medium
ai-confidence: high
ai-validation: 人工重锚：将 config/upstream-sources.yml 的 baseline 改为 f81b8b3（完整 SHA），再与 aggregate/patches/vendor/fanboy/ 已 vendor 内容逐一对账（format-patch 重取 + diff）
ai-open-questions: 是否保留该来源的基线追踪（force-push 频发，基线语义已失效）；或降级为"按需人工对账"并不再登记基线
absorb-stock: n
absorb-v1-safe: n
status: reject
reason: 随 2026-10-21 架构转向废弃并关闭：基座切至 OpenWrt 主线后 W1700K 专用料不再进入构建，上游登记已置 enabled=false；不重锚——如将来确需 W1700K 料，人工按需对账，不登记基线
reviewer: M1s4k1
reviewed_at: 2026-10-21
```

---

## 本轮无更新来源（无需裁决）

| 来源 | 基线 = tip | 证据 |
|---|---|---|
| yyh-openwrt | `c82129e7348fda30b9e2f90572e4f1b3c555c7f2` | 巡检报告 [NO-UPDATE] |
| yyh-mt76 | `2dd6e4c8892f59b7943ee163afd6ced881bfb31b` | 巡检报告 [NO-UPDATE] |
| yyh-http-uboot | `53b73174c0fcb192a355e79710cdef5be61b14af` | 巡检报告 [NO-UPDATE] |
| hurryman-openw1700k-test | `73c3ab3081432f02d90b0084f63ea8ca4ea8589b` | 巡检报告 [NO-UPDATE] |

---

## 采集与验证记录（事实）

- 巡检（首轮，10:36 CST）：`python3 scripts/review-upstreams.py --limit 20`（255.7s）。
  结果：4 no-update / 3 baseline-unresolved / 1 network-fail（总判定 partial）。
- 人工补采（首轮）：对 4 个失败来源用 `git clone --filter=blob:none --no-checkout --depth 1` +
  `fetch --deepen` 在 `/tmp/xr1710g-rev/` 重拉，全部解析成功（openwrt 1303 / naoki 150 /
  gilly 25；fanboy 基线确认孤立：`git fetch origin 9604ab5a` 被服务端拒绝）。
- **工具修复（2026-10-21 当日完成，`tests/test_review_upstreams.py` 10/10 通过）**——
  首轮暴露的缺陷已全部修掉：
  1. 固定超时 ⇒ `--clone-timeout`（默认 120s）/ `--fetch-timeout`（默认 300s）可调；
     clone / unshallow 改 `--filter=blob:none` 部分克隆减负；
  2. unshallow refspec 不含 `refs/tags/*` ⇒ 已补 `+refs/tags/*:refs/tags/*`；顺带修掉两处
     潜伏 bug：`run_git(check=False)` 失败时也返回 `err=None`（曾致 force-push 检测恒失效）、
     `--no-network` 的 `network-disabled` 状态被硬编码成 network-fail；clone `--branch`
     失败现归类 `ref-missing`；
  3. 孤儿基线无独立状态 ⇒ 新增 `baseline-orphaned`（全历史拿到后基线仍缺失，附重锚指引），
     与 `baseline-unresolved`（拿不到全历史，无法比较）区分；完整 SHA 先按 SHA 直 fetch
     再退 unshallow。
- 巡检（复跑，11:20 CST，修复后）：openwrt / gilly / naoki 均 `[ADVANCE]`
  （1303 / 25 / 150 提交，与人工补采数字一致）；fanboy `[BASELINE-ORPHANED]`
  （自动输出重锚指引）；4 no-update。总判定 partial（exit 1）——唯一待办是 fanboy 重锚。
- 巡检（skill 流程复跑，11:56 CST）：8 来源 tip 与 11:20 **完全一致**
  （openwrt 63f702f1c / gilly 8f4812bb4 / naoki c15760c70 / fanboy 仍 orphaned /
  yyh×3 + hurryman no-update）⇒ 距首轮评审无新增变更，16 条待裁决条目维持不变，
  人工字段未被触碰。
- 本文件为评审载体；吸收动作（改 rules / 更新 aggregate）未执行，等待人工裁决。
