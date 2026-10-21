# 2026-08-31 stock ci-87（main@602d9d0，P1/P2 修复后）fresh flash 复验

> 审查对象：build run **#87**（push main `602d9d0`）stock 档 Artifact `firmware-stock`。
> 固件：`openwrt-stock-airoha-an7581-gemtek_xr1710g-ubi-squashfs-sysupgrade.itb`，sha256 `e9c2dc930d60eb414fbfdae492e5f9a02bd2e97595310d3abd5d686c807c200f`。
> 基线：openwrt master `93cf01b`，kernel 6.18.44，`DISTRIB_DESCRIPTION='OpenWrt stock SNAPSHOT r0-93cf01b'`。
> 实机：`root@192.168.123.1`，2026-08-31 以 `sysupgrade -n` 清空 overlay 全新刷入。

## 0. 结论

- **P1（LED 默认 sysfs）关闭**：fresh flash 后 `98-xr1710g-led-sysfs-prefix` 首启自动探测并将 system LED sysfs 改写为 `mt7530-0:*`；`led start` rc=0，6 个 PHY LED `trigger=netdev`、`offloaded=1`。
- **P2（stock 缺 bridge-flow-offload）关闭**：fresh flash 后 `bridge-flow-offload 1.0-r1` 已安装；`nft list table bridge flow_offload` 存在且 `flags offload`；`nft list table bridge fw4` 不存在；logread 无 nft/flow_offload 报错。
- 回归：compat_version 2.0、fw4 flow_offload uci-defaults、NPU offload、三频、风扇、device-hw-probe、wifi down/up 3 轮均通过。
- F66 仍为已知良性 `rdinit=/init failed: -2`（HTTP U-Boot env 覆盖 DTS chosen）。

## 1. 通过项

- [x] **P1 LED 首启探测**：/etc/config/system 自动为 `mt7530-0:*`；`led start` rc=0；6 LED `offloaded=1`
- [x] **P2 bridge-flow-offload**：`apk list --installed` 含 `bridge-flow-offload-1.0-r1`；`/usr/share/nftables.d/ruleset-post/30-bridge-offload.nft` 存在；`nft list table bridge flow_offload` 有 flowtable `br_offload` `flags offload`
- [x] **E2**：`DISTRIB_DESCRIPTION='OpenWrt stock SNAPSHOT r0-93cf01b'`
- [x] **compat_version 2.0**：/etc 与 /rom 均含 `option compat_version '2.0'`
- [x] **fw4 flow_offload 默认**：`flow_offloading='1'`、`flow_offloading_hw='1'`
- [x] **NPU offload**：`npu_loaded=true`、`offload_bound=18`、`offload_total=116`；conntrack `[HW_OFFLOAD]` 29 条
- [x] **三频**：2.4G ch6 20MHz 30dBm；5G ch149 HE80 30dBm；6G ch37 EHT320 29dBm
- [x] **F67 风扇**：`fan start` rc=0
- [x] **F75/A12 device-hw-probe**：route_a-d rc=0
- [x] **issue #10 wifi down/up**：3 轮 rc=0，BSS 均 ENABLED，无 `issue #10 signature`（round 1/3 after-up 2/3 客户端，round 2 3/3）
- [x] **包集合**：207 包（ci-83 206 + `bridge-flow-offload`）

## 2. 未闭环（延续既有口径）

- [ ] F66 rdinit 假警告（需 U-Boot 侧补 `rdinit=/sbin/init` 或换 9002 U-Boot）
- [ ] C2/C3/F69/F71/B2/D3 物理对端/客户端项
- [ ] #88 all（oc-1.3/oc-1.4）与 #89 experimental 构建完成后下载复验
