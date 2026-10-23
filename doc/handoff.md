# XR1710G 固件项目 · 交接文档（AI 接手指南）

> **本文档目的**：让另一个 AI（或新人）在只读本文档 + 本仓库的情况下，完整理解项目并安全接手。
> 最后更新：2026-10-21（架构转向 + Phase 2 完成态）。
> 事实来源优先级：`local/manifest.rules`（补丁清单）> 本文档 > 其他文档。发现冲突时以 manifest 与代码为准。

---

## 1. 项目是什么

为 **Gemtek XR1710G**（Airoha EN7581 SoC / MediaTek MT7996 Wi-Fi7 / 2×10G + 2×1G 网口）构建 OpenWrt 固件的**差异仓库**。

- **不含 OpenWrt 源码**：仓库只放"相对上游主线的差异"——补丁集 + 配置 + 工具链 + 文档。
- **基座是 OpenWrt 主线**（2026-10-21 起）：构建时把本地补丁集应用到一棵 pinned 的 OpenWrt 源码树上。
- 设计哲学：**驱动/框架用主线自带，本项目只保留板级差异与确有必要的能力增强；成熟补丁向上游提交**。

### 硬件关键事实

| 项 | 值 |
|---|---|
| 板级 DTS | `an7581-xr1710g-ubi.dts`（由 9402 创建，include 主线已有的 `an7581.dtsi` + `an7581-npu-mt7996.dtsi`） |
| 内核 | Linux 6.18.55（pin 63f702f1c 时点） |
| mt76 | openwrt/mt76 @ `467ae2e3` |
| 网口映射（9501 后） | **eth1=WAN(10G-1) / eth2=LAN(10G-2) / lan2(1G-1)=LAN / lan3(1G-2)=LAN** |
| 默认 LAN | `192.168.2.1`（9601） |
| MAC | WAN MAC 不钉死——DTS `&gdm2` 绑 nvmem 从 `factory:0x5000` 读出厂值 |

---

## 2. 架构模型（必读，最容易困惑的点）

```
┌─────────────────────┐         ┌──────────────────────────────┐
│  本仓库（差异）      │         │  OpenWrt 源码树（外部提供）   │
│  local/patches/ 100 │─apply──▶│  checkout 到 pin 63f702f1c   │
│  config/ 配置        │         │  （本地 --tree 或 CI clone）  │
│  scripts/ 工具链     │         └──────────────────────────────┘
└─────────────────────┘
```

- **pin**：`config/source-lock.env` 记录 `OPENWRT_REF=63f702f1c0cebe2587aac10b63a02e964fc2a558` 与 `LINUX_VERSION=6.18.55`。`apply-patches.sh` 会校验源码树 HEAD 必须等于 pin（除非 `--allow-drift`）。
- **为什么不含源码**：差异仓库模型——仓库小（可 review 的纯 diff）、上游更新 = re-pin + 复验补丁。整树 fork 模型（~1GB）评估过，结论见第 10 节。
- **历史**：2026-10-21 前本项目基于 `genshanxinli/xr1710g-openwrt` 的冻结快照（aggregate 模式）；当日起基座切为 OpenWrt 主线，aggregate 已移出仓库（可从 github.com/genshanxinli/xr1710g-openwrt@244d433 重新获取）。转向决策记录在**仓库外**：`../xr1710g-mainline-pivot.md`。

---

## 3. 仓库结构

```
xr1710g_openwrt/
├── local/                        # ★ 本项目唯一事实来源（手工维护）
│   ├── manifest.rules            # func 档收录清单（100 条）
│   ├── manifest.rules.v1-safe    # v1-safe 保守档清单（7 条）
│   ├── patches/                  # 100 个补丁（命名即排序）
│   └── seed.local.diff           # 设备与预装包选择（.config seed）
├── config/
│   ├── source-lock.env           # 三重锁定：OpenWrt pin / 内核版本
│   ├── feeds.custom.conf         # 自定义 feed（packages-xr1710g，9603 创建）
│   └── upstream-sources.yml      # 参考来源登记（openwrt=基座；fanboy 已废弃）
├── scripts/
│   ├── apply-patches.sh          # ★ 核心：pin 校验 + 按清单应用补丁
│   ├── build-mine.sh             # 构建入口（树复位→apply→feeds→seed→make）
│   ├── audit-local.sh            # 仓库自检 [A]-[H]
│   ├── check-upstream.sh         # 基座更新跟踪（--fetch 对比 pin..origin/main）
│   └── review-upstreams.py       # 多来源只读巡检
├── doc/                          # 全部运营文档（build/rules/audit/config-ownership/maintenance/handoff）
├── tests/test_review_upstreams.py
├── upstream-decisions.md         # 多来源巡检评审账本（历史轮次）
└── .github/workflows/build.yml   # CI：clone openwrt@pin → audit → apply → build
```

