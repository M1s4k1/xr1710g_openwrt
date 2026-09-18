# 自检（audit-local.sh）

> 本文件由仓库 README.md 抽取并集中到 `doc/`（README 现已精简为项目说明）。
> 维护请以本文件为准；如需回看原始结构见 `doc/README.md` 索引。

## 5. 自检

```bash
scripts/audit-local.sh
```

检查：rules 语法与理由齐全 / 规则目标在上游 MANIFEST 或 local/patches 中可解析 /
本地补丁都被引用 **[D]** `local/files/` 为空（配置改动一律走 patch） /
**[E]** 9501↔9601↔9602 端口命名与网段一致 / **[F]** 无个人配置残留（MAC/口令/SSID 扫描）。

> `[F]` 的扫描做过反向验证：把旧的含 `<REDACTED MAC>`、`<REDACTED KEY>`、
> `<REDACTED SSID>` 的文件放回 `local/files/`，审计确实报红 —— 不是假通过。

---
