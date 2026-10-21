# NPU 多路深度/广度探索记录 — 2026-08-22（experimental 档实机）

- 设备：Gemtek XR1710G（`gemtek,xr1710g-ubi`），OpenWrt SNAPSHOT r0-725cbf1，kernel 6.18.44
- 固件：experimental 档（含 #EXP 02/04-09/17/18 + mt76 9990/9991/9993/0005 + mac80211 411）
- 访问：ssh root@192.168.123.1；LAN 打流主机 192.168.123.102/201/202
- 方法：八路并行探查：
  1. NPU 硬件/设备树/时钟/中断/固件
  2. 数据面 offload 规则与 conntrack/PPE 状态
  3. mt76 Wi-Fi NPU/WED/RRO debugfs
  4. LuCI/ubus RPC 全部 NPU 接口
  5. 转发打流（3 路并发 HTTP，经设备 PPPoE WAN）
  6. L2 bridge offload 规则实际注入测试
  7. EIP93 硬件 crypto 注册与使用情况
  8. 包供给与诊断工具缺口核对

## 结论速览

| # | 发现 | 严重度 | 处置建议 |
|---|---|---|---|
| E1 | 实验档 `bridge-flow-offload` 包未安装，但 target basefiles 的 hotplug 已装入；`apply-rules.sh` 缺失 | 高 | 修正 05 号补丁依赖/包供给；核对 kmod-nft-bridge 是否被 br_netfilter 依赖卡掉 |
| E2 | bridge 家族 `flow offload @ft` 规则注入内核返回 `Protocol error`（inet 家族正常）——即使 E1 修复，规则仍无法应用 | 高 | 修复 675-02/nft_flow_offload 的 bridge family init/validate 路径 |
| E3 | `bridge-flow-offload` 生成的规则会 `destroy table bridge fw4`，若与用户自有 bridge fw4 表冲突有破坏风险 | 中 | 改用独立表名/只在包自己的 include 内管理 |
| E4 | `luci.airoha_npu`/`luci.airoha_flowsense` 的 `getFrameEngine` 因缺 `devmem` 返回 error；`pll_freq_mhz` 恒 0 | 中 | 镜像补入 `devmem`（或 io 工具）或 RPC 优雅降级 |
| E5 | `getStatus` 的 `memory_regions` 只取 dmesg 前 4 条，漏报第 5 个 `npu-ba`（2048 KiB） | 低 | `head -4` 改 `head -5` 或按 of_node 解析 |
| E6 | mt76 pin 59676919 实机无 `token_info` debugfs；`getTokenInfo` 恒返回 token_count=0/空队列；**经 API 核对源码，F22「fanboy14 0001/0003 已上游」结论不成立**（debugfs.c 无 token_info；mac.c 仍含 mt7996_mac_sta_poll） | 高 | 按 pin 59676919 重建并重新启用 fanboy14 0001/0003，或补自持等价补丁 |
| E7 | PPE debugfs `bind`/`entries` 的 `packets=`/`bytes=` 恒 0 | 低 | 上游/自持补丁增加 PPE 单流统计；当前用 conntrack 综合判断 |
| E8 | EIP93 硬件 crypto 已注册（priority 1500）但 `crypto_hw_eip93` refcnt=0，无 IPsec/xfrm 配置使用 | 低 | 评估 strongSwan/xfrm + EIP93 的 IPsec 硬件卸载，作为 NPU 未开发用途 |
| E9 | 设备缺 `ethtool`/`bridge`/`tcpdump`/`iperf3`，深度诊断受限 | 低 | 下轮镜像补入诊断工具包 |

## 关键证据

