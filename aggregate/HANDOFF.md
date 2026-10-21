# HANDOFF — 交接文档（2026-09-08 更新：P1 上游吸收批次已完成并本地提交，见 §9）

> 接任维护者请先读：`README.md`、`CONTEXT.md`、`docs/FIXES.md`（F01–F86）、`docs/adr/0001`、`docs/adr/0002`、`docs/ROADMAP.md`。

## 0. 工作区与远程

- **本地仓库（新宿主，2026-09-07 起）**：`/home/lishujun/项目/xr1710g_openwrt/xr1710g-openwrt`（旧宿主 `/root/workspace/xr1710g-openwrt` 仅为历史记录）
- 工作区根：`/home/lishujun/项目/xr1710g_openwrt/`（素材/验证树在根下 `tmp/`，见 §8）
- 当前分支：**`main`**；当前 HEAD：`git log --oneline -1`（2026-09-08 应为 `8ce968b`）
- **P1 批次已推送（2026-09-08，`b978e02..7ce6c81`，7 commit）**：P1 吸收（`e99b88e`）+ FIXES/HANDOFF（`d0398d2`/`41a2e7b`）+ 411 修复（`0db03a4`）+ 992-21 重建（`7ce6c81`）；**本地领先 1 commit `8ce968b`（vendor/06 改名，未推送）**，待随下轮（CI 结果/收口）一起推。
- 历史 09-07 批次（已推送）：`a8e8270`/`08b6ad8`/`b978e02`（handoff 工作包化 / 411 重建标记 / mac80211-411 backports-7.2 重建）
- 关键节点：`3a7257c` = antenna 合并点；`e0cbe4a` = 实验档毕业批次；`ecb1191` = NPU FDK 合并点；`602d9d0` = P1/P2 修复主推送（build #87/#88/#89 全绿）；`aa4c8cb` = issue#7 防御补丁族；`be72915` = CI 修复批次（删 9028/9994、重建 9010/9014，sync-upstream 恢复）
- 远程：`https://github.com/genshanxinli/xr1710g-openwrt`（默认分支 `main`）
- 推送到 main（**push 自动触发 build.yml——push 事件默认 stock 档——与 sync-upstream**）：
  ```bash
  # 新宿主无 .gh-token（旧宿主遗留）；先 gh auth status 确认凭证，或重取 token：
  # export GH_TOKEN=<token>
  git push "https://x-access-token:${GH_TOKEN}@github.com/genshanxinli/xr1710g-openwrt.git" main
  ```
  > 本宿主 `git push origin` 常无输出/超时，直接用 token URL 最稳；`gh api`/`curl` 偶发 EOF/429，重试 1–2 次即可。

## 1. 仓库是什么

Gemtek XR1710G（Airoha AN7581 + MT7996 三频 Wi-Fi7、2×10G + 2×1G）的**自用 OpenWrt 叠加层仓库**：
- 基线 = `openwrt/openwrt` **main**（kernel 6.18；默认分支已改名 main，2026-09-06 起）；板级/功率/诊断等未合入内容全部由 `patches/` 携带。
- 铁律：**修复而不是降级**；上游已吸收能力的冗余补丁应撤下（非降级）。
- `patches/MANIFEST` 是实际应用清单；`patches/ORDER` 是档位评审视图，二者必须一致。
- 构建：`scripts/build.sh <stock|experimental> [树]`（唯一 CPU 档 OPP 650–1350 + oc-auto 自动退档，见 FIXES F89；容器缺构建工具，实际构建以 GitHub Actions 为准）；CI：`.github/workflows/build.yml`（workflow_dispatch：profile=all/stock/experimental）、`sync-upstream.yml`（2h dry-run）、`collect-sources.yml`。
- 实机：`root@192.168.123.1`，**优先免密**（`.ssh/ssh-device`，`-i .ssh/id_ed25519`；2026-09-16 P23 已把该公钥装进设备 `/etc/dropbear/authorized_keys`，落在 overlay ⇒ 重启不丢），否则密码 `password`。⚠ 设备凭据若被改（如清空密码），先 `ping` 确认在线并与用户确认，别连打（dropbear 限速）。

