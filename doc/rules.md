# 收录清单语法（local/manifest.rules*）

> 2026-10-21 架构转向后重写。**旧语义（aggregate curation：停用 `-`/提档 `^`/追加 `+`）已废止**——
> aggregate 退役，OpenWrt 主线为基座，不存在可 curation 的上游 MANIFEST。

## 新语义

`local/manifest.rules`（func 档）与 `local/manifest.rules.v1-safe`（保守档）是
**本项目补丁收录清单**：每行一个属于该档位的本地补丁文件名。

## 格式

```
<补丁文件名>.patch    # 理由: <必须>
```

- 文件名指向 `local/patches/` 下的实体；
- 每行**必须带理由**（`audit-local.sh` [A] 项检查）；
- 应用顺序 = **文件名字典序**（OpenWrt 补丁机制惯例，"命名即排序"）：
  `9401 < 9402 < 9403 < 9501 < 9601 < 9602 < 9603 <（Phase 2 起）98xx`

## 当前依赖链

```
9402 建板 DTS ──► 9501 改 DTS/board.d 网口名 ──► 9601 初始网络配置（引用 9501 的名字）
                                      └────────► 9602 LED dev 名（同上）
9401 Device 条目（独立）      9403 uboot 支持（独立）      9603 主题/语言包（独立）
```

命名即排序是硬约束：新增补丁必须按依赖关系选号，`audit-local.sh` [E] 项会校验
9501↔9601↔9602 的命名一致性。

## 两档差异

- `v1-safe`：板级使能 + 命名 + 初始配置 + 主题（首刷保守档，主线默认 + 最小差异）；
- `func`：Phase 1 与 v1-safe 相同；Phase 2 起追加 NPU offload 栈（98xx 段）。

## 操作示例

- **加补丁**：文件放进 `local/patches/`，按依赖选号；两档清单按需收录并写理由。
- **改补丁**：直接编辑 patch 文件；若改动影响下游（如 9501 改名），同步检查 9601/9602。
- **弃用补丁**：从清单移除（文件可留 `local/patches/` 但需在文件名或头注释标注
  `RETIRED:`，否则 `audit-local.sh` [C] 会报"未被收录"）。
