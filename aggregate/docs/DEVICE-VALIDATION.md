# 实机验证清单（DEVICE-VALIDATION）——待上机复核的 `#EXP`/`#OC`/overlay 项

**用途**：本仓 CI 只证"补丁层干净 + 内核/包编译通过 + 镜像产出"（`docs/FIXES.md` 各行的"实证"列），
**不证硬件行为**。本文件把散落在台账各行的"实机判据"收成一张可勾选清单，供上机时逐项打勾。
**与 `docs/ACCEPTANCE.md` 的分工**：ACCEPTANCE = known-good 冻结门槛（A/B/C 项，面向"可用固件"）；
本文件 = 每个 `#EXP`/`#OC`/overlay 改动的**专属判据**（面向"这一项到底生效没有"）。

**图例**：档位 `E`=experimental 才有（`#EXP`）/ `S`=stock 也有 / `O`=OC 档（`#OC`）；
状态：`☐` 待实机、`✅` 已通过（注明日期/批次）、`n/a` 不适用。

**通用前置**：`stock` 与 `experimental` 固件分别记录版本（release `ci-*` 与 commit）；
判据里的 `devmem`/debugfs 路径以实际内核为准；无线类判据必须先记录**客户端型号/国家码/频宽**。

---

## 1. SOE / IPsec 硬件卸载（A+D+B+LAG 四段，**必须同档才有完整意义**）

来源：F115（A=xfrm packet-offload 9053、D=EIP93 动态回退 9054）、F122/F142（B=SOE 主体 17..28）、
F143（LAG 共享状态 29..38）。全部 `E`。

- [ ] **V1.1 构建与符号**：experimental 镜像产出且符号生效——
      ⚠ 设备侧**无 `/proc/config.gz`**（内核未开 `IKCONFIG_PROC`，P27 实测坑 72），
      改用三重旁证（2026-09-16 ci-176 实测通过）：
      ① `grep -E "airoha|eip93|bonding" /lib/modules/$(uname -r)/modules.builtin` + `lsmod`：
      `bonding` / `crypto_hw_eip93` / `airoha_eth` / `airoha_npu` 均在；
      ② `modinfo airoha-eth`（SOE 不产出独立 ko：`airoha-eth-$(CONFIG_NET_AIROHA_SOE) += airoha_soe.o`
      ⇒ 代码在 **`airoha-eth.ko`** 内）；
      ③ `strings /lib/modules/$(uname -r)/airoha-eth.ko | grep -c airoha_soe_` = **56**（P27 实测）。
      注意 `zcat /proc/config.gz | grep -E "NET_AIROHA_SOE|..."` 在本镜像**不可执行**。〔F142/F143/F149；P27 坑 72〕
- [ ] **V1.2 SOE 节点**：`dmesg | grep -i soe` 无 probe 失败；`/sys/firmware/devicetree/base/...`（或
      `find /proc/device-tree -name "*soe*"`）存在 SOE 节点。〔F122；dtsi 12 号补丁〕
      ⚠ **P27 实测不通过（坑 71）**：SOE-12 补丁目标是内核树 `arch/arm64/boot/dts/airoha/en7581.dtsi`，
      而本板固件编译的是目标树 `target/linux/airoha/dts/an7581.dtsi`（`9001` 生成板级 dts 的 include
      按同目录优先解析）⇒ 设备 fdt `en7581-soe` 命中 **0**、eth 兄弟节点无 soe ⇒ SOE 全族空转。
      **该修复落地前，V1.2/V1.3/V1.4/V1.6 全部不可能通过**；判据以设备 fdt 独有字符串为准
      （`strings /sys/firmware/fdt | grep -F -c en7581-soe`，修复后期望 ≥1）。
- [ ] **V1.3 IPsec 卸载生效**：配 `ip xfrm state add ... offload dev <10G口> ...` +
      `ip xfrm policy add ... offload`；`ip -s xfrm state` 的计数增长，且
      `dmesg` 无 `offload` 失败；对照两种算法：
      `authenc(hmac(sha256),cbc(aes))`（应走 EIP93/SOE 硬件）与 `rfc4106(gcm(aes))`（应软回退，9054 保证）。
      `grep -c eip93 /proc/crypto`、`ip -s xfrm state` 的 replay/bytes 两栏都必须动。〔F115/F122〕
- [ ] **V1.4 吞吐**：`iperf3` over IPsec（外部对端！）vs 未卸载路径；记录 CPU 占用差异。
      判据：卸载路径吞吐 ≥ 软件路径，且单核 softirq 明显下降。〔F122〕
