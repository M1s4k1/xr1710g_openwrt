# ROADMAP — 后续计划

按优先级排序。原则：**修复而不是降级**——所有"暂缓"都是排队，不是放弃。

## P0 首次实机（刷机后第一轮）
- [x] **真绿门禁**（2026-08-17 F19 修复后）：重建 stock + oc-1.3 + oc-1.4，以 **firmware artifact 存在** 为成功判据。历程：F20（regdb）→ F21（uboot 9002，glob 序/+++/hunk 截断）→ F22（fanboy14 mt76 冗余撤下）→ **F23（9001 内核 DTS hunk 行数 330→427，git apply 静默截断丢 97 行）** 均已修复；**2026-08-17 第五次重建（commit 83f07db）全绿**（push stock=32053502298 + dispatch all=32053692044，firmware artifact 各 ~33.5MB）；同步验证：sync-upstream 32053502231 绿（audit+verify 全通过）。release 自动化闭环由 F25 的 ci-32 验证（2026-08-18，F24）
- [ ] 物理口 ↔ 逻辑名实机核对（netdev-name 已固化：lan1/lan2=双 10G、wan=1G-1（gsw_port1）、lan3=1G-2（gsw_port2），见 9001；`ip -br link` 验证后定稿 files/etc/config/network）
- [x] 核对 6GHz EHT320 实际生效（`iw phy` / hostapd 日志）——ci-74 实机 6G EHT320 up；6G 客户端侧延后（2026-08-31）
- [ ] NPU 加载与卸载验证（luci-app-airoha-npu 已由 19-pack 内置）
- [ ] 风扇曲线实测（温度点/转速），按 NCT7802 实测修正曲线参数
- [ ] 跑 `docs/ACCEPTANCE.md` 全项 → 首个 known-good tag

## P0.5 已评估待吸收（IP-EVAL 2026-08-23，下一轮全部执行）

> 来源：`docs/IP-EVAL-2026-08-23.md`。执行顺序 A1→A12；**已完成**：转正为 `docs/FIXES.md` F64–F75，并从本清单移除。

- [x] A1 reserved_bmt 66MiB 布局对齐（IP02/05/06/07/15）：先实机抓 stock bootlog 核 XR1710G BMT 池；落地 `9001/9002` + `docs/FLASHING.md`
- [x] A2 sysupgrade compat 一致性（IP15）：`9000` 的 XR1710G `DEVICE_COMPAT_VERSION` 2.0→1.0（A1 实证后恢复 2.0）
- [x] A3 rdinit 修复（IP17）：`9001` chosen bootargs 加 `rdinit=/sbin/init`
- [x] A4 风扇双控制器去重（IP25）：`files/etc/init.d/fan` 单控制器 + 动态探测 + 迟滞/兜底；9017 仅留 LuCI 前端
- [x] A5 mt76 0099 tx_failed 记账修复（IP25/IP26）：新增 `mt76-0009`，default
- [x] A6 mt76 0103 NPU RX skb->dev（IP25/IP26）：新增 `mt76-0010`，experimental
- [x] A7 flowsense 1.1.8-r5 bump（IP08）：新增 `root/9030`，experimental
- [x] A8 JCPLL TCLVAR recal（IP10）：新增 `root/9029`，experimental
- [x] A9 6GHz 客户端国家码判据（IP14）：`docs/ACCEPTANCE.md` C2 双侧判据 + F02 备注
- [x] A10 FLASHING 坏版本/救砖（IP19）：`docs/FLASHING.md` 补 8/8 坏版本、8/11 候选锁版、kmod-mtd-rw 救砖
- [x] A11 验收方法学补洞（IP20/24/28）：`docs/ACCEPTANCE.md` 测试方法学节 + B6 + C3 外部端点判据；OC 报告 §①D 降级
- [x] A12 device-hw-probe 增强（IP04）：10G PHY 寄存器判据 + EFR32 去除断言


