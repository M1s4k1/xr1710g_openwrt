# 补丁层规范（patches/）

本目录是本仓库的**自维护补丁层**：openwrt master 尚未合入、或不打算合入（如 OC/regdb 功率）的全部改动都从这里进树。
**政策：遇到问题修复而不是降级**——补丁与上游冲突/失效时，定位根因修复本层，而不是删掉能力。

## 目录与目标映射

| 桶 | 内容 | 落点（相对 openwrt 树根） |
|---|---|---|
| `patches/packages/` | 包级补丁（regdb / mt76 / mac80211 / iwinfo / firewall4 / rpcd / uboot…） | 按 `MANIFEST` 指定目录拷贝 |
| `patches/root/` | 跨目录补丁（#22397 板级、内层内核补丁包裹、OC 相关等） | 树根 `git apply`（包裹补丁装内层到 `target/linux/airoha/patches-6.18/` 等） |
| `patches/specs/` | 补丁**说明书**（来源 URL/上游状态/待取源）或暂存参考补丁 | 不自动应用 |
| `patches/vendor/fanboy/` | **原料桶**：OpenW1700k `ubi2-oc` 全 21 commit（git format-patch，2026-08-17 抓取，2026-09-12 补入 21 号 HSUART） | 评审/拆分后移入正式桶或按 MANIFEST 引用 |

> ⚠ 不存在 `patches/kernel/` 与 `patches/uboot/` 两个桶（2026-09-14 F164 更正旧表格）：内核类改动一律以
> **包裹补丁**形态放在 `patches/root/`（外层 new-file hunk 把内层补丁装进 `target/linux/airoha/patches-6.18/`），
> U-Boot 类同理装进 `package/boot/uboot-airoha/patches/`。

## MANIFEST（应用清单）

`patches/MANIFEST` 每行一条：`<补丁相对路径> <目标目录|ROOT>`。

- `#` 开头 = 注释/停用；`#EXP ` 开头 = 实验档（`apply-patches.sh --experimental` 才应用）；`#OC ` 开头 = OC 档（`apply-patches.sh --oc` 才应用）；`#DISABLED ` 开头 = 停用（文件保留留痕，任何档位都不应用）。
- `patches/ORDER` 是**档位评审视图**，被定义为 MANIFEST 的**投影**（2026-09-14 F164 起）：
  - 档位词汇 `default | oc | experimental | disabled | pending`，与 MANIFEST 前缀一一对应；`pending` = **不在 MANIFEST** 的原料/备选。
  - **`#` 开头的行只作说明，不再承担「禁用」语义**（旧写法 `# experimental root/9037-...` 双重语义已废止）。
  - `scripts/audit-order.sh` 逐条对账（集合 + 档位），由 `apply-patches.sh` 在每次应用前（含 `--dry-run`）自动调用 ⇒ **改 MANIFEST 必须同步 ORDER，否则构建/CI 直接红**。
  - 重生成：`scripts/gen-order.py [仓库根]`（行尾评审注释按路径从旧表继承；`--check` 只校验不改写）。
- **实验档构建/校验（F25，2026-08-18）**：`./scripts/build.sh experimental` 或 CI dispatch `profile=experimental` 可完整构建实验档；本地 `apply-patches.sh --dry-run --experimental` 与 2h sync-upstream cron 均覆盖实验档（audit-patches/verify-copy-patches 已感知 `#EXP` 行，拷贝类实验补丁同样真实应用校验）。**实验档 → 默认档毕业条件**：在 known-good 周期内跑通 `docs/ACCEPTANCE.md` 全项 → 取消 `#EXP` 注释并入默认，并在 `docs/FIXES.md` 对应条目改状态。

## 补丁文件元数据头约定

每个补丁文件首段注释（`#` 行）建议包含：

```
# Source:  <URL / PR 号 / commit>
# Upstream: merged | open(PR #NN) | carried-only | n/a
# Reason: 一句话为什么在本层
```

## OC（超频）不是普通补丁

OC 依赖 master 树当前形态（`an7581.dtsi` OPP 表、`config-6.18` governor、PM domain 的 PLL 公式位置随内核版本漂移），因此不放在 MANIFEST，
由 `scripts/prepare-oc.sh <1.3|1.4>` 在**构建前**对树做确定性编辑（失败即报错，不静默降级）。原始参考补丁见
`patches/vendor/fanboy/20-oc-governor-200mhz-ed7cbc80.patch` 与 `patches/specs/original-oc-80096373b5-6.12-reference.patch`。
OC 变体的**默认限频 1300MHz** 由 `files/etc/init.d/oc-limit` 实现（1.4G 能力 + 保守默认，sysfs 可解锁，重启回退）。

## 新增补丁流程

1. 取源（PR diff / 分支 commit）放入对应桶，写元数据头 + `MANIFEST` 条目（或 `#EXP`）；
2. `scripts/apply-patches.sh <树> --dry-run` 验证可应用——**dry-run 含真实应用校验**（F20/F21 制度化）：
   - ROOT 补丁在树根 `git apply --index` 按序真实应用；
   - 拷贝类（packages）与派生包补丁（ROOT 补丁生成的，如 9002→uboot）由 `scripts/verify-copy-patches.sh`
     按构建语义真实校验：树内包 Makefile 派生源码 tarball（缓存于 `$COPY_PATCH_CACHE` 或 /tmp）→ 解包 →
     「树内已有补丁 + 本层补丁」同目录 → 构建同款 `patch-kernel.sh` glob 排序 `patch -f -p1` → regdb 附
     dbparse.py 校验；**应用失败=红（2h sync cron 尽早暴露），下载失败=⚠ 不红（构建兜底）**；
     **例外（F163）**：**HTTP 404/410 = 源不存在 = 配置错误 ⇒ 红**（源写错是可复现的确定性故障，不是
     瞬时网络问题；旧行为会把它当「未校验」静默降级 ⇒ 该 dest 的补丁长期失去校验而 cron 仍全绿）；
   - 包补丁命名注意 **glob 字节序**（F21 教训）：`1000-` 排在 `100-` 与 `101-` 之间，`9990-` 才在 `999-` 后；
   - 新增拷贝类补丁目标（新包）时需在 verify-copy-patches.sh 登记包源映射，否则 ⚠ 跳过不校验；
     **git 型包（`PKG_SOURCE_PROTO:=git`）的归档 URL 从包 Makefile 的 `PKG_SOURCE_URL` +
     `PKG_SOURCE_VERSION` 派生，不硬编码上游**（F163；归档顶层目录 = **源 URL 的 repo 名**-<全 sha>，
     不是 PKG_NAME/包目录名）；源 URL 不可推导时**报红**而非跳过；
3. 首次构建验证；构建/启动问题 → 修本层补丁（修复不是降级），并记 `docs/FIXES.md`。