### E1/E2/E3 bridge offload
- `apk list --installed` 无 `bridge-flow-offload`；`/usr/share/bridge-flow-offload/` 不存在；但 `/etc/hotplug.d/iface/51-bridge-flow-offload` 存在并引用缺失脚本。
- 手工注入规则（与 05 号 apply-rules.sh 相同的 bridge 表）：
  ```
  nft add table bridge npu_probe
  nft add flowtable bridge npu_probe ft { hook ingress priority 0; devices = { lan3, phy0.0-ap0 }; flags offload; }
  nft add chain bridge npu_probe forward { type filter hook forward priority 0; policy accept; }
  nft add rule bridge npu_probe forward meta l4proto { tcp, udp } flow offload @ft
  # -> Error: Could not process rule: Protocol error
  ```
- 对照组 inet 家族同样操作成功（`nft add rule inet ... flow offload @ft` rc=0）。
- `nft add flowtable bridge ...` 成功，说明 675-02 的 flowtable 类型已注册；失败点在 `flow` 表达式 init/validate/ct 绑定路径。

### E4 devmem 缺口
- `command -v devmem` 无；`busybox devmem` 报 `applet not found`；`getFrameEngine` 返回 `{"error":"devmem not available"}`。
- `getStatus` 的 PLL 频率解析依赖 devmem，故 `pll_freq_mhz` 恒为 0。

### E5 memory_regions 漏项
- dmesg 共 5 条 `reserved mem.*npu`：`npu-binary`/`npu-pkt`/`npu-txpkt`/`npu-txbufid`/`npu-ba`。
- RPC `getStatus` 输出只有前 4 条，缺 `npu-ba`（0x90c06800..0x90e067ff, 2048 KiB）。

### E6 token_info 缺失
- `find /sys -name '*token*'` 无结果；`/sys/kernel/debug/ieee80211/phy0/mt76/` 下无 `token_info`。
- `strings /lib/modules/6.18.44/mt7996e.ko | grep token` 仅 `mt7996_tx_token_put`，无 `token_info` 字符串。
- `ubus call luci.airoha_npu getTokenInfo` 返回 token_count=0、tx_queues=[]；`luci.airoha_flowsense getTokenInfo` 走 PLE/HIF 路径（hw-queues），不受影响。

### E7 PPE debugfs 统计为 0
- `/sys/kernel/debug/ppe/bind` 每条记录 `packets=0 bytes=0`；`entries` 同样。

### E8 EIP93 未使用
- `lsmod`：`crypto_hw_eip93 45056 0`；`/proc/crypto` 注册 `cbc(aes)`/`ctr(aes)`/`hmac(sha256)`/`authenc(hmac(sha256),cbc(aes))` 等，driver 带 `-eip93` 且 priority=1500。
- 设备无 `openssl`；无 `ip xfrm` 配置；IPsec 能力未被使用。

## 转发打流补充

- 清理了上一会话遗留的 4 个 `yes` CPU 压力进程（PID 12482-12489）。
- 3 路并发 HTTP（20MB each，经设备 PPPoE 到 speed.cloudflare.com）：2.27/2.57/2.54s，合计约 60MB，瞬时吞吐约 70Mbps。
- 该 3 条流在 conntrack 中仅 `[OFFLOAD]` 未达 `[HW_OFFLOAD]`；PPE bind 未出现对应记录。与 F30 观察一致：硬件绑定与流建立时机/目标 IP 相关；建议后续用更长流并采样。

## 已提交 GitHub Issues

- #1 实验档 L2 bridge offload（#22533）实机不可用：包未安装且 bridge 族 flow offload 规则注入报 Protocol error
- #2 NPU 诊断 RPC 缺口：缺 devmem/ethtool/bridge，getFrameEngine 报错、pll_freq_mhz 恒 0
- #3 getStatus 的 memory_regions 漏报第 5 个 NPU 保留区 npu-ba
- #4 F22 结论需复查：pin 59676919 实机无 token_info，且 mac.c 仍含 mt7996_mac_sta_poll（fanboy14 0001/0003 并非冗余）
- #5 PPE debugfs bind/entries 的 packets/bytes 恒为 0，建议增加单流硬件转发统计
- #6 EIP93 硬件 crypto 已编译但完全未使用：建议评估 IPsec/xfrm 硬件卸载作为 NPU 未开发用途
