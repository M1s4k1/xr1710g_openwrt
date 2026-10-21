# EN7581/XR1710G 全 PCIe Gen3 深度调研与实施验证方案

> 目标：把所有可用的 PCIe 链路提升到 Gen3（8.0 GT/s）并形成可验证的结论。
> 状态：**D0-stop（2026-08-24）**——pcie2 根端口 LnkCap2 仅报 2.5/5GT/s，不声明 Gen3；不实施 pcie2 Gen3 实验补丁，Gen2 x1 固化为板级正确拓扑。详见 `docs/acceptance-results/2026-08-24-pcie-gen3-baseline.md`。
> 关联 issue：#16（pcie2 Gen2 x1）；上游 PR：#21978、#20149；本仓库补丁：`patches/root/9001-xr1710g-dts.patch`。

---

## 1. 结论先行（TL;DR）

| 链路 | 当前实机状态 | Gen3 目标 | 可行性 |
|---|---|---|---|
| `pcie0`（domain 0，主 `mt7996e` 14c3:7990） | **8.0 GT/s x2（已是 Gen3 x2）** | 保持 Gen3 x2 | 已达成，只需回归保护 |
| `pcie1`（domain 1） | 被 `pcie0` 作为 sister MAC 吸收为 x2 第二 lane | 随 pcie0 Gen3 x2 | 已达成 |
| `pcie2`（domain 2，`mt7996e-hif` 14c3:7991） | **5.0 GT/s x1（Gen2 x1）** | 目标 Gen3 x1（8 GT/s x1）；**x2 不可行** | **未验证，存在硬件上限风险**；本方案给出去/不去决策与实验路径 |

核心判断：
- **pcie2 开 x2 不可能**：EN7581 只有 `pcie0+pcie1` 这一对 MAC 能 bonding；`pcie2` 与 USB3 共享 serdes、物理单 lane，且 `airoha,en7581-pcie` 驱动只对 `pcie0` 的 `num-lanes=2` 做 sister MAC 映射。上游 PR #20149 的 serdes 配置也明确是 `usb2 = "pcie2_x1"`。
- **pcie2 能否 Gen3 x1 是未知数**：上游 PR #21978 的 Gen3 重训只覆盖 x2 路径；PR 讨论中补丁作者明确表示“pcie2 可能只是 x1，OEM 固件同样报 4 Gb/s available bandwidth”。pcie2 的 PHY 是 USB3 共享 PHY（USB3 Gen1 = 5 Gbps），**它是否能跑到 PCIe Gen3 8 GT/s 尚无公开证据**。因此本方案把“PHY 能力判定”作为第一道门，而不是直接写补丁。
- **如果 pcie2 PHY 只能 5 Gbps，则“所有 PCIe 提升到 Gen3”在本硬件上不可达**；此时应固化为“pcie0 x2 Gen3 + pcie2 x1 Gen2 是板级正确拓扑”，并把 pcie2 Gen3 列为上游/厂商跟踪项。

---

## 2. 现状盘点

### 2.1 实机实测（来自 issue #16，2026-08-22）

```
# 主 mt7996e（pcie0）
# cat /sys/bus/pci/devices/0000:01:00.0/current_link_speed
8.0 GT/s PCIe
# cat /sys/bus/pci/devices/0000:01:00.0/current_link_width
2

# mt7996e-hif（pcie2）
# cat /sys/bus/pci/devices/0002:01:00.0/current_link_speed
5.0 GT/s PCIe
# cat /sys/bus/pci/devices/0002:01:00.0/current_link_width
1
# cat /sys/bus/pci/devices/0002:01:00.0/max_link_speed
8.0 GT/s PCIe
# cat /sys/bus/pci/devices/0002:01:00.0/max_link_width
2
```

- 端点 `7991` 最大能力 Gen3 x2；根端口 `0002:00:00.0` 当前上限 Gen2 x1。
- `/proc/interrupts`：`mt7996e` 333196 次 vs `mt7996e-hif` 22848 次，hif 明显不是当前主数据面。

### 2.2 本仓库 DTS 补丁

`patches/root/9001-xr1710g-dts.patch`：
- `&pcie0`：`reg-names = "pcie-mac","sec-pcie-mac"` + 双 lane reset + `num-lanes = <2>` → 主 Wi-Fi 已是 Gen3 x2。
- `&pcie2`：只有 `status = "okay"` + `pinctrl-0 = <&pcie2_rst_pins>`，无 `num-lanes`/PHY lane 伪造。

