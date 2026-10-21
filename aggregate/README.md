# XR1710G 自用 OpenWrt 固件仓库

Airoha AN7581GT + MT7996（BE19000，2×10G + 2×1G）路由器 Gemtek **XR1710G** 的自用固件仓库。

> PCIe 拓扑：主 Wi-Fi 数据面为 `mt7996e`（14c3:7990）经 `pcie0` x2/Gen3；`mt7996e-hif`（14c3:7991）经 `pcie2` x1/Gen2（EN7581 共享 USB3 PHY 单 lane 板级限制；2026-08-24 实机 D0 判定根端口 LnkCap2 仅报 2.5/5GT/s，**Gen2 x1 为板级正确拓扑**，Gen3 降级为上游/厂商跟踪，不作为高速数据面假设，issue #16）。

**定位**：以 openwrt master（kernel 6.18）为基座，自维护补丁层携带全部"最前沿"内容（NPU offload、HW-GRO/LRO、
in-band phylink、PCIe x2、MLO/EHT320、US regdb 功率体系、CPU 超频）。**遇到问题修复而不是降级**——冲突、
失效、失败都按根因修复，不通过删能力/回退规避（政策见 `CONTEXT.md` 与 `docs/FIXES.md`）。

## 关键决策（详见 docs/adr/）

| 决策 | 内容 |
|---|---|
| 基线 | openwrt master fork（6.18）+ 自维护补丁层（ADR-0001） |
| 刷机 | 固化 YYH2913 HTTP U-Boot，官方 chainloader 备用（ADR-0002） |
| 版本线 | 滚动 master + known-good 冻结（`docs/ACCEPTANCE.md` 全项通过才打 tag） |
| 交付 | 单一 CPU 档（F89）：**OPP 650–1350MHz** + `oc-auto` 自动退档（1350 不稳→1300，崩溃→1200；5min 确认窗口）；档位仅剩 stock/experimental（同一 CPU 配置，包集合不同） |
| 预装 | 见 `config/seed-config.diff`（mlo/fancontrol/npu 等）；科学上网/Docker 暂缓（ROADMAP P3） |

## 目录结构

```
patches/            补丁层（root/packages/specs 正式桶 + vendor/fanboy 原料桶 + MANIFEST 应用清单）
scripts/            apply-patches.sh / prepare-oc.sh / build.sh / fetch-sources.sh / sync-upstream.sh
config/             feeds.custom.conf（外部 feed 锁 commit）+ seed-config.diff（预装包）
packages-xr1710g/   内置包 feed（luci-app-airoha-recovery，src-link 供给，锁源 commit）
files/              根文件系统 overlay（network/wireless/system/风扇守护/OC 限频）
docs/               FIXES 台账 / ACCEPTANCE 验收 / ROADMAP / FLASHING 刷机 / adr/
.github/workflows/  build.yml（手动构建 matrix）+ sync-upstream.yml（每 2h 上游同步+补丁校验）
对比报告-骨架目标-vs-OpenW1700k-ubi2-oc.md   与 fanboy 生态的详细对比
```

## 快速开始

### 0) 准备
```bash
# 本仓库就是叠加层；需要一个 openwrt 源码树（fork 或克隆）
git clone https://github.com/openwrt/openwrt.git openwrt
# （推荐）把本仓库内容 merge/拷贝到该 fork 的根目录，随 fork 同步上游 main
```

### 1) 构建
```bash
./scripts/build.sh stock            # 档位：stock / experimental（唯一 CPU 档 650–1350 + 自动退档，见 FIXES F89）；补丁原料已 vendor 入库，fetch-sources.sh 仅用于重取/刷新
```
产物：`bin/targets/airoha/an7581/*-sysupgrade.itb`（+ initramfs）。

> 首次构建前 `./scripts/feeds update -a` 可提前做。CI：GitHub Actions 手动 workflow_dispatch；上游同步与补丁校验由 sync-upstream.yml 每 2h 自动跑（决策：同步越勤冲突越少）。

### 2) 刷机
见 **`docs/FLASHING.md`**——主路径 HTTP U-Boot（192.168.255.1 恢复页），含锁版 SHA256 校验与严禁事项。

### 3) 验收与冻结
按 **`docs/ACCEPTANCE.md`** 全项实机验收，通过后在 FIXES/README 记录 commit 并打 known-good tag。

## 当前补丁层状态（2026-09-11，与 `patches/MANIFEST` 同步）

