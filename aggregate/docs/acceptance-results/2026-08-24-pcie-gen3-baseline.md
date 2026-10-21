# PCIe Gen3 基线采集与 D0 能力判定（2026-08-24）

> 计划：`docs/PCIe-GEN3-PLAN.md` Phase 0 / D0。
> 设备：`root@192.168.123.1`（XR1710G，OpenWrt 6.18.44，实机）。
> 结论：**D0-stop** —— `pcie2` 根端口 `0002:00:00.0` 的 `LnkCap2` 仅报 **2.5/5.0 GT/s**、`LnkCtl2 Target Link Speed=5GT/s`、`max_link_speed=5.0 GT/s PCIe`。根端口未声明 Gen3（8.0 GT/s）能力，pcie2 的 PHY/板级上限为 **Gen2 x1**；不实施 pcie2 Gen3 x1 实验补丁，转入文档固化与上游跟踪。

## 1. 结论速览

| 链路 | 当前速度 | 当前宽度 | 根端口 LnkCap2 声明 | 判定 |
|---|---|---|---|---|
| `0000:00:00.0` / `0000:01:00.0`（pcie0 主 mt7996e） | 8.0 GT/s | x2 | 2.5–8 GT/s | 已 Gen3 x2，基线达标 |
| `0002:00:00.0` / `0002:01:00.0`（pcie2 mt7996e-hif） | 5.0 GT/s | x1 | **2.5–5 GT/s（无 8GT/s 位）** | **D0-stop：Gen3 不可达** |

## 2. 采集环境与工具

- 实机：`Linux xr1710g 6.18.44 #0 SMP Fri Aug 21 18:07:16 2026 aarch64 GNU/Linux`。
- `lspci` 通过 `apk add pciutils` 安装（pciutils 3.14.0-r2；安装过程有 `ERROR: wget: exited with error 8` 的仓库元数据告警，但 4 个包安装成功）。
- `lspci -vv` 运行时会打印 `Unable to load libkmod resources: error -2`（不影响 PCIe 能力/状态解析）。
- `devmem` 只读寄存器**不可用**：设备当前无 `/dev/mem`；`mknod /dev/mem c 1 1` 后 `devmem 0x1fb0009c` 返回 `can't open '/dev/mem': No such device or address`（内核拒绝/未开放 /dev/mem 访问）。因此本基线不含 SCU 寄存器快照，后续如要写寄存器实验必须先刷入启用 `CONFIG_KERNEL_DEVMEM`（本仓库 seed 已启用）并确认 `/dev/mem` 可打开。
- 作为替代，用 `dd if=/sys/bus/pci/devices/.../config` 读取 PCIe 配置空间，解析 PCIe capability 的 `LnkCap/LnkCap2/LnkSta/LnkSta2`，与 `lspci -vv` 输出互相印证。

## 3. 采集命令

```bash
DEV=root@192.168.123.1
ssh $DEV 'lspci -vv -s 0000:00:00.0' 
ssh $DEV 'lspci -vv -s 0000:01:00.0'
ssh $DEV 'lspci -vv -s 0002:00:00.0'
ssh $DEV 'lspci -vv -s 0002:01:00.0'
ssh $DEV 'for d in 0000:01:00.0 0002:01:00.0; do
  echo ==$d==;
  cat /sys/bus/pci/devices/$d/current_link_speed;
  cat /sys/bus/pci/devices/$d/current_link_width;
  cat /sys/bus/pci/devices/$d/max_link_speed;
  cat /sys/bus/pci/devices/$d/max_link_width;
done'
ssh $DEV 'dmesg | grep -iE "pci 000[02]:|pcie|bandwidth" | tail -40'
```

## 4. sysfs 实测

| 设备 | current_link_speed | current_link_width | max_link_speed | max_link_width |
|---|---|---|---|---|
| `0000:00:00.0`（pcie0 RP） | 8.0 GT/s PCIe | 2 | 8.0 GT/s PCIe | 2 |
| `0000:01:00.0`（mt7996e） | 8.0 GT/s PCIe | 2 | 8.0 GT/s PCIe | 2 |
| `0002:00:00.0`（pcie2 RP） | 5.0 GT/s PCIe | 1 | **5.0 GT/s PCIe** | **1** |
| `0002:01:00.0`（mt7996e-hif） | 5.0 GT/s PCIe | 1 | 8.0 GT/s PCIe | 2 |

