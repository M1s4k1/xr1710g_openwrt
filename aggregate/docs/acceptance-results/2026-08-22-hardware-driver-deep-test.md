# 实机硬件驱动深度测试记录 — 灯光 / 网口 / 网口灯光

- 日期：2026-08-22（UTC+8 设备本地）
- 设备：Gemtek XR1710G（`gemtek,xr1710g-ubi`），已固化 HTTP U-Boot
- 固件：OpenWrt SNAPSHOT r0-725cbf1（kernel 6.18.44，experimental 档）
- 仓库分支：`feat/antenna-eeprom-power-unlock` @ 1f059bd
- 访问：`root@192.168.123.1`（SSH 公钥）
- 测试方法：**4 路并行**（每路多角度）：
  - Route A：状态 LED（GPIO）子系统——清点/亮度写回/触发器循环/netdev 触发文件/timer 采样
  - Route B：以太网口电气与 PHY 驱动——sysfs 电口指标、DSA 口映射、PHY 设备与 C45 ID、MDIO 统计、10G 口 down/up 循环
  - Route C：网口 LED——1G 口 PHY LED 清点/亮度写回/netdev offload 探测、10G 口 LED 缺口审计
  - Route D：温控/hwmon/风扇与内核错误日志审计
- 结论：**发现 4 类问题/改进点（HD-1~HD-4），其中 2 项已给出本仓库落地方案；10G 链路速率/物理目视仍需现场补测。**

## 分项结果

### Route A：状态 LED（GPIO）——通过
- sysfs 清点：`blue:status` / `green:status` / `red:status` / `white:status`，`max_brightness=1`。
- 当前运行态：`green:status` brightness=1、trigger=none（与 DTS alias `led-running = &led_status_green` 一致）；其余 0。
- 亮度写回测试：4 个 GPIO LED 均能 `1`/`0` 写回并恢复。
- 触发器：`none timer heartbeat default-on netdev phy0rx phy0tx phy0assoc phy0radio` 全部可用。
- `timer` 采样（red:status）能观察到 brightness 0/1 翻转（采样间隔受 busybox `sleep` 限制，1s 可观察到翻转）。
- `netdev` 触发验证：`blue:status` + `device_name=wan/lan3/eth0` + `link=1` 均使 brightness=1，GPIO LED 软件触发路径正常。

### Route B：以太网口与 PHY 驱动——通过（1 个计数器异常）
- 电口状态：`eth0` 内部口 10000/Full up；`wan` 1000/Full up（DSA p1）；`lan3` 1000/Full up（DSA p2）；`lan1`/`lan2` NO-CARRIER（无 10G 对端，符合预期）。
- DSA 映射：`wan -> port@1 (p1)`、`lan3 -> port@2 (p2)`，`of_node` 与 DTS 一致；`port@3/@4` 及 `phy@b/@c` 均为 disabled（本机仅 2 个 1G 口，符合板级设计）。
- PHY 清点：
  - `phy@05`（lan2）/`phy@08`（lan1）：RTL8261BE 10G PHY，C45 ID `0x001ccaf3`（mmd1/3/7/31 一致），`phy_interface=usxgmii`，hwmon temp 49/49°C，MDIO `errors=0`。
  - `phy@09`（wan）/`phy@0a`（lan3）：Airoha AN7581 PHY，ID `0x03a294c1`，`phy_interface=internal`。
- MDIO bus 统计：`errors=0`（全部 0x00–0x1f 段）。
- **异常（HD-3）**：`lan1` 在无链路、无电缆情况下，每次 `ip link set lan1 down/up` 循环后 `rx_errors`/`rx_dropped` 增加 0~3（实测基线 3 → 5 → 8 → 9）；`lan2` 同样操作不增加。`dmesg` 仅显示正常的 PHY attach/configuring，无 error/oops。

### Route C：网口 LED——1G 口 sysfs 可用但默认关闭；10G 口 LED 缺失
- 1G 口 PHY LED 清点：`mt7530_dsa-0:09:green:lan`、`mt7530_dsa-0:09:amber:lan`（wan）；`mt7530_dsa-0:0a:green:lan`、`mt7530_dsa-0:0a:amber:lan`（lan3）。DTS `led@0=green`、`led@1=amber`。
- 亮度写回测试：4 个 PHY LED 均能 `1`/`0` 写回并恢复。
- **默认状态**：4 个 PHY LED 均为 brightness=0、trigger=none——**1G 口 LED 默认不亮**（即使 wan/lan3 link up）。
- **netdev 硬件 offload 路径**：设置 `trigger=netdev` + `device_name=wan/lan3` 后，LED 出现 `offloaded=1`、`link_10/link_100/link_1000/full_duplex/half_duplex/rx_err/tx_err` 等 AN7581 特有文件。`link=1 rx=1 tx=1` 时 `offloaded=1`；但 `brightness` 保持 0（硬件直接接管，属预期）。
- **异常（HD-2）**：先配置第一个 PHY LED（wan 或 lan3 均可）的 `link/rx/tx=1` 时写入返回 0；再配置第二个 PHY LED 的 `link/rx/tx=1` 时，写入值生效（读回=1）但 sysfs store **返回 EINVAL**，导致 `/etc/init.d/led start` 输出 3 条 `write error: Invalid argument` 且退出码=1。
- **10G 口 LED 缺口（HD-4）**：`/sys/class/leds` 中无 `mt7530_dsa-0:05` / `:08`（RTL8261BE）LED；DTS 中 `ethernet-phy@5` / `@8` 无 `leds` 子节点。10G 口 LED 当前完全不受软件控制（默认行为可能由 PHY 硬件自治，未现场目视确认）。

