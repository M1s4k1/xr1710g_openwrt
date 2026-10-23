# customization.md — XR1710G fork 定制清单与提交史

> **本文档的维护铁律（强制）**：每一次向 `new_main` 的 commit，**必须同步更新本文档**：
> 1. 文件清单有增减/路径变化 → 更新 §1 对应条目；
> 2. 追加 §2 的 commit 记录（改了什么文件、做了什么、修复/新增了什么）。
>
> 漏更新的 commit 应在发现时立即补一条修订记录，不允许出现"树里有改动但文档无记录"的状态。
> 核对面：`git log 63f702f1c0..HEAD`（基线为 openwrt 上游 pin）应与 §2 一一对应。

基线：openwrt `63f702f1c0`（Linux 6.18.55）。我方累计 **10 个 commit**，
相对上游 **247 个文件、+39381 行**（截至 2026-10-23）。

---

## §1 定制文件说明（树形）

图例：`[A]` 新增 ｜ `[M]` 修改 ｜ `[D]` 删除

```
openwrt-fork（相对 openwrt 上游的全部定制）
│
├── target/linux/airoha/                         板级与内核（Airoha AN7581 平台）
│   ├── an7581/
│   │   ├── image/an7581.mk                    [M] 注册 Device：gemtek_xr1710g-ubi
│   │   │                                           解决：上游无 XR1710G 板型，无法出固件
│   │   ├── base-files/etc/board.d/02_network  [M] 网口命名 eth1=WAN(10G-1)/eth2=LAN(10G-2)/
│   │   │                                            lan2(1G-1)/lan3(1G-2)（YYH 约定）
│   │   │                                           解决：上游 lan1/lan2/wan 命名与运维脚本不一致
│   │   ├── base-files/lib/upgrade/platform.sh [M] 固件升级兼容（magic/board 名）
│   │   └── config-6.18                       [M] 板级内核配置（NPU/PPE/hwrng/PCS 等符号）
│   ├── dts/
│   │   ├── an7581-xr1710g-ubi.dts            [A] XR1710G 设备树入口（含 mainline an7581.dtsi）
│   │   │                                           解决：上游只有 an7581 通用 DTSI，无整机 DTS
│   │   └── an7581.dtsi                       [M] NPU 内存保留区、hwrng 时钟顺序
│   └── patches-6.18/                          内核补丁 21 个（详见下方清单）
│
├── target/linux/generic/                       通用内核层
│   ├── pending-6.18/675-01..04                [A] 桥接硬件卸载四件套：
│   │                                               675-01 forward-path 导出（bridge helper/vlan）
│   │                                               675-02 nft_flow_offload 桥接卸载与 flowtable 类型
│   │                                               675-03 netfilter 桥接 conntrack（vlan/pppoe）
│   │                                               675-04 nft_flow_offload bridge init conntrack
│   │                                               解决：Wi-Fi 桥接 + nftables 流卸载在 L2 场景失效
│   ├── hack-6.18/743-rtl826x-led             [A] RTL826x PHY LED 支持（可选 pinctrl）
│   └── config-6.18                           [M] 通用内核配置联动符号
│
├── arch/arm64/boot/dts/airoha/en7581.dtsi     [A] NPU 保留内存区（reserved-memory）
│                                                   解决：NPU firmware 需要固定物理内存窗口
├── drivers/char/hw_random/airoha-trng.c      [A] hwrng 时钟顺序修复载体（scu clock）
│
├── package/kernel/mt76/                        Wi-Fi7（MT7996）NPU 卸载
│   ├── Makefile                              [M] 打开 NPU/ debugfs 相关 Kconfig
│   └── patches/（29 个）                      [A] NPU offload 全栈：
│       9801 token/NPU debugfs 计数器          9817 NPU teardown 顺序
│       9802 MCU WTBL 站点统计                  9818 radar-detecting chanctx
│       9803 txpower 变化刷新功率限制           9819 hwrro sub64 BA 旁路
│       9804 固件 txpower 限制控制（已适配主线） 9821 仅禁止 global WCID
│       9805 EEPROM 功率解锁                    9822 PCIe AER 错误处理
│       9806 只报告终态 tx 失败                 9823 扫描驻留硬件上限
│       9807 txfree overrun 保护                9824 recovery 后 NPU init 重试
│       9808 NPU RX 描述符所有权                9825 NPU RX 队列拆除收尾
│       9810 默认 EEPROM 尺寸校验               9826 NPU DMA 内存与消费者绑定
│       9811 向固件速率控制通告 EHT             9827 跟踪 RX NAPI 注册
│       9812 EHT-320 160MHz BF 回退            9828 refill 后发布 NPU RX 缓冲
│       9813 工作模式传给速率控制               9829 保留 NPU TX ring headroom
│       9814 NPU RX 设置 skb device             9830 重启前关闭设备
│       9815 NPU del-sta                       9831 注销设备前停止 NPU
│                                                   9832 teardown 释放 hwrro 会话
│                                                   解决：mt7996 的 NPU 硬件卸载不可用/不稳定
│
├── package/kernel/mac80211/patches/subsys/     mac80211 修复 10 个
│       9716 link sta capability               9729-9734 CSA finalize/cac/direct-CSA/
│       9726-9728 CSA punct bitmap/cac 调用栈/       AQL BMC MLD/RTS/FT key 上传
│                non-tx BSS 检查                      解决：MLO/CSA/FT 在 MT7996 上的崩溃与行为异常
│
├── package/boot/uboot-airoha/                  U-Boot XR1710G 支持
│   ├── Makefile                              [M] 新增 xr1710g defconfig
│   └── patches/9990-airoha-add-gemtek-xr1710g [A] 板级 patch
├── package/boot/uboot-tools/uboot-envtools/files/airoha_an7581 [M] 环境变量布局
│
├── package/network/config/bridge-hw-offload/  [A] 桥接硬件卸载规则包（hotplug/init/脚本）
├── package/network/config/wifi-scripts/patches/010 [A] EHT beamforming 默认开
├── package/network/services/hostapd/patches/mtk-0015  [A] 6G 免 DFS
├── package/network/services/dropbear/patches/500     [A] 静默会话日志
├── package/network/utils/iwinfo/patches/200-freqlist-per-radio [A] 每 radio 频率列表
├── package/network/utils/iwinfo/patches/9719-txpowerlist-wiphy-dump [A] txpower 列表修复
├── package/network/config/firewall4/patches/9717-bonding-lower-devices [A] bonding 下层设备
├── package/system/rpcd/patches/9718-exec-observe-EOF [A] exec EOF 处理
│
├── package/base-files/files/etc/banner        [M] 彩色定制 Banner
├── package/base-files/files/etc/init.d/led    [M] LED 初始化（9501 改名后适配）
│
├── packages-xr1710g/                          自有 feed（feeds.conf 中 src-link 挂载）
│   ├── package/luci-theme-argon/              [A] Argon 主题（css/less/fonts/icon/模板/ACL）
│   ├── package/luci-app-argon-config/         [A] Argon 主题配置 App（设置页/rpcd/ACL）
│   ├── package/luci-app-airoha-npu/           [A] NPU 状态监控 App（卸载统计/截图）
│   ├── package/luci-app-airoha-flowsense/     [A] 流感知监控 App（npu-monitor/jitter 守护）
│   ├── package/luci-app-w1700k-fancontrol/    [A] 风扇控制 App（status/settings 页）
│   └── package/luci-app-mlo/                  [A] MLO 状态 App
│                                                   解决：官方源无这些 LuCI 应用/主题
│
├── luci-app-mlo/patches/001-xr1710g-mlo-hide-mesh.patch [A] MLO mesh 接口隐藏
│                                                    （mlo feed 启用时生效，现为预置）
│
├── files/                                     镜像默认文件（上游 .gitignore 已放开）
│   ├── etc/config/network                    [A] 默认网络：br-lan=eth2+lan2+lan3，
│   │                                               LAN=192.168.2.1，wan/wan6=eth1
│   ├── etc/config/system                     [A] 默认系统配置（时区/主机名/LED 4 处 dev 纠正）
│   ├── etc/uci-defaults/98-xr1710g-luci-default-lang [A] 首启默认中文
│   └── usr/lib/lua/luci/i18n/*.zh-cn.lmo    [A] 13 个完整汉化语言包
│                                                   解决：默认配置不符合本板端口拓扑、无中文
│
├── feeds.conf                                 [A] 具体化 feeds.conf（default + src-link xr1710g）
├── xr1710g-seed.config                        [A] 设备/预装包选择（func 档）
├── xr1710g.md                                 [A] fork 结构与上游跟踪说明
├── doc/                                       [A] 运营文档 9 篇（build/rules/audit/maintenance/
│                                                   config-ownership/patch-review/handoff/
│                                                   scripting/README + 本文档）
├── scripts/                                   [A] fetch-upstream.sh（拉上游 rebase）
│                                                   build.sh（本地构建入口，仅 Linux/CI）
├── .github/workflows/build.yml                [A] fork 模式 CI（另删除上游 16 个 workflow）
└── .gitignore                                 [M] 放开 /files、/feeds.conf；忽略 .idea/
```

