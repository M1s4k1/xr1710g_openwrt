# NPU CLIENTS offload 深度测试（2026-08-22，experimental 档实机）

## 测试目标

设备已刷 experimental 档。对 LuCI FlowSense/NPU 页 `CLIENTS N offloaded` 判读做多路齐发、多角度严格测试：
确认 `CLIENTS 0 offloaded` 是否真实、问题根因、可改善点与演进路径。

## 设备与前提

- 固件：OpenWrt SNAPSHOT r0-725cbf1 / kernel 6.18.44 / experimental（自建）
- 设备：Gemtek XR1710G，4 个 Wi-Fi 客户端关联（2.4G ×3、5G ×1、6G ×0）
- 数据源：
  - RPC：`ubus call luci.airoha_flowsense getPpeEntries`
  - 内核：`/sys/kernel/debug/ppe/bind`、`/sys/kernel/debug/ppe/entries`
  - conntrack：`/proc/net/nf_conntrack`（`[HW_OFFLOAD]` / `[OFFLOAD]`）
- 复现脚本：`scripts/device-npu-probe.sh`

## 多路测试结果

### 路 A：RPC 数据源一致性

| 项目 | 结果 |
|---|---|
| `luci.airoha_npu getStatus` | `offload_bound=6 offload_total=59~93`；`memory_regions` 4 条（漏 `npu-ba`，issue #3/#8） |
| `luci.airoha_flowsense getStatus` | 同上，`cpu_hw_freq` 随采样变化（800/850/900MHz） |
| `luci.airoha_npu getPpeEntries` | 仅返回裸 `entries` 数组，无 BND/UNB 分组与 totals |
| `luci.airoha_flowsense getPpeEntries` | 结构化 BND/UNB/`band_bnd`/`port_bnd`/`client_bnd` |
| `getTokenInfo`（两个对象） | `luci.airoha_npu` 返回 `npu_active:false`（token_info debugfs 缺失时 fallback 恒 false）；`luci.airoha_flowsense` 无 `npu_active` 字段 |
| `getFrameEngine`（两个对象） | `{"error":"devmem not available"}`（issue #2） |

结论：两个 RPC 对象功能重叠但字段/行为已出现漂移；`luci.airoha_npu.getPpeEntries` 不是 CLIENTS 段的数据源，
CLIENTS 段只看 `luci.airoha_flowsense.getPpeEntries`。

### 路 B：内核 truth

| 项目 | 结果 |
|---|---|
| NPU DT reserved-memory | 5 个节点：npu-binary/npu-pkt/npu-txpkt/npu-txbufid/npu-ba；reg 需 hexdump 解析 |
| NPU clock | 800 MHz（`/sys/kernel/debug/clk/npu/clk_rate`） |
| PPE bind | 6~9 条 BND，`packets=0 bytes=0` 恒成立（issue #5） |
| PPE entries | 59~180 条 UNB，BND 也出现在 entries 中 |
| conntrack | `[HW_OFFLOAD]` 10 条、`[OFFLOAD]` 5 条 |
| flowtable | `flags offload`，devices 含 `lan1/lan2/lan3/phy0.*/pppoe-wan/wan` |
| 工具缺口 | `bridge`/`ethtool`/`devmem`/`opkg`/`od` 缺失，`hexdump` 可用（issue #2） |

### 路 C：CLIENTS offload 计数交叉验证（核心发现）

| 客户端 | IP | 频段 | PPE BND 含 IP | PPE BND eth 含 station MAC | conntrack HW_OFFLOAD | 修复前 client_bnd | 修复后 client_bnd |
|---|---|---|---|---|---|---|---|
| zTC1_0aea | .180 | 2.4G | 否 | 否 | 0 | 0 | 0 |
| LOK-360 | .162 | 2.4G | 否（BND 无行） | 否 | 2 | 0 | 2 |
| iQOO-Neo9-Pro | .240 | 2.4G | 否 | 否 | 0 | 0 | 0 |
| iPhone | .170 | 5G | 是（`orig=192.168.123.170:…`） | **否**（`eth=00:58:28:d7:44:5e->dc:ef:80:59:a7:0d`） | 5 | 0 | 8 |

`band_bnd` 修复前 `[0,0,0]`；修复后 `[0,8,0]`。

### 路 D：45 秒稳定性采样

PPE BND 在 4~9 之间波动、entries 在 59~180 之间波动，conntrack `[HW_OFFLOAD]` 稳定；
无 dmesg/logread 新增 error/oops/panic。波动来自 PPE 表项老化与流量建立节奏，CLIENTS 计数必须
容忍这种抖动——`bnd>0` 即 offloaded，不应要求长时间稳定。

## 根因

`getPpeEntries` 的 `client_bnd`/`band_bnd` 只匹配 `eth=` 中的 station MAC。
PPE BND 行的 `eth=` 字段语义是**桥/下一跳 MAC**，不是 station MAC；
对路由型 `client -> WAN` 的 NAT 流，`eth` 不含 Wi-Fi station MAC，导致 MAC-only 匹配恒为 0，
LuCI 长期显示 `CLIENTS 0 offloaded`，即使同一客户端已有 PPE BND 行和 conntrack `[HW_OFFLOAD]`。

## 修复

- `patches/root/9019-npu-client-offload-accounting.patch`：
  - `band_bnd` / `client_bnd` 增补 BND `orig/new` 中的 station IPv4 匹配。
  - `client_bnd` 增补 conntrack `[HW_OFFLOAD]`/`[OFFLOAD]` 兜底，并新增 `hw_offload`/`sw_offload` 字段。
  - `bnd` 取 eth-MAC / BND-IP / conntrack-HW 三路信号最大值，消除假阴性。
- 实机验证：修复后 `CLIENTS` 从 0 offloaded 变为 2 offloaded（.162、.170）。

## 演进路径

1. UI 增加 per-client `hw_offload`/`sw_offload` 展示与 tooltip，避免单看 BND 数。
2. `band_bnd` 与 `port_bnd` 应同样采用 IP 级匹配 + conntrack 兜底（port_bnd 因 `bridge` 缺失恒 0）。
3. `luci.airoha_npu` 与 `luci.airoha_flowsense` 的 getStatus/getPpeEntries 建议合并为单一 RPC 后端，
   或由 flowsense 复用 npu 的稳定字段，消除漂移。
4. `memory_regions` 改为解析 `/proc/device-tree/reserved-memory/npu-*` 的 reg（hexdump 可用），
   稳定返回 5 条；`getTokenInfo` 的 `npu_active` 应由 NPU 驱动目录或 conntrack HW_OFFLOAD 推导，
   而不是依赖缺失的 token_info debugfs。
5. 增加 `bridge`/`devmem`/`ethtool`/`od` 诊断包，补全 getFrameEngine 与 port_bnd 数据源。

## 关联 issue

- #18 CLIENTS 0 offloaded 假阴性（本次修复）
- #2 诊断 RPC 工具缺口；#3/#8 memory_regions；#4 token_info；#5 packets/bytes 恒 0；#9 ip -s 统计
