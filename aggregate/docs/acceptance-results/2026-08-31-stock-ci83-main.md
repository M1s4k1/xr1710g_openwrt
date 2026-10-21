# 2026-08-31 stock ci-83（main@3a7257c）实机复核

> 审查对象：build run **#83**（id 33331824393，push main `3a7257c`）stock 档 Artifact `firmware-stock`。
> 固件：`openwrt-stock-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb`，sha256 `b308fc20aba7324080cded245fe21687a9427386ba7ce0c05bb41247540956e3`。
> 基线：openwrt master `93cf01b`，kernel 6.18.44，`DISTRIB_DESCRIPTION='OpenWrt stock SNAPSHOT r0-93cf01b'`。
> 实机：`root@192.168.123.1`，2026-08-31 以 `sysupgrade -n` 清空 overlay 全新刷入。

## 0. 结论

- **毕业批次 default 档实机回归基本通过**：compat_version 2.0、fw4 flow_offload uci-defaults、NPU v4/v6 offload、EHT320/HE80/20MHz 三频、tx_failed≈0、wifi down/up 5 轮无复发、device-hw-probe 全绿。
- **发现 1 个 P1（已实机修复，代码待随下轮固件关闭）**：fresh flash 后 LED 默认配置 sysfs 仍为 `mt7530_dsa-0:*`，内核实际为 `mt7530-0:*`，`led start` rc=1、口灯全灭。设备 UCI 已改 `mt7530-0` 并复验 rc=0；main 代码已合入探测式 uci-defaults（`98-xr1710g-led-sysfs-prefix`），下轮固件 fresh flash 复验。
- **发现 1 个 P2（已修 seed）**：stock 档未安装 `bridge-flow-offload`（manifest 无此包；`DEFAULT_PACKAGES += bridge-flow-offload` 未生效，待查）。毕业批次 E1–E3 在 stock 档因此无法实测。已将 `CONFIG_PACKAGE_bridge-flow-offload=y` 移入共享 seed，下轮 stock 构建后实机补验。
- F66 仍为已知良性 `rdinit=/init failed: -2`（HTTP U-Boot 默认 env 覆盖 DTS chosen）。
- C2/C3/F69/F71/B2/D3 需物理对端/客户端，继续延后。

## 1. 通过项

- [x] **E2 档位元数据**：`DISTRIB_DESCRIPTION='OpenWrt stock SNAPSHOT r0-93cf01b'`
- [x] **F65 compat_version**：/rom 与 /etc 均为 `2.0`；同镜像 `sysupgrade -T` rc=0
- [x] **fw4 flow_offload uci-defaults 生效**：fresh flash 后 `/rom/etc/uci-defaults/99-xr1710g-flow-offload` 存在；`/etc/config/firewall` 默认含 `flow_offloading='1'`、`flow_offloading_hw='1'`
- [x] **F64 布局**：mtd `ubi`=`1b700000`、`reserved_bmt`=`04200000`；dmesg `ubi0: good PEBs: 3512, bad PEBs: 0, corrupted PEBs: 0`；ubinfo bad=0
- [x] **F63 NPU**：`npu_version TLB7.7.0.0_v03`、8 核 @ 800MHz；getStatus 返回 5 个 memory regions（npu-ba/npu-binary/npu-pkt/npu-txbufid/npu-txpkt）
- [x] **B5 IPv4 offload**：conntrack `[HW_OFFLOAD]`=17+；offload_bound=16/49
- [x] **B5 IPv6 offload**：route A + sampler：`ppe_bnd_v6=29`、`conntrack_v6_hw=23`、`conntrack_v6_off=13`；nft flowtable 含 `pppoe-wan`、`phy0.x-ap0` 等全部设备
- [x] **F68 tx_failed**：4 个关联站点 tx_retries>0 时 tx_failed 均为 0（2.4G 32/0；5G 1/0、58/0；5G-2 518/0）
- [x] **C1 三频**：2.4G ch6 HE40? 20MHz 30dBm；5G ch149 HE80 30dBm；6G ch37 EHT320 29dBm（AP 侧）
- [x] **eeprom 功率解锁**：dmesg `2G power unlock 28 -> 30 dBm`、`5G UNII-3 power unlock 28 -> 30 dBm`
- [x] **F67 风扇**：`/etc/init.d/fan start` rc=0；`S99fan` 单写者；pwm1=79（hwmon5）
- [x] **LED（修复后）**：设备 UCI 改 `mt7530-0:*` 后 `led start` rc=0；6 个 PHY LED `trigger=netdev`
- [x] **F75/A12 device-hw-probe**：route_a-d 全部 rc=0；B7 EFR32 absent；B2.1 RTL8261BE
- [x] **issue #10 wifi down/up**：5 轮 rc=0，BSS 均 ENABLED，无 `!!! issue #10 signature`
- [x] **D1/D2**：pstore 空；dmesg 无 error/fail/BUG/Oops（除 F66 良性 rdinit）
- [x] **getPpeFlowStats**：available=true，conntrack 合流统计可用

## 2. 未通过/待办

- [ ] **LED fresh flash 默认配置错误（P1，已修 UCI，待代码随下轮固件验证）**
- [ ] **stock 档缺 bridge-flow-offload（P2，已修共享 seed，待下轮构建验证）**
- [ ] F66 rdinit 假警告：HTTP U-Boot 默认 env 覆盖 DTS chosen，需 U-Boot 侧补 `rdinit=/sbin/init` 或换 9002 U-Boot
- [ ] C2 6G 客户端国家码双侧判据 / C3 外部对端 iperf3 / B2 双 10G 对打 / F69 mt76-0010（6G 客户端）/ F71 JCPLL（10G 对端）/ D3 72h 长稳

## 3. 关键原始数据

- 包集合：206 包（与 ci-69 stock 一致）；`airoha-en7581-mt7996-npu-firmware 20260810-r1`、`kmod-mt76 6.18.44.2026.08.22~c5a3bd91`、`kmod-nft-offload`、`luci-app-airoha-flowsense 1.1.8-r5` 在列。
- `sysupgrade -T`：同镜像两次 rc=0（刷入前旧固件、刷入后新固件）。
- 硬件探针：`route_a/b/c/d done (rc=0)`；`B7 OK: uart2 absent / hsuart3 absent`。
