# 实机深度测试记录 — NPU offload 长时间负载

- 日期：2026-08-22（设备本地，UTC 2026-08-21）
- 设备：Gemtek XR1710G（`gemtek,xr1710g-ubi`），固件 OpenWrt SNAPSHOT r0-725cbf1（kernel 6.18.44），experimental 档
- 访问：ssh root@192.168.123.1
- 结论：**NPU offload 在 35 分钟、3 路并发、约 3.38GB 转发负载下稳定工作；发现并修复 npu-monitor 默认 target 不可达问题（ae9a2fd）。**

## 测试方法

- 打流：从 LAN 侧主机（192.168.123.102）经设备 WAN PPPoE 到阿里云镜像，3 路并发 HTTP 下载（单文件 16,122,451 字节）：
  - T4：90 次 / T5：60 次 / T6：60 次，合计 210 次，约 3.38GB
  - 持续约 35 分钟（01:54–02:29）
- 采样：设备端每秒采样 CPU busy、mt76-npu/eth0/mt7996 中断、PPE bind/entries/BND 流数；每 60 秒采样 load、内存、conntrack HW/SW offload 计数、NPU 时钟、温度、jitter。
- 功能验证：`luci.airoha_npu` / `luci.airoha_flowsense` 全部 RPC 状态与 VLAN/PPPoE Offload set/get。

## 结果

| 指标 | 表现 |
|---|---|
| CPU busy | 5–19%；load 峰值 1.63 |
| 硬件卸载 | conntrack `[HW_OFFLOAD]` 峰值 43 条；PPE BND 峰值 18 条 |
| PPE 表回收 | bind 4–18 行 / entries 25–136 行，动态回收无只增不减 |
| 内存 | used 247–250 MB，无泄漏趋势 |
| 温度 | 47–48°C |
| NPU 时钟 | 恒定 800MHz |
| jitter | 0.04–1.78ms（target 修复后采样稳定） |
| 内核日志 | 无新增 error/panic/OOM |

## 发现与处置

1. **npu-monitor 默认 target 1.1.1.1 不可达（已修，ae9a2fd）**
   包默认 UCI `target='1.1.1.1'` 在现网不可达；init 脚本的网关 fallback 仅在未配置 target 时生效。设备端临时改为 223.5.5.5 验证通过后，仓库 `patches/root/9017` 默认值改为 223.5.5.5。

2. **PPE debugfs `packets/bytes` 恒为 0**
   `/sys/kernel/debug/ppe/bind` 与 `entries` 中每条流统计字段始终为 0，无法据此量化单流硬件转发。后续应结合 conntrack `[HW_OFFLOAD]`/PPE BND 计数与 CPU/中断判断。

3. **部分单流仅 `[OFFLOAD]`/UNB，并发后达到 `[HW_OFFLOAD]`/BND**
   单流 `.102 -> 183.232.52.102` 未硬件绑定；强制 `.100` 或 3 路并发时，`.102` 多条流稳定达到 HW_OFFLOAD + BND。判定为流建立/哈希相关行为，非功能故障。

4. **诊断工具缺口**
   设备缺 `bridge`、`ethtool`、`devmem`、`nohup`；`getFrameEngine` 因缺 `devmem` 返回 error。建议后续镜像补入诊断工具或让 LuCI 优雅降级。

5. **2.4G phy0.0-ap0 周期性 re-forwarding**
   uptime 187/380/1741s 出现 `br-lan: port 4(phy0.0-ap0)` disable→blocking→forwarding，与 Wi-Fi 客户端漫游/省电更相关，继续观察。
