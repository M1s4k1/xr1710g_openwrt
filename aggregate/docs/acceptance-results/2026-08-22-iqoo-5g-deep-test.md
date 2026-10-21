# 实机深度测试记录 — iQOO Neo9 Pro 无法连接 5G WiFi（多路并发/多角度）

- 日期：2026-08-22（设备本地 CST，UTC 2026-08-21 夜间）
- 设备：Gemtek XR1710G（`gemtek,xr1710g-ubi`），已固化 HTTP U-Boot
- 固件：OpenWrt SNAPSHOT r0-725cbf1（kernel 6.18.44，base openwrt commit 725cbf1），experimental 档
- 访问：ssh root@192.168.123.1（公钥；已恢复基线）
- 测试目标：iQOO Neo9 Pro（MAC `e2:0d:5e:29:67:6d`，DHCP 主机名 `iQOO-Neo9-Pro`，IP .240）无法连接 5G WiFi
- 测试方法：A 配置与安全 / B RF-PHY 与日志取证 / C 客户端兼容性调研 / D 受控实验 / E 稳定性与工具链 五路并发，逐路多角度验证
- 结论：**AP 5G 链路健康，iQOO 在可观测窗口内从未对 5G 发起有效 auth/assoc（只连 2.4G SAE）；问题优先级为 ① 单 SSID 双频合一下无 band steering/独立 5G SSID 致客户端黏 2.4G；② 5.8G HE160 覆盖到 UNII-4（5850–5895MHz），国行 iQOO 在 5.8G 仅支持 80MHz，存在兼容性风险；③ SAE/PMF 基本可排除（2.4G SAE 成功）。待手机可操作后按文末“复现矩阵”锁定终局根因。**
- 关联 issue：#21；只读取证脚本：`scripts/device-wifi-iqoo-5g-probe.sh`。

## 一、基线与关键状态

| 项 | 实测 |
|---|---|
| 固件 | `OpenWrt SNAPSHOT r0-725cbf1` / kernel `6.18.44` |
| regdb | `country US: DFS-FCC`；5G UNII-3/4 5730-5895@160 30dBm；6G 5925-7125@320 29dBm NO-OUTDOOR |
| 2.4G | phy0.0-ap0，ACS ch1/20MHz（HE40 意图，F32 回退），txpower 30dBm，airtime busy 153/63%，3~4 个 IoT/手机客户端 |
| 5G | phy0.1-ap0，ch149/HE160，center1 5815（5735–5895），txpower 30dBm，noise -92dBm，airtime util 2，干净 |
| 6G | phy0.2-ap0，ch37/EHT320，center1 6105，txpower 29dBm，util 0（无客户端） |
| 加密 | 2.4G/5G `SAE + WPA-PSK + WPA-PSK-SHA256`（WPA2/WPA3 混合，PMF 可选）；6G `SAE`（PMF required，beacon_prot=1） |
| SSID | 三频统一 `K2P`（MLO 前提）；无 802.11k/v/r，无 DAWN/usteer/band steering |
| iQOO 实测 | 只出现在 2.4G phy0.0-ap0，`auth_alg=sae` 关联成功、4-way handshake 完成、DHCP .240；5G 无 auth/assoc 记录 |
| iPhone 实测 | 5G 关联成功（仓库 2026-08-22-wifi-deep-test 佐证：HE80 2SS，PHY rate 1200.9Mbps，-50dBm/SNR42）；本次测试 wifi reload 后暂未回连 |

## 二、测试矩阵与结果

### A. 配置与安全一致性
- [x] `uci show wireless` 三 radio 模型正确：radio0/1/2 均 `phy0` + `radio 0/1/2`（F28 修复有效）。
- [x] 生成 hostapd 配置与 UCI 意图一致：5G `channel=149`、`ieee80211ax=1`、`vht_oper_chwidth=2`、`he_oper_chwidth=2`、center1 163；`noscan=1`。
- [x] 5G 安全配置：`sae_require_mfp=1`、`ieee80211w=1`、`beacon_prot=1`、`okc=1`、`wpa_key_mgmt=SAE WPA-PSK WPA-PSK-SHA256`；与 2.4G 一致。
- [x] 未发现 5G 有 open/WEP/WPS；未发现 `rssi_reject_assoc_rssi`/`rssi_ignore_probe_request` 等弱信号拒接策略。
- [ ] **配置缺口**：无 `ieee80211k/v`、无 `bss_transition`、无 band steering；单 SSID 下客户端黏 2.4G 无法由 AP 引导到 5G。
- [ ] **配置漂移**：设备 2.4G/5G 实际密码为 `12345689`，6G 为 `123456789`；仓库 `files/etc/config/wireless` 三频均为 `123456789` 占位。本问题与 iQOO 连接无关（2.4G SAE 用设备密码已成功），但应尽快统一并改强。
- [x] 实测将 `ieee80211k/v + bss_transition` 加在 **wifi-iface** 上可生成 `bss_transition=1` / `rrm_neighbor_report=1`；加在 wifi-device 上无效。测试后已恢复。

