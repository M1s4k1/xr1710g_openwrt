# PLAN — 吸收 NPU FDK 与 offload-oc（“iCare”）fork

> 状态：草案（待评审）
> 日期：2026-08-24
> 范围：`hurryman2212/airoha-npu-fdk`（NPU FDK）与 `hurryman2212/OpenW1700k-test` 分支 `offload-oc`（IP-EVAL IP09 所称 “iCare offload-oc” fork），以及同类仓库（fanboy/YYH2913/xr1710g-firmware-ci/mervync/openwrt 上游）的对比调查与吸收方案。
> 口径：本仓库铁律——修复而非降级；锁源可复现；个人 fork 代码不直接入 default；先 experimental 实机验证再毕业。

## 0. 结论摘要

| 资产 | 判定 | 吸收路径 |
|---|---|---|
| `hurryman2212/airoha-npu-fdk` | **吸收（CI 构建 + 实机验证后可选替换官方固件）** | MIT 许可已澄清；pin commit + tarball sha256；新增 NPU FDK 构建工作流；产物先不替代官方 linux-firmware，待设备验证 |
| `hurryman2212/OpenW1700k-test:offload-oc` | **选择性吸收（experimental 起步，部分否决）** | 该 fork 与 fanboy ubi2-oc 大量重叠；只吸收 fanboy/YYH 未覆盖的真增量：mt76 0012/0013/0014、EIP93 动态回退、SOE/XFRM（先 raw 跟踪）；其余（RTL8261CE、IXGBE、fastfetch/netspeedtest、banner/feeds 等）否决或已吸收 |
| `OpenWRT-fanboy/OpenW1700k:ubi2-oc` | 已作为原料桶 vendor（01-20） | 继续作为默认/实验档原料，不新吸收 offload-oc 重复部分 |
| `YYH2913/openwrt:xr1710g-6.18-integration` | 已部分吸收 | mt76 0006/0007/9990/9991/9993、mac80211 411、regdb 510/520/530 已入库；继续跟踪 |
| `genshanxinli/xr1710g-firmware-ci` | 参考实现 | 其 NPU FDK 构建工作流、SOE/XFRM 适配历史（PR #3/#15）作为吸收 offload-oc 的工程参照 |
| `mervync/w1700k-openwrt:offload` | 同源旁支 | 与 offload-oc 头部提交重合（`mac80211: emit switchdev FDB DEL on STA disconnect`），不单独吸收 |
| openwrt 上游 / linux-firmware | 基线 | 官方 NPU 固件包 `airoha-en7581-mt7996-npu-firmware` 继续作为默认；跟踪 PR #22532/#22533/#23123/#24038 |

## 1. 调查发现

### 1.1 NPU FDK：`hurryman2212/airoha-npu-fdk`

- **HEAD**：`2d13e291ab511b6b319dc5073f47e26cac958ae4`（“Init.”，main）
- **作者**：Jihong Min（hurryman2212）。**许可**：MIT（LICENSE 明确，IP-EVAL IP09 “许可不明”已过时）。
- **规模**：约 25,069 行 C（255 文件，128 头文件）+ 618 行 Python 构建脚本；纯 C 源码重实现，无 Airoha 专有 SDK/二进制。
- **构建**：`python3 airoha-npu-fdk-build --platform an7581 -o en7581_MT7996_npu --debug-directory debug`
  - 工具链：clang/lld/llvm（host 安装）；`--target=riscv32-unknown-elf -march=rv32imc_zicsr_zifencei -mabi=ilp32`
  - 严格 `-Wall -Wextra -Werror -Wconversion -Wshadow`；已知构建问题：`mt7996_fragment_queue_consumer.c` 的 `__builtin_assume_aligned` 需 cast `const void *`（xr1710g-firmware-ci 的 `npu-fw-build.yml` 已给出补丁）。