## 2. 近期会话成果（别重复做）

1. **2026-08-23 IP-EVAL A1–A12 吸收批次**（`46600b2`，已推送）：A1/F64 66MiB reserved_bmt 布局（9001/9002 ubi `0x1b700000` + reserved_bmt `@1be00000 0x04200000`）；A2/F65 compat 2.0；A3/F66 rdinit；A4/F67 风扇单控制器；A5/F68 mt76-0009；A6/F69 mt76-0010（#EXP）；A7/F70 9030 FlowSense 1.1.8-r5（9018-9023 重放至 9030 基线）；A8/F71 9029（**2026-09-08 已按 PR#143 重写，见下**）；A9/F72 C2 双侧判据；A10/F73 FLASHING 坏版本清单+救砖；A11/F74 验收方法学（B6 已按用户口径取消）；A12/F75 device-hw-probe（B2.1 C45 MMD30 借道 wan/lan3）。
2. **2026-08-30/31 实验档毕业**（`e0cbe4a`，ci-74 实机后毕业 12 项）：`mt76-0005/9990/9991/9993`+`mac80211-411`、`vendor/05/06`+`root/9024/9026`、`vendor/07/09/17/18` 转 default；默认配置补强（compat 2.0、`99-xr1710g-flow-offload` uci-defaults）。9035（FLOW_STATS 共存）08-31 ci-88 验证后转 default（`a820ea0`→`aba19bf` 重建 04 config 上下文，#94 all/#96 experimental 全绿，#94 stock fresh flash 复验通过）。
3. **2026-09-07 CI 修复批次**（`be72915`，已推送）：openwrt 09-01 bump mt76→be5ce791 导致 sync-upstream 连红 7 天——删 9028/9994、重建 9010/9014；dry-run 55/55 全绿，sync-upstream 恢复绿（run 34097546620）。
4. **2026-09-07 mac80211-411 重建**（`b978e02`）：411 适配 backports-7.2（naoki66 9009304b6 为参考实现；vht.c hunk 迁 sta_info.c、等价基元 `ieee80211_sta_bw_capability`+`link_sta->capa_nss`）；ci-97 构建验证状态待查（见 §3）。
5. **2026-09-07 issue#7 防御补丁族**（`aa4c8cb`）：9036/9037（9996/9997 方案 A/B 二选一，#EXP）+ `docs/analysis-issue7-flow-offload-reboot.md`。⚠️ 调研子代理直接提交推送，流程越权已记录。
6. **2026-09-07 并行五路吸收调研**：mt76 / YYH2913 / fanboy / naoki66 / 社区上游——结论与证据见 §9.2 交付物。
7. **2026-09-08 P1 上游吸收批次（10/10 WP 全部完成，commit `e99b88e`，未推送）**：
   - WP-9029：9029 按 rdmitry OW1700k PR#143 机制整体重写（内层 9992：post_config hook 仅 `an7581_pcs_eth` + TCLVAR `0x3→0x5` 脉冲 + ETH/PON 分值 `0x5/0x3`；旧"bringup 内同值重写"=HW no-op，devmem `0x1fa7a030` 证据）
   - WP-0011：`mt76-0011` NPU RX descriptor ownership（Oever González/NTB，**default**，修 consume 越界 panic + refill 竞态）
   - WP-delsta：`mt76-0012` NPU del_sta（naoki66 2d3aa30/Ryan Chen，#EXP，断连→同 MAC 重连 ~1Mbps 残留）
   - WP-USXGMII：`root/9038`（#EXP，内层 9994 = YYH 628 RX CDR SDK crossing 搜索——#22397 "No FBCK Lock" 根因域）；**625 未吸收**（语义前提 = YYH 私有 620/622，master 无 `airoha_pcs_set_usxgmii_speed`），9993 号段保留待补
   - WP-PPE：`root/9039`（#EXP，内层 9990 = hurryman2212 底座 + YYH 916e91a HEAD 态；PACKET_HOST 留 CPU；与 9035/9995 双向顺序验证通过）
   - WP-pinctrl：`root/9040`（#EXP，内层 9998 = YYH 436765d；phy5/phy8 reset pad GPIO46/31 force-GPIO；master 74eb10e 已合 202-xx/203-01/02 基础设施 → 零重建直接适用）
   - WP-SerDes：`root/9041`（#EXP，内层 **742**=622 SDS-mode（naoki66 09feeff 6.18.44 版，删 export hunk——`rtl826x_phy_patch_sds_set` 已非 static）/**743**=restore/**744**=reapply（b74553b/d3a0fa1 语义）按文件名序应用）+ `9001` phy5（`realtek,sds-mode=<0x88c6>`+`reset-before-id-read`+`patch-rtk-serdes`）/phy8（`patch-rtk-serdes`）属性
   - WP-F77：`vendor/fanboy/18` 的 992-21 更新为 e352c48673 83 行版（mbox DONE 轮询 1000→500ms）；992-20 184 行未动；OWT 真应用后 blob 与上游逐字节一致（F77 收口）
   - WP-675：`vendor/fanboy/06` 替换为 `format-patch 2ed1af79c7` 原样（675-01/02/03 精简 -28%，**删 650 KEEP_HW 段**——枚举已删、无消费方）；9026（675-04）复核通过未改动
   - WP-vendor07：`vendor/fanboy/07` 的 0014 按 be5ce791 重生成（hunk 行号重基：main.c 1713→1653、mcu.c 1043→779/1055→791、mt7996.h 300→301；纯行号、语义零变化）
   - **全链验证**：audit-patches 61/61 一致；`apply-patches.sh --dry-run --oc --experimental` 全绿（61 补丁、实验档跳过 0、缺失 0）；verify 真实应用 regdb 5 / mt76 14（含新 0011/0012、0014）/ uboot 41 全部成功
   - FIXES.md：F71 重写、F77/F78 收口、新增 F79–F86；HANDOFF §9.1 同步（commit `d0398d2`）

