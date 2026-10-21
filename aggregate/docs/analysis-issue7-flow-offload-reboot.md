# issue #7 离线根因分析：`flow_offloading_hw` 1→0→1 + `fw4 reload` 后疑似硬件重启

- 日期：2026-09-07（离线代码分析，无实机）
- 对象：Gemtek XR1710G（AN7581 + MT7996），OpenWrt SNAPSHOT r0-725cbf1，kernel 6.18.44，experimental 档
- 关联：FIXES.md F34（issue #7）、F51、F30、F46；`docs/acceptance-results/2026-08-22-npu-toggle-rpc-gap.md`（T1 时间线）、`2026-08-22-npu-offload-stress.md`
- 性质：静态分析 + 修复/取证建议。**未修改任何补丁、未提交**。

---

## 0. 结论速览（TL;DR）

1. **链路上存在一个结构性缺陷**：nf_tables 销毁硬件 flowtable 时，`FLOW_BLOCK_UNBIND`（同步、commit 阶段）必然先于逐流 `FLOW_CLS_DESTROY`（异步、destroy_work + `nf_ft_offload_del` 工作队列）执行；而 airoha 驱动在 UNBIND 后其 `flow_block_cb` 已从 flowtable 的 cb_list 摘除，**逐流 DESTROY 回调永远到不了驱动**（`nf_flow_table_offload.c` 的 `nf_flow_offload_tuple` 遍历的是空列表）。后果：**NPU/PPE 固件侧的 FOE（HWNAT）条目在 1→0 或每次 `fw4 reload` 销毁 `flags offload` flowtable（含实验档的 `bridge flow_offload` 表）时不会被失效**，驱动侧 `eth->flow_table` 中的 `struct airoha_flow_table_entry` 也永不释放（随每次 reload 累积泄漏）。
2. **NPU 固件一侧没有任何"软复位/恢复"路径**：`airoha_npu_send_msg()` 对 mailbox 只做 **100 秒静默轮询**（`regmap_read_poll_timeout_atomic`，失败不打日志）；NPU WDT IRQ 处理器只 `dev_coredumpv` 记录 PC/SP/LR，**不会复位或重启固件**。一旦固件因残留流表/竞态进入异常状态，设备只能靠整机复位恢复——与"重启前无任何内核日志"的现象吻合。
3. **重启机制**最可能是 **SoC 级看门狗/硬件复位**（而非可留痕的 kernel panic）：logread 只保留重启后日志、`/sys/fs/pstore` 为空与两者都兼容，但本平台 pstore 链路本身不完整（见 §7），无法据此区分；需实机取证（devmem 读 WDT 寄存器、串口、远程 syslog、NPU coredump）来一锤定音。
4. **修复优先级**：P1（驱动侧 UNBIND/重绑时主动清空自身 FOE 残留，hunk 草案见 §8.1）→ P2（netfilter 侧 UNBIND 前先排空逐流 DESTROY，上游方向）→ P3（mbox 失败留痕/计数，诊断增强）→ P4（可选加固：重绑时 HWNAT 全新初始化）。用户态缓解与最小复现矩阵见 §8.2/§9。
5. 9035（`CONFIG_NET_AIROHA_FLOW_STATS=y` 共存）**不是**本次事件的原因：事发固件该选项为 `n`（上游 PR #22300 显式关闭），stats 相关路径全部 inert；9035 的 `stats_enabled` 门控仅影响 2026-08-31 之后的固件，且 ci-88/ci-94 实机验证无回归。

---

## 1. 复现事实与时间线（来自 T1 记录）

| 时刻（设备本地） | 事件 |
|---|---|
| 08:27:39 前 | `flow_offloading_hw='0'` + `fw4 reload` 成功；软件流表 7 路打流全 200，conntrack `[OFFLOAD]`，设备正常 |
| ≈08:27:50 | 恢复 `flow_offloading_hw='1'` + `uci commit` + `/etc/init.d/firewall reload`，命令返回 `restored` |
| 08:27:54 | kernel boot 日志开始（设备已重启，uptime 归零） |
| 重启后 | `/sys/fs/pstore` 空；logread 仅 631 行（均为重启后）；PPPoE 重新拨号（WAN IP 172.27.136.218 → 172.27.57.161）；硬件卸载恢复可用 |

关键判读：**崩溃发生在 reload 返回之后约 4–15 秒、且当时无新打流**（7 路下载在 08:27:39 前后已结束）。因此触发源是 reload 提交后的**异步尾随动作**（nft destroy_work / flowtable GC / 数据面残余流量），而非 reload 过程中的同步失败。

---

## 2. 固件代码基线（本分析引用的对象）

设备内核 = **mainline v6.18.44 驱动** + openwrt main `patches-6.18`（099/132/134/915-01/916-02/920/924 等）+ 本仓库叠加层生成补丁：

| 部件 | 基线 | 备注 |
|---|---|---|
| `drivers/net/ethernet/airoha/{airoha_eth.c,airoha_ppe.c,airoha_npu.c,airoha_eth.h,airoha_regs.h}` | torvalds/linux v6.18.44 | 本报告行号均指 v6.18.44 |
| openwrt 增量 | `099-06/07/08/09`（PPE SRAM 由 CPU 直写/PPE setup 时 flush/默认 CPU 口）、`132`（PPE 默认 CPU 口复位）、`134`（`DEV_STATE_REGISTERED` 门控）、`915-01`（DSCP offload）、`916-02`（HW GRO）、`924`（coherent mailbox DMA bounce buffer，**是否已进入 08-22 固件存疑**） | 均不改变 §4 的时序结论 |
| 本层生成 | `675-01..04`（桥接 flowtable，实验档毕业项）、`992-20/992-21`（fanboy/18，NPU WLAN 初始化重试包装；mbox 超时 hunk 因上游已是 100s 而删除，见 F25）、`9991`（9025）、`9995`（9035，事发时**未应用**） | |
| netfilter | `nf_tables_api.c` / `nf_flow_table_{core,offload,path,inet}.c` / `nft_flow_offload.c` @ v6.18.44（+675-02 的 bridge 路由扩展） | 行号指 v6.18.44 |
| fw4 | `openwrt/firewall4` b6e51575（2025-03-17 pin）/ main 同逻辑 | §4.1 |