- **固件格式**：
  - `linker/an7581.ld`：RV32 基址 `0x84000000`，最大 `0x200000`（2MiB）；data 基址 `0x3e900000`，最大 `0x10000`（64KiB）——与内核 `airoha_npu.c` 的 `NPU_EN7581_FIRMWARE_RV32_MAX_SIZE` / `DATA_MAX_SIZE` 一致。
  - 版本字符串：`TLB7.7.0.0_v03`（`include/an7581/platform/data_image.h`），与实机 `luci.airoha_npu getStatus` 观测到的官方固件版本一致。
- **与官方固件的兼容性**：
  - 官方 linux-firmware 文件：`en7581_MT7996_npu_rv32.bin`（122,336 B，md5 `08aa0401162769a0252d251946f33b08`）、`en7581_MT7996_npu_data.bin`（3,084 B，md5 `5bbb27082f163cf4dd9d60cba7ef8ce7`）。
  - FDK 的 `data.bin` 头部是自描述 `ANPU` 容器（`src/an7581/platform/data_image.c`，60B 头 + 28B tunnel payload），而官方 `data.bin` 起始字节是 raw `.data`（首 4B `a0 36 9f 54`），二者**不字节兼容**。因此 FDK 的 `rv32.bin` 与 `data.bin` 必须**成对替换**，不能混用官方 data/自编 rv32。
- **风险**：FDK 固件未经本设备实机验证；data 格式与官方不同意味着回滚需成对恢复官方两个文件；FDK 代码质量整体较高，但属个人重实现，无官方背书。

### 1.2 offload-oc fork：`hurryman2212/OpenW1700k-test:offload-oc`

- **HEAD**：`73c3ab3081432f02d90b0084f63ea8ca4ea8589b`（2026-08-05）
- **相对 fanboy `ubi2-oc`（`ba58ba46`）**：ahead 46 / behind 256 / 210 文件变更（GitHub compare）。该 fork 基于较旧的 fanboy 基线，fanboy 当前 main/ubi2-oc 已领先 256 commit；直接整分支吸收不可行，必须逐提交切分。
- **唯一增量分类**（与当前仓库已吸收资产对比后）：

| 组 | 内容 | 当前仓库状态 | 处置 |
|---|---|---|---|
| G0 | OC +200MHz、LRO 默认、EIP93 使能、fanboy 桥接 offload（05/06）、应用包（9017）、txpower/regdb、mt76 EHT 9990-9993、E2 PCS RX calibration（745） | 已吸收（fanboy 03/11/02/05/06、root 9010/9017、regdb、mt76；E2 在 fanboy 09） | 核对差异，不重复吸收 |
| G1 | `mt76/patches/0012-wifi-mt76-npu-always-call-check_skb-on-rx.patch` | 未吸收 | **候选（experimental）**：小、独立、与 mt76-0010 互补 |
| G2 | `mt76/patches/0013/0014` PPE flush on STA remove；`mac80211/patches/subsys/990-mac80211-emit-switchdev-fdb-del...`；`930-net-airoha-ppe-flush...`；`990-01/02/03`；`991-neigh-headroom` | 未吸收 | **条件吸收（experimental）**：先复现 AP/漫游 PPE stall（#17/#25/#28/IP18），再按组入库；上游跟踪 #23123/#22533 |
| G3 | EIP93 动态软件回退：`999-01/02/03/04` + `999-v7.0-crypto-inside-secure-eip93-correct-ecb-des-eip93-typo.patch`；crypto.mk 选择 CRYPTO_BENCHMARK | 仅 fanboy 02 使能驱动，无动态回退 | **候选（experimental）**：与 ROADMAP P3 IPsec 探索合并 |
| G4 | SOE/XFRM 包卸载：`9999-01..38`（airoha）+ `generic 9990/9991`（bonding/LAG）+ fw4 bonding 补丁 + `NET_AIROHA_SOE` Kconfig | 未吸收 | **先 raw 跟踪，再 experimental 专用构建**；AI 辅助（Codex:gpt-5.6）个人补丁，禁止直接 default；IP09 结论 WireGuard 不可行、ESP offload 是目标 |
| G5 | 桥接 offload 增量 `675-06/07/08`（flow-aware forward path、hw path direct redirect、VLAN encap fix） | fanboy 06 已含 675-01..03；9026 自建 675-04 | **暂缓**：先在 fanboy 06 + 9024/9026 基线上验证桥接 offload 是否还有缺口；有缺口再按 commit 吸收 |
| G6 | RTL8261CE 10G PHY 逆向驱动（`rtk_rtl8261ce_phy.c`，PHY ID `0x001cc890`） | 未吸收 | **否决**：XR1710G 用 RTL8261BE（VEND1 0x103/0x104 判据已入 F75），CE 驱动面向 W1700K2 |
| G7 | IXGBE IPsec offload disable、elfutils AArch64 host patch、fastfetch/netspeedtest、banner/feeds、vermagic 等 | 部分已否决/已裁切 | **否决或暂缓**（与 XR1710G 无关或已决策） |

