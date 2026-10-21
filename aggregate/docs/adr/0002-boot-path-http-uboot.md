# ADR 0002 — 刷机路径：直接固化 YYH2913 HTTP U-Boot（chainloader 槽）

**Status**: accepted（2026-08-17 评审确定）
**Context**: 厂商签名 U-Boot（2014.04-rc1 AXON）+ BMT/BBT 不支持 UBI，OpenWrt 必须先写 chainloader 槽（SPI-NAND 0x600000，1MiB）才能建立 UBI 布局。官方方案（#22151 chainloader + hurrian UBI installer）需 UART/TFTP；YYH2913 定制 U-Boot 提供 192.168.255.1 网页恢复（10GbE 口+内置 DHCP+UBI 布局选择器），免串口。
**Decision**: 刷机路径以**直接固化 YYH2913 HTTP U-Boot**（写入 chainloader 槽）为主：首刷用其 `*-flash-slot.bin`（锁版 v2026.07/commit 59060dde，SHA256 校验），日常升级与救砖走 192.168.255.1 恢复页。官方 chainloader + UBI installer 流程仅作为文档化的备用路径（README/刷机指南给出命令），U-Boot 产物本身不入本仓库交付物、以官方 release 链接指引。
**Why**: 自用单机场景下，网页恢复路径的日常体验与救砖便利（无需串口、TTL 可救）显著优于 TFTP；恢复页的 UBI 布局选择器规避了布局错配导致的 `/dev/fit0` 等待问题。
**Considered Options**:
- 官方 chainloader 为主：全程上游维护、可逆，但每次刷机/救砖需 UART+TFTP，恢复体验差。降为备用路径。
- 双轨并行：维护两套流程成本高，自用无必要。否决。
**Consequences**: 厂商恢复通道（签名校验）退出，flash-slot.bin 写入后依赖第三方引导；必须把"锁版+校验+升级路径"写死进文档，避免随意换版引入差异。