> 核对说明：torvalds master（2026-09 快照）中 `nf_tables_api.c` 的 flowtable 销毁顺序与 airoha 驱动的 BIND/UNBIND 实现与 6.18.44 完全一致（见 §6.4），即该缺陷至今未被上游修复。

---

## 3. 重启链路图（fw4 → nft → 内核 → 驱动）

```
uci set firewall.@defaults[0].flow_offloading_hw='1'
/etc/init.d/firewall reload
  └─ fw4 生成 /tmp/fw4.nft：table inet fw4 / flush table inet fw4
       + flowtable ft { hook ingress priority 0; devices={wan,lan1,lan2,lan3,…}; flags offload; }
       + chain forward { … meta l4proto {tcp,udp} flow offload @ft; }
       + includes('ruleset-post') → bridge-flow-offload 的 30-bridge-offload.nft
         （destroy table bridge flow_offload; … flowtable br_offload { flags offload } …）
  └─ nft -f（单 batch，最后统一 commit）

nf_tables_commit（进程上下文，持 nfnl mutex）
  ├─ flush table inet fw4 → 每个 flowtable 生成 NFT_MSG_DELFLOWTABLE 事务
  │    （nf_tables_api.c:1674 nf_tables_table_flush → nft_delflowtable）
  ├─ case NFT_MSG_DELFLOWTABLE（nf_tables_api.c:10991）
  │    └─ nft_unregister_flowtable_net_hooks → nft_unregister_flowtable_ops
  │         ├─ nf_unregister_net_hook（数据面钩子先摘）
  │         └─ flowtable->data.type->setup(dev, FLOW_BLOCK_UNBIND)      ← ① 同步
  │              └─ ndo_setup_tc(TC_SETUP_FT) → airoha_dev_setup_tc_block()
  │                   └─ flow_block_cb_decref==0 → flow_block_cb_remove + list_del
  │                        （驱动静态 block_cb_list 摘除；cb 随后由 core 释放，但 FOE 无清理）
  ├─ 新表/新 flowtable 创建 → setup(dev, FLOW_BLOCK_BIND)                ← ② 同步
  │    └─ airoha_dev_setup_tc_block() BIND → 新 flow_block_cb 入 cb_list
  └─ schedule_work(nft_net->destroy_work)（异步，commit 返回后执行）      ← ③ 异步
       └─ nf_tables_trans_destroy_work → nf_tables_flowtable_destroy → type->free
            └─ nf_flow_table_free()（nf_flow_table_core.c:752）
                 ├─ cancel_delayed_work_sync(gc_work)
                 ├─ nf_flow_table_offload_flush()（add/del/stats 三个 wq 各 flush 一次）
                 ├─ 逐流 flow_offload_teardown()
                 ├─ nf_flow_table_gc_run() → HW 流 → nf_flow_offload_del() → 队列 FLOW_CLS_DESTROY
                 ├─ nf_flow_table_offload_flush_cleanup() → flush del_wq
                 │    └─ flow_offload_work_del → nf_flow_offload_tuple()
                 │         └─ 遍历 flowtable->flow_block.cb_list —— ① 已把 cb 摘除 → 空列表
                 │              → airoha_ppe_setup_tc_block_cb() 不被调用 → FOE 不失效   ← 缺陷点
                 └─ rhashtable_destroy()

旧 hw flowtable 的 FOE 条目残留（NPU 固件侧 + 驱动 eth->flow_table 侧）
  ↓ 随后数据面
新 flowtable（flags offload）BIND 后首个流 → nf_flow_offload_add → TC_SETUP_CLSFLOWER
  └─ airoha_ppe_setup_tc_block_cb()（airoha_ppe.c:1389）
       ├─ eth->npu 仍非空（从未 deinit）→ 跳过 airoha_ppe_offload_setup()
       └─ airoha_ppe_flow_offload_replace() → 与残留 FOE 哈希碰撞/状态错乱
```

---

## 4. 逐层关键函数与调用点

### 4.1 fw4（ruleset 生成）

- `root/usr/share/firewall4/templates/ruleset.uc:9-28`：`flush table inet fw4` + `delete flowtable inet fw4 ft`（条件）+ 重建 `flowtable ft { … flags offload; }`（仅当 `flow_offloading_hw`）。
- `root/usr/share/ucode/fw4.uc:508-560`：`resolve_hw_offload_devices()` — 设备集 = 各 zone `related_physdevs` 的 lower dev（br-lan → lan1/2/3 + phy*.ap0；wan zone → pppoe-wan）；**每次 reload 都执行 `nft_try_hw_offload()`**（`nft -c` 试建 `fw4-hw-offload-test` flowtable，check 模式不提交），失败则 warn 并回退软件卸载。
- `bridge-flow-offload`（`vendor/05` + `9024`）的 `30-bridge-offload.nft`：`destroy table bridge flow_offload` + `flowtable br_offload { … flags offload; }`，经 ruleset-post 被**每次 fw4 reload** 带入 → 桥接 hw flowtable 每次 reload 都被销毁/重建（实验档固件的独有增量面）。

### 4.2 nf_tables（flowtable 对象生命周期）

- `nf_tables_api.c:8847-8854` `nft_unregister_flowtable_ops()`：`nf_unregister_net_hook()` 之后立即 `type->setup(dev, FLOW_BLOCK_UNBIND)` —— **UNBIND 与数据面摘钩同批、同步**。
- `nf_tables_api.c:10991-11011`：commit 的 `NFT_MSG_DELFLOWTABLE` 处理 → `nft_unregister_flowtable_net_hooks()`（同步）；对象释放留到 destroy_work。
- `nf_tables_api.c:10085-10090` / `10100`：`nf_tables_trans_destroy_work()`（**异步**，`schedule_work`）→ `nf_tables_flowtable_destroy()`。
- `nf_tables_api.c:9542-9549` `nf_tables_flowtable_destroy()`：直接 `type->free()` = `nf_flow_table_free()`。
- `nf_tables_api.c:1674`：`flush table` 对表内每个 flowtable 走 `nft_delflowtable()`（DELFLOWTABLE 事务）——**每次 fw4 reload 必走销毁路径**。