### 2.3 上游内核拓扑（openwrt main `an7581.dtsi`）

| 控制器 | 地址 | PHY | reset-names | 用途 |
|---|---|---|---|---|
| `pcie0` | `0x1fc00000` | `pciephy`（专用 PCIe Gen3 PHY） | `phy-lane0`, `perstout` | 主 Wi-Fi lane0 |
| `pcie1` | `0x1fc20000` | `pciephy` | `phy-lane1`, `perstout` | 可被 pcie0 bond 为 x2 |
| `pcie2` | `0x1fc40000` | `usb1_phy PHY_TYPE_USB3` | `phy-lane2`, `perstout` | hif/第二 PCIe x1 |

关键差异：`pcie2` 的 PHY 不是专用 PCIe Gen3 PHY，而是 **USB3 共享 serdes**（`usb1_phy`，SoC 文档/驱动称之为 USB2 serdes 可复用作 PCIe）。`pcie0`/`pcie1` 的 PHY 驱动（`phy-airoha-pcie.c`）明确提供 PCIe Gen3 初始化；`phy-airoha-usb.c` 对 PHY_TYPE_USB3 在 PCIe 模式下只做 mux 切换，**没有任何 Gen3 校准序列**。

---

## 3. 深度调研

### 3.1 上游 PR/补丁族谱

| 补丁/PR | 内容 | 位置 | 对本计划的意义 |
|---|---|---|---|
| PR #20149 | SCU SSR serdes 配置：`wifi1/wifi2=pcie0_x2`、`usb2=pcie2_x1` | 未合入 main（已关闭）；逻辑由 DTS+PHY 驱动替代 | 证明 pcie2 官方/社区定位就是 **x1**，不是 x2 |
| PR #21978 补丁 911（25.12） | clk 回调只管理 refclk，PERST 交由 PCIe 驱动 | `patches-6.12/911` | 6.18 由 609-02 重构吸收 |
| PR #21978 补丁 912（25.12） | x2 初始化 + **训练后速度检查，Gen2 则 serdes 重训强制 Gen3** | `patches-6.12/912` | Gen3 重训只写在 **x2-mode 分支内**；是 pcie2 Gen3 移植的起点 |
| 6.18 `609-02` | 专用 PERSTOUT reset 控制器（bits 29/26/16） | `patches-6.18/609-02` | pcie2 PERST 可由 reset 框架控制 |
| 6.18 `609-04` | `num-lanes=2` + sister MAC 映射 + 双 lane EQ | `patches-6.18/609-04` | pcie0 x2 上游化；**不消费 `airoha,x2-mode` 旧属性，也不含 Gen3 serdes 重训** |
| 6.18 `913` | clk hw init 时 reset PCIE_HB（暖启动 PCIe 修复） | `patches-6.18/913` | 所有 Gen3 训练必须与 913 共存，避免暖启动回归 |
| 6.18 `220-07` | AN7581 USB PHY 驱动 | `patches-6.18/220-07` | pcie2 PHY 驱动；PCIe 模式下 init/power_on 直接 return 0，无 Gen3 校准 |
| 6.18 `220-10` | PCIe 驱动对 EN7581 调 `phy_set_mode(PHY_MODE_PCIE)` | `patches-6.18/220-10` | 确保 pcie2 mux 切到 PCIe |
| 社区 `910-02` | clk init 清 `REG_NP_SCU_SSTR` bit3（USB_PCIE_SEL=PCIe） | naoki66/lvcdy 等 XR1710G 分支 | 可能是 pcie2 早期枚举保险；主树依赖 220-10 运行时切换。待实测对比 |

### 3.2 关键寄存器（NP_SCU/SCU，从 609-02、912、社区 913 提取）

> 基地址：`scuclk` = `0x1fb00000`。以下偏移以 SCU 基地址为基准；写寄存器前必须先读回并记录原始值。

