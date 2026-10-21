# IPv6 NPU offload 深度广度严格测试 — 2026-08-22（experimental 档实机）

## 测试目标

设备已刷 experimental 档。对 IPv6 数据面的 NPU offload 做多路齐发、多角度严格测试：
确认 IPv6 TCP/UDP/ICMP 的硬件卸载行为、PPE/conntrack/RPC 三个数据源在 IPv6 下的一致性、
可改善点与可进化路径。

## 设备与前提

- 固件：OpenWrt SNAPSHOT r0-725cbf1 / kernel 6.18.44 / experimental（自建）
- 设备：Gemtek XR1710G，`gemtek,xr1710g-ubi`
- 访问：`ssh root@192.168.123.1`；LAN 打流主机 192.168.123.102（容器）
- 主机 IPv6：`2409:8a55:c966:6fd0::/64`（设备 br-lan 下发）；测试期间临时添加
  `::10`–`::17` 作为多源地址（脚本自动清理）
- 复现脚本：`scripts/device-npu-ipv6-probe.sh`（本次新增）

## 多路测试方法

| 路 | 角度 | 方法 |
|---|---|---|
| A | 配置与数据源一致性 | IPv6 地址/路由/flowtable 配置；RPC `getFlowOffload/getPppoeOffload/getVlanOffload/getPpeEntries`；PPE bind/entries；conntrack v6 基线 |
| B | IPv6 TCP 多源并发打流 | 5 个源地址 × 2 个目的端口（80/443）× 2 轮，每流 20MB@1MB/s（10 并发）；远端 3s 间隔采样 conntrack/PPE |
| C | IPv6 UDP 长流 | 2 个源地址绑定独立 UDP socket，向 AliDNS v6（2400:3200::1）以 4 qps 发送 DNS 查询 40s；远端采样 |
| D | ICMPv6 对照 + 稳定性 | ping6 外部 v6；dmesg/logread 错误扫描；NPU 时钟/内存 |

## 结果

### 路 A：配置与数据源

| 项目 | 结果 |
|---|---|
| IPv6 WAN | `pppoe-wan` 获得 `2409:8a55:c906:9e6:.../64`；默认路由经 `fe80::deef:80ff:fe59:a70d` |
| IPv6 LAN | `br-lan` `2409:8a55:c966:6fd0::1/60`，主机在 `2409:8a55:c966:6fd0::/64` on-link |
| flowtable | `nft list flowtable inet fw4 ft`：`flags offload`，devices 含 `pppoe-wan`/`lan1`/`lan2`/`lan3`/`phy0.*`/`wan` |
| 防火墙 | `flow_offloading=1`、`flow_offloading_hw=1` |
| RPC | `getPpeEntries` 返回 `bnd.total/ipv4/ipv6`；`band_bnd`/`port_bnd`/`client_bnd` 均只反映 IPv4/MAC 匹配 |
| PPE debugfs | BND 行中 `IPv6 5T` 仅含 `orig=`（无 `new=`，与 IPv4 NAT 不同），`eth=` 是桥/PPPoE/下一跳语义而非 station MAC |
| conntrack | IPv6 流可带 `[HW_OFFLOAD]`/`[OFFLOAD]`；地址为**展开式**（如 `2409:...:0011`） |

### 路 B：IPv6 TCP 多源并发打流

- 10 条并发流（源 `::11`–`::15` × 80/443，20MB each @1MB/s，2 轮）。
- 第 1 轮启动后约 2s，conntrack v6 `[HW_OFFLOAD]` 从 0 升到 11，PPE `BND IPv6` 从 0 升到 20（峰值），
  PPE entries 随之上升；第 2 轮重新拉起后再次出现 `bnd6=20`。
- 流量结束后 PPE BND v6 快速回 0，conntrack 流转为 `[OFFLOAD]`（软件流表）后老化——符合流表动态回收预期。
- 抽样：`t=... ct6=83 hw=11 bnd=26 bnd6=20 ent=77`；`t=... ct6=144 hw=10 off=35 bnd=21 bnd6=14 ent=110`。
- 全程无 dmesg/logread 新增 error/panic；NPU 时钟恒定 800MHz；内存无单调增长。

