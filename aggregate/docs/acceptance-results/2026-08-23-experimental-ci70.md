# 实机验收记录 — CI #70 experimental（commit 46600b2）

- 日期：2026-08-23（UTC，设备本地 2026-08-23 22:xx）
- 设备：Gemtek XR1710G（`gemtek,xr1710g-ubi`），HTTP U-Boot 2026.07-00766-g53b73174c0fc
- 固件：CI #70 = workflow run `32621217391`（build profile=experimental，commit `46600b2`）
  - `DISTRIB_REVISION='r0-3d1645e'`，kernel `6.18.44`
  - 产物：`firmware-experimental.tar.gz`（sysupgrade.itb sha256 `21cd0c0c…`）
- 访问：ssh root@192.168.123.1
- 结论：**远程可验项大部分通过；发现并修复 1 个 LED sysfs 回归；F66 rdinit 修复被 HTTP U-Boot 默认 env 覆盖，仍为假警告；B5 IPv6 专项已补做并通过；F69/F71/C2/C3/C4/D3 等物理/长稳项待补测。**

## 分项结果

### A 启动与引导
- [x] A1 冷启动/重启：`reboot` 后 SSH 恢复，dmesg 无 panic/oops；冷断电未做。
- [x] F65 sysupgrade 兼容：下载本 run `*-squashfs-sysupgrade.itb` 到设备 `/tmp`，`sysupgrade -T` 返回 0（同版可升级，compat 2.0 与 UBI 2.0 布局一致）。
- [x] F64 新布局：`/proc/mtd`：ubi=`0x1b700000`、reserved_bmt=`0x04200000`；`ubinfo -a`：bad PEBs=0，max/mean erase counter=2/1；重启后无新增坏块。
- [ ] F66 rdinit 假警告：**未通过**。dmesg 仍有 `check access for rdinit=/init failed: -2, ignoring`；`/proc/device-tree/chosen/bootargs` 无 `rdinit=`。根因见 FIXES F66 更新。

### B 网络
- [x] B1 WAN：`wan` PPPoE up，IPv4 172.27.23.206；ping 8.8.8.8 3/3 通；DNS 解析 openwrt.org 正常。
- [ ] B2 双 10G 口：lan1 link 2500/Full（对端 2.5G）；lan2 NO-CARRIER（无 10G 对端）。eth0（CPU 侧）10G/Full。未测 10G 打流。
- [x] B3 1G 口：`wan`=1000/Full up；`lan3` NO-CARRIER（本轮无设备接入，前次记录为 1000/Full up）。
- [x] B4 LAN 网关：br-lan 192.168.123.1/24，dnsmasq DHCP 正常（多客户端租约/NAK 重发记录）。
- [x] B5 NPU offload：`luci.airoha_npu getStatus` npu_loaded=true，offload_bound/offload_total>0；PPE entries 有 LAN↔WAN IPv4/IPv6 条目。IPv6 专项补做（2026-08-24）：`scripts/device-npu-ipv6-probe.sh` 跑通（TCP_ROUNDS=1/UDP_SECONDS=15 及 smoke 复跑 rc=0），conntrack IPv6 出现 `[HW_OFFLOAD]`、`/sys/kernel/debug/ppe/bind` 出现 `BND IPv6`；结束时 `ct6=19`、`ct6_hw=4`、`bnd6=2`，RPC `getPpeEntries.bnd.ipv6` 有计数。
- [ ] B6 管理面改址回连：**按用户要求取消测试**。

### C Wi-Fi
- [x] C1 三频全部 up：2.4G ch1/HE40、5G ch149/HE160、6G ch37/EHT320；SSID `K2P`/`K2P-5G`；加密正常。
- [~] C2 6GHz：AP 侧 US regdb + EHT320 + 29 dBm up；客户端侧国家码/可见可连未验（无 6G 客户端）。
- [ ] C3 速率冒烟：未测（需 160/320MHz 客户端 + 外部对端 iperf3）。
- [ ] C4 MLO：未测（需 MLO 客户端）。