### 补丁清单格式（manifest.rules）

```
<文件名>.patch                        # 理由: ...   ← 应用型：git apply 到树
<文件名>.patch -> <目标目录>/          # 理由: ...   ← 复制型：拷进树的包补丁目录
```

- 每行**必须带理由**（audit [A] 检查）。
- **应用顺序 = 行序**（apply-patches.sh 按行序应用；命名 94xx→98xx 与行序一致）。
- 复制型用于 OpenWrt"包源码补丁"机制：文件落进 `package/kernel/mt76/patches/`、`package/kernel/mac80211/patches/subsys/`、`package/firmware/wireless-regdb/patches/` 等目录，由**构建期**的 `patch -p1` 应用（带 fuzz）——注意这与 `git apply` 语义不同！

---

## 4. 快速开始

### 4.1 本地构建

```bash
# ① 准备 OpenWrt 源码树（只需一次）
git clone https://github.com/openwrt/openwrt.git /path/to/openwrt
cd /path/to/openwrt && git checkout 63f702f1c0cebe2587aac10b63a02e964fc2a558

# ② 构建（首次刷机建议 v1-safe）
scripts/build-mine.sh v1-safe --tree /path/to/openwrt

# 正式档
scripts/build-mine.sh func --tree /path/to/openwrt
```

`build-mine.sh` 流程：源码树复位（`git reset --hard` + `clean -fdx`，**树上别放手工作业**）→ apply-patches（pin 校验 + 应用）→ feeds（官方 + 自定义）→ `make defconfig` → 追加 `seed.local.diff` → `make defconfig` → 符号审计（目标选中 + seed 符号逐一进 .config + 6.18.55 内核门禁）→ `make`。产物：`<树>/bin/targets/airoha/an7581/*.itb`（**FIT 镜像，不是 .bin**）。

其他模式：`--apply-only`（只打补丁）、`--dry-run`（只验证不构建）、`--allow-drift`（树不在 pin 也放行，慎用）。

### 4.2 CI 构建

```bash
gh workflow run build.yml -f profile=v1-safe    # 或 func
```

CI 自动 clone openwrt@pin（内核版本硬门禁），audit → apply → defconfig+seed → make → 上传 .itb + Release。

### 4.3 只验证补丁集（不构建）

```bash
scripts/apply-patches.sh --tree /path/to/openwrt --tier func --dry-run
scripts/audit-local.sh
```

---

## 5. 档位

| 档位 | 哲学 | 补丁数 |
|---|---|---|
| **v1-safe**（首次刷机建议） | 主线默认 + 板级使能最小集：能开机、网口/无线/上网正常。不夹带任何增强 | **7** |
| **func**（正式档） | v1-safe + NPU offload 栈 + 全部功能增强 | **100** |

func = 52 应用型 + 48 复制型。两档差异只在 manifest 清单；seed 相同（func 的 NPU 符号默认已开）。

---

## 6. 补丁全集（100 个）与作用

> **权威清单在 `local/manifest.rules`**（每行带理由）。下表按功能组归纳；每个补丁头部的 `# 原体` 注释记录其来源（aggregate 时代编号）。

### 6.1 板级使能（9401-9403，3 个）——没有它们就没有本板型号

