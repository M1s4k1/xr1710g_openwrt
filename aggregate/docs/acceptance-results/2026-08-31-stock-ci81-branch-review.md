# 2026-08-31 stock ci-81（feat/absorb-npu-fdk-offload-oc）全面 Review / 测试 / 验证 / 排查

> 审查对象：pre-release `ci-81`（`firmware-stock.tar.gz`）= build run **#81**（id 33327020444）@ `6410bf3`，stock 档。
> 分支：`feat/absorb-npu-fdk-offload-oc`（基座 `56466bd` + 2 commits：`a397a2d`、`6410bf3`）。
> 基线：openwrt master `93cf01b`，kernel **6.18.44**（2026-08-29 21:43 构建）。
> 实机：192.168.123.1，up 时刻 2026-08-31 03:51（本地）。

## 0. 结论摘要

- **分支本体（NPU FDK 构建管线，阶段 A0）review 通过**：5 文件 +411 行，只新增独立构建管线与 vendored 补丁，**不改变固件镜像内容**；锁源合规、CI 双绿（双构建 sha256 一致）、本地静态验证（tarball hash / 补丁可应用 / bash -n）全过。
- **固件实机运行健康**：NPU offload（v4+v6）、三频 Wi-Fi、风扇、包集合、eeprom 功率解锁、hw-probe、wifi down/up 5 轮全部通过；pstore 无崩溃记录。
- **发现 1 个 P1 实机回归（已实机修复）**：LED 默认配置 sysfs（`mt7530_dsa-0`）与本固件内核实际 sysfs（`mt7530-0`）不匹配 → 刷机后 `led start` rc=1、口灯全灭。main 同样受影响（#14 新证据）。
- **发现 2 个 P2**：① 分支基座落后 main（缺 ci-74 毕业批次 e0cbe4a 与 antenna 合并 3a7257c）；② 未跟踪的 `patches/root/9035-airoha-ppe-flow-stats-coexist.patch` 无 MANIFEST/ORDER 引用（内容评审通过，建议 #EXP 入库）。

## 1. 分支代码 review（逐文件）

### config/npu-fdk.pin
- `repo/commit/tarball_sha256` 三元组齐全。**实测**：下载 codeload tarball（`2d13e291`）sha256 =
  `7ac4dd434e38c910fcd2dee3a6436c5c2f11bffb8a98e2f2969b62ec4116f0f4`，与 pin **完全一致**（锁源铁律合规）。

### patches/vendor/hurryman/npu-fdk/0001-fix-volatile-assume-aligned.patch
- 修复点真实：clang 17+ 的 `__builtin_assume_aligned` 第一参数要求 `const void*`，FDK 源码 7 处传 volatile 指针被 -Werror 拒绝。
- **语义安全性已核**：cast 仅满足内建类型要求；实际 volatile 访问路径经变量声明保留——
  `packet_words` 声明为 `const volatile uint32_t *`、`packet_control`/`control` 为 `volatile uint32_t *`，读/写仍走 volatile 指针。
- 与上游 xrci 同款修复一致（Origin 注明 pin commit）。

### patches/vendor/hurryman/npu-fdk/0002-provide-memmove-libcall.patch
- `clang -Oz -flto` 把结构体拷贝降为 memmove libcall，补 `npu_memmove` 转发 wrapper。与已有 memset/memcpy wrapper 对称，正确。

### scripts/build-npu-fdk.sh
- `bash -n` 通过。工具链探测（`rv32imc_zicsr_zifencei` 试编译、要求 clang≥17）设计正确——本容器仅 clang-14，被脚本正确拒绝。
- `mkdir -p` 先于 `readlink -f`（6410bf3 修复）✓；下载 + sha256 双重校验、校验失败不污染缓存 ✓；
  补丁循环 `--no-backup-if-mismatch` 失败即停 ✓；产物成对校验 + "不可混用官方 data/自编 rv32" 警示 ✓；trap 清理 ld.lld 临时 symlink ✓。
- 备注：容器 shellcheck 不可用；本地实际编译被容器限制阻断（/var 只读导致 apt 失败）——可复现性由 CI 干净环境双构建佐证（见 §2）。

### .github/workflows/npu-fdk-build.yml
- `workflow_dispatch` only、`permissions: contents: read` ✓；两次构建（OUTPUT_DIR=a/b）+ sha256 对比（6410bf3 修复去路径前缀）✓；artifact 只传 dist-a 一对 bin ✓。
- 小建议（P3）：加 `timeout-minutes` 与 `concurrency` 防重复并发。