## 3. 构建与验证状态（2026-09-08）

- **最后绿 CI（2026-09-08 P1 批次 7ce6c81）**：stock（34134102608）/ all 三档（34134117948）/ experimental（34134122223）**全绿** + sync-upstream（34134102601）绿。ci-97 双缺陷（411 pub->band + 992-21 F77 回归 hunk）已修复并实机构建验证。
- **实机回归（firmware experimental r0-7b39600，已刷）**：见 `docs/acceptance-results/2026-09-08-p1-regression.md` —— LAN2 冷启动 ×20 = 20/20 2.5G（10G 未达成；9029 生效 devmem=0x301D；10G 对端项延后→机制取舍 open）、#22397 未复现、wifi down/up PASS、hw-probe 全绿、风扇 1312RPM、sysupgrade -T PASS。known-good tag：`known-good-p1-20260908`（指向 7ce6c81）。
- 历史：#87 stock/#88 all/#89 experimental 全绿（`602d9d0`）；D3 时长维度 09-07 达标（`docs/acceptance-results/2026-09-07-d3-longrun-7d.md`；2×10G + 三频高负载压力条件未达，D3 整项保持 open）。

## 4. 实机可用命令

```bash
cd /home/lishujun/项目/xr1710g_openwrt/xr1710g-openwrt
# 登录（wrapper 固定 -F /dev/null 绕过本宿主损坏的 ssh_config.d）
./.ssh/ssh-device
# 或 ssh -i .ssh/id_ed25519 -o StrictHostKeyChecking=no root@192.168.123.1

# LED 失败点追踪
ssh root@192.168.123.1 'sh -x /etc/rc.common /etc/init.d/led start' > /tmp/ledx.log 2>&1
# wifi down/up 复现（issue #10）
DEVICE_HOST=root@192.168.123.1 ./scripts/device-wifi-downup-probe.sh
# 硬件深度探针（A12 增强后）
DEVICE_HOST=root@192.168.123.1 ./scripts/device-hw-probe.sh
# NPU IPv6 专项探针（含 HW_OFFLOAD 与 PPE BND v6）
DEVICE_HOST=root@192.168.123.1 ./scripts/device-npu-ipv6-probe.sh
```

