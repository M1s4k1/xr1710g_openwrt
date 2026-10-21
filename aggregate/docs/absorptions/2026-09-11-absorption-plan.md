# 吸收方案与深度调研（2026-09-11）

> 输入：`信息更新调研-2026-09-11.md`（本仓/上游/生态/社区增量）+ 三路并行深度调研
> （B-1 第三方源更优点 / B-2 上游 PR 与新仓库 / B-3 全源穷尽扫描）。
> 本文只记录**结论与可执行方案**；证据路径见 §8。
> 落地状态以 `patches/MANIFEST` 与 `docs/FIXES.md` 为准。

## 1. 摘要（本批已落地 vs 待办）

| 编号 | 内容 | 档位 | 状态 |
|---|---|---|---|
| `mt76-0013` | NPU offload 下刷新 tx-agg(BlockAck) 会话定时器（Gilly 045） | #EXP | **已落盘**，机制前提待实机判定（§3.1） |
| `root/9042` | airoha small RX rings 增长（上游 #24872：fallback 16→32、ring4→128） | default | **已落盘**；**必须置于 vendor/11 之前** |
| `root/9043` | bridge-flow-offload 注入两防护（hw-offload 守门 + 清陈旧 include） | default | **已落盘** |
| `root/9044` | USXGMII 速率自适应移出 else 分支（naoki66 625） | #EXP | **已落盘**，内层待构建树实跑 |
| P1 待办 | Gilly 047 / 034 / 035 / 036 / 042 / 026 / 044（NPU 复位 + panic/竞态/越界） | #EXP | 已实测 APPLIES，待批量吸收 |
| P2 待办 | Gilly 981 / 980 / 976 / 957 / 960 / 961（RX 环恢复 / 中断 / BQL / thermal） | #EXP | 同上 |
| P2 待办 | Gilly 748 **替换** `root/9016`（区分 ENODEV 与真实错误） | default | 方案已定，待实施 |
| P2 待办 | `scripts/prepare-oc.sh` PLL 公式基线断言（硬失败而非告警） | 脚本 | 方案已定，待实施 |
| P3 观察 | Gilly 046 / 972 / 973；上游 #25092 / #24819 / #25090 | — | 条件跟，见 §6 |

**本轮全链验证**：`audit-patches.sh` **65/65 一致**；`apply-patches.sh --dry-run --oc --experimental`
对最新上游 main **`3de9bf7`** 全绿（`处理：65 实验档跳过：0 缺失文件：0`，无冲突）；
`9042 → vendor/11` 顺序实证通过；u-boot 拷贝目标 40 文件真实应用通过。

---

## 2. 已落地补丁

### 2.1 `root/9042` — airoha small RX rings（上游 #24872，default）

- **问题**：ring 4 是共享 "force to CPU" 环（`airoha_fe_vip_setup()` 把 BOOTP、PPPoE Discovery、
  PPP LCP/IPCP/CHAP/PAP/IPv6CP、ISAKMP、DHCPv6、SIP、LLDP 都导到它，两个 CDM 的
  `CDM_VIP_QSEL_MASK` 都 = 4）。16 描述符只占 4096B page 的 512B，硬件跑到环尾**不在边界停下**，
  page 尾部是以 32B 为周期重复的"描述符形状"数据 → 硬件越过已投递描述符、在非环内 slot 找不到
  buffer，标 DROP 但仍写描述符结构 → **越过 page 即写进内核内存**。
- **后果（上游实测）**：DHCP/PPPoE 握手期内核 panic 5 次（垃圾指针落在
  `dbs_irq_work`(cpufreq) / `sched_balance_rq` / `nf_conntrack_hash_check_insert`），
  或 PPPoE 协商永不完成（60s 内 6455 次采样：`REG_RX_DMA_IDX` 0x2c→0x52 前进而
  `REG_RX_CPU_IDX` 卡在 15）。
- **修法**：`RX_DSCP_NUM()` fallback 16→32（vendor SDK 默认；实测 16↔32 之间是硬件边界），
  ring 4 → 128（与 ring 2/11/15 一致）。代价 1088 描述符 ≈ 2.1MiB RX buffer + 34KiB coherent desc。
- **本仓落地**：新增 wrapper 补丁（内层 `182-v7.4-net-airoha-grow-the-small-RX-rings.patch` 逐字节
  等同上游 PR），并同步 `310-10 / 916-02 / 920-12 / 920-13` 的内层 hunk 行号与 `16→32` 上下文。
- **顺序约束（已实证）**：`9042` **必须在 `vendor/fanboy/11`（LRO）之前**——916-02 的基线被本补丁更新，
  vendor/11 的 `@@ -553,8` 段依赖该新基线。dry-run 顺序：`9042`(L39) → `vendor/11`(L41) 均 ✓。
- **上游状态**：`upstream-open`（#24872，`mergeable_state=blocked`）；合入后删除 `9042` 并改 FIXES 状态。

### 2.2 `root/9043` — bridge-flow-offload 注入防护（default）

