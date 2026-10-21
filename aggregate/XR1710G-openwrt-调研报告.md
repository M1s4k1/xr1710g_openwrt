# XR1710G（同源 W1700K）OpenWrt 生态详细调研报告

> 调研时间：2026-08-16（下述 PR/提交状态以当天 GitHub/openwrt.git 为准）
> 结论先行：**Gemtek/Brightspeed XR1710G（Airoha AN7581 + MT7996）的设备支持 PR 已提交但仍在 review（openwrt/openwrt#22397）；同源设备 W1700K 已于 2026-03 合入 OpenWrt master（#17869）。** 围绕它的一整条硬件驱动链（2×10G RTL8261BE 光/电 PHY、MT7996 NPU offload、U-Boot 链加载、MT7530 交换）在 OpenWrt 中均有对应 PR，部分驱动仍在向上游 kernel/U-Boot 推进中。

---

## 1. 设备与同源关系

| 项目 | XR1710G（Brightspeed / 国内流通版） | W1700K（Quantum Fiber/Centurylink） |
|---|---|---|
| 品牌型号 | Gemtek XR1710G，FCC ID `MXF-XR1710G` | Gemtek MXF-W1700K / MX-W1700K |
| SoC | Airoha AN7581GT（EN7581 系，1.3GHz 4 核 CPU + 8 核 NPU） | Airoha AN7581（同源） |
| 内存/闪存 | 2GB（ESMT）/ 512MB（Winbond 25N04KVZEIR，SPI-NAND） | 同左 |
| 网口 | 2×10G（RTL8261BE）+ 2×1G（AN7581 内置 MAC/MT7530） | 2×10G（RTL8261N）+ 2×1G |
| Wi-Fi | MT7996 BE19000：2.4G MT7976GN 4×4 / 5G MT7977BN 4×4 / 6G MT7977AN 4×5（320MHz 回程） | 同为 MT7996 三频 Wi-Fi 7 |
| 差异点 | 去掉 Silabs EFR32 蓝牙/Zigbee、去掉 Airoha GPS、MT7530 LED 改由交换芯片驱动；风扇/温控传感器为 Nuvoton 系（NCT7511Y/NCT7802，版本差异） | 带 EFR32、Airoha GPS、GPIO 驱动 LED |
| 引导 | 厂商签名 U-Boot 2014.04-rc1（AXON 1.6/2.0），BMT/BBT 坏块管理，不支持 UBI | 同左 |
| 官方系统 | 定制 OpenWrt v21.02.1（需账号），基本不可用 | 同左 |