### Route D：温控/风扇与内核错误日志——通过
- hwmon：`mt7530_dsa_0:05`/`_0:08`（10G PHY 49/49°C）、`mt7996_phy0.0/0.1/0.2`（56/50/55°C）、`nct7802`（temp1 49.6°C、fan1 1134、pwm1 69）。`nct7802 temp2_input=127875` 为未接传感器（已知）。
- thermal_zone0：`cpu-thermal` 56.5°C。
- `/etc/init.d/fan` 运行中；曲线温度点 40/50/60/70/80°C 对应 PWM 54/69/95/130/199/255，脚本已按当前 temp1≈50°C 写 pwm1=69。
- 内核错误审计：`dmesg | grep -E 'error|fail|warn|timeout|deferred|oops|panic|BUG'` 零命中。
- 网络 flap 审计：wan/lan3/eth0 均 `carrier_changes=1` 且 up_count=1，无异常 flap。

## 发现与方案（HD 系列）

### HD-1：1G 口 LED 默认不亮 —— 已修（本仓库配置）
- 问题：wan/lan3 1G 口 PHY LED 在系统启动后无任何 UCI LED 配置，sysfs 默认 brightness=0、trigger=none，网口灯不亮。
- 方案：`files/etc/config/system` 增加 `led_wan_green` / `led_lan3_green`（`trigger=netdev`，`dev=wan/lan3`，`mode='link rx tx'`）。设备实测该配置使 LED 进入 `offloaded=1` 硬件接管状态；物理目视待现场确认。
- 注意：见 HD-2 的第二个 LED 写入 EINVAL 问题（值生效，但 `led start` 会打 3 条 write error）。

### HD-2：AN7581 PHY LED 第二个 netdev 配置写回 EINVAL —— 待上游/驱动修复
- 问题：同一 netdev 触发下，第二个 PHY LED 的 `link`/`rx`/`tx` sysfs 写入返回 `EINVAL`，但值已生效（读回=1）。`/etc/init.d/led start` 退出码=1，boot 日志出现 3 条 `write error: Invalid argument`。
- 根因方向：AN7581 PHY LED sysfs store 路径（`drivers/net/phy/mediatek/mtk-ge-soc.c`，本仓库 9016 同文件）在配置第二个 offload LED 时先应用再返回 `-EINVAL`。
- 方案：上游/自持补丁修正 store 返回码；短期可接受（LED 实际工作）。Issue #14。

### HD-3：lan1 (10G/USXGMII) 无链路 down/up 时 rx_errors/rx_dropped 虚增 —— 待驱动修复
- 问题：`lan1` 无电缆时，每次 `ip link set lan1 down && ip link set lan1 up` 使 `rx_errors`/`rx_dropped` 增加 0~3；`lan2` 无此现象。该计数会触发监控误报（如 LuCI/9017 的 Physical Bottleneck 告警）。
- 根因方向：`airoha_eth` 在 USXGMII in-band link 重新配置期间把 link-state 字/伪帧计为 RX error，或重新 open 时未清零统计。
- 方案：驱动在 admin down 或重新 configure link 时清零/冻结 RX error 计数；仅把 carrier up 后的真实帧错误计入 `rx_errors`。Issue #15。

### HD-4：10G 口 LED 无 sysfs/DTS 节点 —— 跟进上游 #24034
- 问题：RTL8261BE（lan1/lan2）无 LED class 设备，DTS `ethernet-phy@5/@8` 无 `leds` 子节点。
- 方案：跟进 OpenWrt 上游 #24034（RTL826x LED）；若短期需要，参考 fanboy 09 号实验档 RTL8261CE LED 支持代码（`rtk_rtl8261ce_phy.c` 内集成 LED）评估移植到 RTL8261BE 的可行性。
- 状态：已修复——9033 carry openwrt #24034（RTL826x LED hooks）+ 9001 DTS `phy5`/`phy8` 增加 `leds` 子节点 + `files/etc/config/system` 增加 lan1/lan2 10G LED netdev 触发。Issue #13。

## 遗留/现场补测
- [ ] 10G 口 10Gbps 链路与吞吐（B2，需 10G 对端）
- [ ] 1G/10G 口 LED 物理目视确认（HD-1/HD-4）
- [ ] 10G 口插拔后 `lan1` 计数是否仍虚增
- [ ] `ethtool`/`bridge`/`devlink` 诊断工具缺失（见 F30）仍待镜像补入

## 可复现脚本
- `scripts/device-hw-probe.sh`（本仓库）：默认 4 路并行执行；`TOGGLE_10G=1` 可开启 10G 口 down/up 循环（注意会污染 lan1 计数器，仅用于复现 HD-3）。