- **问题（本仓原缺）**：① `flow_offloading_hw != 1` 时脚本仍会注入 `flags offload` 流表，
  与用户/前端关闭 HW offload 的意图冲突；② 上一版留在
  `/usr/share/nftables.d/ruleset-post/` 的陈旧 include 不会被清理，开关来回切换后旧规则仍被 fw4 加载。
- **已由 9024 处理、本补丁不重复**：表名 `bridge fw4 → bridge flow_offload`、reload 去后台 `&`（防重入）。
- **修法**：`main()` 内加 `flow_offloading_hw` 守门（不满足则清 `$RULES_FILE` + 删表 + 记日志）；
  写文件前 `rm -f "$RULES_FILE"` 清陈旧 include。
- **来源**：对照 `yahuisme/w1700k-openwrt` 的 `apply-rules.sh` 实践（2026-09-10）提炼，
  **表名沿用本仓 `bridge flow_offload`**。
- **判据**：关 HW offload + 重跑 → `nft list table bridge flow_offload` 为空且无
  `30-bridge-offload.nft`；开回 → 规则恢复、PPE BND 计数恢复增长。

### 2.3 `root/9044` — USXGMII 速率自适应（naoki66 625，**#EXP**）

- **问题**：上游 `airoha_pcs_link_up()` 把整段 USXGMII 速率自适应
  （`RATE_UPDATE_MODE` / `FORCE_RATE_ADAPT_MODE`）关在
  `neg_mode != PHYLINK_PCS_NEG_INBAND_ENABLED` 的 **else 分支**里；而 USXGMII 走 in-band 自协商
  → **该段永不执行**，速率切换后寄存器停在上一档速率。
- **价值**：**直接关联本仓 2026-09-08 实机验收记录"PHY 宣告 10G、AN 落 2.5G"**
  （`docs/acceptance-results/2026-09-08-p1-regression.md` / commit `d25a994`）——
  是 10G LAN2 无法升到 10G 的**确定性候选根因**，且覆盖 10G/5G/2.5G/1G/100 全速率。
- **来源与验证**：naoki66 `target/linux/airoha/patches-6.18/625-…on-link-up.patch`（Ryan Chen）；
  在 naoki66 基线上 clean applies（Hunk #1 succeeded at 694, offset -53，B-1 实测）。
  **本仓构建树内层未实跑** → 列 #EXP。
- **判据**：强制 10G↔2.5G↔1G 切换后 `ethtool` 速率与实际协商一致，
  且 `RATE_UPDATE_MODE` / `FORCE_RATE_ADAPT_MODE` 随速率更新。
- **与既有补丁的关系**：与 9029（JCPLL）/9038（RX CDR）**机制不同、互补**——
  9029/9038 修"链路能否起来/校准"，9044 修"起来后速率档位是否正确"。三者构成 10G LAN2 的
  完整机制矩阵（见 §4）。

### 2.4 `mt76-0013` — NPU 下刷新 tx-agg 定时器（Gilly 045，**#EXP**）

见 §3.1 的机制判定与加固方案。

---

## 3. 两个"机制未定"项的判定链与加固方案

### 3.1 `mt76-0013`：门扩展是否足够（TXS 是否上报）

**静态事实链（已核实，mt76 `be5ce791`）**：
- `ieee80211_refresh_tx_agg_session_timer()` 全驱动**仅 1 个调用点**：
  `mt7996/mac.c:1517`（`mt7996_mac_add_txs_skb()`）。
- 该函数仅由 `mt7996_mac_add_txs()` 调用，而后者仅由 `mt7996_queue_rx_skb()` /
  `mt7996_rx_check()` 的 `case PKT_TYPE_TXS:` 触达。
- NPU TX 走 `mt76_npu_dma_add_buf()`（不登记 skb），但 **token 仍由 `mt76_get_txwi()` 分配**，
  归还只发生在 `mt7996_mac_tx_free()` 的 `mt76_token_release()` → **TXFREE 必然上报**
  （否则 token 池秒空、TX 停摆）。
- 但 **TXS 无任何强制来源**，是固件上报策略，与 `PKT_TYPE_TXRX_NOTIFY` 是两个不同 PKT_TYPE。
- **结论**：`0013` 有效当且仅当 NPU 卸载下固件仍为卸载帧上报 TXS → **静态不可判定**。
- Gilly 本人在论坛亦留了退路（"若是 no-op，refresh 需要挪到 transmit-free 路径"）。

**判定实验（低成本，二选一）**：
1. 在 `mt7996_mac_add_txs_skb()` 的刷新点前加一个 debugfs 计数器（`#EXP` 临时补丁或直接打点），
   跑 Samba/大文件 + Intel 客户端 ≥10min；
2. 计数器**增长** → `0013` 足够，可按判据毕业 default；
   计数器**不增长** → 采用加固方案（下）。

