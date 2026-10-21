# 构建与使用

> 本文件由仓库 README.md 抽取并集中到 `doc/`。维护请以本文件为准。

## 1. 准备 OpenWrt 源码树（只需一次）

本仓库是**差异仓库**（补丁 + 配置），不是源码树——不含 `package/`、`target/`。
构建必须有一棵真正的 OpenWrt 源码树，并 checkout 到 `config/source-lock.env` 的 pin：

```bash
git clone https://github.com/openwrt/openwrt.git <路径>/openwrt
cd <路径>/openwrt && git checkout 63f702f1c0cebe2587aac10b63a02e964fc2a558
```

## 2. 构建

```bash
# 首次刷机建议保守档
scripts/build-mine.sh v1-safe --tree <路径>/openwrt

# 正式档
scripts/build-mine.sh func --tree <路径>/openwrt
```

`build-mine.sh` 流程（2026-10-21 架构转向后）：

| 步 | 动作 | 说明 |
|----|------|------|
| 0 | 源码树复位 | `git reset --hard` + `clean -fdx`（树视为可丢弃品；有未提交改动会先警告） |
| 1 | `apply-patches.sh --tier` | 校验树 HEAD == pin；按清单应用 `local/patches/` |
| 2 | feeds | 官方默认 + `config/feeds.custom.conf`（packages-xr1710g src-link） |
| 3 | 配置 | `make defconfig` → 追加 `local/seed.local.diff` → `make defconfig` → 符号审计（目标选中 + seed 符号逐一进 .config） |
| 4 | `make` | 产物：`<树>/bin/targets/airoha/an7581/*.itb`（**FIT 镜像**） |

其他模式：`--apply-only`（只应用补丁不构建）、`--dry-run`（只做 apply --check）、
`--allow-drift`（树不在 pin 也放行，慎用）。

## 3. GitHub Actions

```bash
gh workflow run build.yml -f profile=v1-safe
```

| 参数 | 默认 | 说明 |
|------|------|------|
| `profile` | `v1-safe` | `func` = 正式档；`v1-safe` = 保守档（首刷建议） |
| `openwrt_ref` | `63f702f1c…` | OpenWrt ref；改它 = 换基座，须同步 `source-lock.env` 并评估补丁兼容性 |
| `create_release` | true | 成功后自动建 Release |

CI 流程：clone openwrt@pin（内核 6.18.55 硬门禁）→ audit-local → apply-patches →
feeds + defconfig + seed + ccache 注入 → make → 上传 `.itb` 与 Release。

## 4. 版本锁定

- 基座 pin：`63f702f1c0cebe2587aac10b63a02e964fc2a558`（Linux **6.18.55**）
- 锁定文件：`config/source-lock.env`；改动 = 显式决策，须全量重新验证补丁集
- aggregate（前基座）已退役为参考目录，见 `aggregate/REFERENCE.md`

## 5. 已定位的环境坑

- **C locale 必须**：上游/构建脚本有「`$VAR` 紧跟全角标点」写法，UTF-8 locale 下
  bash 把多字节首字节并入变量名 ⇒ `unbound variable`。本仓库脚本统一 `export LC_ALL=C`。
- 源码树被 `git reset --hard` + `clean -fdx`：别在树上放手工改动。
- `files/` 在 OpenWrt 树里被 `.gitignore` 忽略——测补丁后清理树要 `clean -fdx`。
- `git apply ... | head` 会吞退出码：脚本里判断应用结果别用管道。
