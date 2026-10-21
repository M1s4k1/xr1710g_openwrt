# ADR 0001 — 固件基座：openwrt master fork + 自维护补丁层

**Status**: accepted（2026-08-17 评审确定）
**Context**: XR1710G 板级支持 PR #22397 仍在 review、master 未含 xr1710g 文件；同 SoC 的 W1700K 已合入。社区最活跃的 YYH2913 分支（`xr1710g-6.18-integration`）已含板级支持与 6GHz/US regdb 系列补丁，但与官方主线相差 157 commit。
**Decision**: 以 openwrt/openwrt **master 为基座** fork，所有未合入内容（#22397 板级支持、YYH2913 regdb/mt76 补丁、11 个 open PR 等）以**独立 `patches/` 目录 + 应用脚本**形式携带，外部包走 src-git feed 锁定 commit，另立 `FIXES.md` 修复台账。补丁分默认档/实验档，实验档调试通过后并入默认档。
**Why**: "包含全部最前沿内容 + 出问题修复不降级"的前提是留在官方前沿线上且改动可溯源——基座越贴近 master，rebased 成本越低；上游合入后对应补丁即可删除（如 #24593 已合，无需携带）。YYH2913 分支作为补丁来源矿场而非基座。
**Considered Options**:
- YYH2913 `xr1710g-6.18-integration` 为基座：开箱即用但偏离主线 157 commits、个人维护、rebase 成本随上游演进持续累积，且"修复不降级"会退变成"跟随作者意愿"。否决。
- ImmortalWrt 基座：三频默认配置成熟，但上游跟随最弱，与"最前沿"矛盾。否决。
- iStoreOS 社区版基座：功能最全但内核/驱动最旧。否决。
**Consequences**: 每周同步上游的冲突处理是常态成本；需为 #22397 建立"合入即删补丁"的跟踪机制（FIXES.md 中标注"待上游"条目）。