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