## 5. 当前 patch 层速览（2026-09-08，与 MANIFEST 逐行核对）

**默认档 ROOT 链**（按应用顺序）：`9000/9001/9002` 板级（66MiB reserved_bmt + rdinit；9001 含 phy5/phy8 SerDes/复位属性） → `vendor/03` cpufreq → `vendor/10` pstore → `9017` apps-pack → `9030` FlowSense 1.1.8-r5 → `9018` VLAN/PPPoE → `9019` CLIENTS → `9020` memory_regions → `9021` sysfs stats → `9022` IPv6/UDP → `9023` 优雅降级 → `9032` PPE 每流统计 → `9025` no-carrier rx stats → `9027` ledtrig-netdev → `9031` LED interval skip → `9033` RTL826x LED → `9010` txpower ucode → `vendor/11` LRO → `9011–9016` 08 切片 → `9035` flow-stats 共存（9995；须在 04 前） → `vendor/05` bridge offload → `vendor/06` nft L2（**2026-09-08 替换为 2ed1af79c7 版**） → `9024` deps/table → `9026` init/conntrack（675-04，复核通过未动） → `vendor/07` HW_RRO teardown（**0014 已按 be5ce791 重生成**） → `vendor/09` HW1.1/2.1 → `vendor/17` cmonroe → `vendor/18` smartrg（**992-21 74 行版，2026-09-08 重建删 F77 吸收版重引入的超时 hunk——F87**）。2026-09-07 CI 批次后 **9028/9994 已删**（上游 bump be5ce791 自带）。

**实验档（#EXP，10 条）**：`vendor/02`（EIP93）、`vendor/04`（DSA）、`mt76-0010`（NPU RX skb->dev，待 6G 客户端）、`mt76-0012`（del_sta）、`9029`（JCPLL recal，PR#143 重写版）、`9036`（issue#7 方案 A，9996；9037 方案 B 备选未启用）、`9038`（USXGMII 628，9994）、`9039`（PPE 本地流，9990）、`9040`（pinctrl force-GPIO，9998）、`9041`（SerDes/SDS 742/743/744）。

**mt76 包补丁默认档**：`0001/0003/0005/0006/0007/0008/0009`、**`0011`**（NTB ownership，新）、`9990/9991/9993`；`0010/0012` 为 #EXP。另 mac80211 subsys `411`（9993 编译依赖，backports-7.2 重建版）。

**内层号占用（target/linux/airoha/patches-6.18/）**：742/743/744（SerDes）+ 992-20/992-21（smartrg）+ 9990（PPE）/9991（9025）/9992（9029）/9993（预留 625）/9994（9038）/9995（9035）/9996（9036）/9997（9037 备选）/9998（9040）。外层号段：9000-9041（9037 备选、9038-9041 新增）。

## 6. 上游状态快照（2026-09-07 查询；09-08 增量标注）