**加固方案（不依赖 TXS 假设，推荐作为 0013 的后续）**：
在 `mt7996_mac_work()`（本仓 `mt76-0003` 已在此轮询固件 AIR_TIME/ADM_STAT/MSDU 计数）中，
对 `mtk_wed_device_active() || mt76_npu_device_active()` 且存在 agg 会话的 TID 周期性调用
`ieee80211_refresh_tx_agg_session_timer(sta, tid)`。
- 优点：不依赖"固件是否报 TXS"；`mac_work` 周期（~100ms）远小于实际 ADDBA timeout；
  与既有轮询合并、**零额外唤醒**。
- 注意：需在 `mt7996` 侧遍历有效 link/TID，避免对未建立 agg 的 TID 调用（mac80211 侧对无
  agg 会话的调用是 no-op，但仍应做门控以省开销）。

### 3.2 Gilly `972/973`（IPv6 UPDMEM 源 MAC）是否需要

- 本仓 `9022` 改的是 **LuCI RPC 展示口径**（`luci.airoha_flowsense` 的 `get_ppe_entries()`，
  IPv6 计数规范化 + UDP `HW_OFFLOAD` 改 conntrack 判读）→ 让 IPv6 卸载问题"看得见"。
- Gilly `972/973` 改的是**内核 `airoha_ppe.c`**：IPv6 流条目源 MAC 走 UPDMEM，而 UPDMEM 只被
  `ndo_set_mac_address` 更新 → VLAN upper 克隆 MAC 时，卸载出去的 IPv6 用**陈旧基址 MAC**
  （MAC 绑定型 ISP 上直接黑洞）；`973` 再补按 MAC 分配槽位解决同端口多 MAC 抢单槽竞态。
- **结论：互补、不可替换**。本仓内核侧 `UPDMEM`/`src_mac` **0 命中**。
- **前置条件**：需存在"克隆 MAC 的 VLAN"且路径走 `airoha_gdm_dev`；本仓 WAN=`gsw_port1`
  → **先实机复现再决定吸收**（不复现则降级为观察）。

---

## 4. 10G LAN2 机制矩阵（现状全景）

| 机制 | 载体 | 档位 | 状态 |
|---|---|---|---|
| E2 silicon 手动 RX 校准开闸（`PRODUCT_ID < 0x2 → < 0x3`） | `vendor/fanboy/09` 内层 745（= Gilly 745） | default | 已有（逐字一致） |
| RX CDR 校准 SDK crossing 搜索 | `root/9038` 内层 9994（= naoki 628） | #EXP | 已有 |
| JCPLL VCO band search 重触发（TCLVAR 0x3→0x5） | `root/9029` 内层 9992（机制 = Gilly 747） | #EXP | 已有（含 ETH/PON 0x5/0x3 拆分 + devmem `0x1fa7a030=0x301D` 证据） |
| RTK SerDes SDS mode + restore/reapply（DT `realtek,sds-mode=0x88c6`） | `root/9041` 内层 742/743/744（= naoki 622/743/744） | #EXP | 已有 |
| RTL8261CE 驱动 + LED | `vendor/fanboy/09` 全量驱动 + `root/9033` | default | 已有 |
| **USXGMII 速率自适应在 in-band 下不生效** | **`root/9044`（= naoki 625）** | #EXP | **本轮新增** |
| 可选 TX FIR override（A/B 钩子） | naoki 629 | — | 未吸收（作者自述无可靠 tuple，实验接口） |

**实机机制取舍实验建议**（下一轮）：在 experimental 档下逐个 disable 9029 / 9038 / 9041 / 9044，
做 LAN2 冷启动 ×20 + `devmem 0x1fa7a030` + `ethtool` 速率三判据，定位真正生效项与冗余项。
`#22397`（上游）自 08-30 后无人提及 E2 校准与 JCPLL —— 本仓手里有 745/9029/9038 三份机制证据，
**可主动补 PR 评论**推动上游定论（成本低）。

---

## 5. 待吸收清单（按价值 × 可行性）

### 5.1 P1（建议下一批）

| 项 | 内容 | 改动面 | 验证状态 |
|---|---|---|---|
| Gilly `047` | 全复位后 restart NPU（`+24/-0`）。上游 `mt7996_mac_restart()` 只重启 WED；NPU 板全复位后 host TX 永死，且两个 NAPI 循环只对 WED 跳过 RRO 队列 → NPU 下对**未 `napi_add` 的队列 `napi_disable()`**，解引用 NULL oops | 新 `mt76-0014`（#EXP，单独成条便于回滚） | 实测 APPLIES |
| Gilly `034/035/036/042/026/044` | `reg_lock` irqsave 防 AP panic / wcid 竞态 / 事件越界校验 / ALTX 队列 / all_sta_info 校验 / ie-countdown TLV 长度 | 新 `mt76-0015`（#EXP，可分组） | 实测 APPLIES（未运行时验证） |

### 5.2 P2

