# PCIe AER 只读诊断与判读（FIXES F116）

> 探针：`scripts/device-pcie-aer-probe.sh`（默认**只读**，无任何写操作）
> 适用设备：Gemtek XR1710G（Airoha AN7581 + MT7996 Wi-Fi7）。MT7996 hif 走 PCIe，BDF = `0002:00:00.0`。

## 一、为什么看 AER

社区已有**两台 W1700K V1.1 无线芯片永久失效**案例，日志链固定为：

```
14c3:6899 Correctable RxErr
  → Uncorrectable Fatal [ 5] SDES / [14] CmpltTO
  → mt7996e_hif AER: can't recover
  → Root Port link has been reset
  → device recovery failed
  → /sys/bus/pci/devices 里设备消失
```

AER（Advanced Error Reporting）是**唯一**能区分下面两种情形的观测面：

| 情形 | AER 形态 | 性质 |
|---|---|---|
| 链路劣化但活着 | 只有 Correctable（RxErr/BadTLP/BadDLLP…）或 Non-Fatal | **可恢复**，需持续观测计数增速 |
| 芯片/PHY 层死亡 | Uncorrectable **Fatal**（SDES / CmpltTO）→ root port 重置 → recovery failed → 设备消失 | **非软件可修**，需 RMA/换板 |

本仓台账 F56（hif 仅 Gen2 x1 板级上限）与 F95（整机复位后 NPU/chip full reset failed）此前没有 AER 视角；
本项补上后，三者构成同一条 Root Port 物理路径的"能力上限 / 复位可靠性 / 错误观测"三面。

## 二、只读用法

```sh
./scripts/device-pcie-aer-probe.sh                        # 只读；输出 /tmp/device-pcie-aer-probe.log
AER_BDF=0002:00:00.0 ./scripts/device-pcie-aer-probe.sh   # 指定 BDF
DEVICE_HOST=root@192.168.123.1 OUT_PREFIX=/tmp/aer ./scripts/device-pcie-aer-probe.sh
```

只读模式做五件事（每步都打印命令 + 原始输出，整段可直接贴进 issue）：

1. **W0/W1 设备存在性与枚举**：`/sys/bus/pci/devices/*` + `lspci -nn` + 每个设备的 link speed/width/driver；
2. **W2 三元寄存器**：对每个设备读 config 的 `seek=131 / 129 / 132`（`dd … | hexdump -C`），小端解析 + 逐位标注；
3. **W3** `lspci -vv -s <bdf>` 的 `Advanced Error Reporting` 段；
4. **W4** `dmesg | grep -iE 'aer|pcieport|mt7996e_hif|can't recover'`（末 60 行）；
5. **W6 汇总**（可贴进 issue）+ **结尾判读结论行**。

退出码：`0` 正常；`2` SSH 不可达（预检失败，`ConnectTimeout=8` + `BatchMode`，不挂死、不等密码）；
`3` 目标 BDF 不在 `/sys/bus/pci/devices`（**设备已被 AER 摘除**，本身就是"硬件死亡"的直接证据）。

## 三、判读表

### 3.1 寄存器语义与基线（相对设备 config 起点，4 字节字）

| 寄存器 | dd 取法 | 偏移 | 语义 | 本机基线值（小端字节） |
|---|---|---|---|---|
| Uncorrectable Error Severity | `bs=4 skip=131 count=1` | `0x20C` | 该未纠正错误位是 **Fatal(1)** 还是 Non-Fatal(0) | `0x00462030`（`30 20 46 00`） |
| Uncorrectable Error Status | `bs=4 skip=129 count=1` | `0x204` | 已发生的未纠正错误（写 1 清除） | 启动基线应为 `0x00000000` |
| Correctable Error Status | `bs=4 skip=132 count=1` | `0x210` | 已发生的可纠正错误（写 1 清除） | 启动基线应为 `0x00000000` |

基线 severity `0x00462030` 的置位含义（bit4=DLP、bit5=**SDES**、bit13=FCP、bit17=RxOF、bit18=MalfTLP、bit22=UncorrIntErr 均为 Fatal）——
即 **SDES 出厂默认就是 Fatal**，这不是被谁改坏的；要让它走可恢复流程必须显式降级（见第五节）。

> ⚠ 读不到 ≠ 健康：若某设备没有扩展配置空间（或已被摘除），`seek=131/129/132` 会读不到 4 字节，
> 脚本打印 `(读取失败：无扩展配置空间，或设备已被摘除)` 并在汇总里给出 `扩展配置可读(0x20C): 0`，
> 此时**不能**用"全 0"判链路健康。MT7996 hif 有完整 4KB 扩展配置，正常应读到基线 `30 20 46 00`。

### 3.2 位级判读 → 结论

位名取自本仓内核树 `drivers/pci/pcie/aer.c` 的 `aer_uncorrectable_error_string` / `aer_correctable_error_string`。