| 补丁 | 作用 |
|---|---|
| 9401 ← 9000 | an7581.mk 注册 `Device/gemtek_xr1710g-ubi` 与 DEVICE_PACKAGES |
| 9402 ← 9001 | 创建板 DTS `an7581-xr1710g-ubi.dts`（include 主线已有的两个 dtsi） |
| 9403 ← 9002 | uboot-airoha 的 XR1710G defconfig/env/uboot 侧 DTS |

### 6.2 命名与初始配置（9501/9601/9602/9603，4 个）——本项目自有，无上游对应

| 补丁 | 作用 |
|---|---|
| 9501 | 网口命名对齐 YYH：eth1=WAN / eth2=LAN / lan2 / lan3（升级后 network 配置接口名不变） |
| 9601 | 镜像初始网络配置：br-lan=eth2 lan2 lan3 / LAN=192.168.2.1 / wan device=eth1（创建型） |
| 9602 | LED dev 名纠正（9501 改名后 netdev 绑定失效致灯灭；创建型） |
| 9603 | 预装 Argon 主题/配置包 + 完整中文语言包（创建 packages-xr1710g feed + i18n + uci-defaults 默认中文） |

### 6.3 triage 小补丁（9701-9712，12 个）——板级体验与驱动修复

| 补丁 | 作用 |
|---|---|
| 9701 | SPI-NAND 降 33MHz（sysupgrade 可靠性） |
| 9702 | 彩色登录 banner |
| 9703 | dropbear 静默每连接日志 |
| 9704 | 显式关闭板载音频（无音频硬件） |
| 9705 | 静默 PHY LED 探测误报（-ENODEV 精准版） |
| 9706 | airoha_eth 无 carrier 时 rx_errors/rx_dropped 虚增修复 |
| 9707 | hw-offload LED interval 不可写时脚本跳过 |
| 9708 | iwinfo 按 radio 报告频率列表 |
| 9709 | 隐藏 MLO mesh 接口（前端过滤，本板无 mesh 时零影响） |
| 9710 | ledtrig-netdev hw-control 预置 link 时 EINVAL 修复 |
| 9711 | RTL826x PHY LED class 支持（carry openwrt PR #24034） |
| 9712 | mt76 per-STA debugfs 的 NOSTDINC 映射（排障时与 MAC80211_DEBUGFS 一并开） |

### 6.4 包源码复制型 · 一组（9713-9719，7 个）

| 补丁 | 落点 | 作用 |
|---|---|---|
| 9713-9715 | wireless-regdb/patches/ | US 6GHz 去 NO-IR + UNII-1/6G 29dBm + UNII-3/4 160MHz 30dBm（6GHz 可用性前提） |
| 9716 | mac80211/patches/subsys/ | 导出 link_sta 能力上限 helper（mt76 9993 编译依赖） |
| 9717 | firewall4/patches/ | flowtable offload 解析 bonding 下带设备 |
| 9718 | rpcd/patches/ | exec 观察 EOF 后再失效管道 fd（修复请求挂到超时） |
| 9719 | iwinfo/patches/ | txpowerlist split wiphy dump 修复 |

### 6.5 fanboy 根补丁（9720-9725，6 个）——SoC/offload/稳定性

| 补丁 | 作用 |
|---|---|
| 9720 | AN7581 cpufreq + PM domain 驱动修复（PR 22029 carry） |
| 9721 | AN7581 bridge hw offload 使能（9743/9744 的前置） |
| 9722 | nft_flow_offload L2 bridge offload 三合一 |
| 9723 | an7581 ramoops/pstore 崩溃日志保留（PR 22473 carry） |
| 9724 | cmonroe 稳定性补丁集 |
| 9725 | smartrg 992-20/992-21 适配 |

### 6.6 mac80211 修复系（9726-9734，9 个）——CSA/CAC/AQL/FT，MLO 相关

主线 subsys 目录无等价修复（已核实）。397 CSA punct bitmap / 399 CAC call trace / 400 non-TX BSS checking / 405 CSA finalize non-tx BSS / 406 CSA IE 信道更新 / 407 direct CSA / 409 AQL BMC MLD / 410 RTS 误置位防护 / 412 AP 侧 FT key 上传延迟。

### 6.7 Phase 2b：airoha PPE/NPU/flowsense/PCS/hwrng（9735-9761，27 个）