| 项 | 内容 | 改动面 |
|---|---|---|
| Gilly `981/980/976` | RX 环停顿恢复 / `RX_NO_CPU_DSCP` 中断 / RX queue 31 中断（与 `9042` 不同 hunk，不冲突） | 新 `root/9045`（#EXP） |
| Gilly `960/961` | thermal 两处 1 行确定性 bug（`FIELD_PREP` 掩码、low-trip 变量） | 同上（可合并） |
| Gilly `957` | QDMA TX 共享环 BQL underflow / UAF | 同上 |
| Gilly `748` **替换** `root/9016` | 9016 无条件删 `an7581_phy_probe()` 的 `dev_err`（会掩盖真实 pinctrl 错误）；748 区分 `-ENODEV`（静默）与真实错误（`dev_warn` + `%pe`）并覆盖 mt7988 | 改 `root/9016` |
| `prepare-oc.sh` 断言 | PLL 公式 `freq_mhz = 500 + state * 50` 找不到时**硬失败**（当前仅告警 → OC 可能静默不完整）。范式取自 yahuisme（其基线 700，本仓须用 650，**勿照抄数值**） | 改脚本 ≈6 行 |
| b2.1 探针扩展 | `device-hw-probe.sh` 打印 10G PHY `phy_id`/`0x103`/`0x104` 判定 + SerDes `0x758d` 链路位，为 #25092 适用性提供实测依据 | 改脚本 ≈15 行 |

### 5.3 P3 / 观察

- Gilly `046`（固件站计数器上报；实测 30s 固件 8937 包 vs mac80211 161 包）——与 `mt76-0003` 路线重叠，需先比对。
- Gilly `972/973`（见 §3.2，先复现）。
- 上游 `#25092`：**本机 10G PHY 已实测判定 = RTL8261BE**（实机 dmesg：
  `RTL8261BE 10Gbps PHY mt7530-0:05 / :08`；`ethtool` lan2 PHYAD 5、lan1 PHYAD 8）
  → `0x001cc899`（RTL8261CE_CG）与 CE 专用极性**均不适用**；**不跟 744/745**。
  但**合入后本仓 `9041` 内层 742/743 与 `9033` 必须重基**（上游改 generic `pending-6.18/742|743`
  并新增 744/745；本仓建的是 `airoha/patches-6.18/742|743|744` —— **不同目录、非文件名冲突**）
  → **加显式监控**。
  > ⚠️ **2026-09-12 口径修正（务必并读 §14）**：上面这条**只对"本机硬件是否适用"成立**。
  > 上游又出现 **#23644**（09-11 20:40，`mergeable_state=blocked`），把 RTL8261CE 做进**主线 realtek 驱动**，
  > 落点是 `generic/**hack**-6.18/744|745` + VEND1 SDS/OCP/极性/EEE（**不是** pending-6.18 的 744/745）。
  > 因此判据须从"本机是否适用"改为"**是否与上游重复**"——本仓 default 档确实背着一份**同硅片双实现**（F101）。
  > 有利事实：本机 c45 `0x001ccaf3` **就是 `RTL_8261N`**，上游 `742` 已支持 → 私有 CE 驱动对本机 10G 链路
  > 很可能非必需（待实机验证；详见 §14）。
- 上游 `#24819`（phylink/phylib + DSA carry）：本机 10G PHY 走 mt7530 MDIO 平台 probe，
  非"DSA 端口晚到 PHY"场景 → 条件跟（出现 EN8811H 类固件加载 PHY 挂交换机时跟 708/709）。
- 上游 `#25090`（AN7583 → 25.12）：其中 OPP 节点名对齐（`opp-7000000000`→`opp-700000000`）
  **对 `prepare-oc.sh` 无功能影响**（脚本 `\bopp-(\d+)` 与位数无关；`opp-hz` 值未动；
  `smcc_opp0..N` 因 `_` 是单词字符不匹配 `\bopp-`）；CPU critical 110→120°C 与 ATF label
  已在 main，本仓 9001 不覆盖 thermal 节点 → **自动继承，无需动作**。
- `suntyrael` 的 **APK `repositories.d` 覆盖冲突教训**：`/etc/apk/repositories.d/customfeeds.list`
  归 `apk-mbedtls` 所有，target base-files 供同名路径会让 APK 安装报 overwrite 错误
  → **规范：`files/` 下新增任何 `*.list`/`customfeeds.conf` 一律用 `zz-` 前缀 + 首启 uci-defaults 生成**。
- `yahuisme` 的 `12-apmode-offload` sysctl（`bridge-nf-call-*tables=1`）**不建议整体照搬**
  （会让桥流量穿 netfilter，可能削弱 HW offload 收益；社区 t/222776 #3902 亦指出 packet steering
  与 NPU 抢流）——若需 VLAN-aware 桥，只取 `bridge-nf-pass-vlan-input-dev=1` 并实测 offload 仍生效。
- mt76 上游 `#1132`（mesh BSSID）、`#1125`（sta_remove 前清 WCID/TX 队列，与 `mt76-0012` 部分同域）、
  `#1131`（CONFIG_MT76_LEDS 子目录失效）：**均条件跟**，当前不动作。

---

## 6. 已确认"无需动作"（避免重复劳动）