### 4.3 nf_flow_table（流条目生命周期）

- `nf_flow_table_core.c:752-766` `nf_flow_table_free()`：顺序 = cancel gc → flush 三 wq → 逐流 teardown → gc_run（HW 流 → 队列 DESTROY）→ flush_cleanup（DESTROY 落地）→ rhashtable_destroy。**所有逐流驱动回调都发生在这里，晚于 §4.2 的 UNBIND。**
- `nf_flow_table_core.c:559-588` `nf_flow_offload_gc_step()`：teardown+HW 流 → `nf_flow_offload_del()`（置 `NF_FLOW_HW_DYING` 后入队）。
- `nf_flow_table_offload.c:1103-1126` `nf_flow_offload_add/del()`：异步工作队列（`nf_ft_offload_add/del`，WQ_UNBOUND）。
- `nf_flow_table_offload.c:971-997` `flow_offload_work_add/del()`：DESTROY 实际执行体，先 `clear_bit(IPS_HW_OFFLOAD_BIT)` 再 `flow_offload_tuple_del()`。
- `nf_flow_table_offload.c:899-933` `nf_flow_offload_tuple()`：**遍历 `flowtable->flow_block.cb_list` 调用 `block_cb->cb(TC_SETUP_CLSFLOWER, …)`** —— UNBIND 后该列表已空 → 回调缺失。这是缺陷的落点。
- `nf_flow_table_offload.c:1250-1271` `nf_flow_table_offload_setup()`：BIND/UNBIND 入口（`ndo_setup_tc(TC_SETUP_FT)` + `nf_flow_table_block_setup`）。

### 4.4 airoha 驱动（v6.18.44）

- `airoha_eth.c:2741-2759` `airoha_dev_setup_tc_block_cb()`：`TC_SETUP_CLSFLOWER → airoha_ppe_setup_tc_block_cb()`；`TC_SETUP_CLSMATCHALL` → meter。
- `airoha_eth.c:2761-2800` `airoha_dev_setup_tc_block()`：
  - BIND：`flow_block_cb_alloc` + `flow_block_cb_add`（`list_add_tail` 挂入 f->cb_list，随后被 core `list_splice` 进 flowtable cb_list，`include/net/flow_offload.h:649-653`）+ `list_add_tail(driver_list)` 到**驱动静态 list**；
  - UNBIND：`flow_block_cb_decref==0` → `flow_block_cb_remove`（`list_move` 移回 f->cb_list，`flow_offload.h:655-659`，随后 core 在 `nf_flow_table_block_setup` 中 `flow_block_cb_free` —— **cb 生命周期本身正确，无泄漏/无双重释放**）+ `list_del(driver_list)`。**真正的缺口：UNBIND 不清空任何 FOE/流条目。**
- `airoha_eth.c:2875-2891` `airoha_dev_tc_setup()`：`TC_SETUP_FT` / `TC_SETUP_BLOCK` 共用 block 路径。
- `airoha_ppe.c:1389-1405` `airoha_ppe_setup_tc_block_cb()`：持 `flow_offload_mutex`；`!eth->npu` 时懒执行 `airoha_ppe_offload_setup()`（`ppe_init` mbox → 轮询 PPE_FLOW_CFG → `ppe_init_stats`（FLOW_STATS 时）→ `airoha_ppe_hw_init` → `flush_sram_entries` → `rcu_assign_pointer(eth->npu, npu)` + `synchronize_rcu()`）。
- `airoha_ppe.c:1345-1387` `airoha_ppe_offload_setup()`：失败路径 `airoha_npu_put()`；**成功后没有任何"关流"逆操作**。
- `airoha_ppe.c:1000-1198` / `1200-1216`：`flow_offload_replace/destroy()` —— 驱动侧 FOE 条目的增/删；destroy 仅在收到 `FLOW_CLS_DESTROY` 时执行。
- `airoha_ppe.c:886-904` `airoha_ppe_foe_flow_commit_entry()`：`e` 插入 `ppe->foe_flow[hash]` 链表（真正的 SRAM 写入是数据面机会性的 `airoha_ppe_foe_insert_entry`，814-864）。
- `airoha_ppe.c:719-763` `airoha_ppe_foe_flow_remove_entry()`：持 `ppe_lock`，SRAM 条目置 INVALID + `rhashtable_remove_fast` + `kfree(e)`。
- `airoha_ppe.c:1569-1586` `airoha_ppe_deinit()`：唯一调用 `ppe_deinit`（HWNAT_DEINIT mbox）+ `airoha_npu_put()` 的地方 —— 仅在 `airoha_hw_cleanup()`（驱动移除）调用，**flowtable toggle 永不触发**。

### 4.5 airoha_npu（mailbox/固件交互，v6.18.44）