- **9735-9742**：9017 应用包树（luci-app-airoha-flowsense / -npu / mlo / w1700k-fancontrol 四个 LuCI 应用）+ 9018-9023/9032 的 rpcd/sysfs/DT/conntrack 功能件（NPU offload 的用户面）
- **9743/9744**：bridge offload 依赖表 + flow offload 初始 conntrack
- **9745-9757**：PPE flow 统计/SRAM/bind rate、NPU dirty lazy clean、PCS USXGMII 稳定化/速率自适应/JCPLL 重校准、pinctrl force GPIO、RTK SerDes bundle、RX 恢复 IRQ/thermal、992-20 上下文、MIB 统计无损
- **9758/9759**：hwrng/TRNG SCU 时钟门顺序 + DTS
- **9760**：9061 元补丁——生成 `target/linux/airoha/patches-6.18/9999-30..35` 六个 NPU 恢复补丁（mailbox 恢复/看门狗生命周期/同步竞争/offload provider 设备链接寿命/RX IRQ 应答/mailbox doorbell 顺序）
- **9761**：wifi-scripts 天线备忘（9014 适配版：天线未变则跳过 `iw set antenna`）

### 6.8 Phase 2a：mt76 NPU offload 栈（9801-9832，32 个，复制型 → package/kernel/mt76/patches/）

按 aggregate ORDER 顺序编号（9801-9832），**顺序链 31/31 验证干净**（9832 为 fanboy/07 载荷适配版）。分组：

- **驱动修复**：0001 token/NPU debugfs 计数、0003 WTBL→MCU 统计、0005 TXFREE 截断静默、0009 仅上报终局 tx 失败、0022 EAPOL tx 空 sta 防护、0101 eeprom 尺寸校验
- **功率**：0006 txpower 变更刷新、0007 固件 txpower 限制控制（**适配版**：剥除上游已吸收的 mcu.h enum/struct 段）、0008 eeprom power unlock
- **NPU RX/卸载**：0010 NPU RX skb->dev、0011 RX 描述符所有权、0012 del sta、0013 tx agg 定时器、0015 固件 sta 计数器、0145 scan dwell、0147 NPU init 重试、0153 teardown 排序（**适配版**：init.c 两 hunk 重锚）、0154 DMA 内存绑定消费者、0156 RX 队列 teardown、0158 refill 后发布 RX buffer、0159 TX ring headroom、0160 重启前 shutdown、0161 napi 注册跟踪、0162 unregister 前停 NPU
- **EHT/速率控制**：9990 向固件速率控制通告 EHT、9991 320MHz BF fallback、9993 传递 operating mode
- **其他**：0016 radar-detecting chanctx、0017 bypass hwrro sub64 BA、0018 sta 重连后 DL OFDMA、0021 仅 disallow global wcid、**0023 PCIe AER 错误处理**（与 naoki-010 互证）、9832 HW RRO 会话在 BA teardown 时释放（**适配版**：按主线 MLO 重构重写 RX_STOP hunk）

---

## 7. 工具链

| 脚本 | 用途 | 关键行为 |
|---|---|---|
| `apply-patches.sh` | 核心应用器 | `--tree`（必填，git 仓库）/ `--tier func\|v1-safe` / `--dry-run` / `--allow-drift`。校验树 HEAD==pin；按行序应用；失败即停并给回滚指引；复制型条目拷文件 |
| `build-mine.sh` | 构建入口 | 树复位 → apply → feeds → defconfig+seed+符号审计 → 6.18.55 门禁 → make。`--apply-only`/`--dry-run` |
| `audit-local.sh` | 仓库自检 | [A] 清单语法 [B] 补丁存在 [C] 收录完整 [D] local/files 为空 [E] 端口命名一致 [F] 无个人配置 [G] git 历史干净 [H] seed 无尾随注释 |
| `check-upstream.sh` | 基座跟踪 | 默认只读本地态；`--fetch` 对比 pin..origin/main + focus 路径提交 |
| `review-upstreams.py` | 多来源巡检 | 8 个登记来源只读巡检，判定词汇 advance/no-update/baseline-orphaned 等 |

