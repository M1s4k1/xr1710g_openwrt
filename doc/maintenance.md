# 长期维护：基座跟踪 + 逐条裁决

> 本文件由仓库 README.md 抽取并集中到 `doc/`。维护请以本文件为准。

## 1. 基座更新感知（OpenWrt 主线）

```bash
scripts/check-upstream.sh            # 只读本地状态（pin、本地树 HEAD，不联网）
scripts/check-upstream.sh --fetch    # fetch 后对比 pin..origin/main
scripts/check-upstream.sh --fetch --focus   # 只列 focus 路径相关提交
```

- focus 路径：`target/linux/airoha`、`target/linux/generic`、`package/kernel/mt76`、
  `package/kernel/mac80211`。
- pin 推进是**显式决策**：见到 focus 相关提交先评审（下节），决定推进再改
  `config/source-lock.env` + 全量验证补丁集（apply + build）。

## 2. 参考来源巡检（多来源）

```bash
python3 scripts/review-upstreams.py            # 8 个登记来源只读巡检
python3 scripts/review-upstreams.py --out <路径>  # 落报告
```

来源登记在 `config/upstream-sources.yml`（openwrt = 基座源；YYH/naoki/gilly 等为
参考源；fanboy 已废弃）。判定词汇：`advance` / `no-update` / `baseline-orphaned` /
`baseline-unresolved` / `ref-missing` / `network-fail` / `force-push`。

## 3. 逐条裁决工作流

1. 巡检产出逐来源报告（来源 / 完整 SHA / 改动内容）；
2. 按候选分析：改动功能、与我们补丁集的重叠/冲突（HIT / COLLIDE / 重复）、
   机型相关性、版本锚；
3. 结论写入 `doc/patch-review.md`：AI 只填事实与 `ai-*` 字段，人工字段
   （`absorb-*` / `status` / `reason` / `reviewer` / `reviewed_at`）由人填写；
4. accept 项的实施：改 `local/patches/`（或推进 pin）后，`audit-local.sh` +
   `build-mine.sh --dry-run` 验证，再真构建。

## 4. 历史账本

`upstream-decisions.md` 保留转向前（aggregate 时代）的裁决记录；转向后的轮次记录在
`doc/patch-review.md`（首轮：2026-10-21，16 候选 + fanboy 重锚待办——后者已随
fanboy 废弃关闭）。

## 5. 收敛原则（转向后的维护哲学）

- 驱动/框架问题：优先推动上游合入（板级方向：社区 PR #22397），本地只做桥接；
- 本地补丁尽量小、可上游化；成熟一个、上报一个；
- aggregate 参考目录仅用于查证 provenance 与 Phase 2 移植，不进构建。

## 6. aggregate 快照已移出（2026-10-21）

转向前内置的 `aggregate/`（genshanxinli/xr1710g-openwrt@244d433 冻结快照，
207 个文件）已于 2026-10-21 晚整体移出仓库：

- **移出前内容**：git 历史可完整取回（`git log --all -- aggregate/`，
  移出前最后状态在 `ff65d49`）
- **挂起项 9010 的源**：复制到仓库外上层目录
  `misaki-openwrt/9010-wifi-scripts-txpower-ucode.patch.pending-rebase`
  （wifi-scripts per-radio txpower，待结构级 rebase；manifest.rules 头有详细说明）
- **溯源不断**：全部本地补丁头的「原体：aggregate/patches/...」注释与
  manifest 的理由行保留（指向历史路径，同 "FIXES Fxxx" 悬空标记的性质）
- **裁决账本**：`upstream-decisions.md`（aggregate 时代）与
  `doc/patch-review.md`（转向后）均保留

## 7. 补丁的内核源码级验证（2026-10-22 建立）

复制型补丁的验证分两层：**树侧可拷贝**（apply-patches.sh --dry-run）与
**内核源码级可应用**（构建期 `patch -p1` 的真实战场）。后者曾长期空白，
2026-10-22 CI func 二连败暴露后补齐，方法：

1. 从 CI 日志拿源码 URL（kernel: `cdn.kernel.org/pub/linux/kernel/v6.x/linux-<ver>.tar.xz`；
   mac80211: openwrt/backports release 资产 `backports-<ver>.tar.zst`；mt76: pin 的 PKG_SOURCE_VERSION）；
2. 抽取补丁目标文件（+ 头文件）；
3. **按序应用主线自身补丁**（同目录、编号小于我们的），得到真实上下文状态
   （注意：目录里若混有我们自己创建的补丁文件，必须排除，否则模拟被污染——
   曾因此误判 9061 的 9999-3x "失败"）；
4. 逐个应用我们的补丁；失败则用「hunk 计数校验器 + 最长前缀匹配分歧行」定位并重锚。

已验状态（截至 2026-10-22）：mt76 32/32（对 mt76@467ae2e）、generic 675-01/02/03、
airoha 957（**superseded 已删**）/960/961/976/980、airoha 9999-30..35、
mac80211 subsys 10/10（对 backports-v7.2）全部干净。

### 7.1 第二批 superseded 与实际基准修正（2026-10-22 晚）

CI GNU patch（gpatch 2.8）全量验证暴露的失败，逐条在**真源**上裁决后处置：

