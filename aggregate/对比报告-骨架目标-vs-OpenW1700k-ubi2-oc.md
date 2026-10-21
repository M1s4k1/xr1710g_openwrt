# 对比报告：我们的骨架与目标 vs OpenW1700k `ubi2-oc` 分支

> 核实日期：2026-08-17（子代理 git clone 全拓扑核实 + GitHub 页面交叉验证）
> 复核日期：2026-08-21（`git ls-remote` + GitHub compare API 核实 ubi2-oc 最新快照；并在最新 openwrt main 干净克隆上 dry-run 本仓库补丁层全部通过）
> 对比基准：本仓库已确认的设计树（master fork + 补丁层 + 双 release + known-good 冻结）
> 参考对象：[OpenWRT-fanboy/OpenW1700k](https://github.com/OpenWRT-fanboy/OpenW1700k) 分支 `ubi2-oc`，消费方 [w1700k-ubi-build](https://github.com/OpenWRT-fanboy/w1700k-ubi-build)

## 0. 结论先行

1. **ubi2-oc 比预想更"前沿"**：= openwrt master @2026-08-20（`725cbf11`，内核 6.18.44）+ 恰好 21 条定制 commit，**0 条落后**；其 `ubi2-oc-auto` 通道每 2 小时自动 rebase 上游并 force-push。08-16 核实快照（`20d94d5a2b27` + 20 条 commit）已被 rebase 重写。
2. **它没有 XR1710G 板级支持**：全分支 `git grep xr1710g` 为 0 命中，只有上游 base 自带的 `an7581-w1700k-ubi.dts` 与 `gemtek_w1700k-ubi` Device——我们自持 #22397 板级支持的必要性再次确认。
3. **OC 三件套可直接借鉴**，其"stock = OC 去顶 commit"的双档机制正是我们双 release 的最优实现方式（同源同构、产物同名、tag 区分）。
4. **最大架构分歧**：它"整枝 rebase + force-push + 无验收"，我们"补丁层 + 台账 + ACCEPTANCE 门槛"。**模型保持我们的，资产吸收它的。**

## 1. 分支画像

| 项 | 事实 |
|---|---|
| head | `c052cc75` "switch to performance governor and overclock +200mhz"（author 2026-02-14，整枝 rebase 于 08-20；08-16 快照 `ed7cbc80` 已被 rebase 重写） |
| base | openwrt master `725cbf11`（2026-08-20T21:49Z），内核 6.18.44 |
| 相对 upstream | ahead 21 / behind 0（merge_base = openwrt main tip `725cbf11`） |
| 相对 08-16 快照的新增 commit | `496c0f5eab36` "mt76: mt7996: handle truncated txfree events silently"（2026-08-19）——已同步入本仓库实验档 `mt76-0005`（2026-08-21） |
| 自身分支 | `ubi2` = ubi2-oc 去顶 commit（stock 档）；`ubi2-oc-auto` 为自动 rebase 通道；旧 OC sha `80096373b5` 与 08-16 快照 `ed7cbc80` 均已在 rebase 中重写不可达 |
| 同步机制 | `update-all.yaml` cron `15 */2 * * *` 每 2h rebase 到 openwrt/main 后 force-push |
| 构建触发 | 全部手动（workflow_dispatch），无 CI 验收 |
| 产物 | 单资产 `openwrt-airoha-an7581-gemtek_w1700k-ubi-squashfs-sysupgrade.itb`（OC 与 stock 同名，仅 tag 区分；tag 格式 `<profile>-<date>-r<rev>-<sha>`） |

## 2. 逐维度对比

| 维度 | 我们侧（已确认目标） | ubi2-oc 实际 | 判定 |
|---|---|---|---|
| 基座 | master fork 滚动 + known-good 冻结 | master 快照 + 2h 自动 rebase（更勤但 force-push 重写历史） | 借鉴其同步频率，保留我们的可追溯性 |
| 设备支持 | XR1710G 显式（#22397 自持） | **无**（仅 W1700K，来自上游 base） | 我们必须自持；w1700k 板级作对照基线 |
| 补丁形态 | 独立 patches/ + 应用脚本 + 元数据 | 21 条 commit 直压分支（rebase 后 hash 全重写） | 我们的模型胜（可追溯、可剥离） |
| OC | 双档 1.3/1.4GHz，stock 默认 | 单 commit 1.4GHz 内置（governor=performance） | 借鉴三件套；档位做保守化处理 |
| 高功率 | regdb 520（UNII-1 29dBm）+ 555（6GHz 30dBm） | **仅 555**（UNII-4 5730–5895@160 + 6GHz 30dBm，**不动 UNII-1**） | 互补：UNII-1 高功率必须靠 520，我们的组合正确 |
| 交付 | 双 release + 首刷包 + 文档 | 单产物同名（tag 区分） | 采纳其"同源去顶"双档模型 |
| 质量 | ACCEPTANCE 全项 + FIXES 台账 + ROADMAP | 无 | 我们的独有项，保留 |
| 默认配置 | 主路由 WAN=1G-1 / 192.168.123.1 / 三频统一 SSID | OpenWrt 原生 | 保留我们的 files/ 定制 |
| 预装应用 | 13 项（含 flowsense/recovery/irqbalance） | minimal 档 12 项（无 flowsense/recovery） | 我们的清单已覆盖其子集 |

## 3. OC 实现（借鉴核心）

**三件套（全部在栈顶 commit 内；08-16 快照 `ed7cbc80`，当前快照 `c052cc75`）**：

1. `target/linux/airoha/dts/an7581.dtsi` — `cpu_opp_table`：删 500/550/600/650MHz 四档、索引整体下压、新增 1250–1400MHz 四档 → **15 档 700–1400MHz**（`opp-shared` + `required-opps=<&smcc_oppN>` 同步）；
2. `target/linux/airoha/patches-6.18/940-pmdomain-airoha-Add-Airoha-CPU-PM-Domain-support.patch` — PLL 公式 `freq_mhz = 500 + state * 50` → `700 + state * 50`（direct-PLL fallback 路径）；
3. `an7581/config-6.18` — `CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND` → `CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE`。

**前置依赖（栈底第 3 条 `e5d23549`，必须同带）**：`939-cpufreq-airoha-Add-EN7581-CPUFreq-SMCCC-driver.patch` + `940-pmdomain...`（含 **direct-PLL fallback**：ATF 未实现 AVS SMC handler 时 `use_smc=false` 直接编程 PLL 寄存器——XR1710G 若 ATF 无 AVS SMC 处理必须携带）。对应上游 open PR #22029。

**双档模型（采纳）**：`ubi2` = `ubi2-oc` 去顶 commit → **stock 与 OC 同树同构、产物同名、tag 区分**。我们落地：stock（默认）+ oc 变体；oc 变体内部 1.3GHz 保守 / 1.4GHz 激进（见 §6 行动项 3）。

## 4. 补丁存在性矩阵（借/弃/自持）

| 目标项 | ubi2-oc 状态 | 处置 |
|---|---|---|
| #22397 XR1710G 板级 | **不存在**（上游 OPEN） | 自持（PR 为参考实现） |
| #24593 NPU 内存修正 | **在 base**（已合 08-11） | 无需携带 ✓ |
| #23828 HW-GRO / #23566 fixes | **在 base**（916/920 系） | 无需携带 ✓ |
| #23383 in-band phylink / #22564 PHY boot fix | **在 base**（w1700k dts 内） | 无需携带 ✓（对照 XR1710G 自持部分） |
| #22029 cpufreq/pmdomain | **fanboy 自持**（939/940 + direct-PLL fallback） | **借用**（我们默认档核心） |
| #22473 pstore | **部分**：kernel ramoops 已开（2f7d2d02），uboot 侧无 | 借用 kernel 侧；uboot 侧待上游 |
| #24034 RTL826x LED | **部分**：rtl8261ce 驱动内集成 LED 支持（afc6dc93） | 观察；XR1710G 用 RTL8261BE，驱动适配待实机 |
| #24619 mt7530 LED | **不存在**（上游 DRAFT） | 自持或等待（我们的 LED 差异项） |
| #24025 SPI-NAND FM25G0102B | **不存在** | 非必需（我们的 NAND 是 Winbond） |
| #22536 USXGMII 修复 | **不存在**（上游 CLOSED，双方都没有） | 遇问题需自研（记入风险清单） |
| regdb 520（UNII-1 29dBm/6GHz 29dBm） | **不存在** | 借 YYH2913（我们默认档） |
| regdb 555（UNII-4/6GHz 30dBm） | **fanboy 自持**（36da8e02，源自 stangri） | **借用**（激进档） |
| mt76 txpower（我们：YYH2913 0006/0007） | fanboy 等价物：**0010/0011 + iwinfo 999 + wifi-scripts ucode（pr-23990）** | 二选一，以 YYH2913 为准，fanboy 备选对比 |
| #22532 DSA（实验档） | fanboy 自持 `aa531917` | **借用**（实验档） |
| #22533 L2 bridge offload（实验档） | fanboy 自持 `649ef957`（nft_flow_offload）+ `701b33a48`（bridge offload） | **借用**（实验档，2026-08-21 同步） |
| 稳定性资产（992-20 net / 992-21 npu-init / 745 rx-calib / 746 mt7530 时序 / SPI-NAND 33MHz） | fanboy 自持 | **评估后借用**（进 ACCEPTANCE 实机验证） |
| eip93 驱动 | fanboy 自持（f80d0507 启用） | 证据冲突（恩山称无硬件加速），实验档待实机 |
| vermagic 注入（buildbot vermagic + extract-distfeeds 每 6h） | fanboy 自持（85005e10 + workflow） | **借用机制**（CI 中让自建 kmod 兼容官方 opkg） |
| mt76 TXFREE 截断事件静默处理 | **fanboy 自持**（`496c0f5eab36`，2026-08-19 新增，生成 `0005-wifi-mt76-mt7996-guard-txfree-overrun.patch`） | **已同步**（实验档 `patches/packages/mt76-0005-…`；已对 pin `59676919` 实证可应用，待实验档构建/实机验证后毕业） |

> 注：上表“fanboy 自持”的 commit hash 为 08-16/17 提取快照，当前分支 rebase 后 hash 已全重写。2026-08-21 逐条 diff 复核并同步：06（L2 offload）与 07（HW_RRO）已更新为当前 fanboy 内容并更新 MANIFEST/ORDER；新增 `mt76-0005` 入实验档；其余 18 条中 17 条与当前对应 commit 内容完全一致（仅 hash 重写），05 仅 commit message 尾注不同；08/18 为本地有意切片/构建修复，不随 fanboy 覆盖。

## 5. 模型对比（最大决策点）

| | fanboy 模型 | 我们的模型 |
|---|---|---|
| 改动载体 | 21 条 commit 直压分支 | patches/ 分层 + 应用脚本 |
| 上游同步 | 2h 自动 rebase + force-push（历史重写） | 补丁层 apply + 周同步（历史稳定） |
| 可追溯性 | 差（rebase 后旧 sha 不可达） | 好（每支补丁带来源/上游状态元数据） |
| 冲突面 | 每次 rebase 全树冲突风险 | 仅在补丁 apply 时暴露 |
| 验收 | 无 | ACCEPTANCE 全项 + known-good tag |
| 借鉴点 | — | ① 同步频率提升（每日或构建前）② tag 格式 ③ vermagic 注入 ④ 双档去顶模型 |

**决策：模型保持我们的**（补丁层 + 台账 + 验收），同步频率建议从"每周"提为"每日"（fanboy 2h 实证：同步越勤冲突越小），见待确认问题。

## 6. 对骨架的行动项清单

1. patches/ 默认档新增：**939/940 cpufreq/pmdomain（含 direct-PLL fallback）**——从 `e5d23549` 提取，标注上游状态（#22029 OPEN）；
2. patches/ 默认档新增：**regdb 555**（激进档）——从 `36da8e02` 提取；520 照旧来自 YYH2913；
3. **OC 三件套**从 `ed7cbc80`（当前快照 `c052cc75`）提取为独立补丁组（opp 表 + PLL 公式 + governor），做成：stock（不带）/ oc-1.3g（保守，opp 上限 1300 或运行时 maxfreq 限制）/ oc-1.4g（激进）三形态，采用"同源去顶 + tag 区分"；
4. **XR1710G 板级**：以 #22397 为参考实现自持（dts/mk/uboot patch/envtools/02_network/airoha_fan），w1700k 上游板级作对照基线；
5. 实验档：**aa531917（DSA）** + **bdfd1ae2/33ac9c66（L2 offload）** 以补丁形式携带（它们 base 与我们的 base 同源，可直接取）；
6. CI：引入 **vermagic 注入**（构建前取官方 snapshot distfeeds）+ 手动/每日双触发 + stock/oc 双产物 + 实验档独立构建；
7. kernel ramoops（`2f7d2d02` 内容）并入默认档 pstore 项；
8. 稳定性资产（992-20/992-21/745/746/SPI-NAND 33MHz）列为 ACCEPTANCE 实机验证候选，验证通过才入默认；
9. mt76 源 pin 到官方 openwrt/mt76（我们目标）或 fanboy mt76-firmware fork（备选），txpower 补丁家族二选一；
10. docs/FIXES.md 增加条目：#22536 USXGMII（CLOSED，遇问题自研）、#24619 mt7530 LED（自持/等待）、eip93（证据冲突待实机）。

## 7. 风险与未确认项

- **整枝 rebase 链**（2h rebase + force-push + MIRROR_HASH=skip）只适合单人私有使用，我们不复用；
- **#22536 USXGMII 数据通路修复上游 CLOSED**、双方都没有——若我们的 10G USXGMII 口出问题需自研；
- **eip93**：恩山称 AN7581 无 AES 硬件加速 vs fanboy 启用 eip93 驱动，证据冲突，实机验证；
- **rtl8261ce 驱动**（HW2.1 适配）与 XR1710G 的 RTL8261BE 硬件版本适配关系未确认；
- **release 资产只有 sysupgrade.itb**（回收/chainload 未在 04-24 release 实据中出现），与我们"交付物含首刷包"的差异需在 CI 脚本层面对齐；
- 939 补丁与 base 内 cpufreq 驱动（`CONFIG_ARM_AIROHA_SOC_CPUFREQ=y` 已存在）的 apply 基线关系未展开验证——提取时需先做 apply 测试。