## P1 资产评审与供给（2026-08-17：应用供给已闭环；08 切片 + 19 精简已收口）
- [x] **F13 拆分**：08 号六项切片入 default（root/9011-9016，2026-08-17 完成）；19 号精简为 root/9017 19-core（去 fastfetch/netspeedtest，2026-08-17 完成）
- [x] 评审 11/13/14/15/16 号定档位（2026-08-17：11 LRO→default；13 mt76 源 pin→否决(供应链)；14 mt76 debugfs→default；15 txpower 备选→不启用；16 wifi-scripts ucode→重建为 root/9010→default）
- [x] `luci-app-airoha-recovery` 供给（2026-08-17：packages-xr1710g/ src-link，源 naoki66@dd9ecfeef）

## P2 上游跟追（PR / 包源 pin，合入或升级即删/复核本层补丁）
- [ ] #22397（板级）——合入后删 `patches/root/9000-xr1710g-common.patch` 等三件套
- [ ] #22029（cpufreq/PM domain）——**已自持 fanboy 03（含 direct-PLL fallback）**；上游合入即删
- [ ] #24034（RTL826x LED）/ #24619（mt7530 LED）——#24034 已 carry 为 `patches/root/9033-openwrt-24034-rtl826x-led.patch`（合入后删）；#24619 仍取决于实机 LED 行为反馈
- [ ] #22473（uboot pstore）——kernel 侧已自持，剩 uboot 侧
- [x] #22533（L2 offload）——已毕业（2026-08-31）：`vendor/05/06`+`root/9024/9026` 转默认，ci-74 实机 E1/E2/E3 通过；#22532（DSA）仍实验档（`vendor/04`）
- [ ] **mt76 上游追踪 / 吸收**（2026-08-22）：跟踪 `openwrt/mt76` master；当前 pin `59676919`，最新 `c5a3bd91`（147 commits / 76 files / +3038/-482）。优先等 openwrt main bump；若 main 不 bump，按锁源铁律自 bump `package/kernel/mt76`（实算 `PKG_MIRROR_HASH`，禁 fork/hash=skip）。升级后删除 `9992`（上游 `06b6976` 已合入同款 PS-sync 修复），逐条复核 `0001/0003/0006/0007/0008` 与 `0005/9990/9991/9993`，CI `all`+`experimental` 构建绿后实机回归（token_info、PS-sync 事件、三频功率、EHT320）
- [ ] **fanboy 18 smartrg 吸收**（F77，2026-08-30 复核）：上游 `ubi2-oc` `765535cf`（08-30 rebase）中 `992-21` 83 行版无进一步变化；`vendor/fanboy/18` 待更新为 83 行版并对 openwrt master 重建 + verify，实验档 CI 复验
- [ ] **naoki66 LAN2 SDS-mode 方案评估**（F78，2026-08-30）：`622-net-phy-realtek-allow-board-specific-RTL826x-SDS-mode.patch` + dts `realtek,sds-mode`/`reset-before-id-read` 与实验档 `9029` JCPLL 对照（互补候选）；若吸收需对 openwrt master 重建并核对 `9001` LAN2 PHY 节点