| 寄存器 | 偏移 | 位 | 含义 | 来源 |
|---|---|---|---|---|
| `NP_SCU_CTRL_REG` / `REG_NP_SCU_PCIC` | `0x88` | 29 | PERSTOUT0（pcie0） | 609-02/912 |
| | | 26 | PERSTOUT1（pcie1） | 609-02/912 |
| | | 16 | PERSTOUT2（pcie2） | 609-02/912 |
| | | 1:0 | serdes mux（x2=2） | 912 |
| `NP_SCU_LANE_CFG1` | `0x834` | 27 | PCIE1 serdes reset（set=assert） | 社区 913 |
| | | 26 | PCIE0 serdes reset（set=assert） | 社区 913 |
| `NP_SCU_LANE_CFG0` | `0x830` | 27 | PCIE2 serdes reset（set=assert） | 社区 913 |
| | | 8 | XSI PHY reset | 社区 913 |
| | | 7 | XSI MAC reset | 社区 913 |
| `REG_NP_SCU_SSTR` | `0x9c` | 3 | USB/PCIe mux：0=PCIe，1=USB3 | 220-07/910-02 |

> 注意：`NP_SCU_LANE_CFG0` 的 bit7/8/27 与 `NP_SCU_LANE_CFG1` 的 bit26/27 来自社区对 912/913 的逆向，**尚无厂商 datasheet 背书**。实施前必须用 devmem 读回当前值，并与 `lspci` 链路状态做交叉验证；不要在基线设备上盲写。

### 3.3 训练时序（PR #21978/912 描述）

正确时序（EN7581 专用，与普通 MediaTek Gen3 不同）：
1. 先通过 SCU 断言 serdes reset 与目标端口 PERST；
2. PHY init / power-on（pcie2 的 USB PHY 在 PCIe 模式返回 0）；
3. 使能 refclk（clk 驱动只做 refclk，609-02）；
4. 配置 MAC EQ preset / PIPE4（必须在时钟使能后写，否则写丢失）；
5. 释放 serdes reset、释放 PERST，开始 training；
6. **读 Link Status / LnkSta speed**：
   - 若 speed=3（Gen3），完成；
   - 若 speed=1/2（Gen1/2），说明 MAC 在复位期间未正确 latch PHY 的 Gen3 capability，需要做一次 serdes reset toggle 后重新 training。

### 3.4 关键结论：pcie2 的 Gen3 重训缺口

- 912 的 serdes 重训逻辑位于 `if (pcie->x2_mode && pcie->np_scu)` 分支，且 toggle bits 是 lane0/1（`LANE_CFG1 BIT(26)|BIT(27)` + `LANE_CFG0 BIT(7)|BIT(8)`）。
- 6.18 的 609-04 连 912 的 x2 Gen3 重训都没有携带；pcie0 x2 在 XR1710G 上实机已是 Gen3，因此暂不需要。
- **pcie2（x1、USB PHY）没有现成的 Gen3 重训路径**。要做，就必须：
  1. 确认 pcie2 的 PHY 本身支持 8 GT/s；
  2. 找到 pcie2 lane 正确的 serdes reset/toggle 位（候选：`LANE_CFG0 BIT(27)` 或 bit7/8 组合）；
  3. 在 PCIe 驱动中为 pcie2 x1 增加“训练后测速 → Gen2 则 serdes toggle 再训练”的实验路径。

---

## 4. 决策门与总体路线

### 4.1 决策门 D0：pcie2 PHY 能力判定（先做，不写补丁）

**目标**：回答“pcie2 的 USB3 共享 PHY 是否具备 PCIe Gen3（8 GT/s）能力”。

判定手段（按成本从低到高）：
1. **只读取证（本仓库可立即做）**：
   - `lspci -vv -s 0002:00:00.0` 读根端口 LnkCap2 的 Supported Link Speeds 矢量（Gen1/Gen2/Gen3 位）；
   - `cat /sys/bus/pci/devices/0002:01:00.0/max_link_speed` 已知端点支持 Gen3；
   - `devmem 0x1fb0009c` 读 SSTR bit3，确认 mux 在 PCIe；
   - `devmem 0x1fb00088` / `0x1fb00830` / `0x1fb00834` 读当前 serdes/PERST 值并记录。
2. **厂商资料/上游渠道核实**：
   - 追 AN7581 datasheet/TRM：确认 USB2 serdes（`AIROHA_SCU_SERDES_USB2`）复用为 PCIe 时最高速率；
   - 在 openwrt/lede 社区问 `Ansuel`/`rchen14b`/`hurrian`：pcie2 是否曾被训练到 Gen3 x1。