- [ ] **V1.5 不回归**：开 IPsec 卸载后普通 IPv4/IPv6 转发、NPU `[HW_OFFLOAD]`、
      Wi-Fi 三频连接均无回归（对照 `V2.*`/ACCEPTANCE B5/C1）。〔F122⑤〕
- [ ] **V1.6 LAG 共享状态**：建 `bond0`（两个物理口、802.3ad）→ 一次 `ip xfrm state add`，
      两 lower 都能卸载（`xdo_dev_state_lag_compatible` 判定同源，见 `dmesg`）；
      lower 断开 / `mode` 切到 `active-backup` / 切回 → ESP 不中断、计数连续；
      `ip -s xfrm state` 的 replay 计数**无跨口错乱**（同一 SA 不因换口丢包/重放）。
      注：SOE 是否真跑起来还取决于 NPU/SOE 固件版本。〔F143〕
- [ ] **V1.7 关闭回退**：移除 xfrm offload 后（或 `rmmod`）流量回到软件路径且不掉线。〔F143〕

## 2. NPU / mt76 生命周期

- [ ] **V2.1 NPU 固件版本**：probe 时 `WLAN_FUNC_GET_WAIT_NPU_VERSION == 0.1111`
      （`dmesg | grep -i "npu.*version"` 或对应调试接口）。〔F125〕
- [ ] **V2.2 watchdog 恢复**：人为触发 NPU core 停滞（或 `debugfs` 钩子）后**无需重启**即可恢复；
      `dmesg` 出现 recovery 日志且 offload 重新绑定成功。〔F125〕
- [ ] **V2.3 reload 20 轮**：NPU 活跃下 `rmmod/insmod mt7996e` 20 轮，
      **无** `NAPI instance ... already registered` / `not been added`。〔F127〕
- [ ] **V2.4 reboot 20 次**：每次 Wi-Fi 都枚举（三频 SSID 可见 + 可连）。〔F127〕
- [ ] **V2.5 coherent 泄漏**：反复 reload 后 `/proc/meminfo` 的 `Slab`/`SUnreclaim` 无单调增长
      （⚠ `slabtop` 本镜像**不可用**，P27 实测；基线 2026-09-16 ci-176：Slab 48388 / SUnreclaim 40612 kB）；
      `dmesg` 无 `coherent` 分配失败。〔F127；P27 坑 72〕
- [ ] **V2.6 长压 12h**：>1Gbps + 6GHz 320MHz 持续 12h，`HOSTADPT_API_Q_FULL` 不增长、
      NPU RX 环 head/tail 不漂移。〔F127〕
- [ ] **V2.7 NPU offload 计数**：`luci-app-airoha-npu` / flowsense 页面 NPU 已加载、
      卸载计数增长、IPv6 UDP 长流达 `[HW_OFFLOAD]`。〔ACCEPTANCE B5；F123〕
- [ ] **V2.8 929 条件项**：只有当"probe 固件版本 0.0 且 928 已修仍复现"时，才需要按 2GiB DDR 布局
      在 DTS 划一块低于 `0xbfffffff` 的 `shared-dma-pool`（名 `mbox`）再吸收 YYH 929——
      现在**不携带**（缺该池会让 `of_reserved_mem_device_init_by_name(dev, node, "mbox")` 直接失败）。
      复现检查：`find /proc/device-tree -name "mbox"`（当前应为空）。〔F125 备注/F146〕

- [ ] **V2.9 `wtbl_lmac_addr` RX 路径 WARN 抓取**（p2 §2.7 尾注/§6.3，本仓**未修**，先抓判据）：
      持续流量 + 多次 STA 断连/重连（含 MLO 站点）时 `logread -f | grep -i "mt7996_mac_wtbl_lmac_addr"`；
      命中则记录完整 `WARNING:` 行 + `RIP:`/`Call Trace`（应见 `mt7996_queue_rx_skb` ← `mt76_npu_rx_poll`），
      并同时抓 `iw dev <if> station dump | grep -E "addr|link"` 以定位 MLO/MLD link 索引。若命中即单开重基/
      修复项（判 `WARN_ON` 条件是"索引越界"还是"未授权 wcid"）。关联：Gilly `048` 修的是**同域 TX 侧**
      NULL sta（已吸收，F153），本条是 RX 侧。〔F155〕
- [ ] **V2.10 EAPOL 竞态无 oops**：4 次握手重传与 disconnect 交叉（快速反复断连/重连、`wifi reload`）
      时 `dmesg` 无 TX worker oops / 无 `NULL pointer dereference`（Gilly `048`/mt76-0022 的收益判据）。〔F153〕