- **Gilly 745 / 746(DSA)**：本仓 `vendor/fanboy/09`（default）内层**逐字一致**。
- **Gilly 747（JCPLL）**：机制等价于本仓 `9029`。
- **Gilly 033**：逐字等价于 `vendor/fanboy/07`。
- **Gilly 037 / 040 / 041 / 043**：上游 `be5ce791` 已合。
- **Gilly 746(PON)**：本仓 WAN=`gsw_port1`，非 PON → 不适用。
- **Gilly 999（RTL8261CE 驱动）**：本仓 `vendor/09` 已含完整 4 个驱动源文件，语义差集仅 2 行。
- **Gilly 039**：等价于 `mt76-0003`（本仓路线更彻底：去掉 WTBL 轮询）。
- **naoki 628 / 622 / 743 / 744 / 204 / mt76 0010 / 0012**：本仓 `9038/9041/9040/mt76-0010/0012` 同源已覆盖。
- **naoki66 0003（NPU del_sta）**：与本仓 `mt76-0012` **逐字一致**（差仅头部注释），无更优版本。
- **02506/t/25004 等**：无新增活动。

---

## 7. 文档与流程一致性（本轮发现的缺口）

| 缺口 | 处理 |
|---|---|
| `docs/FIXES.md` 未记录 F90/F91（PR #26 nikki / #27 DNS Phase 0 已构建绿但 PR 仍 closed 未并） | 待合并后补录 |
| `README.md` 仍写"已携带 9028 bump + mt76-9994 兼容层"（二者 09-07 已删） | 需修正 |
| `vendor/fanboy/09` 的 745/746 有补丁无台账 | 本批随 FIXES 补录 |
| `verify-copy-patches.sh` 上游下载路径首次返回非零（`curl` 下载失败触发早期退出），**重跑即 4/4 通过** | 建议加 `curl -f --retry 3`，消除偶发假红 |
| `prepare-oc.sh` PLL 公式缺失时仅告警 | 改为硬失败（§5.2） |

---

## 8. 证据与验证记录

**本批验证（可复现）**：
- `audit-patches.sh --oc --experimental` → **65/65 一致**
- `apply-patches.sh . --dry-run --oc --experimental --no-download`（上游 `3de9bf7`）
  → `处理：65 实验档跳过：0 缺失文件：0`，**无冲突**；日志 `research-20260911/dryrun-v3.log`
- `9042 → vendor/fanboy/11` 顺序实证（顺序测试树 + dry-run 日志 L39/L41）
- `mt76-0010 + mt76-0013` 同文件顺序共存实证（真实 `mt7996/mac.c`）
- `9043` 在"9024 之后"基线上 `git apply --check` 通过 + `bash -n` 语法通过
- u-boot 拷贝目标真实应用 **40 文件全部成功**（`verify-copy-patches.sh`）

**证据目录**：`research-20260911/`（dryrun 日志、`b2/` PR 原始 diff、`gilly/` 补丁、`naoki625/`、
`mt76files/` 上游源码、顺序验证树）+ `.b1/B1-深度调研报告.md`（第三方源 46 行总表）。

**未验证项（诚实声明）**：
1. `mt76-0013` 是否 no-op（TXS 是否上报）——只能实机计数器判定（§3.1）。
2. `9044` 内层 625 在本仓构建树未实跑（naoki66 基线 clean applies，offset -53）。
3. Gilly `034/035/036/042/026/044/047` 仅 `patch --dry-run` APPLIES，**无运行时验证**。
4. Gilly `972/973` 需实机复现（§3.2）。
5. 上游 `#25092` 仍在更新（09-11 15:54），文件清单可能再变；其合入后 `9041`/`9033` 重基难度未实测。
6. `#24872` 的 `mergeable_state=blocked` 具体原因未查。

---

## 9. 附：发现但未在本批处理的仓库级不一致

- **`patches/ORDER` 已不存在**（由更早的 R3 重构删除，`audit-patches.sh` 也不引用它），
  但 `MANIFEST` 头部注释仍写"`patches/ORDER` 是档位评审视图"、`README.md` 目录结构仍写
  "`patches/`（… + vendor/fanboy 原料桶 + MANIFEST/ORDER）" → **文档死引用**，建议一并清理。
- `README.md` 仍写"已携带 `c5a3bd91` bump（`9028`）+ `mt76-9994` 兼容层"（二者 09-07 已删）、
  "当前补丁层状态（2026-08-22）"表格整体过时 → 建议按当前 MANIFEST 重写该节。
- `docs/FIXES.md` 缺 **F90/F91 以外的既有缺口**：`vendor/fanboy/09` 内层 745/746 与
  `mt76-0013` 的对应关系本轮已补录（F90/F94）；PR #26（nikki）/ #27（DNS Phase 0）落地后
  需补 F95+（当前 PR 已 closed 但未并回 main）。

---

## 10. 第 2 批落地（2026-09-11 追加）