- **同类仓库**：
  - `genshanxinli/xr1710g-firmware-ci` 已做过一次“fanboy 为底、hurryman offload-oc 为 overlay”的 CI 吸收尝试；其提交历史（2026-08-03 ~ 08-08）是最佳冲突地图：已剔除 fanboy 已有的 PPE flow 系列，保留并重基了 SOE/XFRM 系列，新增了 NPU FDK 构建。我们吸收时直接复用其结论，减少试错。
  - `mervync/w1700k-openwrt:offload` 头部与 offload-oc 部分重合；作为 offload-oc 谱系佐证，不单独吸收。
  - OpenWrt 上游 `airoha.mk` 已带官方 NPU 固件包；#22533/#24038（桥接 offload）、#23123（DSA flowtable roaming）是 G2/G5 的上游归宿，优先等上游合入。

## 2. 吸收计划

### 阶段 A：NPU FDK

#### A0. 锁源与 vendor
- 新增 `config/npu-fdk.pin`：
  ```
  repo=https://github.com/hurryman2212/airoha-npu-fdk
  commit=2d13e291ab511b6b319dc5073f47e26cac958ae4
  tarball_sha256=7ac4dd434e38c910fcd2dee3a6436c5c2f11bffb8a98e2f2969b62ec4116f0f4
  # codeload tarball 由 commit SHA 下载；改 pin 必须重算 hash（锁源铁律）
  ```
- 新增 `scripts/build-npu-fdk.sh`：
  1. 从 codeload 按 commit SHA 下载 tar.gz，校验 sha256；
  2. 解包；应用 vendored 构建修复（`patches/vendor/hurryman/npu-fdk/0001-fix-volatile-assume-aligned.patch` 或脚本内嵌 `sed`，按 xrci workflow 的 cast 修复）；
  3. `python3 airoha-npu-fdk-build --platform an7581 -o en7581_MT7996_npu --debug-directory debug`；
  4. 输出 `en7581_MT7996_npu_rv32.bin`、`en7581_MT7996_npu_data.bin`，打印 sha256。
- 新增 `.github/workflows/npu-fdk-build.yml`：workflow_dispatch + 可选的 release 上传；安装 `clang lld llvm`；运行上述脚本；上传 artifact `npu-firmware-fdk`；两次运行 sha256 应一致（可复现验证）。

#### A1. 设备验证（先不改默认固件包）
- 设备备份官方两文件：
  ```sh
  tar czf /tmp/npu-official-backup.tgz -C /lib/firmware/airoha en7581_MT7996_npu_rv32.bin en7581_MT7996_npu_data.bin
  ```
- 将 FDK 两文件拷贝到 `/lib/firmware/airoha/`（同名覆盖），`sync && reboot`。
- 验收：
  - `dmesg | grep -i npu` 无 `-ETIMEDOUT`/`-EPROBE_DEFER`；版本字符串 `TLB7.7.0.0_v03`；
  - `ubus call luci.airoha_npu getStatus` `npu_loaded=true`、8 cores；
  - PPE BND/HW_OFFLOAD 正常（沿用 `docs/ACCEPTANCE.md` B5/NPU 项）；
  - 三频 Wi-Fi、10G 口、IPv4/IPv6 offload 不回归；
  - 失败则成对恢复官方备份文件并重启。
- 结论：
  - **成功** → 进入 A2；
  - **失败** → FDK 维持 CI 构建/跟踪状态，不进入镜像；记录根因到 FIXES。