### 边界确认
- 分支 **不改** build.yml / MANIFEST / defconfig / files——固件镜像内容 ≈ main@`56466bd` 的 stock 档（见 §4 P2 的偏差说明）。

## 2. CI 与产物验证（GitHub API 实查）

| run | workflow | commit | 结论 |
|---|---|---|---|
| #5 (33327014875) | npu-fdk-build | 6410bf3 | **success**：装链→构建A→构建B→**sha256 一致**→上传 artifact，每步 success |
| #81 (33327020444) | build (stock) | 6410bf3 | **success**：resolve→build(stock)（克隆/叠层/补丁/feeds/defconfig+seed/构建/上传）→release，每步 success |
| #180 | sync-upstream | 6410bf3 | success |

- Release 溯源：`ci-81` = "CI 构建 #81（feat/absorb-npu-fdk-offload-oc @ ci-35 起）｜firmware-stock.tar.gz" —— **即用户刷入的固件**。
- 历史：`ci-79`/#79、npu-fdk/#4（`fe30615`）为该分支被 force-push 前的早期迭代（同样 success）；最终 tip 为 `6410bf3`。
- 旧分支 `feat/npu-fdk-build-workflow`（`b731d3a`）的 FDK 三文件与本分支**逐字节一致**（已被吸收）→ 建议删除旧分支。

## 3. 实机验证清单（root@192.168.123.1）

通过项：
- [x] **E2** 档位元数据：`DISTRIB_DESCRIPTION='OpenWrt stock SNAPSHOT r0-93cf01b'`（9a7e608 生效）
- [x] **F64** 布局：dmesg `ubi0: good PEBs: 3512, bad PEBs: 0, corrupted PEBs: 0`；ubinfo bad=0
- [x] **F63** NPU：`airoha-npu 1e900000.npu: NPU fw version: 0.1111`；8 核 @ 800MHz；5 个 memory regions（ubus getStatus）
- [x] **B5 IPv4 offload**：conntrack `HW_OFFLOAD`=21；offload_bound=16/63
- [x] **B5 IPv6 offload**：`device-npu-ipv6-probe.sh` **rc=0**；采样 ct6≈50–100、hw=4–16、bnd6=8
- [x] FlowSense：`getStatus`（npu_version=TLB7.7.0.0_v03、npu_loaded=true）+ `getPpeFlowStats`（conntrack 合流 ct_packets/bytes）+ npu-monitor air_eff=80
- [x] 三频：2.4G ch6 20MHz 30dBm；5G ch149 **HE80** 30dBm（issue #21 修复生效）；6G ch37 **EHT320** 29dBm
- [x] eeprom 功率解锁（mt76-0008）：dmesg `XR1710G eeprom: 2G power unlock 28 -> 30 dBm`、`5G UNII-3 power unlock`
- [x] mt76 锁源一致：`kmod-mt76 6.18.44.2026.08.22~c5a3bd91`（与仓库 pin 一致）
- [x] 包集合：apk 206 包（与 ci-69 manifest 206 一致）；`airoha-en7581-mt7996-npu-firmware-20260810-r1` 在列
      官方 NPU 固件对 hash 基线（供 FDK A1/A2 对照）：rv32 `e743d1b5…` / data `61a75afb…`
- [x] **F67** 风扇：`S99fan` 单写者运行（pwm1=69 @ 67°C）
- [x] **F75/A12** device-hw-probe.sh：route_a–d rc=0，B2.1/B7 正常
- [x] issue #10：`device-wifi-downup-probe.sh` 5 轮 **rc=0** 无复发
- [x] pstore：无崩溃记录
- [x] dmesg 错误扫描：仅已知良性 `rdinit=/init failed: -2`（F66，HTTP U-Boot env 覆盖 chosen）

## 4. 发现的问题与排查

### P1（实机回归，已实机修复）LED 默认配置 sysfs 与内核不匹配
- 证据：`/rom/etc/config/system` 默认 = `mt7530_dsa-0:*`（c2f4ade）；本固件内核 6.18.44 实际暴露 **`mt7530-0:*`**（现场 /sys/class/leds）→ 刷机后 `/etc/init.d/led start` **rc=1**，6 个 PHY LED trigger=none。
- 已修复：设备 UCI `sed s/mt7530_dsa-0/mt7530-0/g` → `led start` **rc=0**，6 LED 全部 `[netdev]`（含 10G :05/:08）。
- 根因：c2f4ade 押注的"新内核 DSA 改名"未发生（kernel 6.18.44@93cf01b 仍 `mt7530-0`）。**main 同样受影响**（#14 正在收集证据：790f57e/a6c9b45）。
- 建议：默认配置改为**首启探测式 uci-defaults**（探测 `mt7530-0` vs `mt7530_dsa-0` 前缀后改写 sysfs），双内核鲁棒；出新 CI 后 fresh flash 复验。