- `airoha_npu.c:149-183` `airoha_npu_send_msg()`：`spin_lock_bh(core->lock)` 内 `regmap_read_poll_timeout_atomic(…, 100us, 100 * MSEC_PER_SEC)` —— **单条命令最多静默轮询 100 秒；超时/固件错误均不打印任何日志**；`MBOX_MSG_STATUS != SUCCESS` 仅返回 `-EINVAL`。
- `airoha_npu.c:230-243` `airoha_npu_mbox_handler()`：只清状态、回 ACK，不做协议校验。
- `airoha_npu.c:245-281` `wdt_work/wdt_handler`：NPU 每核 WDT 触发 → `dev_coredumpv`（PC/SP/LR 512B）→ **无固件复位/重启**。
- `airoha_npu.c:283-345` `ppe_init/ppe_deinit/ppe_flush_sram_entries`：HWNAT_INIT / HWNAT_DEINIT / SRAM_RESET_VAL 三类 mbox；`ppe_deinit` 在 toggle 路径从不被调。
- `airoha_npu.c:347-380` `airoha_npu_foe_commit_entry()`：PPE_SRAM_SET_ENTRY + SET_VAL 两条 mbox，`GFP_ATOMIC`（可从原子/软中断上下文调用）。
- openwrt `924`（coherent mailbox DMA，若事发固件已含）：bounce buffer 常驻，超时后固件仍可能写缓冲 —— 不改变时序结论，但使"超时后无痕"更隐蔽。
- `fanboy/18`（992-21，74 行版）：仅给 **WLAN 初始化** 5 条命令加重试包装（`airoha_npu_wlan_cmd_with_retry`，3 次 × 10ms）；**PPE 命令路径无重试**；mbox 轮询超时保持上游 100s（F25 已删超时 hunk）。

### 4.6 看门狗（复位机制候选）

- `drivers/watchdog/airoha_wdt.c`（v6.18.44，`CONFIG_AIROHA_WATCHDOG=y`，dts `watchdog@1fbf0100` @ an7581.dtsi:387）：`heartbeat = 24`（L43-44）；probe **不主动 stop/start**（L127-173）——若 U-Boot 已 armed，Linux 侧无人喂则到期复位；`WDT_ENABLE BIT(25)`、`WDT_TIMER_LOAD_VALUE 0x2c`、`WDT_TIMER_CUR_VALUE 0x30`（L26-33）。**需实机 devmem 确认 WDT 是否在跑（§9）。**

---

## 5. 根因假设（按可能性排序）

### H1（首选）：flowtable 销毁顺序缺陷 → FOE/固件流表残留 → NPU 固件进入异常状态 → 整机复位

**机制**（全部有代码依据，见 §4）：

1. 每次 `fw4 reload`（实验档固件含 inet `ft` + 桥接 `br_offload` 两个 hw flowtable）都会触发销毁：commit 中同步 UNBIND（cb 摘除）→ destroy_work 中异步 `nf_flow_table_free` → 对仍存活的 HW 流队列 `FLOW_CLS_DESTROY` → 落地时 cb_list 已空 → **`airoha_ppe_flow_offload_destroy()` 永不执行**。
2. 后果 A（固件侧）：NPU 固件 HWNAT/FOE 表保留 BIND 状态的残留条目，指向旧动作（旧 GDM 口/旧 encap）。硬件数据面继续按残留条目转发/丢弃，且与之后新 flowtable 的条目发生哈希碰撞、交叉污染。
3. 后果 B（驱动侧）：`eth->flow_table` 与 `ppe->foe_flow[]` 中的 `struct airoha_flow_table_entry` 永不释放 → 每次 reload 泄漏全部存量 hw 流条目（内存泄漏 + 残留状态）；新流 `replace()` 时 `rhashtable_lookup(cookie)` 永不冲突（cookie 是新 tuple 指针），而 RX 路径 `airoha_ppe_foe_insert_entry()` 遇到残留 BIND 条目直接 `goto unlock`（airoha_ppe.c:831-833）→ 新流永远按旧动作转发。
4. 无自愈/无恢复：FOE 老化只能由固件侧按 idle 回收，驱动侧条目永驻；NPU 固件若因上述错乱触发内部异常（断言/越界），唯一可见痕迹是 `airoha_npu_wdt_handler` 的 devcoredump（且仅当固件 WDT 使能）；mbox 失败**无日志**（§4.5）。最终用户感知 = "无声重启"，与 T1 完全一致。

**支持证据**：① §4.2-4.3 的时序是硬性的（UNBIND 同步于 commit，free 异步于 destroy_work，DESTROY 落地遍历空列表）；② torvalds master 与 openwrt main 至今保持同一顺序、驱动同样不做 UNBIND 清理（§6.4），即"上游未修 + 本层未补"；③ 实验档固件多了一个每次 reload 必销毁/重建的**桥接 hw flowtable**，使 toggle 复现面显著增大；④ 事件发生在 reload 后 4–15s —— destroy_work + 数据面残余流（ssh/PPPoE 保活等桥接流量）正好在这个窗口内与残留 FOE 交互。

**反证/弱项**：① FOE 条目存在硬件 idle 老化（stress 测试观察到"动态回收"），残留条目的绝对寿命有限——但驱动侧 `e` 条目不老化，且老化只清 SRAM 不清固件 HWNAT 管理表；② 无法纯静态证明"固件必然因此 crash"，最终定案需要实机 coredump/mailbox 计数（§9）。

### H2：NPU 固件 mbox 协议/竞态崩溃（toggle 窗口内的命令交错）

**机制**：`fw4 reload` 的 `nft -c` 探测（`nft_try_hw_offload`，check 模式）+ 主 batch 的 BIND + 桥接表重建，使驱动在极短窗口内对同一 `eth->npu` 发出多路 mbox（`HWNAT_INIT` 只会懒触发一次，但 `FOE_SET_ENTRY` 可与 mt76 的 WLAN mbox 并发）；`airoha_npu_send_msg` 每核只有一把 `spin_lock_bh` + 单队列（`core=0`，`/* FIXME */`），任何长轮询都会阻塞其他命令；若固件在切换瞬间收到语义矛盾的 PPE 命令（如 SRAM_SET_ENTRY 指向已被 CPU 直写覆盖的区域），可能触发固件内部异常。固件无恢复路径 → 设备级复位。

**支持证据**：§4.5 代码形态（单队列、无协议校验、100s 静默轮询、无固件复位）；`924` 补丁说明"mailbox 完成后 NPU 仍可能继续写缓冲"，暗示固件侧完成语义不可靠。
**弱项**：无日志佐证，纯推理；命令交错在正常 offload 生命周期（长时间打流）同样存在，而 35 分钟 stress 无异常（F30），说明交错本身不是充分条件——需叠加 H1 的残留污染才解释得通。

