# XR1710G / W1700K 社区固件「CPU 超频 +200MHz」与「5GHz/6GHz 高功率」实现调研报告

> 调研执行：2026-08-17（下文 commit/分支状态以当天 GitHub 为准）
> 调研方法：GitHub HTML 页面 + raw 文件 + `.patch` diff URL + 稀疏 git 克隆（blob:none）逐文件核实；恩山帖用 archiver/printable 版本；OpenWrt 论坛用 Discourse JSON API 逐楼取文。
> 结论先行：
> - **CPU 超频 = 把 OpenWrt DTS 的 operating-points 全表整体 +200MHz（500–1200MHz → 700–1400MHz），并同步改 Airoha CPU PM domain 驱动的 PLL 频率公式 + 默认 governor 改 performance。** 唯一权威实现是 [OpenWRT-fanboy/OpenW1700k](https://github.com/OpenWRT-fanboy/OpenW1700k) 分支 `ubi2-oc`（构建配置 `user/minimal-oc-ubi` 的 REPO_BRANCH）。naoki66 / YYH2913 / hurrian 仓库均**无** OC 补丁。
> - **社区实测上限 = 1.4GHz（+200MHz）**；1.35GHz 已有不稳案例，1.5GHz 无一成功（AN7581 静态电压 546–650mV 不可调是根因）。“1300→1500MHz”不成立。
> - **5GHz/6GHz 高功率 = wireless-regdb 补丁**：UNII-1 23→29dBm（YYH2913 三个分支）；UNII-3 扩到 5895MHz @30dBm、6GHz LPI 12→30dBm（fanboy/stangri）。社区没有任何固件把 UNII-1 设成 30dBm——30dBm 出现在 UNII-3/6GHz。

---

## ① CPU 超频实现（文件路径 + 改动内容）

### A. 唯一 OC 实现：OpenWRT-fanboy/OpenW1700k（分支 ubi2-oc / minimal-OC-ubi）

提交：**`80096373b5a5199dfa7a506961032b363f02b50f` "switch to performance governor and overclock +200mhz"**
（作者 fanboy，2026-02-14；`ubi2-oc` 分支 HEAD = `ed7cbc80bc`；w1700k-ubi-build 的 `minimal-oc-ubi-2026.04.24-r34147-80096373b5` release 即此分支产物，release 注记第一行就是这条 commit）
diff 原文：https://github.com/OpenWRT-fanboy/OpenW1700k/commit/80096373b5a5199dfa7a506961032b363f02b50f.patch

**三个文件、共 3 处改动**（33 insertions / 33 deletions）：

1. **`target/linux/airoha/dts/an7581.dtsi`** — `cpu_opp_table` 15 档频率整体 +200MHz（每档的 `required-opps = <&smcc_oppN>` 保持不变）：

   | 档位 | stock（openwrt master） | ubi2-oc（OC） |
   |---|---|---|
   | 低端 | 500 / 550 / 600 / 650 MHz | **700 / 750 / 800 / 850 MHz** |
   | 中段 | 700 / 750 / 800 / 850 / 900 / 950 / 1000 / 1050 MHz | 900 / 950 / 1000 / 1050 / 1100 / 1150 / 1200 / 1250 MHz |
   | 高端 | 1100 / 1150 / **1200 MHz** | 1300 / 1350 / **1400 MHz** |

   即 `cpu_opp_table` 现为 `opp-700000000 { opp-hz = <700000000>; required-opps = <&smcc_opp0>; }` … `opp-1400000000 { opp-hz = <1400000000>; required-opps = <&smcc_opp14>; }`（15 档）。
   对照 stock：openwrt master `target/linux/airoha/dts/an7581.dtsi` 的 `cpu_opp_table` = 500/550/…/1200MHz（15 档，`opp-level` 0–14）。naoki66、YYH2913、hurrian `xr1710g-plus` 分支均为该 stock 表。

2. **`target/linux/airoha/patches-6.18/940-pmdomain-airoha-Add-Airoha-CPU-PM-Domain-support.patch`** — PM domain 驱动里 CPU PLL 频率公式：
   ```c
   -	unsigned int freq_mhz = 500 + state * 50;
   +	unsigned int freq_mhz = 700 + state * 50;
   ```
   （该驱动按 PM domain state 0–14 直接写 CPU PLL 的 pcw/posdiv 寄存器；DTS 的 OPP 表与这条公式**必须同步**，否则频率表与实际 PLL 频率错位。这就是论坛里说的“同步了 PM 域”。）

3. **`target/linux/airoha/an7581/config-6.18`** — 默认 governor 从 ondemand 改 performance：
   ```kconfig
   -CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND=y
   +# CONFIG_CPU_FREQ_DEFAULT_GOV_ONDEMAND is not set
   +CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE=y
   ```

**前置依赖**：该 OC 提交坐在 `ce1444854b "airoha: fix cpufreq and PM domain drivers for AN7581"`（即 [openwrt/openwrt#22029](https://github.com/openwrt/openwrt/pull/22029)，rchen14b 的 cpufreq/PM domain 修复）之上，OC 才谈得上稳定——自用固件合 OC 时必须先含这条修复（上游 master 已合 `CONFIG_AIROHA_CPU_PM_DOMAIN` 相关修复，见 [CONTEXT.md](CONTEXT.md) §2.2）。

**佐证（独立实现、同手法）**：恩山 c01（XG-040G-MD / AN7581DT）"我自己修改了源码的每一档对应的频率，并同步了PM域，重新编译源码"→ 1.4GHz 跑通（2026-02-21）。

### B. 用户态 cpufreq 调节（非持久）— luci-app-airoha-npu

[rchen14b/luci-app-airoha-npu](https://github.com/rchen14b/luci-app-airoha-npu)：
- `root/usr/libexec/rpcd/luci.airoha_npu`：读 `/sys/devices/system/cpu/cpufreq/policy0/{scaling_cur_freq,scaling_governor,scaling_max_freq,scaling_available_frequencies}`；另**直接读 CPU PM domain PLL 寄存器**（`chg_raw`/`pcw_int`/`pll_posdiv`，`pll_freq = pcw_int*50/(1<<posdiv)`）显示实频、可检测是否处于 OC 状态；`set_governor` 写 scaling_governor。
- `htdocs/luci-static/resources/view/airoha_npu/status.js`：CPU 频率条 + Max Frequency 下拉（改 scaling_max_freq）。
- 论坛（帖 1919，tesf23）：支持 max freq 限制调整与"manual frequency overwrite for overclock **but it won't persist after reboot**"——即用户态改频上限只在本次运行有效，重启回落到 OPP 表。

### C. 无 OC 的仓库（已逐一核实）

- **naoki66/ImmortalWrt-for-Gemtek-XR1710G**（master，kernel 6.18）：`target/linux/airoha/dts/an7581.dtsi` = stock 500–1200MHz；patches-6.18 里只有 `0401-pmdomain-airoha-fallback-to-PLL-registers-when-BL31-GET_FREQ-fails.patch`（**稳定性修复**：BL31 GET_FREQ 失败时回退直接读 PLL 寄存器，`freq_mhz = 500 + state * 50` 仍是 stock）——不含 OC。
- **YYH2913/openwrt** `xr1710g` / `xr1710g-6.18` / `xr1710g-6.18-integration`：an7581.dtsi 全部 stock 500–1200MHz，无 OC 补丁。
- **hurrian/openwrt-w1700k** `xr1710g-plus`：stock 500–1200MHz。

### D. 实测稳定性结论（社区实测，见 §③ 来源）

- 1.4GHz：多台稳定（glassdoor 2×HW1.1；c01 烤机 4 小时 77°C 稳定；"经过2天的测试非常的稳定，甚至可以说是完美"；"默认自动频率是很保守的，所以一下子 performance 1.4 感觉就很明显"）。
- 1.35GHz：一台"两分钟后重置"（不稳）。
- 1.5GHz：无一成功（"Mine is running at 650 and couldn't take 1.5"；"voltage … will open another door to hit something over than 1.6GHz"——没人做到）。
- 性能：coremark 16xx→19xx（约 +20%）；iperf3 回环 463→515 Mbit/s（OC + 关 debug 选项，fanboy 自测）。**注意：该 iperf3 回环数字是本机 CPU 基线，不能作为转发面吞吐判据（IP28）**。

---

## ② 5GHz/6GHz 高功率（regdb 补丁文件与功率值）

> 机制说明：无线功率上限 = min(regdb 上限, 硬件 EEPROM 校准上限, hostapd txpower)。regdb 补丁只抬"监管上限"；**实际发射值还取决于 MT7996 的 eeprom 校准**（W1700K/XR1710G FCC 授权本身支持 ~30dBm 级功率，见下）。

### A. YYH2913/openwrt（三个 xr1710g 分支都有，文件同路径同内容）——UNII-1 高功率就在这

`package/firmware/wireless-regdb/patches/`（文件随 40-wireless-regdb 包按序应用）：

| 文件 | 内容 | 效果 |
|---|---|---|
| `500-world-regd-5GHz.patch` | country 00（World）UNII-1 去 `NO-IR`（20dBm 不变） | World 域 36–48 可开 AP |
| `510-us-regd-6GHz.patch` | US 6GHz `(5925 - 7125 @ 320), (12), NO-OUTDOOR, NO-IR` → 去 `NO-IR` | US 6GHz 可开 AP（mt7996 才能起 6G） |
| **`520-w1700k-us-power-limits.patch`** | US **UNII-1 `(5150 - 5250 @ 80), (23), AUTO-BW` → `(29), AUTO-BW`**；US **6GHz `(5925 - 7125 @ 320), (12), NO-OUTDOOR` → `(29), NO-OUTDOOR`** | **UNII-1 23→29dBm（匹配 W1700K AP 授权）；6GHz LPI 12→29dBm**（patch 注释明确：不编更高 AFC/Standard Power 值，旧 dbparse 无法安全表达） |
| `530-us-6ghz-lab-indoor-sp-override.patch` | US 6GHz 29→**36dBm**（NO-OUTDOOR 保留） | 仅限室内标准功率**实验室测试**（注释自述"不是真 AFC 实现"） |

`520` 的注释要点：2.4G 已是 30dBm（≈授权 29.5dBm conducted 取整）；UNII-1 取 29dBm 是因为旧 db.txt 解析器只能表达整 dBm，29 是授权值的最接近整取整。

### B. OpenWRT-fanboy/OpenW1700k（ubi2-oc / minimal-OC-ubi 等全部分支）——UNII-3 + 6GHz 30dBm

`package/firmware/wireless-regdb/patches/555-w1700k-fix.patch`（提交 `265f0937ac1091879c8475a722aeb9457d0b6465` "Patch wireless regdb to enable UNII-4 and 6Ghz in United States"，2025-12-15；注明源自 [stangri/w1700k-wireless-regdb](https://github.com/stangri/w1700k-wireless-regdb) 的 `patches/555-w1700k-fix.patch`）改 `db.txt` 的 `country US`：

```diff
-	(5730 - 5850 @ 80), (30), AUTO-BW
+	(5730 - 5895 @ 160), (30), AUTO-BW          # UNII-3 延伸到 5895（并入 UNII-4 前段）30dBm
-	(5850 - 5895 @ 40), (27), NO-OUTDOOR, AUTO-BW, NO-IR   # 删除（被上行覆盖）
-	(5925 - 7125 @ 320), (12), NO-OUTDOOR, NO-IR
+	(5925 - 7125 @ 320), (30), NO-OUTDOOR       # 6GHz LPI 12→30dBm 且去 NO-IR
```

**注意：fanboy 的补丁不动 UNII-1**（US UNII-1 保持 stock 23dBm）。

### C. "UNII-1 30dBm" 的准确说法

- 社区固件 regdb 里 UNII-1 的**实际设定值 = 29dBm**（YYH2913），**没有 30dBm 的 UNII-1 补丁**。
- "30dBm" 数字的来源是 W1700K **FCC 授权**：stock db.txt 的注释即写 `# 5.15 ~ 5.25 GHz: 30 dBm for master mode, 23 dBm for clients`——硬件授权支持 AP 30dBm，regdb 出于保守取 23（stock）/29（YYH2913）。若我们自用固件要"UNII-1 30dBm"，需在 YYH 520 基础上再 +1dBm，但这会超出整 dBm 近似且无社区先例。

---

## ③ 对「默认启用 OC」的风险建议

### 社区实测风险证据

1. **存在无法承受内置 OC 的个体（硅差异）**：OpenWrt 论坛 W1700K 主帖（[Quantum Fiber W1700k support #222776](https://forum.openwrt.org/t/quantum-fiber-w1700k-support/222776)）：
   - 帖 3038/3042/3044（dziugas1959）：较新 fanboy 全家桶（全部内置 OC）**启动即 kernel panic**；换同一人的无 OC 测试包（W1700k_Test_6.18）**可正常启动**；自己用 NPU 插件手动 OC：**+300MHz 秒崩；1.4GHz 秒崩；1.3GHz 可跑；1.35GHz 两分钟后重置**。"The embedded OC is badly implemented, and only works on HW 1.0, not 1.1"（他猜测，未证实）。
   - 帖 3045（glassdoor）反例：两台 HW1.1 全都能 1.4GHz 稳定。"It is overclocking that is causing your kernel panics"。
   - 帖 3048（glassdoor）：当时所有 fanboy build 都带 OC，导致该用户全部无法启动；移除 OC 的 build 可启动。
   - 帖 2930（Phytochrome）：较新的 `bridger r33884` build 修复了旧 minimal-oc build 的 kernel panic——**早期 OC + 未修 cpufreq/pmdomain 是恐慌主因，后期修复后缓解**。
2. **电压无余量**（帖 1940，tesf23——OC 上限的技术根因）："an7581 is running at a **static voltage**, one of my AP at 546mv and one at 650mv… no way to adjust it… At 1.4GHz, my device basically running at same temperature and same power level, as voltage does not change"。→ OC 到 1.4GHz **不增加功耗/温度**（同电压），这正是它能"白嫖"的原因；但也意味着**没有电压调节 → 1.4GHz 就是硅片极限附近**（帖 1945："Mine is running at 650 and couldn't take 1.5"）。
3. **温度实测**（恩山，[XG-040G-MD 超频 1.4GHz 帖 #8464535](https://www.right.com.cn/forum/thread-8464535-1-1.html)）：默认散热下高压烤机 4+ 小时 **77°C**，原帖主"没改过散热"；评论区调侃"不改散热默认都 60 多度"——OC 后温度主要由环境/散热决定而非频率（静态电压）。

### 建议（针对"自用固件默认启用 OC"）

1. **不建议把 +200MHz/performance 作为"默认唯一状态"**：存在个体在启动阶段（PM domain/PLL 初始化时序敏感）就 panic 的实锤案例，且早期内核修复前更普遍。自用固件若只有一台机器，可先按 fanboy 方案全量 OC 实测；若要多台/分发，按 2 或 3 处理。
2. **推荐"可选 OC"形态（与社区一致）**：
   - **补丁来源**：直接搬 `80096373b5` 的 3 文件改动（an7581.dtsi OPP 表 / 940-pmdomain 公式 / config-6.18 governor），但**默认保留 stock OPP + ondemand**，不船 performance；
   - 用户态 OC：装 `luci-app-airoha-npu`（支持 max freq 限制 + 手动频率覆写），或启动脚本写 `scaling_max_freq`/`scaling_governor`（重启不持久正好是安全特性：砖了重启即回退）；
   - 若提供 OC 固件变体，参照 fanboy 的双 release 做法（`minimal-ubi` = stock，`minimal-oc-ubi` = OC），并**显式标注 1.4GHz**，防刷错。
3. **绝缘档位设计**：OC 档位建议 1.3GHz（+100MHz，失败案例中稳定）为默认，1.4GHz（+200MHz）为可选激进档；**不要做 1.35GHz 这种中间档**（已有"两分钟后重置"案例）与 1.5GHz+（无先例、无电压手段）。
4. **前置依赖**：OC 必须叠在 cpufreq/PM domain 修复之上（#22029 / fanboy `ce1444854b`）；未包含该修复时代码 panic 高发。我们的 6.18 基线（[调研报告](XR1710G-openwrt-调研报告.md) §2.2）已含 `CONFIG_AIROHA_CPU_PM_DOMAIN`，需再确认 940-pmdomain 补丁版本。
5. **配套**：保留风扇控制（w1700k 风扇插件/温控，XR1710G 风扇型号差异见 CONTEXT.md）与温度监控；OC 不影响功耗但发热仍需散热兜底（77°C 实测）。
6. **功率侧提醒**：regdb 抬到 29/30dBm 是**监管上限**，实际发射还受 MT7996 eeprom 校准封顶；若自用固件要"UNII-1 30dBm"，先在本机 `iw phy` 查看 `mW` 上限确认硬件是否允许，再决定是否把 520 补丁的 29 推到 30。

---

## 来源 URL 与核实日期

核实日期：**2026-08-17**（全部链接当日抓取核实）

**代码（GitHub，均已逐文件/逐 diff 核实）**
- [OpenWRT-fanboy/OpenW1700k 分支列表](https://github.com/OpenWRT-fanboy/OpenW1700k/branches/all)；OC 提交 diff：[80096373b5.patch](https://github.com/OpenWRT-fanboy/OpenW1700k/commit/80096373b5a5199dfa7a506961032b363f02b50f.patch)；regdb 提交 diff：[265f0937ac.patch](https://github.com/OpenWRT-fanboy/OpenW1700k/commit/265f0937ac1091879c8475a722aeb9457d0b6465.patch)
- [OpenWRT-fanboy/w1700k-ubi-build releases](https://github.com/OpenWRT-fanboy/w1700k-ubi-build/releases)（tag `minimal-oc-ubi-2026.04.24-r34147-80096373b5`；profile 配置 `user/minimal-oc-ubi/settings.ini` → REPO_URL=OpenW1700k, REPO_BRANCH=minimal-OC-ubi）
- [YYH2913/openwrt](https://github.com/YYH2913/openwrt) 分支 `xr1710g` / `xr1710g-6.18` / `xr1710g-6.18-integration`，`package/firmware/wireless-regdb/patches/{500,510,520,530}-*.patch`
- [naoki66/ImmortalWrt-for-Gemtek-XR1710G](https://github.com/naoki66/ImmortalWrt-for-Gemtek-XR1710G)（无 OC，仅 BL31 fallback 稳定性补丁）
- [stangri/w1700k-wireless-regdb](https://github.com/stangri/w1700k-wireless-regdb)（555/500 补丁原始出处）
- 上游 stock 对照：openwrt master `target/linux/airoha/dts/an7581.dtsi`（OPP 500–1200MHz）；[openwrt/openwrt#22029 cpufreq & PM domain fix](https://github.com/openwrt/openwrt/pull/22029)；[rchen14b/luci-app-airoha-npu](https://github.com/rchen14b/luci-app-airoha-npu)

**社区实测（OpenWrt 论坛 / 恩山）**
- [Quantum Fiber W1700k support（OpenWrt Forum #222776）](https://forum.openwrt.org/t/quantum-fiber-w1700k-support/222776)：帖 1919/1920（NPU 插件 OC 接口、iperf3 提升）、1940/1945（静态电压 546/650mV、1.5GHz 失败）、2930（bridger 修复 panic）、3038/3042–3048（内置 OC 导致 panic / 无 OC 可启动 / 1.3G 稳 1.35G 不稳 1.4G 崩）
- [XG-040G-MD AN7581DT超频1.4Ghz首次成功（恩山 #8464535）](https://www.right.com.cn/forum/thread-8464535-1-1.html)：方法（改频率表+同步 PM 域）、coremark +20%、77°C 烤机 4h
- [【首发】XG-040G-MD全网唯一超频到1.4Ghz固件（恩山 #8464638）](https://www.right.com.cn/forum/forum.php?mod=viewthread&tid=8464638)："经过2天的测试非常的稳定"，保留自动变频模式
- [brightspeed XR1710G 或者 w1700K 类似物（包含教程）（恩山 #8465834）](https://www.right.com.cn/forum/archiver/tid-8465834.html?page=1)
- [Brightspeed XR1710G same device as the W1700K（OpenWrt Forum #247242）](https://forum.openwrt.org/t/brightspeed-xr1710g-same-device-as-the-w1700k/247242)
---

## 2026-09-08 决策更新（F89，取代上文"绝缘档位设计"与 oc-1.3/1.4 分档）

- **取消 oc-1.3 / oc-1.4 双变体构建与 oc-limit 静态限频**；唯一 CPU 档 = **OPP 650–1350MHz**（`scripts/prepare-oc.sh oc`，PLL base 650：`freq_mhz = 650 + state * 50`，15 档网格同时覆盖退档目标 1200/1300/1350）。
- 1350 的已知个例风险（"两分钟后重置"、启动 panic 体质差异）由运行时 **`files/etc/init.d/oc-auto`** 兜底：开机按 `/etc/oc-state/level` 设置上限（默认 1350，performance，可 sysfs 调低）；5 分钟稳性确认窗口（覆盖 2 分钟不稳案例），窗口内崩溃/重启 → 下电自动退档 **1350→1300→1200**（overlay 持久化，1200 = 原 stock 上限，最终兜底）。
- 构建矩阵仅剩 stock/experimental（同一 CPU 配置，包集合不同）；`apply-patches --oc` 的 #OC 资产（regdb 555 等）随档取消，无线功率回落默认 regdb 521 路径。