### D 温控与稳定
- [x] F67/D1 风扇单控制器：`ps` 仅一个 `S99fan` 进程；`/etc/init.d/fan start` 返回 0 且不重复起；nct7802 pwm1=66、fan_rpm=1087；LuCI fan RPC 可读。
- [x] D2 温度读数：hwmon0/1 为 mt7530 10G PHY（50/68°C），hwmon2-4 为 mt7996 三射频（56/51/57°C），hwmon5 nct7802（temp1 50.6°C，temp2 127875 未接传感器为已知项）。
- [ ] D3 72h 连续运行：未测（截至 2026-08-24 08:00 UTC 设备已连续运行约 18h、dmesg 无内核报错；72h + 2×10G + 三频负载条件仍不满足，继续观察，下一轮收口前补验）。

### E 固件本体
- [ ] E1 OC 档位：experimental 档不含 OC，不适用。
- [~] E2 版本元数据：当前 CI#70 固件仍为 `DISTRIB_DESCRIPTION='OpenWrt SNAPSHOT r0-3d1645e'`（无档位标识）；仓库已在 `scripts/build.sh` 与 `.github/workflows/build.yml` 构建命令注入 `CONFIG_VERSION_DIST="OpenWrt <profile>"`，待下一轮构建后实机验证（预期 `OpenWrt experimental SNAPSHOT r...`）。

## 实验档专项
- [x] 9992/F71 JCPLL TCLVAR recal：构建日志确认 `9992-net-pcs-airoha-jcpll-tclvar-recal.patch` 已应用；实机 lan2 无 10G 对端，功能未验。
- [x] mt76-0009/F68 tx_failed 记账：2.4G/5G 站点 `tx_retries>0` 且 `tx_failed=0`。
- [~] mt76-0010/F69 NPU RX skb->dev：构建日志确认 `mt76-0010` 已应用；功能需 6G 客户端 + conntrack -F 场景，未验。
- [~] 9030/F70 FlowSense 1.1.8-r5：`luci.airoha_flowsense` RPC 与 UI 资产存在，`npu-monitor.settings.air_eff=80`；`getWifiStats` 返回 bands，小流量后 band1 `air_mbps=0.7` 非零。B5/C4 大流量吞吐针未验。
- [x] wifi down/up 5 轮：4 个 BSS 每轮均 `ENABLED` 且 SSID 正确，未复发 issue #10。
- [x] EHT320/9990/9991/9993、TXFREE 0005、bridge-flow-offload 9024/9026：WiFi 三频 up，EHT320/HE160 正常；PPE/BND 有活动条目。

## 发现与修复
1. **LED sysfs 命名回归（本次已修）**：openwrt master 3d1645e 内核把 DSA LED 从 `mt7530_dsa-0:*` 改为 `mt7530-0:*`；`files/etc/config/system` 与 `scripts/device-hw-probe.sh` 仍在用旧名，导致 `led start` 返回 1、路由 C 全挂。已改为 `mt7530-0:*`，并在设备上验证 `led start` 返回 0、无 EINVAL、netdev trigger 正常。
2. **F66 rdinit 修复未生效（待 U-Boot 侧处理）**：9001 的 chosen bootargs 对 HTTP U-Boot 无效——该 U-Boot 默认 env `bootargs=console=… rootwait`（无 `rdinit`）会覆盖 DTS chosen。已尝试写 UBI env（ubootenv/ubootenv2）并重启，U-Boot 未读取。详见 FIXES F66。
3. **device-hw-probe B2.1 VEND1 寄存器已打通（后续已修）**：原经 lan1/lan2 读 `0x103/0x104` 返回 `phy_read (-95)`；根因是 10G PHY 挂在 mt7530-0 MDIO 总线，Airoha GDM ioctl 不支持，须借道 DSA 用户口（wan/lan3）以 C45 MMD30 读 `IFACE/<phy>:30/0x103`。实机：lan1/lan2 PHY VEND1 `0x103=0x8261`、`0x104=0x1141`，`driver=RTL8261BE 10Gbps PHY`。
4. **DISTRIB_DESCRIPTION 缺少档位标识（已修，待下一轮构建验证）**：构建命令已注入 `CONFIG_VERSION_DIST="OpenWrt <profile>"`（`scripts/build.sh` 与 `.github/workflows/build.yml`），下次构建后 `/etc/openwrt_release` 应含档位标识；当前 CI#70 固件仍是旧描述。
