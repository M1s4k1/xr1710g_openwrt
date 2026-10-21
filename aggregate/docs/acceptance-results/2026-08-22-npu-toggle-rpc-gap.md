# NPU 开关切换与 RPC 诊断缺口测试 — 2026-08-22（experimental 档实机）

- 设备：Gemtek XR1710G（`gemtek,xr1710g-ubi`），OpenWrt SNAPSHOT r0-725cbf1，kernel 6.18.44，experimental 档
- 访问：ssh root@192.168.123.1；LAN 打流主机 192.168.123.102/201–206（同一 MAC）
- 方法：在 2026-08-22-npu-offload-stress 与 2026-08-22-npu-multichannel-exploration 基础上，补测四路：
  1. `flow_offloading_hw` 1→0→1 切换安全性与软件/硬件流表对比
  2. 多源 IPv4 TCP 并发打流 + 卸载状态采样
  3. IPv6 TCP/UDP 卸载与 DNS 探测
  4. 全部 LuCI NPU RPC 在长时运行后的行为（dmesg 被 logd 消费后的表现）

## 结论速览

| # | 发现 | 严重度 | GitHub Issue | 处置建议 |
|---|---|---|---|---|
| T1 | `flow_offloading_hw` 1→0→1 + `fw4 reload` 后约 10–15s 设备重启（kernel boot 08:27:54），无 pre-reboot log/pstore | 高 | #7 | 复现并定位 NPU flow_block 解绑/重绑路径；在线开关切换需加防护或提示重启 |
| T2 | `getStatus.memory_regions` 在 dmesg 被 logd 消费后恒为 `[]`；与 #3 的漏报第 5 区叠加 | 中 | #8 | 9017 改为解析 `/proc/device-tree/reserved-memory/npu-*` |
| T3 | `getWanHealth`/`getBridgeStats` 依赖 BusyBox 不支持的 `ip -s link show`，导致统计恒 0 / available:false | 中 | #9 | 读 `/sys/class/net/<dev>/statistics/*` |
| T4 | IPv6 TCP 持续流可达到 `[HW_OFFLOAD]`；IPv6 UDP DNS 到 2400:da00::6666 不可达（非设备问题） | 信息 | - | IPv6 offload 能力确认可用 |

## 打流结果

### 多源 IPv4 TCP 并发（硬件卸载开）

- 14 路并发（源 IP 102/201/202 × 各 2 路 + 其余源 IP 当时未添加失败）：
  - 单文件 38,298,724 字节（`mirrors.aliyun.com/ubuntu/ls-lR.gz`）
  - 6 路成功全部 200 且字节数精确；合计 229.8MB，总耗时 7.63s，聚合 30.1MB/s（约 240Mbps）
- 21 路并发（源 IP 102/201–206 × 各 3 路）：
  - 全部 200 且字节数精确；合计 804.3MB，总耗时 15.55s，聚合 51.7MB/s（约 413Mbps）
  - 采样：conntrack 中对应流带 `[HW_OFFLOAD]`；PPE bind 出现 BND 记录（`packets=0 bytes=0`，计数失效见 issue #5）
- 2 路小样本确认：源 201/202 的下载流在传输中即 `[HW_OFFLOAD]` + PPE BND 双向记录。

### 软件流表基线（`flow_offloading_hw=0`）

- 7 路并发（源 IP 102/201–206 各 1 路，38.3MB）：
  - 全部 200 且字节数精确；总耗时 5.86s（最慢一路），各流 6.5–6.7MB/s，聚合约 45.7MB/s
  - conntrack 全部为 `[OFFLOAD]`（软件 flowtable），无 `[HW_OFFLOAD]`
  - 设备 load 0.73，jitter RPC `cpu_pct` 7
- 恢复 `flow_offloading_hw=1` 后设备重启（见 T1），因此未能在同一 uptime 内完成同规模硬件对照；硬件参考 21 路并发数据（51.7MB/s）。

### IPv6

- 16 路 IPv6 TCP（源 4 个地址 × 4 个目标 `ipv6.baidu.com/www.qq.com/www.163.com/www.taobao.com`）：
  - baidu/qq/163 全部 15/15 成功；taobao 8/15 成功（目标侧行为）
  - 持续 30 请求的 `ipv6.baidu.com` 流，第 5s 采样即 `[HW_OFFLOAD]`，后续 30s 稳定保持，说明 IPv6 TCP 硬件卸载可用，但短流可能只见 `[OFFLOAD]`
- IPv6 UDP DNS：
  - `2400:3200::1`（AliDNS v6）40/40 响应，RTT avg 75ms
  - `2400:da00::6666` 40/40 超时（现网不可达）

### ICMP

- `ping -c 5 223.5.5.5` 成功，conntrack 仅普通 icmp 条目，不带 `[OFFLOAD]`/`[HW_OFFLOAD]`——fw4 的 flowtable 只对 tcp/udp `flow add`，符合预期。

## RPC 长时运行后行为（T2/T3 证据）

- `dmesg | wc -l` 为 0；`ubus call luci.airoha_npu getStatus` 的 `memory_regions` 变 `[]`。
- `ubus call luci.airoha_flowsense getWanHealth` 返回 `rx_bytes:0,tx_bytes:0`，但同一时刻 `/sys/class/net/pppoe-wan/statistics/rx_bytes=860075,tx_bytes=7573199`。
- `ubus call luci.airoha_flowsense getBridgeStats` 返回 `{"available":false}`，但 `br-lan` 正常。
- `ubus call luci.airoha_flowsense getFrameEngine` 返回 `{"error":"devmem not available"}`（已记录于 issue #2）。
- `getVlanOffload/getFlowOffload/getPppoeOffload/getNpuBypass/getJitterResult/getWifiStats/getEthStats` 均正常返回。

## T1 重启事件时间线

1. 08:27:39 前：`flow_offloading_hw=0` + fw4 reload 成功，执行软件流表 7 路打流，设备正常。
2. 08:27:50 左右：恢复 `flow_offloading_hw=1` + `uci commit` + `/etc/init.d/firewall reload`，命令返回 `restored`。
3. 08:27:54：kernel boot 日志开始（设备重启）。
4. 08:28:13：发起硬件对照打流时发现设备 uptime 仅 0 min，SSH 会话中断，下载全部 timeout。
5. 重启后：`/sys/fs/pstore` 为空；`logread` 仅保留重启后的 631 行；无 pre-reboot 日志。设备自动恢复，PPPoE WAN IP 从 172.27.136.218 变为 172.27.57.161。
6. 重启后重新验证：硬件卸载开，源 .201 单流下载 38.3MB 成功，conntrack `[HW_OFFLOAD]` + PPE BND 恢复。

## 建议

- **T1 优先处理**：在线切换 `flow_offloading_hw` 是 LuCI 可操作路径，当前疑似会导致重启。建议在实验档复现（1→0→1）并抓串口/网络 console；在修复前，LuCI set 操作应提示"切换后建议重启"或禁用 1→0→1 快速连续切换。
- **T2/T3 修复**：9017 的 `get_status`、`get_wan_health`、`get_bridge_stats` 改为稳定 sysfs 数据源（设备树保留内存、`/sys/class/net/*/statistics`）。
- **诊断包补齐**：`devmem`、`bridge`、`ethtool`、`tcpdump`、`iperf3` 下轮镜像补入（已在 issue #2）。