#### A2. 可选：进镜像
- 新增 OpenWrt 包 `airoha-en7581-mt7996-npu-fdk-firmware`（`packages-xr1710g/package/`）或 seed 预装脚本，`PROVIDES`/`CONFLICTS` 官方 `airoha-en7581-mt7996-npu-firmware`；安装时成对替换两文件，卸载时恢复官方包文件。
- 默认档**不**预装；experimental 档可选预装，待 ACCEPTANCE 全项通过后再评审判定是否默认替代官方包。
- 风险与铁律：包内两文件必须来自 pin 住的 FDK 构建，禁止混用官方 data；版本升级时两文件同时升。

### 阶段 B：offload-oc 选择性吸收

#### B0. 建 raw 桶与取源
- 新增 `patches/vendor/hurryman/`（与 `patches/vendor/fanboy/` 并列），只放**选定 commit** 的 `.patch` 原文。
- 扩展 `scripts/fetch-sources.sh --offload-oc`：按 commit SHA 从 GitHub `commit/<sha>.patch` 拉取 G1/G2/G3/G4 对应 commit，写元数据头（来源、日期、commit、是否 AI 辅助）。
- 初始拉取清单：
  - G1：`package/kernel/mt76/patches/0012-...`（offload-oc 路径）
  - G2：`a4d0eb2e`、`4cd4a407`、`31fcf809`、`96044679`、`83ac5473`、`4de1e738` 对应补丁 + `930` + `990-01/02/03` + `991`
  - G3：`be72f6fe`、`96247057`、`be44f921` 对应补丁 + `backport 999`
  - G4：`5a81eab5`、`73c3ab30` 对应 9999 系列 + generic 9990/9991 + fw4 补丁 + Kconfig
- 所有 raw 补丁先入桶，**不**写入 MANIFEST。

#### B1. 快赢项（experimental）
- 将 G1 `mt76-0012` 重基到当前 mt76 pin（`c5a3bd91`）后，新增 `patches/packages/mt76-0012-npu-check-unbound-rx.patch`，MANIFEST 标 `#EXP`。
- 验证：`apply-patches.sh --dry-run --experimental` 绿；experimental CI 构建绿；实机 `conntrack -F` 后新建流，br-lan 无丢包、CLIENTS 计数一致（与 F69/mt76-0010 同场景）。

#### B2. EIP93 动态回退（experimental，与 ROADMAP P3 合并）
- 将 G3 重基到当前内核 6.18 与现有 fanboy 02 顺序，新增 ROOT 补丁 `patches/vendor/hurryman/eip93-fallback-*`（或生成 `target/linux/generic/pending-6.18/999-*`），MANIFEST 标 `#EXP`，并置于 fanboy 02 之后。
- 验证：experimental 构建绿；`/proc/crypto` 中 EIP93 驱动注册正常；`ip xfrm` + strongswan 小包/大包流量通过；fallback 行为按设计（后续 FIXES 记验收）。

#### B3. PPE/FDB roaming（条件吸收）
- 先在现有 experimental（fanboy 05/06 + 9024/9026）上复现 `#17/#25/#28`（AP 模式 PPE stall、漫游丢流）。
  - **能复现** → 重基 G2 全组（mac80211 FDB DEL + mt76 0013/0014 + 930 + 990-01/02/03 + 991），`#EXP` 入库；实机按复现脚本验证修复；同时把上游 #23123/#22533 状态记入 FIXES。
  - **不能复现** → 不落补丁，只加验收洞与诊断脚本（延续 IP18 决定）。
- 注意：`xr1710g-firmware-ci` 在 2026-08-07 曾以“fanboy 生产立场”剔除该系列；因此本组**不得**直接进入 default，必须实机复现驱动。