### 内核补丁清单（target/linux/airoha/patches-6.18/，21 个）

| 补丁 | 作用 |
|---|---|
| `625-net-pcs-airoha-update-USXGMII-rate-adaptation` | USXGMII 速率自适应（link up 时更新） |
| `742-net-phy-realtek-allow-board-specific-RTL826x-SDS-mode` | RTL826x SDS 模式板级化 |
| `743-net-phy-realtek-restore-optional-RTK-SerDes-patch` | RTK SerDes 补丁可选化 |
| `744-net-phy-realtek-reapply-RTK-SerDes-after-aneg` | 自协商后重应用 SerDes |
| `980-net-airoha-handle-RX_NO_CPU_DSCP-interrupt` | RX_NO_CPU_DSCP 中断处理 |
| `992-20-net-airoha-stability` | 网络稳定性（**已适配**：trtcm 重试 hunk 因上游 187-v7.3 吸收而删） |
| `992-21-net-airoha-npu-init-stability` | NPU 初始化稳定性 |
| `9990-net-airoha-bind-WLAN-bound-flows-on-PPE-driver-L2-cache-miss` | PPE L2 cache miss 绑流 |
| `9992-net-pcs-airoha-jcpll-tclvar-recal` | PCS JCPLL/TCLVAR 重校准 |
| `9994-net-pcs-airoha-SDK-crossing-RX-calibration` | PCS RX 校准 |
| `9995-net-airoha-ppe-flow-stats-coexist` | PPE 流统计共存 |
| `9996-net-airoha-ppe-npu-dirty-lazy-foe-clean` | FOE 表惰性清理 |
| `9997-net-airoha-ppe-bind-rate` | PPE 绑定速率 |
| `9998-pinctrl-airoha-mux-requested-AN7581-pins-as-GPIO` | AN7581 GPIO pinmux |
| `9999-30-net-airoha-npu-recover-stalled-cores` | NPU 停滞核恢复 |
| `9999-31-net-airoha-npu-fix-watchdog-work-lifetime` | watchdog work 生命周期 |
| `9999-32-net-airoha-npu-close-recovery-synchronization-race` | 恢复同步竞争窗口 |
| `9999-33-net-airoha-fix-offload-provider-device-link-lifetime` | offload provider 设备链接生命周期 |
| `9999-34-net-airoha-npu-acknowledge-only-the-requested-WLAN-RX-IRQ` | WLAN RX IRQ 精确应答 |
| `9999-35-net-airoha-npu-publish-mailbox-command-before-doorbell` | mailbox 命令先发布后敲铃 |