3. **最小化实验（需设备配合，见 Phase 2）**：
   - 在实验档上写一个只对 pcie2 生效的 serdes 重训补丁，dmesg 打印重训前后 LnkSta，观察 `current_link_speed` 是否变为 `8.0 GT/s PCIe`。
   - 若重训 3 轮仍 Gen2，且根端口 LnkCap2 仍不报 Gen3，基本可判定 PHY/板级上限 Gen2；终止 Gen3 x1，转入固化文档。

**通过判据**：任一路径证明 PHY 支持 Gen3 → 继续 Phase 2 完整实施。
**终止判据**：三路证据均不支持 Gen3 → **不实施 pcie2 Gen3 补丁**；更新 `docs/FIXES.md` F56 与 CONTEXT/README，将 pcie2 Gen2 x1 固化为板级正确拓扑，并把“pcie2 Gen3”降级为长期上游跟踪。

### 4.2 总体路线

```
D0: pcie2 PHY 能力判定
 ├─ 不支持 Gen3 → D0-stop: 文档固化，issue/PR 跟踪，方案终止
 └─ 支持 Gen3 → Phase 1 基线 → Phase 2 实验补丁 → Phase 3 实机验证 → Phase 4 毕业/固化
```

---

## 5. 实施阶段

### Phase 0：只读取证与基线采集（本仓库可立即执行）

**执行人/设备**：有 SSH 实机权限的维护者；`root@192.168.123.1`。

**采集命令**：

```bash
DEV=root@192.168.123.1
ssh $DEV 'lspci -vv -s 0000:00:00.0 | grep -E "LnkCap|LnkSta|Speed|Width"' 
ssh $DEV 'lspci -vv -s 0000:01:00.0 | grep -E "LnkCap|LnkSta|Speed|Width"'
ssh $DEV 'lspci -vv -s 0002:00:00.0 | grep -E "LnkCap|LnkSta|Speed|Width"'
ssh $DEV 'lspci -vv -s 0002:01:00.0 | grep -E "LnkCap|LnkSta|Speed|Width"'
ssh $DEV 'for d in 0000:01:00.0 0002:01:00.0; do
  echo ==$d==;
  cat /sys/bus/pci/devices/$d/current_link_speed;
  cat /sys/bus/pci/devices/$d/current_link_width;
  cat /sys/bus/pci/devices/$d/max_link_speed;
  cat /sys/bus/pci/devices/$d/max_link_width;
done'
ssh $DEV 'dmesg | grep -iE "pci 000[02]:|pcie|bandwidth" | tail -40'
# 寄存器只读（devmem 已预装；地址以 SCU base=0x1fb00000 为基准）
ssh $DEV 'for r in 0x1fb0009c 0x1fb00088 0x1fb00830 0x1fb00834; do
  printf "%s = " $r; devmem $r;
done'
```

**交付物**：`docs/acceptance-results/2026-08-2x-pcie-gen3-baseline.md`（含 lspci 全文、sysfs、寄存器快照、dmesg 摘录、结论）。

### Phase 1：pcie0/pcie1 Gen3 x2 回归保护

**现状**：主链路已是 Gen3 x2。但后续 pcie2 实验可能触碰 SCU 公共寄存器，必须先有稳定基线。

**动作**：
1. 在 `scripts/device-hw-probe.sh` 或新脚本 `scripts/device-pcie-probe.sh` 中增加 **PCIe 链路快照断言**：
   - `0000:01:00.0` 必须 `8.0 GT/s PCIe` + width `2`；
   - `0002:01:00.0` 记录当前值（Gen2 x1 允许，作为基线）；
   - 冷启动、`wifi down/up`、`reboot` 三轮各采一次，确认 pcie0 x2 Gen3 稳定、无暖启动回退（913 HB reset 生效）。
2. 回归项：三频 AP、NPU offload、CLIENTS 计数、`device-hw-probe.sh` 全绿。
3. 成功判据：连续 3 轮 pcie0 保持 Gen3 x2，无 `4.000 Gb/s available PCIe bandwidth` 的 **0000:01:00.0** 报错。

### Phase 2：pcie2 Gen3 x1 实验补丁（仅在 D0 通过后启动）