| 源 | 快照 |
|---|---|
| openwrt main | **74eb10e**（09-08 前后，比 09-06 的 fe4bb132 更新；09-08 增量：**pinctrl v7.3 大系列 202-01~202-28 + 203-01/02/06/08/09 合入**——WP-pinctrl 零重建的依据；评估日 09-07 的 master 尚无 203-01/02，评审报告编号"半对"） |
| openwrt mt76 pin | **be5ce791**（09-01）；mt76 包 patches/ 目录已空（上游删 100-mac80211-support-kernel-version-7.1.patch） |
| fanboy ubi2-oc | f08c3d1e（09-06 整枝；mt76 fork 01367e60=be5ce791+1 提交 + 20260721 固件）；ubi2=00ed581b；无新 release |
| YYH2913 integration | c82129e7（08-31，+8 提交：USXGMII/SerDes/PPE/MIB/pinctrl/px5g/DHCP） |
| naoki66 | 621c27093（09-07）；09-03 固件 release（0e959250f7）；mt76 pin=be5ce791 与本地一致 |
| YYH2913/http-uboot 锁版 | 53b73174 无变化（锁版不受影响；升级前核对 release 页 SHA256） |
| wireless-regdb | 上游 2026.09.03 新发布；openwrt 包仍 2026.05.30（本地 regdb 补丁无漂移） |
| openwrt feeds | packages=1056fa0f、luci=7dda604a（09-07） |

- 跟踪 PR：仍 open #22397（XR1710G 板级，代码停在 04-11 但 review 类活动持续）、#22029（cpufreq/pmdomain）、#22473、#22532、#22533、#24034（RTL826x LED）、#24619、#23990、#24025；**#24973（PCS fwnode DRAFT）为 9029/9001 唯一冲突窗口，每轮 sync 检查**；已 merged 大批（#21777/#23078/#23383/#21978/#22391/#24593/#22289/#23427/#22564/#23566/#23828 等）。
- 失效源：`Arthur97172/Gemtek-XR1710G-wrt-builder`、`hx801217/iStoreOS-for-Gemtek-XR1710G`、`luoyizhi1987/XR1710G-YYH-OC` 均 404（`Arthur97172/Airoha-wrt-builder` 仍存在）。

## 7. 下一步：P1 推送 → CI → 实机回归 → 收口

### 7.1 推送与构建（2026-09-08 已执行：推送 + dispatch 完成）
1. ✅ `b978e02..7ce6c81` 已推 main（2026-09-08 14:38Z，7 commit）——自动触发 stock build + sync-upstream。
2. ✅ 手动 dispatch：all + experimental（runs 34134117948 / 34134122223）。
3. ✅ ci-97 已定性并修复：run 34107054747 失败 = 411 重建版 `pub->band` 编译错（构建日志实证：
   `sta_info.c:3735:55: error: 'struct ieee80211_link_sta' has no member named 'band'`）→ `0db03a4`
   按 naoki66 9009304b6 重写；另发现并修复 F87（992-21 F77 回归 hunk，`7ce6c81`）。
4. 牵动面（同 §7.1 原文）：experimental 是主要验证载体——本批含 1 条 default 新补丁（0011）+
   4 条新 #EXP 内核补丁目录（9038-9041）+ 3 个 vendor 内容更新（06/07/18）+ 9029 重写；
   **内核内层链已本地全序真实应用 19/19 + 符号审计（9029/9038-9041/742-746/992-20/21/9990-9998）**。

### 7.2 实机回归清单（P1 吸收后；判据见 FIXES F71/F77-F86 / 上游吸收方案 §五）
- **LAN2 10G 冷启动 ×20 + link 率**：9029（PCS JCPLL）/9038（RX 校准）/9041（PHY SerDes）三机制联合判定；`devmem 0x1fa7a030` 一行实证（写 `0x1D` 后 lan2 link → 冷启动 5/5 → F71 收口）
- **#22397 复现脚本**（ifdown/up 恢复）+ dmesg FBCK_LOCK：9038 是否命中真根因；与 9029 对照后决定机制取舍（可能其一冗余）
- **断开→同 MAC 重连吞吐**（mt76-0012：~1Mbps 残留修复）；**NPU 长时间稳定**（mt76-0011）
- **bridge + FLOW_STATS 共存回归**（新 675 系列 × 9035）
- **GPIO 46/31 方向生效**（/sys/kernel/debug/gpio）+ PHY 复位行为（9040）；与 9001 新 dts 属性（9041）联动
- 回归项：三频/wifi down/up（0011/0012 同域）、风扇/LED、device-hw-probe 全绿、`sysupgrade -T`
- 6G/10G 物理对端项仍未闭环（C2 客户端侧、C3 外部 iperf3、B2 双 10G 对打）——按用户口径延后