### P2（分支管理）分支基座 `56466bd` 落后 main
- 缺 `e0cbe4a`（ci-74 毕业批次：mt76-0005 / 9990 / 9991 / 9993、mac80211-411、vendor 05/06/07/09/17/18、root 9024/9026 转默认）。
- 缺 `3a7257c`（`files/etc/config/system` 补 compat_version 2.0；`files/etc/uci-defaults/99-xr1710g-flow-offload` 默认开 fw4 flow_offloading/hw）。
- 影响：本 stock 固件 **fresh install** 将：无 flow offload 默认、无 compat 2.0 默认、缺全部毕业补丁（EHT320 advertise 等）。本机因配置继承 + 手动设置未受影响（flow_offloading=1 现场在 UCI，非 /rom）。
- 建议：分支 merge/rebase main 后再出下一轮固件；或明确本固件为"FDK 管线验证用临时固件"。

### P2（资产处置）`patches/root/9035-airoha-ppe-flow-stats-coexist.patch` 未跟踪、无 MANIFEST/ORDER 引用
- 内容：wrapper 补丁 = 在 openwrt 树创建内核补丁 `patches-6.18/9995`（`airoha_eth.h` + `bool stats_enabled`；`airoha_ppe.c` 5 hunk：SRAM stats 分区与统计消费端全部 guard、`ppe_init_stats` 失败改 dev_warn 不致命）+ `an7581/config-6.18` 启用 `CONFIG_NET_AIROHA_FLOW_STATS=y`。
- 验证：config hunk 上下文与 openwrt-src 实文件**逐行匹配**；内层补丁对 linux master（含 flow-stats）**5 hunk 全部干净套用**（offset ≤24 行）；调用顺序正确（`stats_enabled` 在 `airoha_ppe_hw_init` 分区之前置位，成功/失败两条路径 SRAM 布局自洽）。
- 定位：当前固件 FLOW_STATS=n → 9035 行为零变化（防御性）；价值在 NPU fw 未来实现 `PPE_FUNC_SET_WAIT_FLOW_STATS_SETUP` 时，启用 stats 不再杀死 NPU offload。
- 建议：以 **#EXP 入库**（MANIFEST/ORDER 同步登记）→ experimental CI 构建 + 实机验证（dmesg 应出现 "NPU flow stats unavailable" 或 stats 生效，offload 必须存活）。

### P3（低）
- 上游 `airoha_fan` init.d 随新基线进入镜像且 enabled：实测其 boot() 仅处理 `gemtek,w1700k-ubi`，XR1710G **空操作**，无实际 pwm 双写（F67 仍成立）；建议 uci-defaults disable 或 root patch 移除，防未来上游给 xr1710g 加 case 后变成真双写者。
- rdinit 假警告（F66 已知良性，需 U-Boot 侧解决）。
- 本地容器无法编译 FDK（/var 只读；clang-14 不支持 zicsr）——脚本探测行为正确。
- 仓库根目录 4 个 .deb（旧会话遗留）建议清理或 .gitignore。

### 需物理条件（延续既有口径延后）
C2 6G 客户端国家码双侧判据、C3 外部对端 iperf3、B2 双 10G 对打、F71 JCPLL、F69 mt76-0010（NPU RX skb->dev）、D3 72h 长稳。

## 5. 建议下一步（优先级序）

1. LED 默认配置改首启探测式 uci-defaults（main + 分支）→ 新 CI → fresh flash 复验（关 P1）。
2. 分支 merge/rebase main（吃进毕业批次 + flow-offload/compat 默认）→ 重新出 stock 固件（关 P2-1）。
3. 9035 以 #EXP 入库 → experimental 构建 + 实机验证（关 P2-2）。
4. FDK A1/A2：npu-fdk artifact 与官方 pair（§3 基线 hash）对比，成对替换实验 → 实机验证 offload 与稳定性。
5. 删除 `feat/npu-fdk-build-workflow` 旧分支；清理根目录 .deb。
6. npu-fdk workflow 加 timeout/concurrency（小优化）。