#### B4. SOE/XFRM 包卸载（长周期，先 raw 后 experimental）
- 第 1 步：`scripts/soe-xfrm-dry-run.sh` 新建 disposable 树：openwrt master + 默认/实验档补丁 + G4 原始序列（按 offload-oc 顺序），只做 apply + `make target/linux/compile` 级验证；冲突处理记录到 `docs/FIXES.md`（参照 xr1710g-firmware-ci 的重基记录）。
- 第 2 步：序列可应用且编译过后，再把 G4 以 `#EXP` 写入 MANIFEST（约 40 条），并新增 fw4 bonding 补丁；experimental CI 构建绿。
- 第 3 步：实机验收（`docs/ACCEPTANCE.md` 增加 IPsec/SOE 项）：
  - strongswan + `ip xfrm` 建 ESP 隧道，流量经隧道；
  - 确认 SOE offload 生效（PPE/flowtable 计数或 debugfs 证据）；
  - XFRM SA 更新/重挂不失败（9999-25 重基后的 `-EEXIST` 语义专项）；
  - WireGuard 不承诺卸载（IP09 已否决）。
- 第 4 步：全部通过后按毕业流程评估是否转 default；未通过则保持在 experimental 或 raw 跟踪。

#### B5. 否决/暂缓项
- G6 RTL8261CE 驱动：不吸收；若未来 XR1710G 实测 PHY ID `0x001cc890` 再另议。
- G7 IXGBE/elfutils/fastfetch/netspeedtest/banner/feeds：不吸收。
- G5 675-06/07/08：B3 桥接 offload 验收后仍缺 VLAN encap/direct redirect 再吸收；否则等上游 #22533/#24038。

## 3. 验证与毕业

- 所有新补丁一律 `#EXP` 起步，通过：
  1. `scripts/audit-patches.sh --experimental` 绿；
  2. `scripts/apply-patches.sh tmp/openwrt-src --dry-run --experimental` 真实应用绿；
  3. experimental CI 构建绿（firmware artifact 存在）；
  4. 实机验收对应项（沿用 `docs/ACCEPTANCE.md`，新增 IPsec/SOE 与 FDK 固件项）；
  5. 至少一个 known-good 周期（72h 长稳 / 对应场景）无回归；
  6. 取消 `#EXP` 转入 default，并同步 FIXES/ROADMAP/README。

## 4. 回滚

- 所有 offload-oc 吸收项在 `#EXP` 阶段不进入 stock/oc release；回滚 = 从 MANIFEST 移除对应行。
- NPU FDK 设备验证失败：恢复官方两个固件文件；镜像默认继续官方 `airoha-en7581-mt7996-npu-firmware` 包。
- 若 SOE/XFRM 系列在 dry-run 阶段冲突过多：暂停吸收，保留 raw 桶与冲突记录，等上游或下一个 fork 版本。

## 5. 待澄清/风险

1. “iCare fork”在本计划中按 IP-EVAL IP09 + `xr1710g-firmware-ci` upstreams.yml 推断为 `hurryman2212/OpenW1700k-test:offload-oc`；若有其它（非 GitHub）源，请提供 URL 后重定向。
2. FDK 的 data 格式与官方不兼容，设备验证前不得与官方固件混用；成对备份/恢复是硬性操作纪律。
3. SOE/XFRM 与 EIP93 动态回退均为 `Assisted-by: Codex:gpt-5.6` 个人补丁，无上游背书；毕业前需人工审查 diff 与许可证兼容性（GPL kernel 补丁 + MIT FDK 分属不同层，各自记录来源）。
4. offload-oc 基线落后 fanboy 256 commit；逐 commit 重基是主要成本，优先等上游 PR #22533/#23123/#24038 合入以减少自持面。

## 6. 参考链接

- `https://github.com/hurryman2212/airoha-npu-fdk`
- `https://github.com/hurryman2212/OpenW1700k-test/tree/offload-oc`
- `https://github.com/OpenWRT-fanboy/OpenW1700k/tree/ubi2-oc`
- `https://github.com/YYH2913/openwrt/tree/xr1710g-6.18-integration`
- `https://github.com/genshanxinli/xr1710g-firmware-ci`
- `https://github.com/mervync/w1700k-openwrt`
- `https://github.com/openwrt/openwrt`（NPU #24593 已合入；固件包 `package/firmware/linux-firmware/airoha.mk`）
- 官方固件：`https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/airoha/`