| 载体 | 内容 | 档位 | 验证 |
|---|---|---|---|
| `mt76-0014` | Gilly `047+034+035+036+042+026+044`：NPU 复位（整机复位后 host TX 永死 + NAPI NULL oops）、`reg_lock` irqsave 防 AP panic、wcid 竞态与事件越界校验 | #EXP | 逐条对 `be5ce791` 真实源码 `patch -p1` 命中；047 与 `0010/0013` 同文件顺序共存实证 |
| `root/9045` | Gilly `981+980+976+957+960+961`：RX 环停顿恢复、`RX_NO_CPU_DSCP`/q31 中断、QDMA TX BQL UAF、thermal 两处 1 行 bug | #EXP | 内层名与上游无冲突；dry-run 全绿 |
| `root/9016`（**替换**） | Gilly `748`：PHY LED pinctrl 可选——`-ENODEV` 静默 / 其他错误 `dev_warn`，覆盖 an7581+mt7988 | default | 内层对 Linux v6.18 两 hunk 命中；原版备份留痕 |

**上游漂移复查**：main 已前进到 **`e59c7876`**（09-11 13:07，新增 `airoha: add the missing PHY_AIROHA_AN7583_PCIE config symbol`，与本仓无关）→ 全量 dry-run **67/67 全绿、零冲突**。

**仍待办**：`prepare-oc.sh` PLL 断言（§5.2）、`device-hw-probe.sh` PHY 变体判定扩展、Gilly `046`/`972`/`973` 条件跟、`#25092` 合入后 `9041`/`9033` 重基监控、`mt76-0013` 机制判定实验（§3.1）。

---

## 11. 本轮完成度对照（objective A / B）

**A（落地可验证变更）——已达成**：
新增补丁 7 个（`mt76-0013`/`mt76-0014` + `9042`/`9043`/`9044`/`9045` + `9016` 替换），
`MANIFEST` 活动行 **50→52**、`#EXP` **10→14**，`docs/FIXES.md` 新增 **F90–F97**（8 条），
产出 `docs/absorptions/2026-09-11-absorption-plan.md`（11 节）；
全部经 **hunk 审计 67/67** + **对最新上游 main `e59c7876` 的全量 dry-run（67/67、零冲突）** +
候选补丁对 **`be5ce791` / Linux v6.18 真实源码**的逐条 `patch -p1` 命中验证。

**B（多角度深调研 + 更优吸收点）——已达成**：
覆盖 Gilly（65 补丁全枚举）、naoki66（187 个 airoha 补丁域的交叉核对）、
上游 #24872/#25092/#24819/#25090、5 个新发现仓库、mt76 上游 PR/分支、社区补丁。
产出"已覆盖/缺失/更优"三分类总表 + 4 个机制级技术对比段 + 更优方案清单（见 §2–§6），
并据此落地了本轮全部高价值项。

**仍待办（已排期，非本 objective 未达成项）**：见 §5.2 与 §10 末段。

## 12. 第 3 批落地（README 一致性 + 脚本断言）

| 项 | 内容 | 验证 |
|---|---|---|
| `README.md` | 补丁层状态节由 `2026-08-22 第三会话` 更新为 **`2026-09-11` 实况**：mt76 pin 改 `be5ce791` 并注明 `9028/9994` 已于 09-07 删除；实验档改为"**当前 #EXP 14 条**"实际清单；新增 3 行（FOE/RX 环与 DMA、bridge offload 注入防护、10G LAN2 机制矩阵）；删除对已不存在的 `patches/ORDER` 的引用（目录结构行） | 过时引用已清除（除"历史 9028/9994 已删除"的**有意说明**） |
| `scripts/prepare-oc.sh` | PLL 公式改为**断言式**（F98）：公式在 → 替换并计数；PM domain 补丁在但公式不匹配 → 硬失败；无补丁 → 提示先 apply-patches | 三路径实测 + `bash -n` 通过 |

> 至此 objective A 的"含 FIXES 台账、README 一致性"两个显式要求在字面上均已闭合。

## 13. 第 4 批（用户授权后）：commit+push、实机只读验证、剩余待办

### 13.1 已推送
- commit **`629b3e8`** → push 到 `main`（`df3b12e..629b3e8`）。
- 该 commit 触发的 **sync-upstream 已 success**（= 在全新克隆中 67 补丁 + 新监控步骤全绿）；build 当时 in_progress。

### 13.2 实机只读验证（2026-09-11，设备 `192.168.123.1`，固件 `r0-f36067d`；全程只读，唯一写入是 `force_tx_status` 置位后**立即恢复原值**）
- **10G PHY 变体判定（原 U1 未知项）已实机定论**：
  - `dmesg`：`RTL8261BE 10Gbps PHY` 绑定 `mt7530-0:05`（lan2）与 `mt7530-0:08`（lan1）；
  - C45 sysfs `c45_phy_ids` = **`0x001ccaf3`**（两个 10G 口一致）；C22 `phy_id` = `0x00000000`（C45-only 器件，C22 读不到——**不能只看 phy_id**）；
  - 1G 口 `mt7530-0:09/:0a` = `Airoha AN7581 PHY`（c22 `0x03a294c1`）。
  - **结论**：#25092 的 `0x001cc899`（RTL8261CE_CG）与 CE 专用 SerDes polarity 路径 **对本机不适用**；合入后只需按 §5.3 处理 9041/9033 的重基。