### H3：`bridge flow_offload`（675 系列）桥接路径缺陷——数据面崩溃候选

**机制**：实验档固件的 `675-02` 在 `nft_flow_offload_eval` 对桥接包走 `nft_flow_route_bridging()`（假 dst：`rt_dst_alloc`/`ip6_dst_alloc` + `dst_hold` 双向共享，patch 内 `nft_flow_route_bridging` 函数）；`675-03` 的 `nf_ct_bridge_inner()` 对每个桥接包做 VLAN/PPPoE 内层解析（`__skb_pull/push`）。这两处都是本次 toggle 会话中新引入、且**桥接流量（ssh、PPPoE 控制帧等）在 reload 后依然存在**的数据面代码；若假 dst 引用计数失衡（DIRECT 释放 vs NEIGH 保留的双向混合）或 skb 偏移恢复错位，可产生 `dst_release` 的 refcount 下溢 BUG / 内存损坏 → panic 或数据面卡死。
**支持证据**：`675-02` 的双向共享 dst 引用计数逻辑（dst_hold 一次 + 两个 dir 分别 release/持有）在混合 xmit 类型下不平衡的边界确实存在；桥接表每次 reload 重建（§4.1）。
**弱项**：纯静态无法确定具体触发路径；同样需要崩溃栈（串口/远程 syslog）定案。

### H4：9035 / FLOW_STATS 路径——**排除**

事发固件 `CONFIG_NET_AIROHA_FLOW_STATS` 为 `n`（`an7581/config-6.18:236` `# CONFIG_NET_AIROHA_FLOW_STATS is not set`，PR #22300 因"该选项=y 会破坏 AN7581+MT7996 NPU offload"而关闭）；`airoha_ppe_get_num_stats_entries()` 返回 `-EOPNOTSUPP` 时 stats 相关函数全部提前返回（F51）。9035（2026-08-31 起）把 `ppe_init_stats` 失败从"offload setup 整体失败"改为"仅禁用 stats 继续"（`stats_enabled` 门控 + `dev_warn`），ci-88/ci-94 实机均验证 offload 存活。**结论：9035 不是 #7 的原因，也不是修复 #7 的方案**；它只改变了"stats 不可用时 offload 是否可用"的语义。

### H5：SoC 看门狗被触发（复位"机制"，非"原因"）

`airoha_wdt` heartbeat=24s；U-Boot 是否遗留 armed 未知。任何单 CPU 长时间关中断/自旋（如 mbox 100s 原子轮询、`ppd` 卡死、nft 提交死锁）都可能最终由 WDT 复位。**H5 与 H1/H2 是"机制-原因"关系**：H1/H2 解释为何系统变坏，H5 解释为何"重启且无日志"。判别方法见 §9（devmem 读 `0x1fbf0100`/`0x1fbf0130` 计数）。

---

## 6. 为什么"没有日志 / pstore 为空"——证据链

| 观测 | 兼容解释 | 判别 |
|---|---|---|
| 重启前无内核日志 | ① SoC WDT 复位（内核没机会写）；② kernel panic 但无串口、logd 环缓冲随重启丢失 | 无法仅凭 logread 区分 |
| `/sys/fs/pstore` 为空 | ① WDT 复位（无 panic 写入）；② 有 panic 但 ramoops 记录被引导加载器 DDR 重初始化擦除；③ 板级 DTB 实际未含 ramoops 节点 | 见下 |
| PPPoE 重新拨号、uptime 归零 | 整机复位（两种机制都符合） | — |
| 打流后设备"自动恢复、一切正常" | 复位清空了固件/驱动双方残留状态 | — |

pstore 链路现状（本仓库证据）：

1. `vendor/fanboy/10`（2f7d2d02）为 an7581 目标加 `CONFIG_PSTORE*/PSTORE_RAM=y` + dtsi `ramoops@86ff0000`（64KiB，`record-size 0x1000`）。`9001` xr1710g dts `#include "an7581.dtsi"` → 节点理论上存在（需实机 `ls /proc/device-tree/reserved-memory/` 确认）。
2. **已知缺口（F09）**："U-Boot pstore #22473 未合入；uboot 侧待上游"——ramoops 内容在 DRAM，若引导流程（厂商签名 U-Boot / HTTP U-Boot → chainloader）每次做 DDR 训练/重初始化，**任何复位方式留下的 ramoops 记录都会被擦除**，`/sys/fs/pstore` 恒空。这与 T1 观测完全自洽。
3. 因此：**"pstore 为空"既不能证明是 WDT 复位，也不能排除 panic**。要让下次复现留证，必须把日志送**设备外**（远程 syslog/串口，§9），并做一次"人为 `reboot` 后 pstore 是否保留"的基准实验。

master/upstream 现状（§2 核对）：`nf_tables_api.c`（master）与 6.18.44 的 flowtable 销毁顺序一致；airoha 驱动（master）UNBIND 同样无清理（cb 生命周期正确，但 FOE 不清）。即 **H1 的结构性缺陷目前无上游修复可引用**，本层需自持补丁（§8）。

---

## 7. 修复方案

### 7.1 内核侧补丁候选（hunk 级草案）

**P1（首选，本层可落，风险最低）：驱动侧 UNBIND 后置清理——"残留流表清零"**

思路：在 UNBIND 摘除最后一个 cb 时，把本驱动的 FOE 残留全部失效并释放，使 toggle 不再向固件遗留任何状态（cb 生命周期由 core 管理，驱动无需也不得自行释放）。失效动作优先用 **CPU 直写 SRAM**（openwrt `099-07` 已引入的 `airoha_ppe_foe_commit_sram_entry()`，无 mbox、无 100s 风险），mbox 路径作为备选。