**验证套件**（改完任何东西后跑，今天的终审即这 8 项）：

```bash
export LC_ALL=C LANG=C
for f in scripts/*.sh; do bash -n "$f"; done          # ① 语法
python3 -m py_compile scripts/*.py tests/*.py          # ②
scripts/audit-local.sh                                  # ③ 自检
scripts/apply-patches.sh --tree <树> --tier func --dry-run    # ④ 52 应用型
scripts/apply-patches.sh --tree <树> --tier v1-safe --dry-run # ⑤ 7 个
# ⑥ mt76 顺序链（需 mt76 源码 checkout 467ae2e3，用 patch -p1 -F3 --batch 按 9801-9832 序）
# ⑦ 2b 顺序链（pin 树上先应用 25 个应用型，再按 9735-9760 序 git apply）
# ⑧ manifest↔文件一致性（ls patches/ 与清单列去注释后 diff）
```

---

## 8. 配置体系

### 8.1 seed（`local/seed.local.diff`）

追加进 `.config` 的符号选择。**铁律（F164）**：活动 `CONFIG_*` 行只允许「符号=取值」，说明写上一行注释——尾随注释会被 kconfig 截断 ⇒ 静默丢符号（audit [H] 检查）。内容：目标选中（airoha/an7581/gemtek_xr1710g-ubi）+ 基础系统 + kmod + LuCI/工具 + 运维套件（bash/coreutils/phytool/mdio-tools/ip-full/openssh-sftp-server/upnp）+ Argon 主题 + Phase 2 符号（bridge-hw-offload / NPU / flowsense / mlo / fancontrol）。默认注释项：`MAC80211_DEBUGFS`（排障时与 9712 一并开）、airoha-recovery（未移植）、openclash/docker（决策暂缓）。

### 8.2 feeds（`config/feeds.custom.conf`）

`src-link xr1710g ../packages-xr1710g/package`——包目录由 9603 在树里创建（luci-app-argon-config + luci-theme-argon）。9017 系另建 `package/luci-app-airoha-*` 等直接在树里。

### 8.3 版本锁定（`config/source-lock.env`）

`OPENWRT_REF` / `LINUX_VERSION`。**改动 = 显式决策**：须全量重新验证补丁集（今天的 8 项套件），并在 commit message 说明理由。

---

## 9. 配置归属铁律（防“固件绑定特定机器”）

| 类 | 内容 | 去处 |
|---|---|---|
| A | 上游能力 | 进仓库（随 pin 免费获得或补丁携带） |
| B | 环境适配（LAN IP、接口名、LED 名） | 进仓库，一律走 patch 改 `files/etc/config/*` |
| C | SSID/密码/自定义 MAC/防火墙策略 | **绝不进固件**——用 backup.tgz 恢复 |

- `local/files/` 必须保持为空（audit [D]）——历史教训：曾用整文件覆盖并夹带个人配置。
- WAN MAC 不钉死（读出厂值，见第 1 节）。

---

## 10. 当前状态与遗留事项（2026-10-21）

### 已完成

- ✅ 架构转向 + pin 63f702f1c（kernel 6.18.55 / mt76 467ae2e3）
- ✅ triage 19 + review 补漏 17（0156/0161 流程疏漏 + fanboy 6 + mac80211 9）
- ✅ Phase 2a mt76 31/31、Phase 2b/2c 26/26（顺序链全干净）
- ✅ 9014 适配版；func 100/100；audit/dry-run/链测全过
- ✅ aggregate 与 .stage 已移除（9010 源存仓库外 `../9010-wifi-scripts-txpower-ucode.patch.pending-rebase`）

### 遗留（按优先级）