## 3. PPPoE / DHCPv6 与 rootfs overlay

- [ ] **V3.1 overlay 进镜像**：`cmp` 设备上 `/lib/netifd/ppp6-up`（1457 B）、
      `/lib/netifd/proto/dhcpv6.sh`（8056 B）、`/lib/netifd/xr1710g-dhcpv6-guard.sh`（4542 B）
      与仓库 `files/...` 逐字节一致；`grep -c xr_dhcpv6_has_explicit /lib/netifd/ppp6-up` = 1。
      本地复核：F140/F141 的 FIT 解包 recipe（`tail -c +$((OFF+1))` + `unsquashfs -cat`）。〔F140/F141〕
- [ ] **V3.2 去重生效**：⚠ **P27 修正口径（坑 74）**：`pidof odhcp6c | wc -w` 在分层设备上
      正确态就是 **2**（现网 `wan6` dev `wan` 与 PPP 动态 `wan_6` dev `pppoe-wan` 是**两个 L3 设备**，
      各跑一个 odhcp6c，ubus 对象 `odhcp6c.wan` / `odhcp6c.pppoe-wan` 互不冲突）。
      判据改为：**同一 L3 设备**不得有两个 odhcp6c 实例；
      `logread` 无 `ubus_add_object` 失败 / `EEXIST`；
      `ubus list | grep odhcp6c` 的对象按接口一一对应。〔F118/F136〕
- [ ] **V3.3 不回归**：普通 PPP 自动 IPv6、仅独立 dhcpv6 接口两种场景各自单独存在时仍正常起。〔F118〕

## 4. 网络与桥（管理面）

- [ ] **V4.1 br-lan MAC 唯一**：10G WAN + 10G LAN 同插时**管理页可访问**；
      `ip -br link` 显示 `br-lan` 与 `lan1/lan2` MAC **互不相同**；
      `lan2` 单独接主机能拿到 DHCP；
      `bash scripts/device-hw-probe.sh` 的 E3 判 `VERDICT: UNIQUE`。〔F117/F119〕
      ⚠ 首次应用会改 br-lan MAC → 桥重建，管理面 ssh 会断一次（属预期，重连即可）。
      ⚠ 根因（F119 实机 + 2026-09-13 F145 对 `9001` 逐行复核）：`&gdm1`(lan1) 与 `&gdm4`(lan2)
      **都取 `<&lan_mac 0>`**（`&gdm2` 取 `<&wan_mac 0>`、Wi-Fi 三频取 `<&lan_mac 1/2/3>`；`lan_mac` 是
      `compatible = "mac-base"`、`#nvmem-cell-cells = <1>` 的 6 字节基址，参数即地址增量）。
      ⇒ **`lan_mac` 的 1/2/3 已被三频占用，没有空闲的有线口索引**，DTS 侧改索引不是干净修法
      （会改 lan1/lan2 的 MAC，波及 DHCP 静态租约/交换机 MAC 表，且需先实机摸清 "base+N" 的映射）。
      因此**配置层派生唯一 MAC（本仓 `98-xr1710g-brlan-mac-unique`，已交付）就是该问题的正解**，不是临时绕道；
      剩下的 DTS 观测（gdm1/gdm4 同索引）单列为"待实机确认 MAC 映射"的观察项，不阻塞本项。
- [ ] **V4.2 bridge-hw-offload**：开关 `flow_offloading_hw` 后
      `nft list table bridge flow_offload` 随之出现/清空、**无需 reboot**；
      flowsense 页面为 gauge（无 `◄BND`）、无 VLAN/PPPoE 徽章、`air_eff=80` 生效；
      F88 CDM1 百分比仍含 `rx_hwf_fast`。〔F123〕

## 5. Wi-Fi（含 802.11r / FT）

- [ ] **V5.1 802.11r 生效**：`uci show wireless | grep -c "ft_over_ds='1'"` = 4（出厂四段）；
      `iwinfo` / hostapd 日志显示 MDIE（`mobility_domain 6616`）已下发。〔F144〕
- [ ] **V5.2 漫游无重认证**：三频/双 AP 环境下用 Apple 客户端漫游，
      `logread` **无** `did not acknowledge authentication response`；
      `iw station dump` 的 `connected time` 连续、无重认证、漫游延迟下降。〔F144〕
- [ ] **V5.3 兼容性**：非 FT 客户端、PMF、WPA2/WPA3 混合（`sae-mixed`）均可正常关联；
      AP 不因 802.11r 起不来（`logread` 无 hostapd 配置错误）。〔F144〕