**补丁命名**（遵循仓库惯例）：
- `patches/root/9032-xr1710g-pcie2-gen3-x1-retrain.patch`
  - 内含 `target/linux/airoha/patches-6.18/9995-pcie-mediatek-gen3-en7581-pcie2-gen3-retrain.patch`
  - `MANIFEST` / `ORDER` 标记 `#EXP`。

**补丁设计要点**：

1. **DTS**：给 `&pcie2` 增加实验属性（不进 default）：
   ```dts
   /* #EXP 实验：pcie2 Gen3 x1 重训（D0 通过后才启用） */
   airoha,serdes-retrain = <1>;
   ```
   或复用社区属性名 `airoha,serdes-lanes-mask = <0x4>`，但驱动必须真正消费它；方案评审时二选一。

2. **驱动改动**（基于 6.18 `pcie-mediatek-gen3.c` 609-04 之后的状态）：
   - 在 `mtk_pcie_en7581_power_up()` 中，对 `pcie2`（`reg_base == 0x1fc40000` 或 DT 属性）增加非 x2 的 Gen3 检查：
     - PERST2 只管理 bit16（不要像旧 912 那样一次 assert 全部三个 PERST）；
     - 训练完成 `msleep(800/1000)` 后，从 Link Status/LnkSta 读当前 speed；
     - 若 speed < 3，则：
       a. assert pcie2 serdes reset（候选位：`NP_SCU_LANE_CFG0 BIT(27)`，必要时叠加 bit7/8）；
       b. `msleep(100)`；
       c. deassert 同一组 bits；
       d. 等待再训练 `msleep(2000)`；
       e. 重读 speed；
     - 最多重试 2 次；每次都要打印 `dev_info`。
   - **必须避免**：不要调用旧 912 的 `LANE_CFG1 BIT(26)|BIT(27)`（那是 pcie0/pcie1 的 reset，会打挂主链路）。

3. **PHY 侧**（如 D0 显示需要）：
   - 若根端口 LnkCap2 始终不报 Gen3，可能需要在 `phy-airoha-usb.c` 为 PCIe 模式补充 Gen3 相关 serdes 校准（需厂商 TRM；当前公开代码为空实现）。
   - 若 SSTR bit3 在 clk init 时被置成 USB，则同步移植 910-02 的清 bit 逻辑（`REG_NP_SCU_SSTR BIT(3)`）。

4. **构建验证**：
   ```bash
   ./scripts/apply-patches.sh tmp/openwrt-src --dry-run --experimental
   ./scripts/audit-patches.sh --experimental
   ```
   通过后以 `experimental` 档构建实机固件。

### Phase 3：实机验证矩阵

**刷机**：按 `docs/FLASHING.md` HTTP U-Boot 恢复页刷入 experimental 产物（新布局 UBI 2.0）。

| 编号 | 测试项 | 通过判据 |
|---|---|---|
| V1 | pcie2 重训日志 | dmesg 出现 `pcie2: link at Gen2, retraining` / `pcie2: link at Gen3, no retry needed` 等新日志 |
| V2 | pcie2 链路速度 | `/sys/bus/pci/devices/0002:01:00.0/current_link_speed` = `8.0 GT/s PCIe`；width=1 |
| V3 | pcie2 根端口能力 | `lspci -vv -s 0002:00:00.0` LnkCap2 报 Gen3 支持（若仍 Gen2，判 PHY 硬件限制） |
| V4 | pcie0 回归 | `0000:01:00.0` 仍为 `8.0 GT/s PCIe` x2；三频 AP 正常；`wifi down/up` 5 轮不复发 |
| V5 | hif 功能 | `mt7996e-hif` 出现在 lspci；`/proc/interrupts` 中 hif 中断递增；Wi-Fi 客户端可关联、NPU CLIENTS 计数正常 |
| V6 | 稳定性 | 冷启动 + `reboot` 3 轮，pcie2 速度不回退 Gen2（暖启动 913 协同） |
| V7 | USB 回归（如板上有 USB） | 确认 USB3 口无退化；若 XR1710G 无 USB3 引出，则记录“不适用”并确认 SSTR bit3=PCIe 后 USB2 仍正常（如有） |
| V8 | 吞吐相关性 | 外部对端 iperf3 打满 5G/6G，观察 hif 中断/吞吐是否因 Gen3 x1 提升；**禁止本机 iperf3 当转发面判据** |

