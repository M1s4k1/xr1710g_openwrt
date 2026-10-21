# 自检（audit-local.sh）

> 本文件由仓库 README.md 抽取并集中到 `doc/`。维护请以本文件为准。

```
scripts/audit-local.sh        # 退出码 0 全过；1 有红
```

## 检查项（2026-10-21 架构转向后）

| 项 | 内容 |
|---|---|
| [A] | 收录清单语法：每行一个补丁文件名，必须带「理由」 |
| [B] | 清单补丁存在：清单中每个文件都在 `local/patches/` 下 |
| [C] | 收录完整：`local/patches/*.patch` 都被 func 或 v1-safe 清单收录 |
| [D] | 配置归属纪律：`local/files/` 必须为空（配置改动一律走 patch，不靠 files 覆盖）——历史教训：曾用 `local/files/etc/config/{network,wireless}` 整文件覆盖上游并夹带个人配置 |
| [E] | 端口命名/网段一致性：9501（改名）↔ 9601（同一套名字 + 钉死 192.168.2.1）↔ 9602（LED dev 名） |
| [F] | 固件不含个人配置：全仓扫描 SSID / 密码 / 自定义 MAC 等 C 类残留 |
| [G] | **git 历史**不含个人配置（push 到公开仓库前必查；特征串 base64 存储避免自带泄露） |
| [H] | seed 写法铁律（F164）：活动 `CONFIG_*` 行不得带尾随注释（kconfig 截断 ⇒ 静默丢符号） |

## 已知跨平台陷阱（写检测器时先拿"必然命中的样本"验证）

- macOS BSD grep 的 ERE **不支持 `\b` / `\s` / `\|` alternation**——用错会**静默零命中**⇒ 假绿。
  本项目用「非 hex 字符边界」`(^|[^0-9a-fA-F:])` 做 MAC 检测的词锚。
- bash 3.2 无 `mapfile`；`$VAR` 后紧跟非 ASCII 必须 `${VAR}` 界定（UTF-8 变量名坑）。
- `git apply ... | head` 会吞掉真实退出码（head 的）——测补丁应用别用管道。

## 构建期审计（build-mine.sh 内）

除本脚本外，`build-mine.sh` 在构建配置阶段还会校验：
目标设备符号进 `.config`、`seed.local.diff` 全部符号逐一进 `.config`（F15 教训：
kconfig 静默忽略未知符号）、内核版本 == `source-lock.env` 的 `LINUX_VERSION`。