| 寄存器 | 位 | 名称 | 含义 | 观测到的值 | 结论 |
|---|---|---|---|---|---|
| Severity 0x20C | 5 | **SDES** | Surprise Down：链路对端**意外消失** | `1`（基线 `0x00462030`） | 出厂 Fatal；`0`=已被降级（见第五节） |
| Severity 0x20C | 4 / 13 / 17 / 18 / 22 | DLP / FCP / RxOF / MalfTLP / UncorrIntErr | 链路层协议错、流控错、接收溢出、畸形 TLP、内部错 | `1`（基线） | Fatal 语义，不可当"噪声"忽略 |
| UncorrSts 0x204 | 5 | **SDES** | 已发生 Surprise Down | `1` | **硬件/PHY 层失效**：对端消失，软件无法恢复 |
| UncorrSts 0x204 | 14 | **CmpltTO** | Completion Timeout（对端不再回应） | `1` | 与 SDES 同时出现 = 设备/链路已死 |
| UncorrSts 0x204 | 4 | DLP | Data Link Protocol Error | `1` | Fatal；链路层训练/同步崩坏 |
| UncorrSts 0x204 | `ues & usev` | — | Fatal 位集合 | `≠0` | 至少一个 Fatal 已发生 → 观察 root port 是否重置 |
| CorrSts 0x210 | 0 | **RxErr** | Receiver Error（社区失效链的第一个信号） | `1` | **可恢复**，但属链路劣化早期信号，需看增速 |
| CorrSts 0x210 | 6 / 7 / 8 / 12 / 13 | BadTLP / BadDLLP / Rollover / Timeout / NonFatalErr | 可纠正的 TLP/DLLP/重放/超时 | `1` | **可恢复**；持续增长 ⇒ PHY/走线劣化 |
| 任意 | `0x00000000` | — | 无任何置位 | `0` | 链路健康（或本次启动未触发） |

### 3.3 三种结论与对应动作

| 结论 | AER 判据 | 动作 |
|---|---|---|
| **可恢复** | 仅 Correctable（或仅 Non-Fatal 未纠正） | 记录计数并定期重跑本脚本比对增速；不改 severity、不动硬件 |
| **需降级观测** | 有 Fatal 位但 **无** root port link reset / recovery failed | 先用只读留证；确认硬件仍可枚举后，才可 `AER_DEMOTE=1` 降级 SDES 继续观测（第五节） |
| **硬件失效** | **Fatal + Root Port link reset + device recovery failed**（或 BDF 已从 sysfs 消失） | 停止软件侧折腾：RMA / 换板；把 W0–W6 输出整段贴进 issue |

> 第四种情形（不是结论，是"读数无效"）：`扩展配置可读(0x20C): 0` ⇒ 该设备无 AER 能力或已被摘除，
> 任何"全 0"读数都不作数——先查 BDF 是否还在 `/sys/bus/pci/devices`（脚本 W0 会直接以退出码 3 报出）。

## 四、SDES=Fatal ⇒ 链路对端消失（Surprise Down）

判读链（脚本结尾会打印同样的结论行）：

```
Severity bit5 (SDES) = 1   →  该错误按 Fatal 处理，内核直接走 aer_root_reset / link reset，
                              不给驱动"纠正并继续"的机会
Status   bit5 (SDES) = 1   →  事件已经发生：链路对端（MT7996 hif）在链路层"意外消失"
                              伴随 [14] CmpltTO（对端不再回 completion）
+ dmesg "can't recover" / "link has been reset" / "device recovery failed"
                           ⇒  硬件/PHY 层失效，非软件可修
```

要点：**降级（把 bit5 的 severity 由 1 改 0）不修复任何东西**——它只把该错误从 Fatal 改成 Non-Fatal，
让链路层不再立刻 reset，从而"继续看到"后续寄存器/dmesg 证据，便于定位是 PHY、走线、供电还是固件。

## 五、降级观测（AER_DEMOTE=1）与风险

```sh
AER_DEMOTE=1 ./scripts/device-pcie-aer-probe.sh
```

脚本先打印将写入的字节、目标设备，再写：

```sh
printf '\x10\x20\x46\x00' | dd of=/sys/bus/pci/devices/0002:00:00.0/config bs=4 seek=131 count=1
# 0x00462030 → 0x00462010：仅清 bit5（SDES 的 Fatal 位）
```

风险与限制：

- **需 reboot 或重新 enable（`echo 1 > .../enable`）才能完全还原**该 severity 位；脚本不会自动还原。
- **仅在确认硬件仍可枚举时使用**：BDF 已消失时脚本走 W0 分支直接退出 3，不会对不存在的 config 写。
- 写操作**只**在 `AER_DEMOTE=1` 分支内；默认路径对 `config` 只有 `dd if=` 读，无任何 `dd of=`。
  自证：`grep -n -B3 'dd of=' scripts/device-pcie-aer-probe.sh`（唯一可执行写点在 `if [ "$DEMOTE" = "1" ]` 之内）。
- 降级后一切 Fatal 判读都要**回退到"以 Status 位 + dmesg 链"为准**，不要因为 severity 变 0 就判"已修好"。

## 六、与 F56 / F95 的关系（AER 视角）

- **F56（hif 仅 Gen2 x1 = 板级上限）**：根端口不声明 Gen3，链路裕度更小。AER 视角下，同样的
  Correctable RxErr/BadDLLP 在 Gen2 x1 上不会因"提速"缓解——**没有"降速保命"这条退路**，
  因此 Correctable 计数增长应视为硬信号，而不是可调优项。
- **F95（整机复位后 NPU/chip full reset failed）**：整机复位与 AER root port link reset 命中的是
  同一条 Root Port 路径。若复位后 AER 出现 SDES/`device recovery failed`，说明复位后**链路本身没起来**，
  与 F95 的 NPU/chip 复位可靠性问题叠加，属同一物理层的两个故障面。
- 二者都不新增补丁；AER 视角的唯一载体是本脚本 + 本文档（零补丁成本）。

## 七、参考

- 探针：`scripts/device-pcie-aer-probe.sh`（F116）
- 位名来源：本仓内核树 `drivers/pci/pcie/aer.c`（`aer_uncorrectable_error_string` / `aer_correctable_error_string`）
- 相关台账：`docs/FIXES.md` 的 F56、F95、F116
- 相关链路基线：`docs/acceptance-results/2026-08-24-pcie-gen3-baseline.md`、`docs/PCIe-GEN3-PLAN.md`