| 补丁/段 | 处置 | 真源依据 |
|---|---|---|
| 9998（airoha_ppe.c flush_sram） | **删**（9746 整文件） | 内核 6.18.55 已把函数重构为 `airoha_npu->ops.ppe_flush_sram_entries` 委派（签名多 `npu` 参数、循环只 memset、错误由 ops 层传播） |
| mt76 9809/9816/9820 | **删** | mt76 **真基准是 openwrt pin Makefile 的 467ae2e**（非注释里的 be5ce791）：主线已含 `sta &&` EAPOL 守卫、NPU agg-timer 门、删 add_sta(DISCONNECT) |
| 9999-30/31 的 offload.h hunk | **补回误删的 diff 文件头** | 上一轮删 superseded hunk 时把 `+diff --git a/include/...` 等四行一起删了 ⇒ hunk 沦为 npu.c diff 延续 ⇒ GNU patch 上下文全 FAILED（连锁 9999-32） |
| 992-20 hunk 8/9（trtcm retry） | **删** | 上游平台补丁 `187-v7.3-Add-retry-mechanism-to-airoha_qdma_set_trtcm_param`（Airoha Leto Liu，ansuelsmth 改进入集）已用 `TRTCM_CONFIG_RETRY_MAX` for 循环 + 回读 + `-EBUSY` 实现同一功能且更强；187 字典序先应用 ⇒ hunk 9 旧侧被破坏，且 hunk 8 加的 value_lo/retry_num 成死代码 |

**方法论沉淀**：

1. **Reversed ≠ superseded**：GNU patch 报 Reversed 只说明"新侧已在文件中"，可能是主线吸收，
   也可能是顺序链中**前置补丁**先应用了同一改动。判定必须回到**隔离 dry-run**（纯净源 + 单补丁）。
   本轮 9809/9816/9820 曾被误判——隔离 dry-run 全干净，实为验证树基准用错 commit。
2. **包版本基准永远以树的 Makefile 为准**（`PKG_SOURCE_VERSION`），注释里记录的 commit 可能过期；
   本例 mt76 注释写 be5ce791，而 pin 树实际 467ae2e。
3. **元补丁删段时必须保住 diff 文件头**：`+diff --git`/`+index`/`+---`/`++++` 四行是补丁内容的
   结构骨架，删 hunk 时连带删除会让后续 hunk"嫁接"到前一个文件的 diff 上。
4. **删段后三件事**：重算 `@@ -0,0 +1,N` 计数（N = 该段 `+` 行数）；保结尾换行；
   `git apply --check` 验整个元补丁（计数不精确会报 corrupt patch）。

### 7.2 verify 脚本前置守卫与 /files 陷阱（2026-10-22）

- openwrt 的 `.gitignore` 第 16 行是 `/files` ⇒ **整个 files/ 目录被忽略**：
  `git clean -fd` 清不掉其中残留，`git status` 也不显示。复用验证树 reset 必须
  `git reset --hard && git clean -fdx`。
- 若树未应用本地补丁集，各组 apply_set 全部"无补丁，跳过"⇒ 输出**"全部通过"——假绿**。
  已在脚本加 `_preflight` 守卫：树内无 9999x/98xx/dts/uboot 任一产物即 `die`。
  判据不用 `99*` 通配——上游 airoha 平台目录自带 17 个 99x 补丁（998/9990-9997 等）。

### 7.3 编译级失败与符号重复定义（2026-10-23）

源码级验证（补丁能应用）之后还有**编译级**关卡，CI func 首次进 make 后连败两次，
各暴露一类新问题，均已修复并沉淀：

| 失败 | 类别 | 根因 | 修复 |
|---|---|---|---|
| `nf_flow_table_path.c:307 error: label 'skip_l3' used but not defined` | 重锚不完整 | 9722/675-02 重锚时保留 `goto skip_l3` 丢了标签定义 | 对照原源 fanboy/06 补回标签（hunk 新侧 21→23） |
| `airoha_npu.c:414 error: 'airoha_npu_cancel_wdt_work' defined but not used` | 删段副作用 | 删 9999-31 的调用方 hunk 4/5 时保留了函数定义 hunk 3 | 一并删除（9999-31 计数 87→73） |
| `mcu.c:6161 error: redefinition of 'mt7996_mcu_set_tx_power_ctrl'` | **符号重复定义** | 主线 mt76@467ae2e 已吸收该函数（mcu.c + mt7996.h 声明 + main.c 第一处调用），9804 又加一份 | 9804 删函数定义 hunk、删 main.c 第一个调用（主线已有 hardcoded true）、删 mt7996.h 声明；`#define TX_POWER_LIMIT_TABLE_PATH` 移入常量 hunk（242→243） |

**方法论**：

1. **"补丁能应用"有三层关卡**：补丁应用（patch 语义）→ 源码结构自洽（标签配对、
   函数有调用者）→ 编译（符号唯一、类型匹配）。verify-source-patches.sh 只覆盖第一层。
2. **符号重复定义是新失败类别**：补丁新增的顶层符号（函数/结构体/宏）若主线已吸收
   ⇒ 重定义编译错误。判定法：在**纯净主线**（不是 lazy clone 的假阴性！）grep 符号；
   注意 `git clone --filter=blob:none --no-checkout` 的树 grep 会假阴性，须先 checkout。
3. **删段时必须检查"定义-使用"配对**：删调用方时要连带删定义；反之删定义时要删调用。
4. **hunk 上下文连续性**：GNU patch 要求 hunk 上文末行与下文首行在目标文件连续；
   主线在两函数间插入新函数时，跨函数的新增 hunk 会 FAILED——此时应把新增内容
   （如 #define）移到同函数的其他 hunk 或常量区，而不是硬保原 hunk。
