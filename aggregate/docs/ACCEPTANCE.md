# 验收清单（ACCEPTANCE）——"可用固件"的定义

**用途**：known-good 冻结门槛。一个版本只有**全项通过**才打 known-good tag；任何一项失败 → 修复（不改清单、不降级），修复后重测。
**实机环境**：设备已固化 HTTP U-Boot（docs/FLASHING.md 主路径）；测试机通过 10G 电口/千兆口接入。

## 测试方法学（IP20/IP24/IP28）
- 吞吐类指标（B2 对打、C3 无线速率等）必须使用**外部对端**（PC / 另一台设备）作为 iperf3 端点；**禁止使用路由器本机 iperf3 作为转发面吞吐判据**。
- 路由器本机 iperf3 只可作为 CPU 基线，并在结果中明确标注“CPU 基线，非转发面”。
- 无线速率项需同时记录客户端能力（国家码 / HE/EHT 频宽 / MIMO / 距离 / 是否同频段干扰）。
- 管理面改址类测试必须用“改后从新地址回连成功”作为通过判据，不能只验证 UCI 写入成功。

## 启动与引导
- [ ] A1 冷启动：HTTP U-Boot 引导 → OpenWrt 完整启动（无 kernel panic / 无 fit0 等待）
- [ ] A2 sysupgrade 往返：由旧版 sysupgrade 升到本版本；再由本版本 sysupgrade 回退旧版（均成功、配置保留/提示）
- [ ] A3 恢复兜底：192.168.255.1 恢复页可进入（10G 口 + reset 时序）

## 网络
- [ ] B1 WAN（1G 口 1）：DHCP 获取 IP；外网连通（ping 8.8.8.8 / 域名解析）
- [ ] B2 双 10G 口：均能 10Gbps 链路（ethtool speed 10000）；10G 对打带宽 ≥ 8Gbps
- [ ] B3 剩余 1G 口：接入正常（speed 1000）
- [ ] B4 LAN 网关 192.168.123.1：DHCP 分发、LAN 互访、NAT 上网正常
- [ ] B5 硬件 flow offload / NPU 卸载生效（luci-app-airoha-npu 显示 NPU 已加载；卸载计数增长；IPv6 TCP 多源并发达 `[HW_OFFLOAD]`+PPE BND v6、IPv6 UDP 长流达 `[HW_OFFLOAD]`）
- [ ] B5.1 纯 IPv6 无线客户端（该站无 IPv4 地址/租约）产生 IPv6 TCP 流：`getPpeEntries.client_bnd` 中该站 `bnd>0` 且 `ip6` 非空（issue #19 终验）
- [ ] B6 管理面改址回连：LuCI 将 LAN IP 改为 192.168.50.1/24（或静态 CIDR）后仍可从新地址回连；改回后恢复（IP20）

## Wi-Fi
- [ ] C1 三频全部起来且可连接：2.4G / 5G / 6G，统一 SSID「K2P」、WPA2/WPA3 混合
- [ ] C2 6GHz 正常工作（US regdb、EHT320 or 160MHz fallback 注明当前实际）；**客户端国家码须为 US**——非 US 客户端看不到 6G SSID 是预期行为，不作为失败，但必须记录客户端国家码与“可见可连”双侧判据（IP14）
- [ ] C3 速率冒烟（外部对端 iperf3，禁止路由器本机 iperf3 作为吞吐判据）：5G ≥ 1200Mbps（160MHz 客户端）；6G ≥ 2400Mbps（320MHz 客户端）；记录客户端国家码/频宽/MIMO/距离（IP24/IP28）
- [ ] C4 MLO 可配置且生效（luci-app-mlo：多频绑定成功）

> C3/C4 速率与 MLO 吞吐验收以主 `mt7996e`（14c3:7990，`pcie0` x2/Gen3）数据面为准；`mt7996e-hif`（14c3:7991，`pcie2` x1/Gen2，EN7581 共享 USB3 PHY 单 lane 板级限制；2026-08-24 实机 D0 判定根端口 LnkCap2 仅报 2.5/5GT/s，**Gen2 x1 为板级正确拓扑**）不作为瓶颈假设（issue #16）。

## 温控与稳定
- [ ] D1 风扇曲线接管（`/etc/init.d/fan` 运行，温度点切换 PWM 正确）
- [ ] D2 温度读数正常（CPU / 10G PHY / switch / Wi-Fi；fancontrol 页面无 N/A）
- [ ] D3 72h 连续运行（含 2×10G + 三频负载）无重启、无内核报错（dmesg 检查）

## 固件本体
- [ ] E1 OC 档位（oc-1.3/oc-1.4 时）：`cpuinfo_max_freq` 分别为 1300000/1400000 kHz；启动正常（无 panic）；烤机 77°C 上限内
- [ ] E2 版本元数据正确（DISTRIB_DESCRIPTION 含档位标识与 commit）

## 验收结论（每次冻结时填写）
| 版本（commit/tag） | 档位 | 测试日期 | 结果 | 备注 |
|---|---|---|---|---|
| `feat/antenna-eeprom-power-unlock` @ 77170e1（+F28 实机修复） | experimental | 2026-08-21 | **未冻结**（远程可验项通过；B2/C3/C4/D3/A2/A3 待补测） | 详细记录：`docs/acceptance-results/2026-08-21-experimental.md` |
| `7ce6c81` @ `known-good-p1-20260908` | experimental（r0-7b39600） | 2026-09-08 | **未冻结**（R1–R7 已执行：wifi down/up、hw-probe、风扇/LED、sysupgrade -T、#22397 均通过；**B2 10G 未达成**（LAN2 冷启动 20/20 2.5G，9029 生效 devmem=0x301D）；C2/C3/C4/B5.1/B2 对打/D3 72h 压力等对端项按用户口径延后） | 详细记录：`docs/acceptance-results/2026-09-08-p1-regression.md`；tag 已推（冻结门槛 = 全项通过，本行仅为 P1 阶段状态） |