1. **CI 构建验证未跑**（用户选择跳过）——**刷机前必须至少一次完整构建**。这是 manifest 头上的红字警告。func 的 48 个复制型补丁只在树侧验过"可拷贝"，其**内核源码级应用性**（尤其 9760 生成的 9999-30..35）只有构建能证伪。
2. **9010 挂起**（wifi-scripts per-radio txpower，YYH pr-23990）：上游把 `setup()` 的 `active_ifnames` 数组重构为 `wdev_data` 字典，须**结构级重推导**（owe push / `setup_radio_txpower` 入参），非重锚可解。源文件在仓库外（见上）。
3. **naoki 系列待并入**：010（PCIe 调参）/011（RTL826x SerDes，与 9752 同域）并入板 DTS（9402 系）；012（IPTV GRO）/014（build-in 配置）随批。
4. **fork 模型评估结论**：暂不迁整树 fork（~1GB，向主线靠拢哲学有张力）。触发条件：下次 re-pin 的 rebase 痛感 > fork 合并成本。中间路线：可随时搭"本地提交级工作树"（pin + 补丁全 apply + commit，不 push）。

### 仓库外文件（本项目的一部分，不随仓库发布）

| 文件 | 内容 |
|---|---|
| `../xr1710g-mainline-pivot.md` | 架构转向决策记录（含复现命令） |
| `../9010-wifi-scripts-txpower-ucode.patch.pending-rebase` | 挂起补丁的 rebase 源 |
| `../xr1710g-*.md`（8 份） | 转向前设计/决策文档 |

---

## 11. 接手 AI 操作守则（血泪教训，务必遵守）

### 11.1 环境坑（macOS/zsh 环境，本项目已反复栽过）

1. **`timeout` 不存在**——别用；用 `command -v` 守卫。
2. **BSD grep 不支持 `\s`/`\b`/BRE 的 `\|` 交替**——用 `[[:space:]]`、`grep -E`；写检测器先拿"必然命中的样本"验证它能红。
3. **bash 3.2 无 `mapfile`**——用 `while IFS= read -r`。
4. **`$VAR` 后紧跟非 ASCII 必须 `${VAR}` 界定**——否则 UTF-8 首字节并入变量名，`set -u` 下报 unbound。
5. **管道吞退出码**——`cmd | head/tail/grep` 的 `$?` 是最后一个管道命令的。验证必须重定向到文件再取 `$?`（本项目当天栽过 4 次）。
6. **`git -C <dir> apply <相对路径>`** 会相对错误的目录解析——用绝对路径。
7. **`.gitignore` 忽略树的 `files/`**——清残留要 `git clean -fdx`。

### 11.2 补丁操作纪律

1. **手写/改 hunk 后必须同步修正 `@@` 计数**（旧行数=上下文+删除，新行数=上下文+新增）——计数错会 malformed/ignored 连锁（当天栽过 3 次）。
2. **空上下文行是单空格** `" "`，不是纯空行。
3. **改完用 `git apply --reject` 看搜索文本逐字节对比**，别凭记忆。
4. **顺序链测试**：单独 `--check` 通过不代表能用（锚点可能来自前序补丁——mt76 0156/0161 的假失败教训）。
5. **包补丁用 `patch -p1 -F3 --batch`**（构建同款），不要用 git apply 判定包补丁生死。
6. **移植时逐段判 superseded**：主线已吸收部分内容（0007 的 mcu.h enum/struct、rro_id 字段）——先查主线再 rebase。
7. **并行会话风险**：本项目存在用户并行操作（曾出现两套并行移植）——动手前 `git log`/`git status` 确认最新状态，尊重对方成果。

### 11.3 变更纪律

- 改 manifest/补丁/seed 后跑第 7 节验证套件；提交信息写清"改了什么+为什么+验证结果"。
- 推进 pin 是显式决策：全量复验 + commit 说明。
- 刷机前必须构建验证（当前最大风险项）。

---

## 12. 一页纸速查

```
项目    = OpenWrt 主线(pin 63f702f1c/kernel 6.18.55) + 100 个本地补丁
构建    = scripts/build-mine.sh <func|v1-safe> --tree <openwrt树>
验证    = audit-local.sh + apply-patches.sh --dry-run（两档）
清单    = local/manifest.rules（func 100 / v1-safe 7）
seed    = local/seed.local.diff（F164 铁律：无尾随注释）
网口    = eth1=WAN / eth2+lan2+lan3=LAN(br-lan) / LAN 192.168.2.1
最大风险 = 未经构建验证；刷机前必须 CI 或本地完整构建
挂起项  = 9010（结构级 rebase）；naoki-010/011/012/014 待并入
```
