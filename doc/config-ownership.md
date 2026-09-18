# 配置归属：哪些属于固件，哪些属于你

> 本文件由仓库 README.md 抽取并集中到 `doc/`（README 现已精简为项目说明）。
> 维护请以本文件为准；如需回看原始结构见 `doc/README.md` 索引。

## 6. 配置归属：哪些属于固件，哪些属于你

| 类 | 含义 | 处理 |
|----|------|------|
| A | 上游固件自带的能力 | 不管，跟随上游 |
| B | 环境适配（改名后必须的连带修正、网段） | **进仓库，走 patch**（9501 / 9601 / 9602） |
| C | 纯个人配置（SSID / 密码 / 自定义 MAC / 防火墙策略） | **不进仓库** —— 用 `backup.tgz` 恢复 |

固件**不携带**任何 C 类内容：无线是上游默认（`K2P` / `123456789`，三频三 SSID + 802.11r），
WAN MAC 不钉（由 DTS `&gdm2` 绑 `nvmem-cells = <&wan_mac 0>` 从 `factory:0x5000` 读出厂值，
与 YYH 行为一致）。刷机后 `sysupgrade` 默认**保留 `/etc/config`**，你的个人配置自然在；
若用 `-n` 清配，则从备份恢复即可。

### 为什么用 patch 而不是 uci-defaults

`files/etc/config/*` 是**打进镜像的初始配置**，首启 `board.d/02_network` 会重新生成 `network` ——
uci-defaults 与之的先后**顺序不确定**，做增量是脆弱的。patch 直接改源文件，产物确定、无时序依赖。

> 例外：确实依赖运行时探测的修正（如 LED `sysfs` 前缀 `mt7530_dsa-0:*` vs `mt7530-0:*`），
> 仍应由 uci-defaults 做 —— 上游的 `98-xr1710g-led-sysfs-prefix` 就是这么做的，
> 我们的 9602 只改 `dev`、**不碰 `sysfs`**，两者各管一段。

### 上游自带 5 个 uci-defaults（勿重复实现）

`98-xr1710g-led-sysfs-prefix`、`98-xr1710g-brlan-mac-unique`、`98-xr1710g-ft-over-ds`、
`98-xr1710g-luci-apply-window`、`99-xr1710g-flow-offload`。细节见仓库外的设计文档 `xr1710g-config-compat-layer.md`（位于上层工作目录，不随本仓库发布）。

---