（另有 `998-net-phy-mediatek-make-LED-pinctrl-optional`、`939-cpufreq-airoha-EN7581-CPUFreq-SMCCC`、
`940-pmdomain-airoha-CPU-PM-Domain` 见 §2 对应 commit。）

---

## §2 commit 历史记录

> 记录规则：每条 = 一个 commit（新→旧排列）；含 commit 短 SHA、主题、改动文件摘要、
> 做了什么、修复/新增了什么。括号内为合并前的原始 commit 主题。

### 10. `c953b64f7f` doc: add customization.md (custom file inventory + commit history)

- **改动**（2 文件）：新增 `doc/customization.md`；修改 `doc/README.md`（索引加一行）
- **做了什么**：建立"定制清单 + 提交史"文档，并把"每次 commit 必须同步更新本文档"
  定为维护铁律（§3 检查清单）
- **新增**：§1 全部定制文件树形说明（247 文件的目录级归类 + 内核补丁 21 个清单表）；
  §2 按合并后历史的逐 commit 记录；§3 commit 前后检查清单
- **背景**：同批把 git 历史从 14 个 commit 合并为 9 个（7 个内容 commit 保持原样；
  3 个构建配置 commit 合为 #8；4 个基础设施 commit 合为 #9），原始 sub-commit 主题
  保留在对应条目的括号内，信息不丢失