- **`device-hw-probe.sh` B2.1 增强（F99 同批）**：原实现依赖 `phytool`，本机未安装 → 只能打印一句提示，**实际从未取到判据**。已补**只读回退**：driver 绑定名 + `c45_phy_ids`（去重）+ dmesg 识别 + 器件族归类（`0x001ccaf3`→RTL8261BE/N、`0x001cc898/99`→RTL8261C/CG），并在实机以 POSIX `sh` 复跑验证输出正确。
- **`mt76-0013` 的 TXS 判定实验：本机不可闭环，已判定为"需带补丁的新固件"**：
  - `tracefs`/kprobe **不可用**（无 `/sys/kernel/tracing`）→ 无法用 ftrace 无侵入观测 `mt7996_mac_add_txs_skb`；
  - `force_tx_status` 可写（已置 1 并立刻恢复 0），但本机**无已关联站点**（stations=0），无法产生卸载数据面流量；
  - 且设备运行 `r0-f36067d`（**早于本批 0013**），即使有 TXS 也不含新门。
  - → 判定方法保留为：在**含 0013 的 experimental 固件**上测"Intel 客户端 Samba 大文件是否仍塌陷 + `devmem 0x1fa7a030` 类旁证"，或在 `mt7996_mac_add_txs_skb()` 刷新点加临时 debugfs 计数器（若计数不涨 → 按 §3.1 改 `mt7996_mac_work()` 周期刷新）。
- NPU 状态旁证：`token_info` 显示 `NPU Offload status: active`、`wed_token_count: 0`（NPU 路径生效、WED 未用）；`wed_enable=N`。

### 13.3 剩余待办处置
| 项 | 处置 | 理由 |
|---|---|---|
| `#25092` 重基监控 | **已实施**：`scripts/audit-upstream-watch.sh` + 接入 sync-upstream.yml（见 F99） | 把"等 dry-run 红"提前为确定性预警 |
| `device-hw-probe.sh` PHY 变体判定 | **已完成**（§13.2，只读回退 + 实机验证） | 原实现因缺 phytool 形同虚设 |
| `mt76-0013` TXS 判定 | **转实机流程**（§13.2）：需含补丁的新固件，本轮无法在不刷机的前提下闭环 | tracefs 不可用 + 无站点 + 设备固件早于本批 |
| Gilly `046` | **观察（不吸收）** | 与本仓 `mt76-0003`（固件 AIR_TIME/ADM_STAT 轮询）路线重叠，需先做逐行比对；单条价值不足以单独携带 |
| Gilly `972/973`（IPv6 UPDMEM 源 MAC） | **观察（先复现）** | 前提是"存在克隆 MAC 的 VLAN 且路径走 `airoha_gdm_dev`"；本机 WAN=`gsw_port1`，§13.2 的只读探测未能构造该条件（无第二 10G 链路在测） |

---

## 14. 第 5 批（2026-09-12）：上游 RTL8261CE 分叉的判据修正与守护扩面

> 台账：**F101**（同硅片双实现）、**F102**（上游 #25132 config 符号，无冲突）、**F103**（守护扩面）。
> 本轮调研报告：`../../信息更新调研-2026-09-12.md` §五；证据：`research-20260912/pr23644/`、`research-20260912/dryrun/`。

### 14.1 事实（多角度核实）

| 角度 | 事实 | 证据 |
|---|---|---|
| 上游 | PR **#23644**（hurrian，头仓 `hurrian/openwrt-w1700k@rtl8261ce`，3 提交，09-11 20:40 更新，`mergeable_state=blocked`）把 RTL8261CE 做进**主线** `drivers/net/phy/realtek/realtek_main.c`：`RTL_8261CE_REV_C 0x001cc899`、VEND1 SDS option（0x6972~0x6977）、SerDes OCP 窗口（0x7587/7588/7589/758a）、**lane polarity（DT tx/rx-polarity）**、VND2 EEE（0xd036/0xd038）、过温降速位、`rtl8261c.bin` | `gh api repos/openwrt/openwrt/pulls/23644/{files,commits}` |
| 落点 | 上游 `generic/**hack**-6.18/744-net-phy-realtek-speedup-rtl8261x-fw-load.patch`、`.../745-net-phy-realtek-add-support-for-rtl8261d-ce-cg.patch`，另有 `pending-6.18/743-01..04`（c45 soft_reset / master_slave / RTL8261C-CG / 固件加载） | 同上 files 清单 |
| 本仓 | `vendor/fanboy/09`（default 档）新增 `generic/files/drivers/net/phy/rtl8261ce/{Kconfig,Makefile,rtk_rtl8261ce_patch.h(623 行),rtk_rtl8261ce_phy.c(1110 行)}` + `generic/hack-6.18/999-net-phy-realtek-rtl8261ce.patch` | `grep '^+++ b/' patches/vendor/fanboy/09-*.patch` |
| 同源性 | 两边出现**同一批寄存器常量与同一 OCP 窗口**；#23644 自述"based on a dump of the vendor driver from a **Lumen W1700K2**"，本地驱动头注释同为 "recovered from `rtk-rtl8261ce-phy.ko` module from the stock **LUMEN W1700K2** firmware" | 逐项 grep 对照（见报告 §五 5.1） |
| 冲突面 | 本地 `PHY_ID_MATCH_MODEL(0x001cc890)` 按模型位匹配 `0x001cc89x` **全部 revision**；主线已注册 `RTL_8261C_CG 0x001cc898`，+23644 的 `0x001cc899` → **同 C45 ID 双驱动争抢 binding** | `grep RTL8261CE_PHY_ID / PHY_ID_MATCH_MODEL` |
| 本机 | 实机 c45 `0x001ccaf3` = **`RTL_8261N`**；上游 `742` 补丁已定义 `#define RTL_8261N 0x001ccaf3` 且有 `rtl8261be_match_phy_device` / `rtl8261n_match_phy_device` → **主线本就支持本机 10G PHY** | upstream 742 补丁 grep + §13.2 实机记录 |