## P3 能力增强（决策标注的后续计划）
- [x] **07 天线改善固件侧落地（2026-08-20）**：regdb-0521 默认档（UNII-3/4 160MHz 30dBm）+ mt76-0008 默认档（eeprom 2G/5G 解锁）+ 默认无线 5G ch149/HE160、6G ch37、2.4G MU-MIMO 关；CI all/experimental 构建全绿（ci-36/ci-37）。（2026-08-26 修订：5G 默认改 HE80，见下条 issue #21 闭环）
- [ ] **漫游优化**（决策：暂不设置，固件稳定后实施）：802.11s/EHT320 回程、usteer/802.11k/v/r、（如多设备）mesh 配置
- [x] **iQOO 5G 兼容性实机复核（F41/issue #21，2026-08-26）**：二分矩阵闭环——HE160（psk2/sae-mixed 均拒，AP 零 auth）→ HE80（psk2/sae-mixed 均可连，PHY 1200.9Mbps）。默认 5G 改 HE80，HE160 转注释化可选档（非国行终端）；K2P-5G 保留 sae-mixed。测试记录：`docs/acceptance-results/2026-08-26-iqoo-5g-he80-fix.md`
- [ ] OC 实机验证报告：oc-1.3 与 oc-1.4 在实机的稳定性/温度，归档到 FIXES F08
- [ ] 科学上网（OpenClash/PassWall）+ Docker——暂缓项，稳定后再决策 feed 与体积预算
- [x] mt76 实验补丁（integration 树 9990-9993：EHT 广告/320M BF fallback/PS-sync/rate control）——**F25 评审（2026-08-18）+ F59 复核（2026-08-22）**：9990/9991/9993 重建入实验档；**2026-08-31 毕业转默认**（ci-74 实机 AP 侧 EHT320 + wifi down/up 5 轮通过；6G 客户端侧延后）；9992 已随 9028 bump 删除
- [ ] **IPsec/站点间 VPN 硬件卸载探索（EIP93，issue #6/F52）**：驱动已在实验档编译、/proc/crypto 注册正常；先实机验证 xfrm 连通性与 EIP93 refcnt，再按档位预装 strongswan/kmod-ipsec/ip-full；注意 EIP93 未注册 GCM-AEAD，rfc4106(gcm(aes)) 可能落软加密
- [ ] 530 实验室 6GHz SP 补丁——默认停用；如需高功率实验，手动启用并在验收注明非合规
- [x] **全 PCIe Gen3 计划（issue #16 深化）**：D0 已执行（2026-08-24）——pcie0 x2 Gen3 基线达标；pcie2 根端口 `0002:00:00.0` LnkCap2 仅报 2.5/5GT/s、不声明 Gen3，**D0-stop：pcie2 Gen2 x1 固化为板级正确拓扑**，Gen3 x1 降级为上游/厂商长期跟踪（证据：`docs/acceptance-results/2026-08-24-pcie-gen3-baseline.md`）。

## P4 工程化
- [x] 构建产出后自动打 pre-release（含 FIXES 变更摘要；2026-08-17 实现——但 F19 假绿修复前 release 是空壳，真绿后才有意义）
- [x] 构建退出码硬化（F19：pipefail + no-files-found=error，2026-08-17）
- [x] 拷贝类补丁 dry-run 真实应用校验（F20 制度化，2026-08-17：新增 `scripts/verify-copy-patches.sh` 接入 `apply-patches.sh --dry-run`——按构建语义解包包源码 + glob 排序真实 `patch -p1`，regdb 附 dbparse 校验；2h sync cron 尽早暴露而非等构建）
- [x] 实验档可构建化（F25，2026-08-18）：build.sh 加 `experimental` 档 + build.yml dispatch 支持 + sync-upstream cron 的 dry-run 加 `--experimental`（实验档享受 2h 漂移检测）；audit-patches/verify-copy-patches 感知 `#EXP` 行（apply-patches.sh 透传）；apply-patches.sh dry-run 的 set -e 缺陷修复（verify 失败不再跳过 git reset）
- [x] **守卫自证来源 + 配置错误不静默降级**（F163，2026-09-14）：`verify-copy-patches.sh` 的 git 型包源码 URL 改为**从包 Makefile 的 `PKG_SOURCE_URL` 派生**（不硬编码上游——F161 实证：硬编码在换代到 fork 源后 404，32 个 mt76 补丁会静默失去校验而 2h cron 仍全绿）；**HTTP 404/410（源不存在 = 配置错误）报红**，仅瞬时网络故障仍按 F19 保持 ⚠ 不红
- [ ] 实验档毕业的自动化：experimental 构建通过 + ACCEPTANCE 子集 → PR 式合并到默认 MANIFEST（2026-08-31 已手工毕业一批：`mt76-0005`、`9990/9991/9993`+`411`、`05/06/9024/9026`、`07/09/17/18`；自动化仍未实现）
- [ ] vermagic 注入接入 CI（F14，让自建 kmod 兼容官方 opkg）
- [ ] 2h 同步工作流稳定后，把"冲突出现 → 修复 → 回归"流程沉淀为 CI 注释/文档（sync-upstream.yml 已就位）