### 7.3 收口
- 实验档毕业决策：9029 vs 9038/9041 对照后定去留；625 待吸收 YYH 620/622 后补（9993 号段预留）；`vendor/06` 文件名旧 hash `c0ed8295` 建议改名（连同 ORDER/MANIFEST 注释）
- `docs/ACCEPTANCE.md` 全项（含 D3 压力条件：2×10G + 三频高负载），冻结 known-good tag
- 跟踪：sync-upstream 2h cron 对新增 #EXP 补丁的漂移检测；#24973；MIB lossless（上游 netdev 已合，等内核 bump——届时 **9025/F55 需同步重建**：清 MIB 与 delta 法冲突 → 改只同步 mib_prev）

## 8. 宿主环境备忘（新宿主，2026-09-07 起）

- 容器缺 `make/gawk/mkhash` 等完整 OpenWrt 构建工具；本地只做 patch 生成、审计、验证、ssh 实机。真正构建以 GitHub Actions 为准。
- `gh api`/`curl` 偶发 429/EOF；空输出先重试。**新宿主无 `.gh-token`**（推送需先取凭证，见 §0）。
- **沙箱每次 bash 调用 `/tmp` 隔离**：probe `OUT_PREFIX` 与下载缓存须指向工作区（`COPY_PATCH_CACHE`）。
- **验证基座（2026-09-08 搭建，P1 验证用）**：
  - `tmp/owrt-absorb` = openwrt main **74eb10e** 浅克隆 + 仓库层 rsync（`--exclude='.git' --exclude='.github' --exclude='tmp' --exclude='docs/acceptance-results'`；**rsync 勿带 --delete**，会误删 openwrt 树 scripts/patch-kernel.sh）——全链 dry-run 用
  - `tmp/kernel-base` = linux **6.18.44**（GitHub gregkh/linux codeload；cdn.kernel.org 多次断流）+ openwrt 6.18 补丁集已应用的 git 仓库（baseline + applied 两个 commit）——内核内层补丁验证用（`git apply --check`；真应用用 `--clone --shared --sparse` 副本）
  - `tmp/mt76_clone` = be5ce791（09-08 已修复工作区损坏；`git archive` 可作干净副本源）
  - 素材/规格：`tmp/absorb/00-wp-specs.md`（工作包规格+验证指南）、`tmp/absorb/dryrun-full.log`（09-08 全链 dry-run 日志）、`tmp/absorb/wp-*/`（各 WP 产物与验证副本）
