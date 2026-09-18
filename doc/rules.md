# rules 语法与选择集

> 本文件由仓库 README.md 抽取并集中到 `doc/`（README 现已精简为项目说明）。
> 维护请以本文件为准；如需回看原始结构见 `doc/README.md` 索引。

## 4. rules 语法（`local/manifest.rules*`）

每行一条规则，**必须带 `# 理由: ...`**：

| 符 | 含义 | 效果 |
|----|------|------|
| `-` | 停用 | 给上游活动行加 `#DISABLED ` 前缀 |
| `^` | 提档 | 删除上游行使能行（默认/#EXP）的 `#EXP ` 前缀 → 变活动 |
| `+` | 追加 | 把本地补丁插入 MANIFEST（语义路径写 `patches/local/xxx.patch`，物理文件放 `local/patches/xxx.patch`） |

> **提档/停用后必须重生成 `patches/ORDER`**：`stage.sh` 已自动调用 `gen-order.py`，
> `apply-patches.sh` 会跑 `audit-order.sh` 校验 MANIFEST ↔ ORDER 一致，不一致直接失败。
> 直接手改 MANIFEST 而不重生成 ORDER 会导致构建中断。

活动行必须是**精确两字段**（`<path> <dest>`），**不能带行尾注释**。

---
