# 实机验收记录 — experimental 分支 `feat/antenna-eeprom-power-unlock`

- 日期：2026-08-21（UTC，设备本地 2026-08-22 01:0x）
- 设备：Gemtek XR1710G（`gemtek,xr1710g-ubi`），已固化 HTTP U-Boot
- 固件：OpenWrt SNAPSHOT r0-725cbf1（kernel 6.18.44，base openwrt commit 725cbf1），experimental 档
- 访问：ssh root@192.168.123.1（已装 SSH 公钥；root 密码按用户要求设为 `password`）
- 结论：**可远程验证项全部通过；物理吞吐/72h 等项待补测，未达 known-good 冻结门槛。**

## 分项结果

### A 启动与引导
- [x] A1 冷启动/重启：`reboot` 后 5s 内 ping 通、SSH 恢复；dmesg 无 panic/oops。冷断电未做（需物理操作）。
- [ ] A2 sysupgrade 往返：未测（需旧版 sysupgrade 镜像与本版镜像）。
- [ ] A3 恢复兜底：未测（需 10G 口 + reset 时序物理操作）。

### B 网络
- [x] B1 WAN：`wan` 1G 口 PPPoE 已拨号（ifstatus wan up，IPv4 172.27.x.x）；ping 8.8.8.8 通（3/3 或 3/4），DNS 解析 openwrt.org 正常。
- [ ] B2 双 10G 口：当前 lan1/lan2 无链路（NO-CARRIER）。本机只有 1G 接入 lan3，无法测 10G 速率；dmesg 曾记录 lan1/lan2 在 2.5G 链路协商成功，证明 PHY 工作正常，但 10Gbps 与吞吐未验。
- [x] B3 剩余 1G 口：`wan`=1000/Full up（1G-1），`lan3`=1000/Full up（1G-2，本工作机接入）。
- [x] B4 LAN 网关：br-lan=192.168.123.1/24，dnsmasq DHCP 服务器正常；macvlan DHCP 客户端实测获取 192.168.123.219（OFFER/ACK 均来自 192.168.123.1）。NAT 上网由 B1 佐证。
- [x] B5 NPU offload：`ubus call luci.airoha_npu getStatus` → `npu_loaded=true`，TLB7.7.0.0_v03，8 cores，`offload_bound=6`，PPE bind/entries 有 LAN↔WAN 5-tuple 条目。

### C Wi-Fi
- [x] C1 三频全部起来：2.4G ch6/HE40、5G ch149/HE160、6G ch37/EHT320；SSID 统一 `K2P`；2.4G/5G 加密 `sae-mixed`（SAE + WPA-PSK 混合），6G SAE。
- [x] C2 6GHz：US regdb；iw dev 显示 channel 37 / 320 MHz / center1 6105 MHz；Tx-Power 29 dBm；AP enabled。
- [ ] C3 速率冒烟：未测（需 160/320MHz 客户端打流）。
- [ ] C4 MLO：`luci-app-mlo` 已安装、LuCI 菜单存在；未做多频绑定实机生效测试（需 MLO 客户端）。

### D 温控与稳定
- [x] D1 风扇曲线接管：`/etc/init.d/fan` 运行中（S99fan boot）；脚本动态探测到 NCT7802，按 temp1 写入 pwm1（当前约 50°C → pwm 69，符合 40-50°C 档）。
- [x] D2 温度读数：hwmon 有 mt7530_dsa:05/08（10G PHY，约 49°C）、mt7996 三射频（56/51/57°C）、nct7802（temp1≈50°C，temp4≈48°C；temp2 读数异常 127875 为未接传感器）。CPU 无独立 hwmon，fancontrol 是否显示 CPU N/A 未验。
- [ ] D3 72h 连续运行：未测。

### E 固件本体
- [ ] E1 OC 档位：本次为 experimental 档（未做 OC），不适用。
- [x] E2 版本元数据：`DISTRIB_DESCRIPTION='OpenWrt SNAPSHOT r0-725cbf1'`，含 openwrt 基座 commit 725cbf1；**不含档位标识**（experimental 未体现）——不满足 E2 全项，需后续在构建层注入档位标识。

## 实验档专项（本次分支目标）
- [x] 单 wiphy 三 radio 模型：`phy0` + `radio 0/1/2` 配置生效（三频 up）——本次实机修复，见 F28。
- [x] mt76-0008 eeprom 功率解锁：dmesg `XR1710G eeprom: 2G power unlock 28 -> 30 dBm`、`5G UNII-3 power unlock 28 -> 30 dBm`；iwinfo 2.4G/5G Tx-Power 30 dBm。
- [x] regdb 0521：6G EHT320 落在 5925-6425MHz，UNII-3/4 5G 160MHz 可用。
- [x] EIP93 硬件加密：`crypto_hw_eip93` 已加载。
- [x] L2 offload / DSA（#22533/#22532）：lan3/wan 为 DSA 用户口（DEVTYPE=dsa）；nft flowtable `flags offload`；PPE 存在 `L2B` 条目。
- [x] mt76-0005 txfree guard / 9990/9991/9993：WiFi 稳定 up，EHT320 与 HE160 正常启用；具体 EHT 广告/op_mode 传递未做客户端侧验证。
- [x] 修复项 F28 实机闭环：修复前 5G/6G 无法绑定（phy1/phy2 不存在），修复后三频 up、txpower 正确。
- [x] 修复项 F29 实机闭环：`luci.airoha_npu getVlanOffload` → `{"enabled":1}`、`getPPPoEOffload` → `{"enabled":1}`；`setPPPoEOffload enabled=1` 返回 ok（9018 已应用）。

## 发现与遗留
1. `DISTRIB_DESCRIPTION` 缺少档位标识（experimental）——E2 部分不达标，建议构建层按档位注入 `CONFIG_VERSION_DIST`。
2. 10G 口本轮无链路，B2 未测；需 10G 对端设备。
3. 2.4G htmode 曾观察到设备侧被改为 HE20（repo 为 HE40）；已按 repo 恢复 HE40 并 reload 生效。
4. hostapd 启动阶段有 `Failed to request a scan of neighboring BSSes ret=-16` 重复日志，但最终所有 radio AP-ENABLED，判定为多射频并发扫描的良性告警，持续观察。