### 14.2 判据修正（本节的核心结论）

- **旧判据**（§5.3 / §13.2）："本机 10G PHY = RTL8261BE（`0x001ccaf3`）→ CE 专有路径不适用 → 不跟 744/745"。
- **新判据**：本机适用性回答的是"**实机行为风险**"（= 0，成立）；但补丁层要回答的是"**是否与上游重复**"。
  两个问题不同：即使 CE 路径对本机无用，仓库仍**背着一份与上游重复的同硅片驱动**，长期成本是
  "要么永久私有 rebase、要么某天与主线争 binding"。
- 因此本项从"**不跟**"升级为"**条件必跟 + 预置二选一决策**"，触发条件 = 上游 `#23644`（或 backport #25092）合入。

### 14.3 已实施（F103，本轮）

`scripts/audit-upstream-watch.sh` 重写扩面：
- **基线表 3 → 6 个 blob**：新增 `target/linux/airoha/an7581/config-6.18`、`target/linux/airoha/image/an7581.mk`、`package/boot/uboot-airoha/Makefile`（后两者同时服务 `#24926` DT overlay 监视）。
- **同址冲突 glob 7 条**：`generic/hack-6.18/744-*`、`744-*`(`pending`)、`745-*`(`hack`/`pending`)、`pending-6.18/743-0*`、`generic/files/drivers/net/phy/rtl8261ce/*`、`airoha/dts/*.dtso`。
- **文本级探测**：上方 742 补丁内是否出现 `RTL_8261CE|8261CE_REV_C|0x001cc899`。
- **正确性修复**（实证发现）：路径清单取 `ls-tree` ∪ `ls-files --cached --others`（覆盖"磁盘上有、未提交"）；文件 SHA 取工作区 `git hash-object` 且**必须先判存在性**（`git rev-parse HEAD:<path>` 在已删除文件上仍返回 blob，会误判"未变"）；输出分 `[基线]`/`[冲突]`/`[缺失]` 三类并打印"上游 HEAD vs 基线锚点"。
- **验证**：正例（上游 `f0d3e332` 干净树）全 ✓ exit 0；反例 6 组全部正确 exit 1；端到端 CI 等价序列 dry-run **68/0/0** + 拷贝类 **4/4**。

### 14.4 决策预案（#23644/#25092 合入后二选一）

| 方案 | 动作 | 前提/判据 | 代价 |
|---|---|---|---|
| **A（首选）改跟主线** | 从 `vendor/fanboy/09` 删除 `rtl8261ce/` 4 文件与 `hack-6.18/999-*`，改为依赖上游 `744/745/743-0x` | 实机验证：**10G lan1/lan2 冷启动 ×20 link 正常**、`ethtool` 速率档正确、SDS-mode 行为不退化（本地 `9041`/F78 的 `realtek,sds-mode=0x88c6` 属板级 SerDes，理论上与 PHY 驱动选择解耦——**需实测确认**） | 一次性验证成本；省长期 rebase 债 |
| **B 保留私有** | `hack-6.18/999-*` 改名避号（如 `998-`），MANIFEST 注明"与主线 CE 入口互斥"，必要时关闭主线 CE 匹配 | 若 A 的实机验证不通过（私有驱动含主线没有的 hwmon 温度通道 / BE 特定修正） | 长期双份维护 + 同 ID 双驱动风险仍在 |

> **A 为什么可能成立**：本机 PHY 的 c45 ID `0x001ccaf3` **就是主线已支持的 `RTL_8261N`**，而本地私有驱动的匹配面是 `0x001cc89x`（RTL8261CE 家族）——**严格说本机并不落在私有驱动的目标 ID 上**，私有驱动对本机 10G 链路的必要性存疑。这同时意味着：即便今天删掉它，本机也应该仍由主线的 RTL8261BE/N 路径驱动（§13.2 的实机日志正是 `RTL8261BE 10Gbps PHY` 绑定 `mt7530-0:05/:08`）。
> **仍需实机确认**：该结论来自 ID 与日志推断，未做"删驱动后重构建 + 实测"的闭环。