结论：**IPv6 TCP 硬件卸载可用**，多源并发时 BND/HW_OFFLOAD 快速建立。

### 路 C：IPv6 UDP 长流

- `::16`/`::17` 各一条长 UDP DNS 流（40s，115–153 queries，100% 响应）。
- 传输中 conntrack 出现 `[HW_OFFLOAD]`（`hw16=1 hw17=1`），确认 **IPv6 UDP 可硬件卸载**。
- 但 PPE `bind` 中未出现对应 BND 行；PPE `entries` 中为 **UNB IPv6**（每条流正反两行），
  `packets=0 bytes=0` 依旧失效（issue #5）。
- 流结束后 conntrack 恢复普通 UDP 条目，无 `[HW_OFFLOAD]`/`[OFFLOAD]`。

结论：IPv6 UDP 会进入硬件卸载（conntrack 标志），但 PPE debugfs 呈现为 UNB 而非 BND；
以 `bind` 表 BND 行数判断 UDP 卸载会假阴性。

### 路 D：ICMPv6 对照 + 稳定性

- `ping6 -c 5 2400:3200::1` 成功（RTT ~13ms），conntrack 出现 `ipv6 ... icmpv6` 条目，
  无 `[HW_OFFLOAD]`/`[OFFLOAD]`——fw4 flowtable 只对 tcp/udp `flow add`，符合预期。
- dmesg/logread 错误计数在测试前后不变（dmesg 4、logread 4），无 oops/panic/timeout。
- NPU 时钟恒定 800MHz；内存 182–187MB / 1868344KB，无泄漏趋势。

## 发现汇总

| # | 发现 | 严重度 | 处置建议 |
|---|---|---|---|
| V6-1 | IPv6 TCP offload 实机可用：多源并发 2s 内达 `[HW_OFFLOAD]`+PPE BND，10 流并发稳定 | 信息 | 纳入验收基线 |
| V6-2 | IPv6 UDP offload 实机可用但不可见为 BND：conntrack `[HW_OFFLOAD]` 有，PPE `bind` 无 BND，`entries` 仅 UNB | 中 | PPE/诊断口径需区分 TCP BND 与 UDP UNB；LuCI 不应仅按 BND 数判读 UDP 卸载（issue #20） |
| V6-3 | RPC `getPpeEntries` 的 `band_bnd`/`client_bnd` 无法计 IPv6 客户端：`client_bnd` 仅从 `/tmp/dhcp.leases` + IPv4 `ip neigh` 建 IP 映射；`@NEIGH` 显式跳过 IPv6（`index(ipx,":")==0`）；`band_bnd` 的 IP 匹配虽经 `ip neigh show` 混入压缩式 IPv6，但 PPE BND `orig=` 为展开式 IPv6（如 `2409:8a55:c966:6fd0:0000:0000:0000:0011:42796`），压缩式 `2409:...:6fd0::11` 无法匹配 | 中 | 扩展 `9019-npu-client-offload-accounting.patch`：见下方进化路径 P1（issue #19） |
| V6-4 | `bnd.ipv6` 已能统计 IPv6 BND 总数（本次实测 16–20），但 `band_bnd`/`client_bnd` 的 IPv6 缺口会导致 LuCI `CLIENTS N offloaded` 在纯 IPv6 客户端场景再次假阴性 | 中 | 同 V6-3；应在 F39 修复基础上补 IPv6 归一化匹配 |
| V6-5 | `ip neigh show` 与 `ip -6 neigh show` 输出 IPv6 压缩式，PPE/conntrack 输出展开式；任何 IPv6 匹配必须做地址规范化 | 中 | 见 P1 的 awk `canon6()` 方案 |
| V6-6 | 短 TCP 流也能卸载：`ipv6.baidu.com`/`www.qq.com`/`www.163.com` 的 200–500B HTTPS 流在 conntrack 中均出现 `[HW_OFFLOAD]` | 信息 | 卸载判定不依赖流长；短流用 conntrack 标志更可靠 |
| V6-7 | PPE debugfs `packets/bytes` 恒 0 在 IPv6 下同样存在 | 低 | 已有 issue #5 |