### B. RF-PHY 与日志取证
- [x] `iw phy`：5G HE160 能力、EHT160 能力均在；5G 可用信道 36-64(24dBm DFS)/100-144(24dBm DFS)/149-177(30dBm)，其中 169/173/177 为 regdb 0521 扩展的 UNII-4 前段。
- [x] `iw dev`：5G `channel 149 (5745), width 160, center1 5815`；2.4G `channel 1 (2412), width 20`；6G `channel 37 (6135), width 320, center1 6105`。
- [x] `iwinfo`：5G Tx-Power 30dBm / Noise -92dBm；2.4G Noise -88~-89dBm，干扰偏重（busy 最高 153%）。
- [x] 日志取证（`logread | grep e2:0d:5e:29:67:6d`）：iQOO 全部事件绑定 `phy0.0-ap0`（2.4G），两次 `AP-STA-CONNECTED auth_alg=sae`、两次 `EAPOL-4WAY-HS-COMPLETED`、DHCPACK→.240；`phy0.1-ap0`（5G）对 iQOO **零 auth/assoc**。
- [ ] probe 级证据缺失：hostapd 默认日志等级不落 probe request；无法判定 iQOO 是否发过 5G probe。需空口抓包（monitor VIF + tcpdump）或临时提高 hostapd 日志等级。

### C. 客户端兼容性调研（外部资料 + 规格推断）
- [x] iQOO Neo9 Pro：天玑 9300/9300+，Wi-Fi 7，WPA3-SAE/PMF，OriginOS 智能连接/双 WLAN。
- [x] **国行 5.8G 仅支持 80MHz**：中国 5.8G 频段为 5725–5850MHz（信道 149/153/157/161/165），160MHz 需要 5735–5895MHz（覆盖 ch169/173/177 UNII-4 前段），国行终端在 5.8G 通常不启用 160MHz。
- [x] 5.1–5.3G（ch36–64）才能组成合法 160MHz（含 DFS 信道），但国行终端对 5.1G 160MHz 支持较好。
- [x] SAE/PMF 兼容性有 2.4G SAE 成功作反证，基本排除；但 5G 射频若单独配不同安全参数需现场核实（本机实测与 2.4G 一致）。

### D. 受控实验（已恢复基线）
- [x] **HE80/HE160 切换**：`radio1.htmode=HE80` 后 `iw dev` 5G width 80/center1 5775，hostapd conf `vht_oper_chwidth=1`/`he_oper_chwidth=1`，AP-ENABLED；恢复 HE160 后 width 160/center1 5815。证明 AP 侧 HE80 与 HE160 均健康。
- [x] **802.11k/v 注入实验**：wifi-iface 上设置 k/v/bss_transition 后 hostapd conf 正确生成 `rrm_neighbor_report=1`/`bss_transition=1`，三频 up；测试后已删除恢复。
- [x] **2.4G 禁用强制漫游实验**：`radio0.disabled=1` + `wifi reload` 后 90s 内 5G 无 iQOO 关联尝试；恢复 2.4G 后 60s 内 iQOO 未回连（手机当时应处于睡眠/不在用）。**该实验为弱证据**：窗口内手机可能睡眠，不能据此判定 iQOO 5G 故障；需手机在手边时重复。
- [x] 实验期间未触发 F31（wifi down/up 拒客）；均使用 `wifi reload`，风险可控。