```c
// drivers/net/ethernet/airoha/airoha_ppe.c
/* 清空驱动侧全部 FOE 条目（flowtable teardown 时调用，避免固件残留）。
 * 注意：所有条目（L2/L4）都挂在 eth->flow_table（e->node），L2 还挂在
 * ppe->l2_flows（e->l2_node）；释放前必须从两个表都摘除，否则后续
 * rhashtable 遍历会命中已释放节点。 */
void airoha_ppe_offload_drain(struct airoha_eth *eth)
{
	struct airoha_flow_table_entry *e;
	struct rhashtable_iter hti;

	if (!eth->ppe)
		return;

	spin_lock_bh(&ppe_lock);

	rhashtable_walk_enter(&eth->flow_table, &hti);
	rhashtable_walk_start(&hti);
	while ((e = rhashtable_walk_next(&hti)) && !IS_ERR(e)) {
		/* 与 airoha_ppe_foe_remove_flow() 相同的失效逻辑，
		 * 但用 CPU 直写 SRAM（airoha_ppe_foe_commit_sram_entry）
		 * 置 AIROHA_FOE_STATE_INVALID，避免在 flow_block_lock
		 * 持锁期间做 100s mbox 轮询 */
		if (e->hash != 0xffff) {
			e->data.ib1 &= ~AIROHA_FOE_IB1_BIND_STATE;
			e->data.ib1 |= FIELD_PREP(AIROHA_FOE_IB1_BIND_STATE,
						  AIROHA_FOE_STATE_INVALID);
			airoha_ppe_foe_commit_sram_entry(eth->ppe, e->hash);
			e->hash = 0xffff;
		}
		hlist_del_init(&e->list);
		if (e->type == FLOW_TYPE_L2) {
			struct airoha_flow_table_entry *s;
			struct hlist_node *n;

			hlist_for_each_entry_safe(s, n, &e->l2_flows,
						  l2_subflow_node)
				kfree(s);
			rhashtable_remove_fast(&eth->ppe->l2_flows,
					       &e->l2_node,
					       airoha_l2_flow_table_params);
		}
		/* 迭代中摘除当前节点（与 nf_flow_offload_gc_step 同型） */
		rhashtable_remove_fast(&eth->flow_table, &e->node,
				       airoha_flow_table_params);
		kfree(e);
	}
	rhashtable_walk_stop(&hti);
	rhashtable_walk_exit(&hti);
	spin_unlock_bh(&ppe_lock);
}
```

```c
// drivers/net/ethernet/airoha/airoha_eth.c
	case FLOW_BLOCK_UNBIND:
		block_cb = flow_block_cb_lookup(f->block, cb, port->dev);
		if (!block_cb)
			return -ENOENT;

		if (!flow_block_cb_decref(block_cb)) {
			/* issue #7: flowtable teardown 时逐流 FLOW_CLS_DESTROY
			 * 晚于 UNBIND 且 cb 已移回 bo->cb_list（随后被 core
			 * flow_block_cb_free），驱动收不到 DESTROY；
			 * 在此主动清空 FOE 残留，避免 NPU 固件流表错乱。
			 * 注意：cb 生命周期由 core 管理，此处只做流表清理。 */
			airoha_ppe_offload_drain(port->qdma->eth);
			flow_block_cb_remove(block_cb, f);
			list_del(&block_cb->driver_list);
		}
		return 0;
```

> 说明：`rhashtable_walk_next` 迭代中删除条目与 `nf_flow_table_iterate`（nf_flow_table_core.c:416-449）同型，内核支持；L2 子流处理对齐 `airoha_ppe_foe_remove_l2_flow()`（airoha_ppe.c:738-750）。若担心持锁时间，可退化为"置 `eth->npu_dirty` 标志 + UNBIND 只摘 cb"，把 drain 移到下次 `airoha_ppe_setup_tc_block_cb()` 首个命令前（重绑后必达）——效果等价且更保守，推荐实机先验证后者。

**P2（上游方向，netfilter 侧）：UNBIND 前排空逐流 DESTROY**

```c
// net/netfilter/nf_tables_api.c  nft_unregister_flowtable_ops()
static void nft_unregister_flowtable_ops(struct net *net,
					 struct nft_flowtable *flowtable,
					 struct nf_hook_ops *ops)
{
	nf_unregister_net_hook(net, ops);
+	/* issue #7: 在驱动回调仍挂载时先让遗留 FLOW_CLS_DESTROY 落地，
+	 * 避免 flow_block UNBIND 后逐流销毁遍历空 cb_list 导致硬件流表残留 */
+	if (nf_flowtable_hw_offload(&flowtable->data)) {
+		nf_flow_table_gc_cleanup(&flowtable->data, NULL);
+		nf_flow_table_gc_run(&flowtable->data);
+		nf_flow_table_offload_flush_cleanup(&flowtable->data);
+	}
	flowtable->data.type->setup(&flowtable->data, ops->dev,
				    FLOW_BLOCK_UNBIND);
}
```

> 语义：每次设备 UNBIND 前把该 flowtable 全部流标记 teardown → gc 把 HW 流 DESTROY 入队 → flush del_wq 让回调在 cb 仍在时执行 → 之后 UNBIND；后续 `nf_flow_table_free()` 再执行时这些流已 `HW_DEAD`，直接释放、不再触碰驱动。该修法对所有"UNBIND 后依赖 cb 清流"的驱动（mtk_eth_soc 等）通用，适合提 upstream（`netfilter-devel`）。需在 `include/net/netfilter/nf_flow_table.h` 给 `nf_flow_table_gc_run`/`nf_flow_table_offload_flush_cleanup` 补导出（二者当前为内核内函数）。

**P3（诊断增强，低成本高价值）：mbox 失败留痕**

```c
// drivers/net/ethernet/airoha/airoha_npu.c  airoha_npu_send_msg()
	ret = regmap_read_poll_timeout_atomic(npu->regmap,
					      REG_CR_MBQ0_CTRL(3) + offset,
					      val, (val & MBOX_MSG_DONE),
					      100, 100 * MSEC_PER_SEC);
+	if (ret) {
+		dev_err_ratelimited(npu->dev,
+				   "mbox timeout: func %d len %d ctrl %08x\n",
+				   func_id, size, val);
+		/* 计数并暴露：per-core mbox_timeout 计数器，debugfs/sysfs 可读 */
+	} else if (FIELD_GET(MBOX_MSG_STATUS, val) != NPU_MBOX_SUCCESS) {
+		dev_err_ratelimited(npu->dev, "mbox status error: func %d\n",
+				    func_id);
+		ret = -EINVAL;
+	}
```