- [ ] **V5.4 可回退**：`uci set wireless.default_radio1.ieee80211r='0'`（或 `ft_over_ds='0'`）+
      `uci commit wireless` + `wifi reload` → 回到改动前行为。〔F144〕
- [ ] **V5.5 AP 侧 FT key 竞态**（mac80211 412，`#EXP`）：AP 侧 FT（PMF 客户端）反复漫游时
      `dmesg` **无** `nl80211: kernel reports: key addition failed`；`ip -s link` 无异常丢包。〔F144〕
- [ ] **V5.6 mac80211 8 项（397/399/400/405/406/407/409/410）**：三频 + MLO 回归——
      CSA/CAC 场景无 call trace、AQL BMC 正常、RTS 不被意外置 0。〔F129〕
- [ ] **V5.7 hostapd**：本仓 hostapd 补丁 0 条（F138 定案）；6GHz 不需 DFS 已由
      `vendor/fanboy/17` 携带——`dmesg`/hostapd 日志确认 6G AP 起在非 DFS 信道无 CAC 等待。〔F138〕

## 6. 其他 `#EXP` / `#OC` 硬件项

- [ ] **V6.1 EIP93 可靠性三修（9062 内层 9999-40..42）**：连续加解密无 `dma` 清理告警；
      `hmac` 在 `setkey` 前被拒（不 panic）；PE ready 顺序无竞态告警。
      命令：`dmesg | grep -i eip93`；`/proc/crypto` 里 eip93 条目被实际使用。〔F131/F115〕
- [ ] **V6.2 PCS RX-lock 诊断（9055）**：10G 口接对端/断开两种状态下，
      诊断接口（debugfs/`ethtool -S`）能区分"无信号"与"CDR 未锁"；服务 F81/F93 的判读。〔handoff_p2 §2.1〕
- [ ] **V6.3 PCIe AER 探针**：`bash scripts/device-pcie-aer-probe.sh` 只读采集，
      记录 AER 计数基线（社区已有两台硬件死亡案例，需长期对照）。〔handoff_p2 §2.6〕
- [ ] **V6.4 hwrng（9058/9059）**：`head -c 32 /dev/hwrng | hexdump -C` 有输出
      （⚠ 设备**无 `od`/`xxd`**，P27 实测坑 72，统一用 `hexdump`）、
      `dmesg` 无 SCU 时钟顺序告警、熵池增长（`cat /proc/sys/kernel/random/entropy_avail`，P27 实测 256）、
      `cat /sys/devices/virtual/misc/hw_random/rng_current` = `1faa1000.rng`（驱动绑定判据）。
      ⚠ 9059 的 `airoha,scu` 修复因坑 71（DTS 载体错位）尚未进 DTB——TRNG 注册成功属"竞态非必现"，
      该修复落地前本项**不能作为 9059 生效证据**，只证 9058/驱动绑定。
- [ ] **V6.5 CPU/OC 与温控（`#OC` 档 + `files/etc/init.d/oc-auto`）**：OPP 650–1350 生效
      （`cat /sys/.../cpufreq/scaling_available_frequencies`）、1350 不稳定时自动退档日志、
      长压不触发热关机。〔F89〕
      （P27 基线：avail 650000…1350000、level=1300 已自动退档一次、governor performance、
      风扇 nct7802 pwm=74。）
- [ ] **V6.6 MTU/RX ring/GRO 类（9042/9037/9047/9048/9035/9050）**：
      10G 口 MTU 9000 往返、`ethtool -S` 的 RX ring 无丢包、PPE BND 计数随流量增长、
      flow stats 与 NPU 并存无 `-22`。〔各 F 行〕
      ⚠ **9047 bind_rate 待定性（P27 坑 71 同轮新发现）**：设备
      `cat /sys/kernel/debug/ppe/bind_rate` 实测 **30**（连读一致），而 9047 应设
      `AIROHA_PPE_BIND_RATE_DEFAULT(8)` 且 CI 干净应用、符号齐备——读数与补丁意图矛盾，机制未定。
      允许写的定性实验（**须用户确认后做**）：`echo 8 > /sys/kernel/debug/ppe/bind_rate` 后回读。
- [ ] **V6.7 992-20/992-21 稳定性**：长时间跑 Wi-Fi + PPE 卸载无 `WARNING: CPU` / call trace
      （含 issue #17 的 `mt7996_mac_wtbl_lmac_addr` RX 路径告警——**本仓未修**，若复现需单开）。〔handoff_p2 §2.x 备注〕