### 9. `704474c49e` build: fork infrastructure — CI, docs, scripts, workflow cleanup
（由原 4 个 commit 合并：doc migrate / fork-mode CI+scripts+readme / branch names / workflow cleanup）

- **改动**（27 文件）：新增 `.github/workflows/build.yml`、`scripts/build.sh`、`scripts/fetch-upstream.sh`、
  `xr1710g.md`、`doc/`×9；删除上游 16 个 workflow（kernel/toolchain/packages/coverity/
  llm-review/push-containers/github-release/label-*/build-pr-profile/tools.yml + scripts/）；
  修改 `.gitignore`（+`.idea/`）
- **做了什么**：把 fork 的构建/跟踪/文档基础设施一次配齐；清掉随 fork 继承的上游 CI
- **修复**：上游 workflow 在 fork 里每次 push 必败（需 openwrt 官方 runner/s3/secrets）——
  删除后 push 不再产生红色 run；`xr1710g.md` 与 fetch-upstream.sh 的分支引用改为
  `new_main` / `upstream/main`（上游默认分支是 main 不是 master）
- **新增**：fork 模式 CI（checkout→feeds→defconfig→seed→符号门禁→make→产物）；
  上游 rebase 工作流脚本；构建入口脚本；运营文档体系

### 8. `2679d901b5` build: fork build config — default files, feeds.conf, seed
（由原 3 个 commit 合并：track default files / commit feeds.conf / seed config）

- **改动**（19 文件）：新增 `files/etc/config/{network,system}`、`files/etc/uci-defaults/98-…-lang`、
  `files/usr/lib/lua/luci/i18n/*.zh-cn.lmo`×13、`feeds.conf`、`xr1710g-seed.config`；
  修改 `.gitignore`
- **做了什么**：把镜像默认配置、自定义 feed、设备/包选择固化进仓库
- **修复**：上游 `.gitignore` 的 `/files` 与 `/feeds.conf` 会**静默丢弃**这些文件
  （9601-9603 的配置曾因此不进 commit、固件丢默认配置）——删除两条 ignore 规则
- **新增**：默认网络（br-lan=eth2+lan2+lan3 / LAN=192.168.2.1 / wan=eth1）、默认系统配置、
  首启中文、13 个完整汉化 lmo；`feeds.conf` 内嵌 `src-link xr1710g ../packages-xr1710g/package`；
  `xr1710g-seed.config`（设备 gemtek_xr1710g-ubi + 预装包）

### 7. `3440b8ac94` mt76: NPU offload stack for mt7996 (Airoha EN7581)

- **改动**（29 文件）：`package/kernel/mt76/patches/9801-9832` 共 29 个补丁
- **做了什么**：移植并适配 Wi-Fi7 NPU 硬件卸载全栈
- **修复**：9804（固件 txpower 限制控制）与主线符号重复定义——删除主线已吸收的
  `mt7996_mcu_set_tx_power_ctrl` 定义/声明/第一处调用，保留主线没有的 BACKOFF 控制；
  `#define TX_POWER_LIMIT_TABLE_PATH` 移入常量区（原位置上下文因主线插入同函数而不连续）
- **新增**：NPU RX/TX 卸载、teardown 顺序、recovery 重试、PCIe AER、debugfs 计数器等
  （逐条见 §1 补丁表）

### 6. `04673b2f0d` packages: regdb US rules, mac80211 CSA/FT/AQL fixes, firewall4/rpcd/iwinfo

- **改动**（16 文件）：regdb 3 + mac80211 subsys 10 + firewall4 1 + rpcd 1 + iwinfo 1
- **做了什么**：无线监管与子系统稳定性补丁集
- **修复**：CSA（信道切换）在 STA/非 tx BSS/MLO 场景的崩溃与行为异常（mac80211 397-412）；
  rpcd exec 的 EOF 处理；iwinfo txpowerlist 的 wiphy dump
- **新增**：US 6GHz no-no-ir、UNII1-29 功率限制、UNII3-4 160MHz 规则；mac80211 link sta
  capability；firewall4 bonding 下层设备支持

### 5. `5b4b89dd05` target: airoha - NPU/PPE hardware offload stack

- **改动**（74 文件）：内核补丁 21 个（`target/linux/airoha/patches-6.18/`）、
  `target/linux/generic/pending-6.18/675-04`、`arch/arm64/boot/dts/airoha/en7581.dtsi`、
  `drivers/char/hw_random/airoha-trng.c`、LuCI 应用 6 个（npu/flowsense/fancontrol/mlo 等）、
  `package/network/config/bridge-hw-offload` 规则、`config-6.18`