### Phase 4：毕业 / 固化

- 若 V1–V8 全过：
  - 将 9032 从 `#EXP` 转正 default；
  - 更新 `docs/FIXES.md` F56（pcie2 Gen3 x1 已实现，引用 9032）；
  - 更新 `CONTEXT.md` MT7996 词条（pcie2 为 Gen3 x1）；
  - 重跑 `docs/ACCEPTANCE.md` C3/C4 外部对端吞吐，记录 hif 带宽变化。
- 若 V2/V3 不过但 V4–V7 正常：
  - 判定 pcie2 PHY/板级 Gen2 x1 为硬件上限；
  - 不转正 9032，保留 `#EXP` 或删除；
  - 文档固化：pcie2 Gen2 x1 是正确拓扑；把“pcie2 Gen3”跟踪项挂到 ROADMAP 长期上游；
  - 关闭 Gen3 x1 计划，避免后续重复投入。

---

## 6. 风险与回退

| 风险 | 概率 | 影响 | 缓解/回退 |
|---|---|---|---|
| pcie2 Gen3 实验打挂主 pcie0 x2 | 中 | 高：三频 Wi-Fi 不可用 | 寄存器写只允许在 pcie2 对应 bits；代码评审禁止出现 `LANE_CFG1 BIT(26/27)`/PERST0/1 写操作；实验档单独构建 |
| pcie2 链路训练失败（down） | 中 | 中：hif 缺失，可能影响 NPU offload | 驱动重试后保留 Gen2 回退；DTS 属性关闭即回退；不留默认启用路径 |
| 暖启动 pcie0 回退 Gen2 | 低 | 高 | 保持 913 HB reset；Phase 3 V6 三轮回测 |
| USB3 共享 PHY 被切到 PCIe 后 USB 异常 | 低 | 低（XR1710G 无 USB3 引出则 NA） | V7 回归；必要时 SSTR bit3 恢复 USB |
| 寄存器位定义错误（社区逆向不可靠） | 中 | 高 | Phase 0 只读基线；写入前保存原始值；单次实验可恢复；争取厂商 TRM 确认 |
| 上游 6.18 后续改动漂移 | 中 | 中 | 2h sync 覆盖实验档 dry-run；补丁基于 prepare 后源码生成 |
| 实验档构建/刷机影响现有 CI | 低 | 中 | 仅 `#EXP`，不影响 stock/oc |

---

## 7. 交付物清单

1. `docs/PCIe-GEN3-PLAN.md`（本文件）。
2. `docs/acceptance-results/2026-08-2x-pcie-gen3-baseline.md`（Phase 0 结果）。
3. `scripts/device-pcie-probe.sh`（可选：PCIe 链路快照与断言脚本）。
4. `patches/root/9032-*`（仅当 D0 通过）。
5. `docs/FIXES.md` F56 更新（Gen3 x1 达成或固化为硬件上限）。
6. `CONTEXT.md` / `README.md` / `docs/ACCEPTANCE.md` 同步更新。

---

## 8. 决策记录

- 不伪造 `&pcie2` 的 `num-lanes=2`：驱动不消费该属性，x2 靠 sister MAC，pcie2 没有 sister MAC。
- 不在 pcie0/1 的 reset bits 上做 pcie2 实验，避免主链路回归。
- 先判定 PHY 能力，再写补丁；不通过就不上实验档。
- Gen3 x1 即使成功，也只代表链路速率提升，不代表 Wi-Fi 吞吐线性提升；最终以外部对端 iperf3 与 hif 中断/卸载计数为准。
- **D0 判定（2026-08-24）**：实机 `lspci -vv` + sysfs 配置空间解析确认 `0002:00:00.0` 根端口 `LnkCap2` 仅 2.5/5GT/s（`LnkCtl2 Target=5GT/s`、`max_link_speed=5.0 GT/s`），而端点 `0002:01:00.0` 为 2.5-8GT/s。根端口不声明 Gen3 → 按终止判据 **D0-stop**：pcie2 Gen2 x1 固化为板级正确拓扑，pcie2 Gen3 降级为上游/厂商跟踪，不进入 Phase 2/3。