### E. 稳定性与可维护性
- [x] `wifi reload` 连续多轮（含 HE80/HE160、k/v 注入、2.4G 禁用恢复）三频均 `up=true`，无 `retry_setup_failed`。
- [x] 未使用 `wifi down/up`（F31 危险操作）；自动化测试建议只走 `wifi reload`。
- [ ] 诊断工具仍缺：`hostapd_cli`/`wpa_cli`/`tcpdump`/`iperf3` 未装；空口抓包与认证排障受限（同 F30④）。
- [ ] hostapd ubus `get_features` 对 5G/6G 返回 `vht_supported:false`（疑似上报字段 bug，同 2026-08-22-wifi-deep-test）。

## 三、问题与方案（优先级排序）

| # | 级别 | 问题 | 证据 | 方案 |
|---|---|---|---|---|
| P1 | 中 | 单 SSID 双频合一，无 band steering/802.11v BTM/独立 5G SSID；iQOO 黏在 2.4G | iQOO 仅在 2.4G 关联（SAE 成功）；2.4G busy 63~153% 干扰大，5G util 2 干净；仓库无 steering 配置 | ① 首推：新增 5G-only SSID（如 `K2P-5G`，仅 radio1，同密码）作为手动选择/排障通道；② 在 wifi-iface 上开 `ieee80211k/v + bss_transition`（已实测生成配置）并评估 DAWN/usteer 的 RSSI 门限与 5G 优先策略；③ 合一 SSID 保留（MLO 前提），但把 5G 优先引导交给 DAWN/usteer 或手机侧智能连接 |
| P2 | 中 | 5G 默认 ch149/HE160 覆盖 5735–5895（UNII-4 前段），国行 iQOO 在 5.8G 仅 80MHz，存在“看到但连不上/直接忽略”的兼容性风险 | `iw phy` 169/173/177 为 regdb 0521 扩展；国行终端 5.8G 仅 80MHz；iPhone 以 80MHz 关联 HE160 AP 成功说明 AP 可收窄，但部分国行客户端对越界频宽广播兼容性差 | ① 对 5G 增加 **HE80 兼容档**（ch149/HE80 或 ch36-64 段 HE160），供国行手机场景切换；② 默认档是否改 HE80 需 ACCEPTANCE 与 160MHz 客户端实测后定（勿直接降级，采用配置档/注释方式）；③ 保留 HE160 供支持 5.8G 160MHz 的终端（如部分非国行设备） |
| P3 | 低 | SAE/PMF 兼容性（5G） | 2.4G SAE 成功反证；但需现场复核 5G 同安全配置（本机实测一致） | 排障时临时将 5G 改 `encryption 'psk2'` 二分定位；确认后恢复 `sae-mixed` |
| P4 | 低 | probe/认证级排障能力缺失 | 无 tcpdump、无 hostapd debug 日志；hostapd 默认不记 probe | ① 临时 `tcpdump -i phy0.1-ap0` 或 `iw dev phy0.1-ap0` monitor 抓 Probe Request；② 临时提高 hostapd logger 等级；③ 镜像补入诊断包（同 F30④） |
| P5 | 低 | 设备密码漂移 + 弱口令 | 设备 2.4G/5G 为 `12345689`，仓库为 `123456789` | 统一并改强口令；仓库占位符保持提示 |

## 四、复现矩阵（需 iQOO 在手边时执行）

1. **贴脸 5G 基线**：手机靠近路由器，观察是否仍连 2.4G；`ubus call hostapd.phy0.1-ap0 get_clients` 看是否出现 `e2:0d:5e:29:67:6d`。
2. **5G-only SSID**：新增 `K2P-5G`（仅 radio1，同密码），手机手动连接；成功=问题在双频合一/选择，失败=问题在 5G 链路/认证。
3. **HE80 兼容性**：把 radio1 改为 HE80（ch149），重复 1/2；若 HE80 可连而 HE160 不可连，则坐实 P2。
4. **WPA2-only 二分**：把 `K2P-5G` 改为 `encryption 'psk2'`；若可连，则 SAE/PMF 为 5G 侧阻断。
5. **空口抓包**：`tcpdump`/monitor VIF 抓 iQOO 的 Probe Request 与 Assoc Req，看 5G 是否收到、是否被 hostapd 拒绝。

## 五、恢复验证

- 2026-08-22 10:53 后已恢复基线：radio0/1/2 均 up，5G ch149/HE160，无 802.11k/v/bss_transition 残留，无测试 SSID 残留。
- 2.4G 客户端 b0:73/d0:ba 已自动回连；iPhone 与 iQOO 因手机睡眠暂未回连，待用户操作后自动恢复。
- 设备未触发 F31/F33 新增问题。