- 官方论坛确认两者同源设备帖：[Brightspeed XR1710G same device as the W1700K](https://forum.openwrt.org/t/brightspeed-xr1710g-same-device-as-the-w1700k/247242)
- 中文教程与参数帖（恩山）：[brightspeed XR1710G或者w1700K类似物（包含教程）](https://www.right.com.cn/forum/archiver/tid-8465834.html?page=1)
- 中文上手博客：[XR1710G 上手](https://blog.yazawaniko.com/index.php/archives/336/)

---

## 2. OpenWrt 主线 PR

### 2.1 设备支持主 PR（核心）

| PR | 标题 | 状态 | 说明 |
|---|---|---|---|
| [openwrt/openwrt#22397](https://github.com/openwrt/openwrt/pull/22397) | airoha: add support for Gemtek XR1710G | **open**（2026-03-13 提出，12 comments） | XR1710G 主 PR，13 个文件：`an7581-gemtek-17xx-common.dtsi`（与 W1700K 共用底子）、`an7581-xr1710g-ubi.dts`、image/an7581.mk、uboot 补丁 `999-airoha-add-gemtek-xr1710g.patch`、`998-airoha-add-snfi-label.patch`、uboot-envtools、02_network、airoha_fan、platform.sh |
| [openwrt/openwrt#17869](https://github.com/openwrt/openwrt/pull/17869) | airoha: add support for Gemtek W1700K | **merged 2026-03-10**（commit 87c2c474） | W1700K 主 PR（作者 andrewjlamarche），先于 XR1710G 合入 master；含 UBI 布局、链加载 U-Boot 方案说明、`an7581-w1700k-ubi.dts` |
| [openwrt/openwrt#22374](https://github.com/openwrt/openwrt/pull/22374) | [25.12] airoha: add support for Gemtek W1700K | closed（未合并，2026-07-02 关闭） | 25.12 分支回移被拒/关闭 → **设备支持只进 master，25.12 分支不带 W1700K/XR1710G 设备**（详见 2.5 的 chainloader 例外） |
| [openwrt/openwrt#20430](https://github.com/openwrt/openwrt/pull/20430) | airoha: add support for Gemtek W1701K | open | 同 17xx 家族衍生机型（aiamadeus），可作同源参考 |
| [openwrt/openwrt#21019](https://github.com/openwrt/openwrt/pull/21019) | airoha: add support for kernel 6.18 | merged 2026-06-03 | XR1710G/W1700K 所需内核基线能力（6.18 补丁集） |

### 2.2 平台 bring-up 与内核（airoha/an7581 目标）

- 内核版本路线：6.12 支持 [#19038](https://github.com/openwrt/openwrt/pull/19038)（merged 2025-09）→ 切 6.12 弃 6.6 [#20137](https://github.com/openwrt/openwrt/pull/20137)（merged 2025-09）→ 6.18 支持 [#21019](https://github.com/openwrt/openwrt/pull/21019)（merged 2026-06）→ 6.18 为默认并弃 6.12 [#23640](https://github.com/openwrt/openwrt/pull/23640)（merged 2026-06-04）
- 平台初始化清理：kernel config 清理 [#18112](https://github.com/openwrt/openwrt/pull/18112)（merged 2025-03）；flow offload + PCIe 上游补丁回填 [#18166](https://github.com/openwrt/openwrt/pull/18166)（merged 2025-07）；broken patches 修复 [#20740](https://github.com/openwrt/openwrt/pull/20740)；SCU SSR serdes 配置 [#20149](https://github.com/openwrt/openwrt/pull/20149)；UART 波特率控制 [#20049](https://github.com/openwrt/openwrt/pull/20049)（merged 2025-09）；switch 端口中断 [#21016](https://github.com/openwrt/openwrt/pull/21016)（merged 2026-01）；自动刷新补丁 [#22399](https://github.com/openwrt/openwrt/pull/22399)（merged 2026-03）；netdev-name 支持 [#20475](https://github.com/openwrt/openwrt/pull/20475)（merged 2025-10）
- **PCIe（MT7996 挂载关键）**：EN7581 PCIe 初始化修复 + x2 双通道链路（W1700K 无线模块需要 x2）[#21978](https://github.com/openwrt/openwrt/pull/21978)（merged 2026-02），25.12 回填 [#22336](https://github.com/openwrt/openwrt/pull/22336)（merged 2026-03）；pcie lane 2 使能 [#17844](https://github.com/openwrt/openwrt/pull/17844)
- **以太网驱动（airoha_eth 上游回填）**：缺位补丁回移 [#22479](https://github.com/openwrt/openwrt/pull/22479)（merged 2026-03）；USXGMII 变速数据通路修复 [#22536](https://github.com/openwrt/openwrt/pull/22536)；LRO（RX 队列 19-12）[#23431](https://github.com/openwrt/openwrt/pull/23431)（merged 2026-05）；HW-GRO [#23828](https://github.com/openwrt/openwrt/pull/23828)（merged 2026-06）；master airoha fixes [#23566](https://github.com/openwrt/openwrt/pull/23566)（merged 2026-05）；multi-serdes 重构 [#23481](https://github.com/openwrt/openwrt/pull/23481)（merged 2026-05）+ 顺序修正 [#23849](https://github.com/openwrt/openwrt/pull/23849)（merged 2026-06）
- **NPU（Wi-Fi 卸载）**：NPU 固件包 + 加载支持（`airoha-en7581-mt7996-npu-firmware`）[#22289](https://github.com/openwrt/openwrt/pull/22289)（merged 2026-03）+ [25.12] 版 [#22372](https://github.com/openwrt/openwrt/pull/22372)（merged 2026-04）；an7581-evb 开 NPU [#22343](https://github.com/openwrt/openwrt/pull/22343)；NPU Wi-Fi 卸载 PCIe 子节点 [#22516](https://github.com/openwrt/openwrt/pull/22516)；eagle（MT7996 平台）关 NPU 统计 [#22300](https://github.com/openwrt/openwrt/pull/22300)；NPU 保留内存修正 [#22465](https://github.com/openwrt/openwrt/pull/22465) → 只在实际 Wi-Fi 板保留 NPU 内存并修 NPU 固件加载 [#24593](https://github.com/openwrt/openwrt/pull/24593)（merged 2026-08）；NPU mailbox 用 coherent DMA（2026-08-12 已合 commit）；npu 不用 sysfs fallback（2026-08-11 已合）
- **cpufreq / PM domain**：AN7581 cpufreq & PM domain 驱动修复 [#22029](https://github.com/openwrt/openwrt/pull/22029)（open，作者 rchen14b）；补 `CONFIG_AIROHA_CPU_PM_DOMAIN`（2026-08-08 已合）
- **pinctrl / SCU**：AN7581/AN7583 pinctrl 修复 [#24267](https://github.com/openwrt/openwrt/pull/24267)（merged 2026-07）；pcie 节点 SCU regmap 修复 [#24315](https://github.com/openwrt/openwrt/pull/24315)；pinctrl 同步 linux-7.3（2026-08-11 已合）
- **open 中的平台能力 PR**：DSA kmod + netlink 支持 [#22532](https://github.com/openwrt/openwrt/pull/22532)；nft_flow_offload L2 桥接卸载 [#22533](https://github.com/openwrt/openwrt/pull/22533) / generic 版 [#24038](https://github.com/openwrt/openwrt/pull/24038)；switch 节点改 mt7621 风格（RFC）[#20483](https://github.com/openwrt/openwrt/pull/20483)；DTO/dtso 支持 [#24151](https://github.com/openwrt/openwrt/pull/24151)/[#23716](https://github.com/openwrt/openwrt/pull/23716)/[#23734](https://github.com/openwrt/openwrt/pull/23734)；an7581-evb sysupgrade+factory [#24168](https://github.com/openwrt/openwrt/pull/24168)；DTS compatible 修正（ASU 识别）[#22879](https://github.com/openwrt/openwrt/pull/22879)

### 2.3 Wi-Fi（MT7996 / mt76 / hostapd / wifi-scripts）

| PR | 说明 |
|---|---|
| [openwrt/openwrt#20826](https://github.com/openwrt/openwrt/pull/20826) | mt76：Enable NPU support for airoha-7581 target（merged 2025-11，LorenzoBianconi） |
| [openwrt/openwrt#21588](https://github.com/openwrt/openwrt/pull/21588) | wifi-scripts：6GHz 320MHz 下 WiFi 6E 发现修复（merged 2026-01，rchen14b） |
| [openwrt/openwrt#22956](https://github.com/openwrt/openwrt/pull/22956) | wifi-scripts：hostapd 配置补 EHT 选项（merged 2026-07） |
| [openwrt/openwrt#23840](https://github.com/openwrt/openwrt/pull/23840) | wifi-scripts：多 radio phy 的 detect_band 选项（hurrian） |
| [openwrt/openwrt#23786](https://github.com/openwrt/openwrt/pull/23786) | wifi：按 DT 设置每 radio MAC（open，hurrian） |
| [#20912/#23704/#24142/#24599](https://github.com/openwrt/openwrt/pull/24599) 等 | hostapd 滚动更新（EHT/MLO 能力依赖） |
| [#20964](https://github.com/openwrt/openwrt/pull/20964) | mac80211 更新至 6.18 系 |

> mt76 包本体在 [github.com/openwrt/mt76](https://github.com/openwrt/mt76)（上游向 linux-wireless 提交）；NPU offload 系列见 §3。

### 2.4 10G PHY（RTL8261N / RTL8261BE，XR1710G 核心驱动链）

| PR | 说明 |
|---|---|
| [openwrt/openwrt#20450](https://github.com/openwrt/openwrt/pull/20450) | phy-realtek：导入 RTL8251L/8254B/8261BE/8261N/8264/8264B 厂商驱动 + 固件包（closed 2026-05-18 **未合**，被下方 #23427 体系取代） |
| [openwrt/openwrt#20392](https://github.com/openwrt/openwrt/pull/20392) | rtl8261n：bugfixes and patch updates（balika011） |
| [openwrt/openwrt#21777](https://github.com/openwrt/openwrt/pull/21777) | kernel: fix rtl8261n driver for non-realtek chips（merged 2026-01，非 Realtek SoC 上的兼容性修复，W1700K/Askey 实测） |
| [openwrt/openwrt#20429](https://github.com/openwrt/openwrt/pull/20429) | kernel: rtl8261n 可选为独立 kmod（hurrian） |
| [openwrt/openwrt#22563](https://github.com/openwrt/openwrt/pull/22563) | generic: net: phy: realtek: add 5G and 10G PHY support（ecsv 上游系列） |
| [openwrt/openwrt#23427](https://github.com/openwrt/openwrt/pull/23427) | **generic: net: phy: realtek: 5G/10G PHY 支持 for Linux 6.18（merged 2026-05）** → `pending-6.18/742-net-phy-realtek-add-5G-and-10G-PHY-support.patch` + `package/firmware/rtl826x-firmware` |
| [openwrt/openwrt#22564](https://github.com/openwrt/openwrt/pull/22564) | airoha: an7581: w1700k: fix RTL8261N PHY boot failure（merged 2026-05-14，rchen14b） |
| [openwrt/openwrt#23078](https://github.com/openwrt/openwrt/pull/23078) | airoha: w1700k: drop RTL8261N phy interrupt（merged 2026-05-14） |
| [openwrt/openwrt#23383](https://github.com/openwrt/openwrt/pull/23383) | airoha: RTL8261N USXGMII 口转 in-band phylink（merged 2026-05-15） |
| [openwrt/openwrt#24034](https://github.com/openwrt/openwrt/pull/24034) | generic: realtek RTL826x LED 支持（open，hurrian） |
| [openwrt/openwrt#23644](https://github.com/openwrt/openwrt/pull/23644) | generic: realtek rtl8261ce 支持（open，hurrian） |

> 关键 master 提交（官方 gitiles）：[airoha: an7581: 6.18: switch to kmod-phy-realtek for w1700k（ecabaa534e）](https://git-03.infra.openwrt.org/openwrt/openwrt/commit/?id=ecabaa534ed01b123dec42f2b89e5b62ff1494e2)——6.18 起 W1700K 从独立 rtl8261n kmod 切到 kmod-phy-realtek + rtl826x-firmware 体系。

### 2.5 U-Boot / ATF / 安装器（boot 链）

| PR | 说明 |
|---|---|
| [openwrt/openwrt#22151](https://github.com/openwrt/openwrt/pull/22151) | airoha: an7581: add uboot chainloader（merged 2026-03-05，hurrian）——签名厂商引导 + BMT/BBT 的规避方案 |
| [openwrt/openwrt#22294](https://github.com/openwrt/openwrt/pull/22294) | [25.12] airoha: an7581: add uboot chainloader（merged 2026-05-15）——**25.12 分支唯一合入的 W1700K 相关件** |
| [openwrt/openwrt#21984](https://github.com/openwrt/openwrt/pull/21984) / [#23393](https://github.com/openwrt/openwrt/pull/23393) / [#24165](https://github.com/openwrt/openwrt/pull/24165) / [#24173](https://github.com/openwrt/openwrt/pull/24173) | uboot-airoha 更新至 v2026.01 / v2026.01(25.12) / v2026.07 / v2026.07 |
| [openwrt/openwrt#24410](https://github.com/openwrt/openwrt/pull/24410) | uboot-airoha: fix ethernet on an7581 boards（merged 2026-07-28） |
| [openwrt/openwrt#24257](https://github.com/openwrt/openwrt/pull/24257) | packages/boot: add arm-trusted-firmware-airoha + U-Boot sync（Ansuel） |
| [openwrt/openwrt#24503](https://github.com/openwrt/openwrt/pull/24503) | airoha: an7581: 保持 W1700K 恢复模式下以太网可用 |
| [openwrt/openwrt#22473](https://github.com/openwrt/openwrt/pull/22473) | uboot-airoha: add pstore（open，hurrian） |
| [openwrt/openwrt#24025](https://github.com/openwrt/openwrt/pull/24025) | uboot-airoha: FM25G0102B SPI NAND 支持（open） |
| [openwrt/openwrt#22445](https://github.com/openwrt/openwrt/pull/22445) / [#22466](https://github.com/openwrt/openwrt/pull/22466) | kmod-pwm-an7581 → kmod-pwm-airoha 重命名（merged 2026-03） |

### 2.6 杂项功能/修复 PR（风扇、GPS、LED、存储、加密）

- 风扇：修复 w1700k fan script [#22391](https://github.com/openwrt/openwrt/pull/22391)（merged 2026-03）；通用 `kmod-leds-fan5646` [#20476](https://github.com/openwrt/openwrt/pull/20476)（open）
- GPS（W1700K 才有）：fix GPS support on Gemtek W1700k [#23936](https://github.com/openwrt/openwrt/pull/23936)（merged 2026-06）
- MT7530：kernel 支持 mt7530 LED [#24619](https://github.com/openwrt/openwrt/pull/24619)（open，XR1710G 的 LED 改由 switch 驱动）；Nokia 设备网络活动 LED [#24673](https://github.com/openwrt/openwrt/pull/24673)(merged 2026-08)
- SPI-NAND：SkyHigh S35ML-3 [#21808](https://github.com/openwrt/openwrt/pull/21808)；FM25G01B/G02B [#23864](https://github.com/openwrt/openwrt/pull/23864)(merged 2026-06)；HYF1GQ4UDACAE [#23742](https://github.com/openwrt/openwrt/pull/23742)(merged 2026-08)
- 加密：eip93 patch 换上游实现 [#20130](https://github.com/openwrt/openwrt/pull/20130)（open）/ [#20991](https://github.com/openwrt/openwrt/pull/20991)；crypto eip93 hmac setkey 修复 [#22886](https://github.com/openwrt/openwrt/pull/22886)（merged 2026-04）
- USB（AN7581 使能）：[#21460](https://github.com/openwrt/openwrt/pull/21460)（merged 2026-01）、[#24155](https://github.com/openwrt/openwrt/pull/24155)、[#24168](https://github.com/openwrt/openwrt/pull/24168)
- 其它：禁用 AFE 默认 [#23921](https://github.com/openwrt/openwrt/pull/23921)/[#22660](https://github.com/openwrt/openwrt/pull/22660)；audio 支持 [#24266](https://github.com/openwrt/openwrt/pull/24266)（open）

### 2.7 同 SoC（EN7581/AN7583/AN7563）其他设备 PR（可交叉参考）

- Nokia/Valyrian：Nokia Valyrian [#21761](https://github.com/openwrt/openwrt/pull/21761)（merged 2026-03）；Nokia XG-040G-MD [#23569](https://github.com/openwrt/openwrt/pull/23569)（merged 2026-06，另 [#21896/#21913/#21807/#21843] 多个早期版本）；Nokia XG-040G-MF（UBI）[#23809](https://github.com/openwrt/openwrt/pull/23809)(merged 2026-07) / [#24654](https://github.com/openwrt/openwrt/pull/24654)(merged 2026-08)
- AN7583 平台（下一代同族）：[#24264/#24265/#24285/#24397/#24609](https://github.com/openwrt/openwrt/pull/24609) 等
- VSOL V2901Q-A / V2902A-S [#24465](https://github.com/openwrt/openwrt/pull/24465)（open）；Airoha AN7563/AN7552 + 小米 BE5000 [#23960](https://github.com/openwrt/openwrt/pull/23960)（open，验证了目标的可扩展性）

---

## 3. 硬件驱动「上游仓库」与状态

### 3.1 Linux 内核 mainline（torvalds/linux，截至 master/6.18）

| 驱动 | 上游路径 | 状态 |
|---|---|---|
| AN7581/EN7581 以太网 MAC | `drivers/net/ethernet/airoha/` | ✅ mainline（含 flow offload、LRO/GRO 演进、[NPU callbacks 系列](https://lists.openwrt.org/pipermail/linux-arm-kernel/2025-July/1048210.html)） |
| MT7996 Wi-Fi（mt76） | `drivers/net/wireless/mediatek/mt76/mt7996/`（含 `npu.c`） | ✅ mainline；[NPU offload 系列「wifi: mt76: Add NPU offload support to MT7996」](https://lwn.net/Articles/1042483/)（[linux-mediatek 2025-09 版](http://lists.openwrt.org/pipermail/linux-mediatek/2025-September/098355.html)） |
| cpufreq | `drivers/cpufreq/airoha-cpufreq.c` | ✅ mainline（[EN7581 Cpufreq SMC 系列](https://lists.openwall.net/linux-kernel/2024/11/13/1053)） |
| pinctrl | `drivers/pinctrl/airoha/` | ✅ mainline（6.13 起） |
| clk/reset | `drivers/clk/en7523.c` | ✅ mainline |
| SPI-NAND 控制器 | `drivers/spi/airoha-snfi.c` | ✅ mainline（[6.19 系列持续完善](https://github.com/openwrt/openwrt/pull/23640)） |
| watchdog | `drivers/watchdog/airoha_wdt.c` | ✅ mainline |
| TRNG | `drivers/char/hw_random/airoha-trng.c` | ✅ mainline |
| PWM | `drivers/pwm/pwm-airoha.c` | ⚠️ master 已合、6.18 未含 → OpenWrt 以 `kmod-pwm-airoha` 携带（[上游 v12 系列](https://lkml.indiana.edu/2505.1/02628.html)） |
| CPU PM domain | （`drivers/pmdomain` 相关） | ⚠️ OpenWrt 携带（`CONFIG_AIROHA_CPU_PM_DOMAIN`），[上游 v10 系列](https://lists.openwall.net/linux-kernel/2025/01/16/276)推进中；OpenWrt 侧修复 PR [#22029](https://github.com/openwrt/openwrt/pull/22029) open |
| PCS（USXGMII standalone） | `drivers/net/pcs/` | ⚠️ 未上游，OpenWrt 携带（“backport PCS standalone” [#23734](https://github.com/openwrt/openwrt/pull/23734) 等） |
| **RTL8261N/BE 5G/10G PHY** | `drivers/net/phy/realtek/` | ⚠️ **未上游**：OpenWrt 以 `pending-6.18/742-net-phy-realtek-add-5G-and-10G-PHY-support.patch` + `package/firmware/rtl826x-firmware`（Realtek 固件 blob）携带；上游提交为 ecsv 的 “net: phy: realtek: add 5G and 10G PHY support” 系列（对应 [#22563](https://github.com/openwrt/openwrt/pull/22563)/[#23427](https://github.com/openwrt/openwrt/pull/23427)） |

### 3.2 U-Boot 上游（u-boot/u-boot）

- mainline 已有 Airoha 平台支持：`arch/arm/mach-airoha/` + `configs/an7581_evb_defconfig`（[仓库](https://github.com/u-boot/u-boot)）
- W1700K/XR1710G 板级支持由 OpenWrt `package/boot/uboot-airoha` 补丁提供（`999-airoha-add-gemtek-w1700k.patch` / `999-airoha-add-gemtek-xr1710g.patch`）
- ML 上进行中的上游化：pinctrl Airoha SoCs 系列 v8（[patchwork](https://patchwork.ozlabs.org/project/uboot/cover/20260518235116.2664557-1-mikhail.kshevetskiy@iopsys.eu/)）、[an7581 pinctrl/gpio config](https://lists.denx.de/pipermail/u-boot/2026-April/616541.html)、[2026-07 v15 版](https://lists.u-boot-project.org/pipermail/u-boot/2026-July/623861.html)

### 3.3 其他上游/参考仓库

- OpenWrt 包：`package/boot/uboot-airoha`、`package/firmware/rtl826x-firmware`、`package/firmware/airoha-en7581-mt7996-npu-firmware`（[linux-firmware 更新 PR #22373](https://github.com/openwrt/openwrt/pull/22373)）、`package/kernel/mt76`（镜像 [github.com/openwrt/mt76](https://github.com/openwrt/mt76)）、`wireless-regdb`
- MediaTek 官方 WiFi7 SDK feed（商用 mt7996 驱动参考）：[git01.mediatek.com mtk-openwrt-feeds（mt7988_mt7996_mac80211）](https://git01.mediatek.com/plugins/gitiles/openwrt/feeds/mtk-openwrt-feeds/+/0f312e824f7bbf8a6ab8ee1fceb5e4fc1859a767%5E%21/autobuild_mac80211_release/mt7988_mt7996_mac80211/package/kernel/mt76/src/mt76x02_regs.h)
- 厂商 GPL/SDK：Quantum Fiber 定制 OpenWrt v21.02.1（[论坛拆机帖](https://forum.openwrt.org/t/quantum-fiber-w1700k-support/222776)）；社区镜像 [lotusmomo/airoha_sdk](https://github.com/lotusmomo/airoha_sdk)（AN7581 SDK）

---

## 4. 相关「功能仓库 / 固件项目」

| 仓库 | 说明 |
|---|---|
| [hurrian/w1700k-ubi-installer](https://github.com/hurrian/w1700k-ubi-installer) | W1700K UBI 安装器（基于 [dangowrt/owrt-ubi-installer](https://github.com/dangowrt/owrt-ubi-installer)），TFTP 链加载 → UBI installer 完整流程 |
| [YYH2913/openwrt](https://github.com/YYH2913/openwrt) | **XR1710G 最活跃功能分支**：`xr1710g` / `xr1710g-6.18` / `xr1710g-6.18-integration`（含 6GHz 支持、US regdb 功率补丁等） |
| [YYH2913/http-uboot(-xr1710g)](https://github.com/YYH2913/http-uboot-xr1710g) | XR1710G 定制 U-Boot：**HTTP Recovery（192.168.255.1）**、10GbE、DHCP、链加载槽位固化 |
| [YYH2913/mt76](https://github.com/YYH2913/mt76) / [YYH2913/luci-app-mlo](https://github.com/YYH2913/luci-app-mlo) | XR1710G 专用 mt76/MT7996 适配；MLO 管理 LuCI |
| [jjcszxh/openwrt-XR1710G](https://github.com/jjcszxh/openwrt-XR1710G) | YYH2913 `xr1710g-6.18-integration` 的镜像（国内可访问） |
| [orangeyoo/XR1710G-OpenWrt-iStoreOS-Community](https://github.com/orangeyoo/XR1710G-OpenWrt-iStoreOS-Community) | iStoreOS 风格社区固件（Linux 6.18.41、MT7996 固定 b2704cf5、6GHz 802.11s/EHT320 回程、OpenClash/Docker/iStore）；[论坛发布帖](https://forum.openwrt.org/t/gemtek-xr1710g-community-build-airoha-an7581-mt7996-wi-fi-7-6-ghz-802-11s-mesh-eht320-istoreos-style-luci-and-u-boot/252504) |
| [hx801217/iStoreOS-for-Gemtek-XR1710G](https://github.com/hx801217/iStoreOS-for-Gemtek-XR1710G) | 每日 CI 的 iStoreOS XR1710G 固件 |
| [naoki66/ImmortalWrt-for-Gemtek-XR1710G](https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G)（88★） | ImmortalWrt 定制固件（kernel 6.18.41、三频默认配置） |
| [skyboooox/ImmortalWrt-Gemtek-17xx](https://github.com/skyboooox/ImmortalWrt-Gemtek-17xx) | XR1710G + W1700K 可复现 ImmortalWrt 构建器 |
| [OpenWRT-fanboy/w1700k-ubi-build](https://github.com/OpenWRT-fanboy/w1700k-ubi-build) / [OpenW1700k](https://github.com/OpenWRT-fanboy/OpenW1700k) | W1700K UBI 构建；CPU 超频等 |
| [andrewjlamarche/openwrt](https://github.com/andrewjlamarche/openwrt)（w1700k 分支） | W1700K 设备支持最初开发分支 |
| [Gilly1970/Gemtek-W1700K-6.18](https://github.com/Gilly1970/Gemtek-W1700K-6.18) | 6.18 快照构建脚本 |
| [Arthur97172/Gemtek-XR1710G-wrt-builder](https://github.com/Arthur97172/Gemtek-XR1710G-wrt-builder) / [Airoha-wrt-builder](https://github.com/Arthur97172/Airoha-wrt-builder) | OpenWrt/ImmortalWrt 一键编译 |
| [lvcdy/openwrt_xr1710g](https://github.com/lvcdy/openwrt_xr1710g) | 含 `luci-app-airoha-npu`（NPU 诊断）、`luci-app-mlo` 等定制包 |
| [luoyizhi1987/XR1710G-YYH-OC](https://github.com/luoyizhi1987/XR1710G-YYH-OC) | 5GHz UNII-1 30dBm + +200MHz CPU OC overlay |
| [rchen14b/luci-app-w1700k-fancontrol](https://github.com/rchen14b/luci-app-w1700k-fancontrol) | 风扇曲线/温度监控 LuCI（CPU/NCT7802/10G PHY/switch/WiFi 温度） |
| [mossdef-org/w1700k-wireless-regdb](https://github.com/mossdef-org/w1700k-wireless-regdb) | w1700k 无线 regdb 补丁包（6GHz/功率） |
| [lightingghost/w1700k_efr32_flasher](https://github.com/lightingghost/w1700k_efr32_flasher) | W1700K 上 Silabs EFR32（BT/Zigbee）刷写（XR1710G 已移除该模块） |
| [woziwrt/mt7996-wifi7-manager](https://github.com/woziwrt/mt7996-wifi7-manager) | 通用 MT7996 WiFi7/MLO 管理（BPI-R4，同芯片参考） |

---

## 5. 相关「修复」仓库/PR 聚焦

- **RTL8261N PHY 启动失败**：`#22564`（merged）、`#22564` 配套 `#23078`（去中断）、`#23383`（in-band phylink）——XR1710G 换 10G 口/重启后 link 不稳的关键修复集
- **非 Realtek SoC 上 rtl8261n 驱动劣化**：`#21777`（merged 2026-01，band-aid until #20450 merge）
- **NPU 内存/固件加载**：`#22465` → `#24593`（merged 2026-08）+ 8 月 master 提交（reserve regions only on Wi-Fi boards、npu load without sysfs fallback、coherent DMA for NPU mailbox）
- **PCIe 链路训练失败/Gen3 丢速**：`#21978`（EQ preset 时钟序、PERST 分离、Gen3 重训、x2 绑定）
- **恢复/刷机保活**：`#24503`（W1700K 恢复模式以太网）、`#24410`（U-Boot an7581 以太网修复）、`#22391`（风扇脚本修复）
- **GPS**：`#23936`（W1700K GPS 修复）
- **SCU/pinctrl**：`#24315`、`#24267`
- **25.12 分支回移**：`#22336`（PCIe）、`#22151→#22294`（chainloader）、`#22372`（NPU）、`#22070`（[25.12] airoha backport upstream changes）
- 上游修复系列（kernel）：[net: airoha: Add dma_rmb()/READ_ONCE() in airoha_qdma_rx_process()（2026-04）](https://mail.openwall.com/netdev/2026/04/03/274)

---

## 6. 社区与资料

- OpenWrt 论坛：[Quantum Fiber W1700k support（696 帖，开发的从 0 到合入全程）](https://forum.openwrt.org/t/quantum-fiber-w1700k-support/222776)、[Brightspeed XR1710G same device as the W1700K](https://forum.openwrt.org/t/brightspeed-xr1710g-same-device-as-the-w1700k/247242)、[XR1710G 社区固件发布帖](https://forum.openwrt.org/t/gemtek-xr1710g-community-build-airoha-an7581-mt7996-wi-fi-7-6-ghz-802-11s-mesh-eht320-istoreos-style-luci-and-u-boot/252504)
- 恩山无线论坛：[XR1710G/W1700K 教程帖（含 FCC、刷 U-Boot 教程）](https://www.right.com.cn/forum/archiver/tid-8465834.html?page=1)、[iStoreOS/OpenWrt 6GHz Mesh 稳定版更新帖](https://www.right.com.cn/forum/thread-8484444-1-1.html)
- 博客/科普：[XR1710G 上手](https://blog.yazawaniko.com/index.php/archives/336/)、[什么值得买 400 元 BE19000 双万兆口](https://post.smzdm.com/p/a708zg39/)
- OpenWrt 官方 gitiles（canonical 提交源）：[openwrt.git](https://git-03.infra.openwrt.org/openwrt/openwrt/log/?id=ecabaa534ed01b123dec42f2b89e5b62ff1494e2)

---

## 7. 结论与建议

1. **上游跟进对象**：盯 [openwrt/openwrt#22397](https://github.com/openwrt/openwrt/pull/22397)（XR1710G 主 PR，仍 open）；其前置（W1700K #17869 已合；6.18 #23640 已合；RTL8261 5G/10G PHY #23427 已合）都已就绪，XR1710G 合入只是时间/评审问题。
2. **版本线**：设备支持只在 **master（6.18）**；25.12 分支只有 chainloader 等零星回移。要稳定线需自行 carry 或等 下一版本（25.12 之后的正式版）。
3. **刷机路径**：厂商签名 U-Boot + BMT/BBT 无 UBI → 必须先用 UART/TFTP 装 **U-Boot chainloader**（`ubi-chainload-uboot.itb`），再走 UBI installer（hurrian/w1700k-ubi-installer 或 OpenWRT-fanboy 构建）；XR1710G 可直接用 **YYH2913 HTTP U-Boot（192.168.255.1 网页恢复）**，无需串口。
4. **硬件驱动风险点**：10G 口依赖 Realtek 固件 blob（rtl826x-firmware）与 phy-patch 体系（非 Realtek SoC 兼容性曾出问题，#21777）；NPU 内存布局随版本调整（#24593）；LED/风扇脚本针对 W1700K vs XR1710G 有差异（MT7530 LED、NCT7511Y/NCT7802、EFR32/GPS 有无）。
5. **可贡献方向（open PR）**：#22532（DSA）、#20483（switch 节点重构）、#24034（PHY LED）、#23644（rtl8261ce）、#22029（cpufreq/pmdomain）、#22473（uboot pstore）、#24025（SPI-NAND U-Boot）。