- **做了什么**：NPU/PPE 硬件卸载栈主体 + 配套 LuCI 监控应用 + 板级包
- **修复**：992-20 与上游 187-v7.3 重复的 trtcm 重试（hunk 8/9 删除）；
  RX_NO_CPU_DSCP 中断、PCS 校准、hwrng 时钟顺序等硬件问题
- **新增**：NPU 保留内存区（DTS）、flowsense/npu-monitor/fancontrol/mlo 应用、
  bridge-hw-offload 规则包、PPE 流统计/绑定/惰性清理

### 4. `6a167d42fd` target: airoha - platform fix bundle for an7581

- **改动**（16 文件）：`patches-6.18/`×7（939 cpufreq/940 pmdomain/998 phy-LED/9991/
  992-20/992-21）、`pending-6.18/675-01..03`、hostapd mtk-0015、wifi-scripts 010、
  bridge-hw-offload 包、`an7581/config-6.18`、`an7581/target.mk`、`an7581.dtsi`
- **做了什么**：平台级修复与桥接卸载前置
- **修复**：EN7581 CPUFreq（SMCCC）与 PM domain 缺失；6G 免 DFS；EHT beamforming 默认关闭
- **新增**：nft L2 bridge offload 三件套（675-01/02/03）、桥接硬件卸载规则包、
  smartrg/cmonroe 稳定性补丁

### 3. `5122fbcaef` xr1710g: misc board tweaks

- **改动**（13 文件）：banner、init.d/led、mt76 Makefile、dropbear 500、iwinfo 200、
  `an7581/config-6.18`、`an7581.dtsi`、patches 998/9991、`generic/config-6.18`、
  hack-6.18/743、pending-6.18/680、`luci-app-mlo/patches/001`
- **做了什么**：日常可用性微调集合
- **修复**：ledtrig-netdev link-mode mutex（680）；PHY LED pinctrl 可选（998）；
  MTK PHY LED 可选依赖
- **新增**：SPI 33MHz、彩色 banner、dropbear 静默日志、snd-soc 关闭、
  iwinfo 每 radio 频率列表、MLO mesh 隐藏、RTL826x LED 支持

### 2. `8973859c9c` xr1710g: netdev naming (YYH convention) and default board config

- **改动**（68 文件）：`packages-xr1710g/`×66（Argon 主题 + 配置 App）、
  `an7581-xr1710g-ubi.dts`、`board.d/02_network`
- **做了什么**：网口命名对齐 YYH 约定 + 预装 Argon 主题与中文 i18n
- **修复**：端口命名与运维脚本/既有习惯不一致（lan1/lan2/wan → eth1/eth2/lan2/lan3）
- **新增**：Argon 主题、Argon 配置 App、自有 feed `packages-xr1710g` 结构

### 1. `4456562295` target: airoha - add Gemtek XR1710G board support (an7581)

- **改动**（7 文件）：`an7581.mk`、`an7581-xr1710g-ubi.dts`、uboot-airoha Makefile +
  patches/9990、uboot-envtools airoha_an7581、`board.d/02_network`、`platform.sh`
- **做了什么**：从零注册 XR1710G 板型
- **新增**：Device `gemtek_xr1710g-ubi`（镜像可出）、整机 DTS、U-Boot 支持、
  升级兼容（platform.sh magic/board）、网口初始化骨架

---

## §3 维护检查清单（每次 commit 前后）

```
[ ] 改动是否落入 §1 已有条目？→ 更新其说明（解决/新增了什么）
[ ] 是否新增/删除/移动了定制文件？→ 更新 §1 树形与计数
[ ] §2 是否追加了本 commit 的记录（SHA/文件/做了什么/修复/新增）？
[ ] 合并或 rebase 改变了历史？→ 重写受影响条目，保持与 git log 一一对应
[ ] 头部计数（commit 数 / 文件数 / 行数）是否同步刷新？
```

已知长期趋势：上游逐步合入 Airoha AN7581 支持后，本清单中板级注册（§2 #1）、
DTS（#1）、部分 NPU 补丁（#5）会被上游原生实现取代——届时在 rebase 中 drop 对应
commit 并同步缩减本文档，即为"修改量逐渐降低"的可量化体现。