## 7. mt76 固件换代（F161，**换代后必跑**；与 stock/experimental 档无关）

来源：F161——mt76 主源 `be5ce791`（上游 2026-03-11 固件）→ fanboy fork `01367e60`（2026-07-21 固件），
`be5ce791..01367e60` = **22 文件 / 0 行源码增删 / +9 069 388 B，全部是 `firmware/mt7996/*.bin`**。
**本组的特殊性**：换代**只动固件二进制、源码零改动** ⇒ CI 绿只证「补丁照样应用 + 编译过」，
**完全不证固件行为**。故以**字节指纹**为第一判据（客观、可复算），行为项为第二判据。

> **指纹表**：`docs/device-validation-f161-firmware-sha256.txt`——逐文件 old/new sha256 + 内嵌 `build_date`。
> 机器判据摘要：**驱动会加载的 7 个 MT7996 生产固件全部内容变**（不只是 4 个 `_wm`：`dsp`/`rom_patch`×2/`wa`×2
> 是「同大小或 +64 B、内容变」）；5 个新增 `*_tm*.bin`（9 134 512 B）**驱动源码与包 Makefile 均零引用**
> ⇒ 既不进运行时路径、也不进镜像。

- [ ] **V7.0 换代确实进了镜像（字节指纹；**先做这一条**）**：设备上
      `cd /lib/firmware/mediatek/mt7996 && sha256sum *.bin | sort`，与指纹表的 **new 列**逐字符比对
      （存在的文件必须全部匹配；未安装的芯片变体允许缺失，但**不允许出现 old 列的值**）。
      另：`ls /lib/firmware/mediatek/mt7996/*_tm*.bin` 必须 **No such file**。〔F161〕
- [ ] **V7.1 固件版本行（最硬的实机判据，字面匹配）**：`dmesg | grep -E 'Firmware Version'`。
      换代后必须出现 **`Build Time: 20260721003035`**（`mt7996_wm.bin`，444 变体）**或**
      **`20260721003609`**（`mt7996_wm_233.bin`，233 变体）——**这一行同时告诉我们本机走的是哪个变体**；
      换代前对应 `20260311120504` / `20260311120702`。`WA` 应见 `20260721002917` / `20260721003453`，
      `DSP` 应见 `20260721002848`。`fw_ver` 字段是占位 `____000000`，**不比它**。
      〔源：blob 尾部 `struct mt76_connac2_fw_trailer`（`mt76_connac_mcu.h:176-188`），
      驱动打印点 `mt7996/mcu.c:3708`〕
- [ ] **V7.2 无固件加载失败**：`dmesg` 无 `Failed to start` / `Invalid firmware` /
      `Direct firmware load` + `failed` / `firmware` + `timeout`；三频（2.4/5/6G）全部起来且可关联
      （枚举判据同 V2.4）。〔F161〕
- [ ] **V7.3 三频吞吐基线（与换代前对照）**：2.4/5/6G 各跑 `iperf3`（记录客户端型号/国家码/频宽）。
      判据：**不劣于**换代前同一测法的记录（同客户端、同位置、同频宽）；单次差异 >5% 必须复测确认。
      〔F161；与 ACCEPTANCE C1 同源〕
- [ ] **V7.4 NPU 卸载长稳（本机 WM 变体路径）**：开 NPU 卸载、持续 >1 Gbps 至少 1 h（理想 12 h，同 V2.6）：
      `HOSTADPT_API_Q_FULL` 不增长、NPU RX 环 head/tail 不漂移、`dmesg` 无 `WARNING` / call trace。
      〔F161；F127〕
- [ ] **V7.5 冷启动 ×N 无固件超时**：`reboot` ≥10 次 → 每次都有 V7.1 的版本行、无 V7.2 的失败模式、三频可见。
      重点在**固件加载时序**（不是枚举本身，枚举见 V2.4）。〔F161〕
- [ ] **V7.6 可回退**：刷回换代前 release（`ci-167` 或当时的档位产物）→ 字节指纹回到 **old 列**、
      `dmesg` 回到 `20260311120504`。换代必须**可逆**、且回退后不残留。〔F161〕

---

## 记录模板（每项通过时）

```
V<x>.<y> 通过  <年-月-日>  镜像 ci-<N>（<commit>，档位 stock|experimental）
  命令与关键输出：<贴 3-10 行>
  反例/边角：<例如 6G 客户端国家码非 US 时不可见（预期）>
  关联台账：F<NNN>
```
