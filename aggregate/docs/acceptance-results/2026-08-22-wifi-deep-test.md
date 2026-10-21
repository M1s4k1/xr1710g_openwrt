# 实机深度测试记录 — Wi-Fi 多角度严格测试

- 日期：2026-08-22（设备本地 CST，UTC 2026-08-21 夜间）
- 设备：Gemtek XR1710G（`gemtek,xr1710g-ubi`），已固化 HTTP U-Boot
- 固件：OpenWrt SNAPSHOT r0-725cbf1（kernel 6.18.44，base openwrt commit 725cbf1），experimental 档
- 访问：ssh root@192.168.123.1（公钥；已重启恢复基线）
- 测试思路：按「配置一致性 / RF-PHY / 协议功能 / 稳定性与故障恢复 / 安全 / 性能与容量 / 诊断可维护性」七路并发，逐路多角度验证。
- 结论：**三频 EHT320/HE160/HE40 能力在基线上成立，但发现 1 个严重故障（wifi down/up 后 AP 拒绝 STA）、1 个配置意图与实际不一致（2.4G HE40→20MHz）与若干可改善项；均记录在 FIXES F31-F33。**

## 一、基线与关键状态

| 项 | 实测 |
|---|---|
| 固件 | `OpenWrt SNAPSHOT r0-725cbf1` / kernel `6.18.44` |
| regdb | `country US: DFS-FCC`；5G UNII-3/4 5730-5895@160 30dBm；6G 5925-7125@320 29dBm NO-OUTDOOR |
| 2.4G | phy0.0-ap0，ch6 或 ch1（ACS），配置 HE40，实际 20MHz（见 F32），txpower 30dBm |
| 5G | phy0.1-ap0，ch149/HE160，center1 5815，txpower 30dBm |
| 6G | phy0.2-ap0，ch37/EHT320，center1 6105，txpower 29dBm |
| 加密 | 2.4G/5G `SAE + WPA-PSK + WPA-PSK-SHA256`（WPA2/WPA3 混合，PMF 可选）；6G `SAE`（PMF required，beacon_prot=1） |
| MLO | luci-app-mlo 已安装（apk list -I 含 `luci-app-mlo`），但 `/etc/config/mlo` 不存在，未配置/未实测 |
| 客户端 | 2.4G：多个 IoT/手机（802.11n，HE 关）；5G：1 台 HE 80MHz 2SS 手机（实测 1200.9Mbps 速率）；6G：无客户端 |

## 二、测试矩阵与结果

### 1. 配置一致性
- [x] `uci show wireless` 与 `ubus call network.wireless status` 一致；三 radio 均 `up=true, pending=false, retry_setup_failed=false`。
- [x] 单 wiphy 三 radio 模型正确：radio0/1/2 均 `phy0` + `radio 0/1/2`；F28 修复有效。
- [x] 生成 hostapd 配置与 UCI 意图一致：2.4G `ieee80211ax=1` / 5G `he_oper_chwidth=2` / 6G `ieee80211be=1` + `eht_oper_chwidth=7`。
- [x] txpower 三频分别为 30/30/29 dBm，与 mt76-0008 + regdb 0521 预期一致。
- [x] `iw dev` 与 `iwinfo` 在 5G/6G 带宽上一致；**2.4G 两者不一致**（`iwinfo` 报 HE40，`iw dev` 报 20MHz）——记录为 F32。

### 2. RF-PHY 层
- [x] `iw phy`：2.4G HE40 能力、5G HE160 能力、6G EHT320 能力均在；AP 侧 6G EHT320 MCS map `0x444444` 正常。
- [x] 天线：TX/RX `0xfff`，配置与可用一致。
- [x] 频段/信道/带宽实测：
  - 2.4G `channel 6 (2437), width 20`（ACS 回退，见 F32）
  - 5G `channel 149 (5745), width 160, center1 5815`（正确）
  - 6G `channel 37 (6135), width 320, center1 6105`（正确）
- [x] `iw survey dump`：三频 channel active/busy/transmit 计数均有，2.4G 干扰最高（busy 约 61%），5G/6G 干净。
- [x] `iw dev <if> set txpower fixed 20/23/22 dBm` 三频均立即生效，可恢复 30/30/29；per-radio txpower（9010）链路正常。

### 3. 协议功能层
- [x] 2.4G/5G WPA2/WPA3 混合 SAE：实机有 `auth_alg=sae` 与 `auth_alg=open` 客户端同时成功关联。
- [x] 6G SAE + PMF required：hostapd 配置 `wpa_key_mgmt=SAE`、`ieee80211w=2`、`beacon_prot=1` 正确。
- [x] 5G HE160 与 6G EHT320 AP-ENABLED；6G `op_class=137`、`he_oper_chwidth=3`、`eht_oper_chwidth=7` 正确。
- [ ] 6G EHT320 客户端实测：**无 EHT 客户端**，无法验证 C3 6G 2400Mbps 与 EHT 广告（9990/9991/9993 待客户端毕业验证）。
- [ ] MLO 生效实测：**无 MLO 客户端且未创建 MLO 配置**，C4 继续待补测。
- [x] hostapd ubus `get_status`/`get_clients`/`get_features`/`switch_chan`/`bss_mgmt_enable` 等接口存在且 `get_status`/`get_clients` 返回正常。
- [ ] hostapd ubus `get_features` 对 5G/6G 返回 `vht_supported: false`（疑似 hostapd ubus 上报字段 bug，待观察，不影响功能）。

