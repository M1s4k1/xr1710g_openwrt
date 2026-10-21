# 刷机指南（FLASHING）

> 主路径：**YYH2913 HTTP U-Boot**（决策 ADR-0002）。官方 chainloader + UBI installer 为文档化备用路径。
> 任何刷机都有变砖风险；本指南要求的校验一步都不能省。救砖底牌：**UART/TTL**（永远保留）。

## 背景（为什么必须换引导）

厂商签名 U-Boot（2014.04-rc1 AXON）+ BMT/BBT 坏块管理**不支持 UBI**，而 OpenWrt 需要 UBI 布局
（`vendor 6MiB → chainloader 槽 1MiB@0x600000 → ubi 0x1b700000 → reserved_bmt@1be00000 0x04200000`，卷 `ubootenv/ubootenv2/fit/factory`，`root=/dev/fit0`）。
必须先写 chainloader 槽才能跑 OpenWrt。

## 路径 A（主）：固化 HTTP U-Boot

### A1 材料（锁版 + 校验）
- 仓库：https://github.com/YYH2913/http-uboot （原 http-uboot-xr1710g）
- 锁版：**v2026.07 / commit 59060dde**（2026-07-12 验证）
- 文件：
  - `xr1710g-uboot-v2026.07-59060dde-flash-slot.bin`（908,778 B）→ 写入 chainloader 槽
  - `xr1710g-uboot-v2026.07-59060dde-chainloader.itb`（900,330 B）→ RAM 验证
- **升级锁版前**：在恢复页/上游 release 页核对 SHA256，并把新校验值记入 FIXES/README——不盲升级。

### A2 首次安装（三选一）
1. **ECNT 厂商 U-Boot（UART）**：`tftpboot 0x81800000 xr1710g-chainloader-slot.bin; bootm 0x81802100`（RAM 验证）
   → 确认后 `flash write 0x600000 0x100000 0x81800000` 等（参考 A4 命令族的 1MiB 槽写法）；
2. **Linux nandwrite**（旧 tclinux 布局）：先 `nanddump -l 0x100000 -f /tmp/tclinux-head-1m.bin /dev/mtd5` 备份，
   再 `flash_erase /dev/mtd5 0 8; nandwrite -p /dev/mtd5 /tmp/xr1710g-chainloader-slot.bin`
   ——**只写前 1MiB**；严禁用 sysupgrade 写 U-Boot；
3. 从 w1700k-ubi-installer 迁移：先 `printenv bootcmd` 核对兼容形式再写槽。

### A2.1 锁版纪律与坏版本清单（IP19）
- **坏版本**：2026-08-08 的 HTTP U-Boot 恢复页（社区流传 `g93da8f980ef0`）上传固件必 failed——恢复页逻辑缺陷，非单纯 NAND 擦除问题。**不要锁定/刷入该版本**。
- **候选锁版**：2026-08-11 修复版 `b7710e5cc851`（社区验证修复上传失败；锁版前仍需在 YYH2913/http-uboot release 页核对 SHA256 与发布时间）。
- 升级后必须把新 SHA256 与验证结果记入 FIXES/README；未核对前不盲升级。

### A2.2 OS 内救砖（kmod-mtd-rw 覆写 chainloader 槽）
> 仅当 HTTP U-Boot 恢复页不可用（如坏版本 `g93da8f980ef0` 已刷入）且仍能进 OpenWrt 时使用；有 UART 优先走路径 B。
1. 备份当前槽：`dd if=/dev/mtd1ro of=/tmp/chainloader-slot.bin` 备份 1MiB chainloader 槽（或 `mtd read`）；
2. 安装可写 MTD 模块：`opkg update && opkg install kmod-mtd-rw`；然后 `insmod mtd-rw i_want_a_brick=1`；
3. 覆写前再次核对新 flash-slot.bin 的 SHA256；
4. 写槽：`mtd -e chainloader write /tmp/xr1710g-uboot-<版本>-flash-slot.bin chainloader`（只写前 1MiB 槽，严禁整片擦写）；
5. 重启进恢复页验证；本步骤是救砖底牌，不是日常升级路径。

### A3 日常升级 / 恢复（免串口）
1. PC 接 **10GbE 口**、DHCP；开机待 10G 口 LED 开始闪时**按住 reset**；
2. 状态 LED 由常红变跑马灯后松开 → 打开 `http://192.168.255.1`；
3. `firmware` → 上传 `*-sysupgrade.itb`（写 `ubi:fit`）；`uboot` → 上传 `*-flash-slot.bin`（写 chainloader 槽）；
4. **布局选择器必须与镜像匹配**（UBI 2.0 / 1.5 / 1.0）：选错会 `not enough PEBs / Waiting for root device /dev/fit0`——重刷匹配布局即可恢复。

### A4 严禁事项
- 不要上传 `u-boot.bin` / `u-boot.img` / `xr1710g-ubi.img` 到恢复页；
- 不要整槽覆写（只动前 1MiB）；
- 布局选择器**只定擦除/重建边界、不转换镜像**——镜像本身由本仓库构建。

## 路径 B（备用）：官方 chainloader + UBI installer

材料：hurrian/w1700k-ubi-installer release（W1700K + XR1710G 各两份）：
`*-chainload-uboot.itb`（0x600000 槽）+ `*-initramfs-installer.itb`（TFTP 启动）。

厂商 U-Boot（UART，任意键打断）：
```
setenv serverip 192.168.1.10 ; setenv ipaddr 192.168.1.1
tftpboot 0x89000000 openwrt-airoha-an7581-gemtek_xr1710g-ubi-chainload-uboot.itb
setenv one "flash read 0x600000 0x100000 \$loadaddr"
setenv two "; bootm"
setenv bootcmd "$one$two"
saveenv
flash erase 0x600000 0x100000
flash write 0x600000 0x100000 0x89000000
reset
```
重启进 chainloader 菜单 → **4. Boot installer via TFTP**。installer 问 `Existing UBI layout detected. Proceed and overwrite?`——**答 yes 重建**（旧非 UBI 残留会卡 `Volume fit not found`）。

## 救砖
- 厂商 U-Boot 的 0x0–0x600000 区未动，任何时刻可 UART 重新 tftpboot+flash 回写 → 这就是永久救砖通道；
- 无 UART 只能依赖 HTTP U-Boot 恢复页；变砖仍可用 TTL 线恢复（恩山教程：https://www.kdocs.cn/l/chjtOZ5Lykgh）。