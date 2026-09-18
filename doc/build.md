# 构建与使用

> 本文件由仓库 README.md 抽取并集中到 `doc/`（README 现已精简为项目说明）。
> 维护请以本文件为准；如需回看原始结构见 `doc/README.md` 索引。

## 2. 快速开始

### 2.1 先准备 OpenWrt 源码树（只需一次）

本仓库与上游 `xr1710g-openwrt` 都只是**叠加层**（补丁 + 配置），**不是源码树** ——
它们不含 `package/`、`target/`、`scripts/feeds`。构建必须有一棵真正的 openwrt 源码树：

```bash
git clone https://github.com/openwrt/openwrt.git <路径>/openwrt
cd <路径>/openwrt && git log -1 --date=short   # 建议接近补丁快照日期（见 §7）
```

当前已备好的树示例：`<源码树路径>`（如 `../openwrt` 或 `../source_openwrt/openwrt`，
官方 `openwrt/openwrt` main，kernel 6.18，含 `target/linux/airoha`）。

### 2.2 构建

```bash
# 建议首次刷机走保守档（不提档实验补丁，最小差异，63 条活动）
scripts/build-mine.sh v1-safe --tree <源码树路径>

# 正式档（func 选择集，103 条活动补丁）
scripts/build-mine.sh stock --tree <源码树路径>

# 只合成 .stage/ 不构建（调试 rules 用）
scripts/build-mine.sh v1-safe --stage-only

# 全链但停在构建前（验证 stage + audit + 源码树定位）
scripts/build-mine.sh v1-safe --dry-run

# 保留上游超频（默认 DISABLE_OC=1 关闭超频，跑 stock 1200MHz）
scripts/build-mine.sh stock --disable-oc 0
```

`--tree` 可省略：脚本会依次自动探测 `$OPENWRT_DIR`、`../openwrt`、`../../openwrt`、`../source_openwrt/openwrt` 等目录。

产物：**`<源码树>/bin/targets/airoha/an7581/*.itb`**（**FIT 镜像，不是 .bin**；
注意在源码树内，**不在 `.stage/` 下**）。刷机步骤见上游仓库 `docs/FLASHING.md`。

首次构建需联网装 feeds，耗时 1–3 小时、磁盘十几 GB。日志在 `.stage/build-<tier>.log`。

---

## 3. 构建流水线（build.sh 上游 6 步 + 本仓库预处理）

| 步 | 动作 | 说明 |
|----|------|------|
| 0 | reset / rsync 上游 → `.stage/` | 上游版本 `1fea1e5` |
| 1 | apply-patches | 叠加 `patches/` 到构建树 |
| 2 | prepare-oc | **本仓库用 sed 改写为 no-op**（DISABLE_OC=1 时） |
| 3 | feeds | 更新软件源 |
| 4 | defconfig + seed | 叠加 `local/seed.local.diff` |
| 5 | make | 编译，出 `.itb` |

`stage.sh` 的 7 步 = rsync → merge-manifest → 重生成 ORDER → 叠加本地补丁 → 叠加 files → 追加 seed → 禁 OC。

---

## 7. 版本锁定

- 上游基线：`1fea1e5`（ci-172）
- 已裁决至：`244d433`（2026-09-17，见 `../upstream-decisions.md`）
- YYH 参考：tag `xr1710g_260831`，SNAPSHOT r2363-e88fbe28ea，kernel 6.18.44，**apk** 系
- 本产物：**opkg** 系（func 上游）

---

## 8.5 GitHub Actions 构建（推荐，替代本机）

全量构建 1–3 小时且吃满 CPU，用 CI 更划算。workflow：`.github/workflows/build.yml`。

### 首次设置（一次性）

本仓库尚未推到 GitHub，先在网页建仓库（**建议 Public**：Actions 分钟不限量；
Private 免费额度 2000 分钟/月，一次构建 1–3 小时，只够 10–30 次）：

```bash
cd <项目根>/openwrt
git remote add origin git@github.com:<你的账号>/<仓库名>.git
git push -u origin main
```

### 触发构建

```bash
gh workflow run build.yml -f profile=stock
# 或在 GitHub 网页：Actions → build → Run workflow
```

网页端可选参数：

| 参数 | 默认 | 说明 |
|------|------|------|
| `profile` | `stock` | **stock = func 正式档（103 活动）**；`v1-safe` = 保守档（63 活动） |
| `openwrt_ref` | `f1230284c6…` | OpenWrt 源码树 ref |
| `upstream_ref` | `1fea1e59…` | 上游叠加层 ref |

### 为什么 pin 两个 ref

默认锁到 **2026-09-17 实测通过**的组合，保证可复现。取最新 `main` 可能引入补丁
上下文冲突（先例：`21-hsuart` 与 09-16 树不匹配，已停用；换版本可能再现同类冲突）。
需要跟进上游时**显式改 input**，别默认跟随。

### CI 流程

取出本仓库 → clone 上游叠加层 + OpenWrt 源码树 → `stage.sh` 合成 `.stage/`
→ rsync 进源码树 → `apply-patches.sh` → feeds → defconfig+seed(+ccache) → make
→ 上传 `firmware-<profile>` 与 `buildlog-<profile>`。

内置 ccache（3G，需 `restore-keys` 才命中，上游 F166 实证）与防假绿措施
（`set -euo pipefail`、`if-no-files-found: error`）。

---

## 9. 两个已定位的环境坑（实测，非推测）

### 9.1 必须 C locale —— 否则上游脚本一启动就崩

上游脚本有 **41 处**「`$VAR` 紧跟全角标点」的写法（典型：`build.sh` 的 `echo "... （$TIER）"`）。

在 **UTF-8 locale** 下 bash 会把多字节字符并入变量名，**即使变量已定义**也报：

```
build.sh: line 36: TIERï¿½: unbound variable
```

实测对照：

| locale | 结果 |
|--------|------|
| `C.UTF-8` / `en_US.UTF-8`（macOS 默认） | ✗ 必崩 |
| `LC_ALL=C` | ✓ 正常 |

上游 CI 跑在 C locale，所以从未暴露。`stage.sh` / `build-mine.sh` 已 `export LC_ALL=C` 规避。

### 9.2 本地 `96xx` 补丁改 `files/`：dry-run 与真实构建的行为差异

`96xx` 改的是 `files/etc/config/*`。该目录由 `build.sh` 第 0 步 rsync 叠进源码树，
**在源码树里是未跟踪文件**，于是：

| 场景 | 命令 | 结果 |
|------|------|------|
| **真实构建** | `git apply`（无 `--index`） | ✅ 正常（已实测：9601/9602 均应用成功） |
| dry-run 预检 | `git apply --index` | ❌ `does not exist in index` |

**真实构建不受影响**，只有对外部树跑 `--dry-run` 会在本地补丁处停。
（上游 CI 的 dry-run 是对仓库自身跑，`files/` 已跟踪，故不受影响。）

> 实测记录（2026-09-17，源码树 `openwrt/openwrt@f1230284c6`）：叠加后跑 dry-run，
> 全部 93 个 ROOT 补丁通过，仅本地 9601 因子上原因停止 —— 属预期，非补丁缺陷。