- 社区源码克隆：`tmp/ow1700k-ubi2oc`（ubi2-oc f08c3d1e）、`tmp/yyh2913-openwrt`（c82129e7）、`/home/lishujun/项目/xr1710g_openwrt/naoki66-xr1710g`（**在工作区根，不在 tmp/**，621c27093）、`tmp/yyh2913-patches/`（8 提交导出）、`tmp/research_20260907/`（rdmitry PR#143/144、NTB 补丁 1-6、backports-7.2 解包 `bp72/`）。
- ssh 免密已重建：`.ssh/id_ed25519`（新钥）+ `.ssh/ssh-device` wrapper（本宿主 `/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf` 属主损坏，wrapper 固定 `-F /dev/null` 绕过；首参含空白自动补 `DEVICE_HOST`）。

## 9. 上游吸收批次记录（2026-09-07 编排，P0/P1 已完成）

> 背景：openwrt 2026-09-01 bump mt76（59676919→be5ce791），导致 sync-upstream 自 08-31 20:03Z（run 33433908434）连红约 7 天。
> **P0（CI 修复）**：`be72915` 已推送（删 9028/9994、重建 9010/9014）；`b978e02` 411 重建（ci-97 验证中，待查）；`aa4c8cb` 9036/9037 防御补丁族（#EXP，dry-run 验证过）。
> **P1（10 工作包）**：2026-09-08 全部完成（commit `e99b88e`/`d0398d2`，本地未推送），详见 §2.7。WP 素材位置与步骤细节保留在本次 commit diff、FIXES F71/F77-F86 与 `tmp/absorb/`。
> ⚠️ 遗留提示：① `vendor/06` 文件名旧 hash `c0ed8295`（改名下轮做）；② naoki66 源仓 622 补丁文件 hunk 计数损坏（其 fork 直接搬用会红，本地已修正）；③ `reset-before-id-read` 内核侧消费（naoki66 hack-6.18/705）未吸收——属性惰性无害，实机需要再补；④ 625 待 620/622；⑤ 内层号/外层号段占用表见 §5。

### 9.1 P2（可选/低优先）
- OPP dts 增量（naoki66 bb84606：smcc_opp15-18，唯一档 base 650 重建（F89），运行时段由 oc-auto 退档链（1350→1300→1200）替代 oc-limit 1300；BL31 须接受 opp-level 15-18，实机验证）
- PPE bind_rate 补丁②（`tmp/research_20260907/ntb_patch6.txt`，对 6.18 airoha_ppe.c:148 重建）
- 20260721 mt7996 固件覆盖层（不跟 fork——F13 fork+hash=skip 否决；需时自制或等上游收录）
- e4e7c4f 仅跟踪（FW_LOADER_FALLBACK off，本地 5 个 config 区不相交）；px5g-mbedtls / DHCP clientid 一行（各 1 行级，可选）
- master→main 文案清理（ADR/README 措辞）

### 9.2 不采用 / 等上游（勿重复工作）
regdb 510/520 合并 30dBm（naoki66：删 DFS flag、U-NII-4 无 NO-IR、CN 2.4G 超 MIIT——合规回退，本地体系更稳）；luci-app-airoha-factory（fw_env 指 stock env，本地 UBI env 布局不兼容，假成功）；MIB lossless（等内核 bump，届时 9025/F55 同步重建）；eeprom 0 值填充（Mironov aaf90b24，本机空转）；e61a1bb-629 TX FIR DT 覆盖（A/B 实验钩子，仅跟踪）；1c8dfcf luci-theme-glass（无承载对象，仅跟踪上游）；v1.5.0 前台 CAC（本地已前台）；TWT/MLD/WED 8 条（随 be5ce791 自然获得）；上 open PR 全部继续跟踪（见 §6）。

### 9.3 交付物（报告/方案/证据）

| 文件 | 内容 |
|---|---|
| `上游吸收方案-2026-09-07.md`（工作区根） | 吸收方案汇总（P0-P3 表 + 实机回归清单 + 不采用清单） |
| `评估-YYH2913-08-31八提交-吸收评估.md`（工作区根） | YYH2913 8 提交逐项评估（9036-9041 号段落点；9025 联动重建） |
| `fanboy-ubi2oc-09-06重建评审报告.md`（工作区根） | fanboy 整枝评审（992-21/675 系列/HW-RRO 删除/20260721 固件） |
| `信息更新调研-2026-09-07.md`（工作区根） | 社区/上游信息更新汇总 |
| `tmp/naoki66-0907-absorb-report.md` | naoki66 提交评估（411 重建/SerDes/SDS/factory/regdb/OPP） |
| `tmp/research_20260907/` | rdmitry PR#143/144 diff、NTB 补丁 1-6 全文、backports-7.2 解包、论坛 JSON |
| `tmp/research/dryrun-logs/` | 四轮 dry-run 复现日志（9028/9010/9014 漂移证据链） |
| `docs/analysis-issue7-flow-offload-reboot.md` | issue #7 离线根因分析（aa4c8cb1 提交） |
| `tmp/absorb/00-wp-specs.md` + `tmp/absorb/dryrun-full.log` | P1 工作包规格/验证指南 + 2026-09-08 全链 dry-run 日志 |