## 进化路径（Proposals）

### P1（建议实现）：9019 补丁增加 IPv6 客户端卸载统计

当前 `patches/root/9019-npu-client-offload-accounting.patch` 的 F39 修复只覆盖 IPv4。建议扩展：

1. `neigh` 采集增加 `ip -6 neigh show`（或继续用 `ip neigh show` 但去掉 `index(ipx,":")==0` 过滤），
   把 MAC→IPv6 映射写入 `mac2ip6`。
2. 在 awk 内实现 `canon6(ip)`：把 `::` 压缩展开成 8 组 `xxxx`（补齐前导零），
   对 `ip neigh` 的压缩式与 PPE/conntrack 的展开式都规范化后再比较。
3. `band_bnd` 的 `has_ip` 与 `client_bnd` 的 BND/conntrack 匹配同时使用 `mac2ip`（IPv4）和 `mac2ip6`（IPv6）；
   `client_bnd` 输出增加 `"ip6":"..."` 字段，`bnd` 取 eth-MAC / BND-IP(v4/v6) / conntrack-HW 三路最大。
4. `band_unb` 的 UNB 源地址解析对 IPv6 也做 `src=地址部分`（去端口）并规范化，而不仅 `split(orig,p,":")` 取第一段。
5. 实机验证：让 IPv6 Wi-Fi 客户端（如 iPhone `.170` 的 `2409:8a55:c966:6fd0::a05`）产生 IPv6 流，
   确认 `client_bnd` 中该站 `bnd>0` 且 `ip6` 非空。

### P2（建议跟进）：PPE/UDP 卸载可视化

UDP 卸载在 `bind` 中无 BND 行（仅 `entries` UNB）。LuCI 与诊断脚本应：
- 把 conntrack `[HW_OFFLOAD]` 作为 UDP 卸载主判据；
- `getPpeEntries` 的 `unb` 段增加 `ipv6`/per-flow 计数（当前已有 `band_unb`，但同样存在 IPv4-only 问题）；
- 或者为 UDP 卸载在 PPE debugfs 增加类似 BND 的绑定态展示（上游/自持补丁）。

### P3（建议跟进）：PPE 单流统计

PPE debugfs `packets/bytes` 恒 0（issue #5）导致无法按流量化硬件转发占比。
建议推动上游增加 PPE 单流统计，或先用 conntrack 流表字节/包数作为近似。

### P4（工程化）：把 IPv6 NPU offload 纳入验收

- `docs/ACCEPTANCE.md` 的 NPU 项增加 IPv6 子项：TCP 多源并发 10 流 20MB 必须出现 `[HW_OFFLOAD]`+PPE BND v6；
  UDP 长流 40s 必须出现 `[HW_OFFLOAD]`；ICMPv6 不卸载。
- 本次新增 `scripts/device-npu-ipv6-probe.sh` 作为复现实测脚本。

## 复现

```bash
# 默认配置（10 流 TCP 20MB × 2 轮 + 2 路 UDP 40s + ICMP + 采样）
./scripts/device-npu-ipv6-probe.sh

# 快速冒烟
TCP_ROUNDS=1 TCP_BYTES=5000000 UDP_SECONDS=10 SAMPLES=5 INTERVAL=2 \
  OUT_PREFIX=/tmp/ipv6-probe-smoke ./scripts/device-npu-ipv6-probe.sh

# 若 host 不是 2409:8a55:c966:6fd0::/64 子网，显式指定前缀
LAN6_PREFIX=2409:8a55:c966:6fd0 ./scripts/device-npu-ipv6-probe.sh
```

## 关联 issue

- #19 IPv6 client_bnd/band_bnd 假阴性（本次提交）
- #20 IPv6 UDP HW_OFFLOAD 在 PPE bind 无 BND、entries 仅 UNB（本次提交）
- #18 CLIENTS 0 offloaded 假阴性（F39 IPv4 修复；本次提出 IPv6 扩展）
- #5 PPE debugfs packets/bytes 恒 0（本次 IPv6 下再次确认）
