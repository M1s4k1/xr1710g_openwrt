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