> 同时建议给 `airoha_npu_wdt_handler` 的 coredump 补一条 `dev_err`，并把 `REG_WDT_TIMER_CTRL` 的使能/当前计数值一并写入 dump（§9 的取证直接受益）。

**P4（可选加固）**：BIND 重绑时若 `eth->npu` 非空且 `npu_dirty`，先 `npu->ops.ppe_deinit(npu)` + 重新 `airoha_ppe_offload_setup()`（HWNAT 全新初始化），从固件侧根除残留——等价于"toggle 即重初始化"，语义最干净，但对固件依赖更大，建议在 P1/P2 落地并实机验证后再评估。

### 7.2 用户态缓解（立即可做，不依赖内核）

1. **LuCI/RPC 防护（9018/9019 同域）**：`setFlowOffload/setPppoeOffload/setVlanOffload` 中凡涉及 `flow_offloading_hw` 的写操作，检测"上一次 hw 状态 + 时间戳"（状态存 `/tmp/flow-offload-state`），**60 秒内 1→0→1 快速切换直接拒绝并返回提示**；切换 hw=1 后 sleep 2s 回读 `conntrack -L`（或 `getPpeFlowStats`）确认有流可达 `[HW_OFFLOAD]`/BND，否则返回"建议重启"。
2. **uci-defaults 保持现状**（`99-xr1710g-flow-offload` 默认双开）；`files/etc/config/firewall` 无改动。
3. **恢复脚本（可选）**：`npu-monitor` 的 jitter 采样发现连续 N 次 mbox/卸载异常（RPC 层判断）时写 `/tmp/npu-reset-req` 并在 logread 落一条带原因日志——避免"无声重启"。
4. **远程 syslog（取证前提）**：默认镜像含 `logread -f | nc <LAN-host> 514` 的 uci-defaults 开关（默认关，测试期开）。

### 7.3 修复状态（补丁已入库草案）

- **2026-09-07**：P1 的两个防御补丁已按"生成式补丁"规范入库 `patches/root/`（#EXP 档，待 CI 构建验证）：
  - `patches/root/9036-xr1710g-airoha-npu-dirty-lazy-clean.patch` → 内层 `9996-net-airoha-ppe-npu-dirty-lazy-foe-clean.patch`（方案 A，推荐首选）：`FLOW_BLOCK_UNBIND` 只置 `eth->npu_dirty` 脏标记，重绑后首个 offload 命令统一 `airoha_ppe_offload_drain()`。
  - `patches/root/9037-xr1710g-airoha-ppe-offload-drain.patch` → 内层 `9997-net-airoha-ppe-offload-drain.patch`（方案 B）：UNBIND 摘除最后一个 cb 时立即 `airoha_ppe_offload_drain()`。
  - 二者**二选一**（同时应用会在编译期以函数重定义报错暴露）；drain 均为 CPU 直写 SRAM 置 INVALID（复用 `airoha_ppe_foe_commit_entry`/`airoha_ppe_foe_commit_sram_entry`，无 mbox 长等待），L2/L4 双 rhashtable（`eth->flow_table`/`ppe->l2_flows`）同时摘除。
  - 与 §7.1 原草案差异（以 openwrt main / kernel 6.18.44 + patches-6.18 实测代码为准）：`airoha_ppe_setup_tc_block_cb` 签名已随上游多 netdev 重构变为 `(struct airoha_ppe_dev *dev, void *type_data)`；本树 FOE 提交路径本身已是 CPU 直写（099-07 系），mbox 风险主要存在于 NPU 侧；drain 的 rhashtable walk 释放推迟到 walk 结束之后（walker 会跟随被摘除节点保留的 `->next`），并在 resize（-EAGAIN）时重建迭代器。

---

## 8. 实机复现与取证建议

### 8.1 复现矩阵（最小集，每次切换间隔 ≥5 分钟记录基线）

| # | 场景 | 前置状态 | 操作 | 期望 |
|---|---|---|---|---|
| A | 纯 nft，无打流 | 冷启动后 | `nft add table inet t; nft add flowtable inet t ft { hook ingress priority 0; devices={lan1,lan2,lan3,wan}; flags offload; }; nft add chain inet t f { type filter hook forward priority 0; policy accept; }; nft add rule inet t f flow offload @ft` → 等 30s → 逐条 delete | 观察是否复现（无驱动残留流时理论不复现） |
| B | fw4 切换 + 无打流 | 默认双开 | 1→0→1 各一次 fw4 reload，全程**不打流**，每步间隔 60s | 复现概率低，但记录 |
| C | fw4 切换 + 打流 | B 基础上桥接流量保持（ssh 保活 / ping 192.168.123.1 每 2s） | 1→0→1 | **预期复现窗口**（桥接 hw 流表残留 + 数据面残余） |
| D | fw4 切换 + 打流（WAN 侧） | C 基础上加 2 路 WAN 下载 | 1→0→1 | 高复现期望（H1+H2 叠加面） |
| E | LuCI 页面切换 | — | 页面 Enabled/Disabled 往返 ×5 | 与 C/D 对照 RPC 层差异 |

每轮 N≥10，任一场景复现即停（设备会自动恢复），记录：复现前最后一次 `dmesg` 全文、`/sys/class/devcoredump/*`、WDT 寄存器、`/sys/kernel/debug/ppe/entries` 残留条数（重启前残留 BIND 条目数应随 reload 递增——**H1 的直接可观测证据**）。

### 8.2 取证装备（下次复现必须提前部署）

