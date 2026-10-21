# 实机验收记录 — experimental ci-74（pre-release firmware-experimental）

- 日期：2026-08-31（UTC；设备本地 CST 2026-08-31 凌晨）
- 设备：Gemtek XR1710G（`gemtek,xr1710g-ubi`），HTTP U-Boot
- 固件：pre-release `ci-74` = `firmware-experimental.tar.gz`
  - `DISTRIB_DESCRIPTION='OpenWrt experimental SNAPSHOT r0-93cf01b'`（E2 ✅）
  - kernel `6.18.44`；manifest 214 个包；sysupgrade.itb sha256 `18e7a612bc84cac93ab00ac0af7a2e95612f2db7de5b59b49f69f66ab134a257`
- 访问：ssh root@192.168.123.1
- 结论：**非 6G/10G 客户端项全部通过；按用户口径，除 F66 良性假警告、D3 72h 未满、以及 6G/10G 客户端相关延后项外，实验档可毕业。** 毕业转正已在仓库执行（见 MANIFEST/ORDER）。

## 逐项结果

| 项 | 结果 | 证据/说明 |
|---|---|---|
| E2 版本元数据 | ✅ | `DISTRIB_DESCRIPTION='OpenWrt experimental SNAPSHOT r0-93cf01b'` |
| F64 布局 | ✅ | `/proc/mtd`：ubi=`1b700000`、reserved_bmt=`04200000`；`ubinfo -a` bad PEBs=0、max erase counter=2 |
| F65 sysupgrade -T | ✅ | 本机 `compat_version` 缺失时失败；已 `uci set system.@system[0].compat_version='2.0'` 后 `sysupgrade -T /tmp/ci74-sysupgrade.itb` rc=0。仓库默认配置已补 `compat_version '2.0'` |
| 包集合 | ✅ | manifest 214；设备 215 = manifest + phytool（B2.1 需要） |
| LED | ✅ | 内核 LED 前缀为 `mt7530_dsa-0`，含 10G PHY LED `:05`/`:08`。设备 UCI 补齐 6 个 LED 后 `led start` rc=0；6 个 PHY LED 全部 `offloaded=1`；无 EINVAL |
| F67 风扇 | ✅ | `/etc/init.d/fan start` rc=0；单 `S99fan`；`luci.fan getStatus` 可读 |
| F63 NPU regions | ✅ | `luci.airoha_npu getStatus` 返回 5 个 memory regions |
| B5 NPU offload（IPv4） | ✅ | 开启 fw4 hw flowtable 后 `offload_bound=12`、`offload_total=134`；conntrack `[HW_OFFLOAD]` 31+；`device-npu-probe.sh` rc=0，采样 `ppe_BND=12`、`conntrack_hw=44` |
| B5 IPv6 | ✅ | `device-npu-ipv6-probe.sh` rc=0（LAN6_PREFIX=2409:8a55:c963:5bf0，TCP_ROUNDS=1/TCP_BYTES=10M/TCP_RATE=20M/UDP_SECONDS=10）；采样 `ct6_hw` 最高 25、`bnd6` 最高 12；UDP DNS 39/39 |
| bridge-flow-offload E1/E2/E3 | ✅ | `apk info bridge-flow-offload` 存在；`nft list table bridge flow_offload` 有 `flowtable br_offload { flags offload }`；`nft list table bridge fw4` 不存在；logread 无 nft/flow_offload 报错 |
| C1 三频 AP | ✅ | 2.4G HE40 up、5G HE80 up、6G EHT320 up |
| issue #10 wifi down/up | ✅ | `device-wifi-downup-probe.sh` ROUNDS=5 rc=0；每轮 BSS `ENABLED`；round1/3/5 客户端总数回到基线 3，round2/4 为 2；logread 无 `Could not add STA`/`handle_assoc_cb` |
| F68 tx_failed | ✅ | 5G 站点 tx_retries=1842、tx_failed=0；2.4G 站点 tx_retries=34/60、tx_failed=0/1 |
| F75/A12 device-hw-probe | ✅ | 4 路 rc=0；B2.1 `0x103=0x8261`/`0x104=0x1141` → RTL8261BE；C4 10G LED count=2，phy5/phy8 leds-dir-count=1 |
| B1 WAN | ✅ | PPPoE up，IPv4 172.27.107.3；设备 ping 8.8.8.8 3/3 |
| B4 LAN / DHCP | ✅ | br-lan 192.168.123.1/24；dnsmasq 4 租约 |
| D1/D2 温控 | ✅ | nct7802 temp1≈51°C、fan_rpm≈1136、pwm1=69；mt7530 10G PHY 68/51°C；mt7996 三射频 56/50/57°C |
| F66 rdinit | ❌ 已知良性 | 仍见 `check access for rdinit=/init failed: -2, ignoring`（HTTP U-Boot 默认 env 覆盖 DTS chosen） |
| D3 72h | ⏳ 未满 | 本会话仅运行数小时；长稳计时可后续补 |
| C2 客户端/C3/F69/F71/B2 10G | ➖ 用户口径延后 | 暂无 6G 客户端 / 10G 对端；相关项保留实验档或注释化，发现后修复 |

## 毕业/转正执行

- 已转 default：`mt76-0005`、`mt76-9990/9991/9993` + `mac80211-411`、`vendor/05/06` + `root/9024/9026`、`vendor/07/09/17/18`。
- 保留 `#EXP`：`mt76-0010`（6G 客户端）、`root/9029`（10G 对端）、`vendor/02`（EIP93 未用）、`vendor/04`（DSA 上游）。
- 仓库默认配置补强：`files/etc/config/system` 增 `compat_version '2.0'`；新增 `files/etc/uci-defaults/99-xr1710g-flow-offload` 默认开启 `flow_offloading`/`flow_offloading_hw`。
