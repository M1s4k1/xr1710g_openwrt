# P1 实机回归记录（2026-09-08，firmware r0-7b39600 experimental）

> 前置：P1 批次（e99b88e + 411 修复 0db03a4 + 992-21 重建 7ce6c81 = 7ce6c81）CI 全绿
> （stock 34134102608 / all 34134117948 / experimental 34134122223 / sync-upstream 34134102601），
> 固件 experimental r0-7b39600 已刷入实机（2026-09-08 00:02，keep config）。
> 基线对照：`tmp/regression-baseline-2026-09-08.md`（r0-93cf01b BEFORE 值）。

## 1. 结果汇总

| # | 项（判据） | 结果 | 证据 |
|---|---|---|---|
| R1 | LAN2 10G 冷启动 ×20 + link 率（F71/F81/F84 联合） | **20/20 冷启动均为 2.5G——10G 未达成**；9029 机制确认生效（boot 态 devmem `0x1fa7a030`=0x301D，BEFORE=0x301B，TCLVAR=5）；devmem 0x1D 诊断写后寄存器=0x1D、link 不升 | tmp/lan2-coldstart-p1.log（20 轮，每轮全新 boot uptime<300s，fbck=0，wifi=4） |
| R2 | #22397 复现（ifdown/up + FBCK_LOCK dmesg） | 未复现：ifdown/up 后 dmesg 无 FBCK/校准错误，lan2 稳定 2.5G | regress-wifi22397.log |
| R3 | wifi down/up（issue #10） | **PASS**：down 后 0 AP → up 后 4 AP 恢复，hostapd 2 进程，无关联错误（仅 down 期 benign "Failed to remove interface"） | 直接功能测试 2026-09-08 01:30 |
| R4 | device-hw-probe | **全绿**：route_a-d rc=0，B7 EFR32 缺席判定 OK，LED 清单完整 | /tmp/hwprobe-p1.log（40 行） |
| R5 | LED/风扇 | LED 在位（status + mt7530_dsa lan），风扇 nct7802 1312 RPM | 2026-09-08 01:35 |
| R6 | sysupgrade -T | **PASS**（rc=0，图像元数据校验通过；itb 与 CI 产物 md5 逐字节一致 e9be0753…） | 2026-09-08 02:00 |
| R7 | 三频/链路稳态 | 4 AP up；eth0=10G / lan2=2.5G / wan=1G / br-lan=2.5G；mem Avail 1.6G | post-flash 稳态捕获 |
| R8 | GPIO 46/31（F83/9040） | 受限：debugfs 仍显示 `PHY reset` 功能（out hi）；sysfs export 46/31 被拒（无 gpio46/31 节点，CONFIG_GPIO_SYSFS 限制）→ 方向写入不可直接验证；**间接证据**：20 次冷启动均无 PHY ID 读失败/复位异常（9001 reset 路径功能正常） | 2026-09-08 02:07 |

## 2. 结论与决策输入（§7.3）

- **9029/9038/9041 联合未能在本 rig 达成 lan2 10G 冷启动**（20/20 2.5G）。判据：
  9029 内部 recal 生效（boot 态 TCLVAR=5）但 10G AN 仍未建立；`devmem 0x1D`（OW1700k 诊断法）
  在本机写后 link 不升（且会清 0x300000 位——后续复测应避免裸写 0x1D，改 0x301D 语义域）。
  **补充证据（2026-09-08 03:2x）**：`ethtool lan2` = PHY 支持并广播 10000baseT/Full
  （100/1000/2500/5000/10000 全档），但 AN 协商结果为 2.5G → 限制在**对端或 AN 路径**而非 PHY 能力；
  驱动层强制 10G 被拒（`Cannot set new settings: Invalid argument`，RTL826x 无 forced-10G 路径）。
  **机制取舍决策无法在本 rig 闭合**：lan2 对端设备能力未知（10G 物理对端项 C2/C3/B2 按用户口径
  延后）——三条补丁暂保持 #EXP，待 10G 对端复测后再定去留（F71/F81/F84 备注同步）。
- **mt76-0011/0012**：无 NPU panic 观测（本时段无重负载；0011 default 已入，0012 #EXP）。
  长稳 soak 建议：留机连续运行 ≥24h 后复查 dmesg（D3 续跑）。
- **F87 修复在真机构建验证**：stock/experimental kernel-prep 均通过（992-21 74 行版）。

## 3. 遗留

- 10G/6G 对端项（C2/C3/B2）、D3 压力条件、625 吸收（YYH 620/622）、`reset-before-id-read`
  内核侧消费（F78）——按用户口径/上游进度延后。
- 沙箱传输限制发现：本宿主 bash 单命令数据流 ~28KB 上限（ssh/scp 大数据截断），
  大文件传设备需分块（tmp/chunk-transfer.sh）或设备侧主动拉取——HANDOFF §8 备忘已记。