| 项 | 状态 |
|---|---|
| #22397 XR1710G 板级支持 | 携带（对 master 重建三件套 `patches/root/9000-9002`，含 dts/uboot/envtools/02_network/mk；合入即删） |
| US regdb 功率（510/520/521） | 内置（world 5GHz 去 NO-IR 已上游自带 500-world-regd-5GHz.patch，F20 删重复 0500）；521（UNII-3/4 160MHz 30dBm）= 默认档；555（仅 6GHz 30dBm）= OC 档；530 实验室 SP 停用 |
| mt76 txpower（0006/0007/0008） | 内置（YYH2913 家族；0006/0007 功率执行链 + 0008 eeprom 功率解锁 2G/5G，默认档；fanboy 0010/0011 备选对比） |
| mt76 pin / 包补丁 | pin 跟上游 **`be5ce791`（2026-09-01）**，上游 `mt76` 包 `patches/` 已空。默认档：`0001/0003/0005/0006/0007/0008/0009/0011` + `9990/9991/9993`（`0011`=NPU RX descriptor ownership）；#EXP：`0010`（NPU RX skb->dev）/`0012`（NPU del_sta）/`0013`（NPU 下刷新 tx-agg 定时器）/`0014`（NPU 复位 + panic/竞态/越界加固）。历史 `9028`（c5a3bd91 bump）与 `9994`（6.18 mac80211 兼容层）**已于 2026-09-07 删除**（上游 bump 自带） |
| 天线优化（07 报告） | 默认无线：5G ch149/HE80（国行 5.8G 合规/兼容，issue #21 实机定位）、6G ch37/EHT320、2.4G MU-MIMO 关；HE160 可选档已注释化（非国行/支持 5.8G 160MHz 终端）；eeprom 解锁见 mt76 0008 |
| cpufreq / PM domain（#22029） | 已自持（`vendor/fanboy/03`，含 direct-PLL fallback，OC 前置） |
| CPU 超频 | `scripts/prepare-oc.sh oc`（唯一档 OPP 650–1350，PLL base 650）+ `files/etc/init.d/oc-auto` 自动退档（1350→1300→1200，5min 稳性确认窗口，overlay 持久化） |
| NPU（#24593） | master 已合，无需携带 |
| pstore / ramoops（#22473） | kernel 侧已自持（`vendor/fanboy/10`）；uboot 侧待上游 |
| 风扇温控 | `files/etc/init.d/fan` 动态探测（NCT7802/NCT7511Y） |
| 实验档（experimental） | `build.sh experimental` 或 CI dispatch `profile=experimental`；2h cron 与本地 dry-run 覆盖实验档（audit/verify 感知 `#EXP`）。**当前 #EXP 14 条**：ROOT `9029`（JCPLL）/`9036`（issue#7 方案A）/`9038`（USXGMII RX CDR）/`9039`（PPE 本地流）/`9040`（pinctrl force-GPIO）/`9041`（RTK SerDes bundle）/`9044`（USXGMII **速率自适应**）/`9045`（RX 环恢复 + 中断 + BQL UAF + thermal）；mt76 `0010`/`0012`/`0013`/`0014`；vendor `02`（EIP93）/`04`（DSA）。计数与清单以 `patches/MANIFEST` 的 `#EXP` 行为准 |
| npu/flowsense/mlo/fancontrol/filemanager/recovery 应用 | 决策五件套全就绪：npu/flowsense/mlo/fancontrol/wifi7=9017 19-core（2026-08-17 从 19 号切片去 fastfetch/netspeedtest）；filemanager=官方 luci feed；recovery=packages-xr1710g src-link（锁 dd9ecfeef） |
| 08 号可靠性/兼容切片 | 六项已切为 `patches/root/9011-9016` 入 default（SPI33MHz/banner/dropbear 静默日志/antenna-memo/snd-off/LED-pinctrl）。其中 `9016` 于 **2026-09-11 替换**为 Gilly 748 版本：`-ENODEV` 静默 / 其他 pinctrl 错误 `dev_warn`（原版无条件删日志会掩盖真实错误），覆盖 an7581+mt7988（F97） |
| FOE/RX 环与 DMA（F92/F95/F96） | `9042`（default）= 上游 #24872：ring 4（force-to-CPU，承载 DHCP/PPPoE/CHAP/ISAKMP/LLDP）fallback 16→32 + ring4→128，修硬件 DMA 越过环尾写入内核内存（**必须置于 `vendor/fanboy/11` 之前**）；`9045`（#EXP）= RX 环停顿恢复 + `RX_NO_CPU_DSCP`/q31 中断 + QDMA TX BQL UAF + thermal 两处 1 行 bug |
| bridge offload 注入防护（F91） | `9043`（default）：`flow_offloading_hw != 1` 时不注入流表并清表；写文件前清 `ruleset-post` 陈旧 include（表名与 reload 重入由 `9024` 处理） |
| 10G LAN2 机制矩阵 | `vendor/fanboy/09` 内层 745（default，E2 silicon 手动 RX 校准）+ `9029`（JCPLL VCO 重触发）+ `9038`（RX CDR SDK crossing 搜索）+ `9041`（RTK SerDes SDS）+ `9044`（USXGMII 速率自适应）——互补：前四者修「链路能否起来/校准」，`9044` 修「起来后速率档位」。详见 `docs/absorptions/2026-09-11-absorption-plan.md` §4 |

## 风险声明（自用范围）

- 6GHz/功率补丁（US regdb 520/521、mt76-0008 eeprom 解锁）**无 AFC/合规背书**，自用责任自负；
- 超频存在**个体体质差异**（部分机器启动 panic）——由 `oc-auto` 退档链（1350→1300→1200）兜底，1200 即原 stock 上限；按 FIXES F08/F89；
- 第三方 U-Boot 刷入后厂商恢复通道失效——锁版 + 校验，救砖通道见 FLASHING；
- 网口命名已固化（netdev-name：lan1/lan2=10G、wan=1G-1、lan3=1G-2），物理口 ↔ 逻辑名仍需首次实机核对（ROADMAP P0）。