1. **串口 console**：确认 XR1710G UART pad（npu_uart? 见 9001 dts），`console=ttyS0,115200n8` 需写进 U-Boot env 的 bootargs（注意 F66：HTTP U-Boot 默认 env 覆盖 DTS chosen）。接 `screen/plink -l` 全程录屏。
2. **远程 syslog 落盘**：`logread -f | nc -u <host> 514`（或 ulogd json 到 http），**设备外**保存；配合 `kernel.printk='7 7 7 7'` 或 `ignore_loglevel`（测试期）。
3. **devmem 看门狗判定**（CONFIG_DEVMEM 已随 F45 开启）：
   - 复现前基线：`devmem 0x1fbf0100`（TIMER_CTRL，BIT25=WDT_ENABLE）、`devmem 0x1fbf012c`（LOAD）、`devmem 0x1fbf0130`（CUR_VALUE 递减计数）；
   - 切换后每 500ms 采样 `0x1fbf0130`：若观察到**递减并在复位前归零** → WDT 复位实锤；
   - 复位后读 `0x1fbf0100`：WDT_ENABLE 是否仍置位（U-Boot 是否重武装）。
4. **NPU coredump**：切换后循环 `ls /sys/class/devcoredump/`；出现即 `cat …/data` 存证（PC/SP/LR → 可反查固件符号）。
5. **pstore 基准实验**：`echo c > /proc/sysrq-trigger`（自愿 panic）后重启，检查 `/sys/fs/pstore` —— 若为空则证明"本平台复位即擦 ramoops"，今后不再依赖 pstore 判案；若 panic 能留痕，则 #7 复现后 pstore 有内容即可直接判定 panic 型。
6. **ftrace**（轻量）：`trace-cmd record -e 'flow_offload*' -e 'airoha*'` 常驻，事件量小、开销可接受；复现后 `trace-cmd report` 看最后一次 DESTROY/REPLACE 序列。
7. **计数探针**：`/proc/interrupts` 的 npu mbox/wdt IRQ 计数 500ms 采样；`/sys/kernel/debug/ppe/entries` 中 `state=BIND` 且 conntrack 已无对应流的条目数（残留条目的直接读数）。

### 8.3 判定表（复现后的证据 → 根因）

| 证据 | 指向 |
|---|---|
| pstore 有 panic 记录（且基准实验证明可保留） | 内核 panic（H3/其他）→ 拿栈定位 |
| pstore 空 + WDT 计数归零复位 | SoC WDT（H5 机制）+ H1/H2 原因 |
| NPU coredump 出现 PC 异常 | NPU 固件崩溃（H1/H2） |
| 复位前 ppe/entries 残留 BIND 条目数随 reload 递增 | H1 的驱动侧残留直接证据 |
| 复现仅发生在 C/D（有流量）场景 | 数据面/固件交互触发（H1+H2） |
| 纯 A/B 也复现 | 时序性缺陷独立触发（H1 结构性） |

---

## 9. 附录：关键引用索引

| 文件（版本） | 行/函数 | 作用 |
|---|---|---|
| `nf_tables_api.c` v6.18.44 | 8847-8854 `nft_unregister_flowtable_ops` | UNBIND 同步先于 free |
| 同上 | 10991-11011 commit DELFLOWTABLE | 提交期摘钩/UNBIND |
| 同上 | 10085-10100 `nf_tables_trans_destroy_work` | 对象释放异步 |
| 同上 | 9542-9549 `nf_tables_flowtable_destroy` | type->free 入口 |
| 同上 | 1674 `nf_tables_table_flush` | flush table 也销毁 flowtable |
| `nf_flow_table_core.c` v6.18.44 | 752-766 `nf_flow_table_free` | 逐流 DESTROY 发生点（晚于 UNBIND） |
| 同上 | 559-588 `nf_flow_offload_gc_step` | HW 流 DESTROY 入队 |
| `nf_flow_table_offload.c` v6.18.44 | 899-933 `nf_flow_offload_tuple` | 遍历 cb_list（空→漏删） |
| 同上 | 971-997 `flow_offload_work_del` | DESTROY 执行体 |
| 同上 | 1103-1126 add/del 入队 | 异步化 |
| `airoha_eth.c` v6.18.44 | 2761-2800 `airoha_dev_setup_tc_block` | BIND/UNBIND（FOE 无清理；cb 由 core 释放） |
| 同上 | 2741-2759 / 2875-2891 | block cb / TC_SETUP_FT 分发 |
| `airoha_ppe.c` v6.18.44 | 1389-1405 `airoha_ppe_setup_tc_block_cb` | 懒 offload_setup |
| 同上 | 1345-1387 `airoha_ppe_offload_setup` | HWNAT_INIT + flush |
| 同上 | 1000-1216 replace/destroy | FOE 增删（destroy 依赖 DESTROY 回调） |
| 同上 | 1569-1586 `airoha_ppe_deinit` | 仅驱动移除时调用 |
| `airoha_npu.c` v6.18.44 | 149-183 `airoha_npu_send_msg` | 100s 静默轮询 |
| 同上 | 245-281 wdt handler | 只 coredump、不复位 |
| `airoha_wdt.c` v6.18.44 | 43-52 / 127-173 | heartbeat 24s、probe 不接管 |
| openwrt `924` | — | coherent mbox（事发固件是否含存疑） |
| `fanboy/18`（992-21 74 行版） | — | WLAN 命令重试；PPE 路径无重试 |
| fw4 ruleset.uc:9-28 / fw4.uc:508-560 | — | 每次 reload flush+重建、hw 探测 |
| `bridge-flow-offload`（05/9024） | apply-rules.sh | 桥接 hw 表每次 reload 重建 |
| 本仓库 | F34/F51/F30/F46、T1 记录 | 事件台账与测试证据 |

> 源码获取记录：v6.18.44 airoha 驱动/看门狗/netfilter 源码、torvalds master 对照、openwrt main `patches-6.18` 相关补丁、fw4（openwrt/firewall4 b6e51575）已下载至工作区 `tmp/openwrt-src/`（含 `airoha-6.18.44/`、`owrt-patches/`、`master-*.c`、`fw4/`），供后续补丁落地与复审使用。