## 5. lspci 关键行摘录

```text
0000:00:00.0 PCI bridge: MEDIATEK Corp. Device 6899 (rev 01)
    LnkCap: Port #1, Speed 8GT/s, Width x2, ASPM L0s L1
    LnkSta: Speed 8GT/s, Width x2
    LnkCap2: Supported Link Speeds: 2.5-8GT/s, Crosslink- Retimer- 2Retimers- DRS-
    LnkCtl2: Target Link Speed: 8GT/s

0000:01:00.0 Network controller: MEDIATEK Corp. MT7996 primary link ...
    LnkCap: Port #1, Speed 8GT/s, Width x2
    LnkSta: Speed 8GT/s, Width x2
    LnkCap2: Supported Link Speeds: 2.5-8GT/s
    LnkCtl2: Target Link Speed: 8GT/s

0002:00:00.0 PCI bridge: MEDIATEK Corp. Device 6899 (rev 01)
    LnkCap: Port #1, Speed 5GT/s, Width x1
    LnkSta: Speed 5GT/s, Width x1
    LnkCap2: Supported Link Speeds: 2.5-5GT/s
    LnkCtl2: Target Link Speed: 5GT/s

0002:01:00.0 Network controller: MEDIATEK Corp. MT7996 secondary link ...
    LnkCap: Port #1, Speed 8GT/s, Width x2
    LnkSta: Speed 5GT/s (downgraded), Width x1 (downgraded)
    LnkCap2: Supported Link Speeds: 2.5-8GT/s
    LnkCtl2: Target Link Speed: 8GT/s
```

## 6. PCIe 配置空间解析（sysfs config 二进制）

| 设备 | LnkCap speed/width | LnkCap2 速度矢量 | LnkSta | 结论 |
|---|---|---|---|---|
| `0000:00:00.0` | 8GT/s x2 | `0x0e`（2.5+5.0+8.0） | 8GT/s x2 | Gen3 x2 |
| `0000:01:00.0` | 8GT/s x2 | `0x0e`（2.5+5.0+8.0） | 8GT/s x2 | Gen3 x2 |
| `0002:00:00.0` | **5GT/s x1** | **`0x06`（2.5+5.0，无 8.0）** | 5GT/s x1 | **Gen2 x1 上限** |
| `0002:01:00.0` | 8GT/s x2 | `0x0e`（2.5+5.0+8.0） | 5GT/s x1 | 端点能力 Gen3 x2，被根端口限制 |

> LnkCap2 速度矢量位定义（Linux `PCI_EXP_LNKCAP2_SLS_*`）：`0x02`=2.5GT/s，`0x04`=5.0GT/s，`0x08`=8.0GT/s。

## 7. dmesg / 中断

- `dmesg | grep -iE "pci 000[02]:|pcie|bandwidth"` 无匹配（本机当前无 PCIe 带宽告警或重训日志）。
- `/proc/interrupts` 未在本轮截取；issue #16 历史值：`mt7996e` 333196 次 vs `mt7996e-hif` 22848 次，hif 非主数据面。

## 8. D0 判据核对

| D0 判据 | 结果 |
|---|---|
| 根端口 `0002:00:00.0` LnkCap2 报 Gen3（8.0 GT/s） | **否**：`Supported Link Speeds: 2.5-5GT/s` |
| 根端口 `max_link_speed` | 5.0 GT/s PCIe（Gen2） |
| 端点 `0002:01:00.0` LnkCap2 | 2.5-8GT/s（端点本身支持 Gen3 x2） |
| SSTR / SCU 寄存器读取 | 不可用（/dev/mem 被内核拒绝，见 §2） |

**结论**：pcie2 的根端口未声明 Gen3 能力。按计划 D0 终止判据，**不实施 pcie2 Gen3 x1 实验补丁**；`pcie2` Gen2 x1 固化为板级正确拓扑，Gen3 x1 降级为长期上游/厂商跟踪项。

## 9. 后续动作

- 更新 `docs/FIXES.md` F56：记录 LnkCap2 实测证据，状态改为“板级上限已实锤”。
- 更新 `CONTEXT.md` / `README.md` / `docs/ROADMAP.md`：pcie2 Gen2 x1 为板级正确拓扑；Gen3 降级为上游跟踪。
- `docs/PCIe-GEN3-PLAN.md` 状态更新为 D0-stop。