### 4. 稳定性与故障恢复
- [x] `wifi reload` 连续 3 轮：三频均 `up`，无 `retry_setup_failed`；客户端可重连。
- [x] `wifi down` 后接口全部移除，`wifi up` 后三频 AP-ENABLED。
- [x] 冷重启：`reboot` 后 67s 内 ping 通、SSH 恢复；dmesg 无 panic/Oops；mt76 固件加载与 eeprom 功率解锁日志正常。
- [ ] **`wifi down` → `wifi up` 后客户端重连：失败**。AP-ENABLED 但 hostapd 持续报 `Could not set STA to kernel driver` / `Could not add STA to kernel driver` / `handle_assoc_cb: STA ... not found`，2.4G 与 5G 客户端均无法关联；`wifi reload` 不能恢复，**只有重启恢复**。记录为 F31。
- [x] 重启后客户端恢复：2.4G d0:ba/b0:73 与 5G 1e:f3 均重新关联，5G 速率 1200.9Mbps。
- [x] 启动期日志存在 9 次 `Failed to request a scan of neighboring BSSes ret=-16 (Resource busy)`（daemon.err），最终 AP-ENABLED，判定为单 wiphy 多 radio 并发扫描的良性但应治理项——记录为 F33。

### 5. 安全
- [x] 2.4G/5G：`sae_require_mfp=1`、`ieee80211w=1`、`beacon_prot=1`。
- [x] 6G：`sae_require_mfp=1`、`ieee80211w=2`、`beacon_prot=1`。
- [x] `okc=1`（快速漫游缓存）三频均开启。
- [x] 未发现 open/WEP 残留；hostapd 配置无 `wps`。
- [ ] 口令强度：设备实际 2.4G/5G 口令与仓库占位不同，且为纯数字（用户自管，建议改强）。仓库文件仍为 `123456789` 占位。

### 6. 性能与容量
- [x] 5G 手机客户端实测 PHY rate：RX 1200.9Mbps / TX 1200.9Mbps（HE-MCS11, 80MHz, 2SS），expected throughput 1002.2Mbps；信号 -50dBm/SNR 42。
- [x] 设备到客户端 ICMP：2.4G zTC1 0% loss（avg 25ms），LOK-360 0% loss（avg 62ms），5G iPhone 0% loss（avg 203ms，max 1003ms，抖动偏大，与手机省电相关）。
- [x] 2.4G 客户端 PHY rate 在 39-144Mbps，符合 IoT 设备能力。
- [ ] 有线↔无线吞吐、6G 吞吐、MLO 吞吐：需客户端配合，待补测。
- [x] 三频空口利用：2.4G airtime utilization 168（繁忙），5G 3，6G 0（无客户端）。

### 7. 诊断可维护性
- [x] `iw`/`iwinfo`/`ubus hostapd.*`/`/sys/kernel/debug/ieee80211/phy0` 可用。
- [x] apk 可用（apk-tools 3.0.5），包列表可查。
- [ ] 缺 `hostapd_cli`、`wpa_cli`、`tcpdump`、`iperf3`、`ethtool`、`bridge`、`devmem`（F30④ 已记，wifi 测试同样受影响）。
- [ ] hostapd `get_features` 的 `vht_supported` 字段疑似错误（见上），建议后续提报或镜像内用 `iw phy` 能力替代。

## 三、关键问题与方案

| # | 级别 | 问题 | 方案 |
|---|---|---|---|
| F31 | 严重 | `wifi down`/`wifi up` 后 AP 拒绝所有 STA 关联，`wifi reload` 无效，仅重启恢复 | 短期：文档标注 `wifi down/up` 为危险操作，优先用 `wifi reload`；中期：定位 mac80211/mt76/hostapd 在 full down/up 后的 STA 表同步，修本层或提报；自动化测试纳入 down/up 场景 |
| F32 | 中 | 2.4G HE40 意图与 20MHz 实际不符，`iwinfo` 误报 HE40 | 二选一：① 接受 ACS 回退，radio0 明确为 `HE20`/auto 并记录；② 固定 `channel '6'` + `option noscan '1'` 强制 HE40。判读以 `iw dev` 为准 |
| F33 | 低 | 启动期 9 次 neighbor scan 失败（ret=-16）error 日志，拖慢启动 | 已对固定信道的 radio1/radio2 增加 `option noscan '1'`（固定信道且非 DFS，无需扫描），并在本机 `wifi reload` 验证：hostapd conf 已带 `noscan=1`，无新 ret=-16，5G 客户端正常重连 |
| 待补测 | - | 6G/EHT320 客户端、MLO 配置与生效 | 需 6GHz EHT 客户端与 MLO 客户端；luci-app-mlo 已就位，创建配置后实测 |

## 四、恢复验证

- 发现 F31 后于 2026-08-22 08:28 重启设备；重启后 dmesg 无 mt76 error/panic，`logread` 无 `Could not set STA` 残留。
- 重启后三频恢复：2.4G ch6/20MHz、5G ch149/HE160、6G ch37/EHT320；客户端自动重连，5G 速率 1200.9Mbps。
- 当前设备处于 experimental 档正常服务状态。
