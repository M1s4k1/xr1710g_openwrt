# 本目录是自用固件的**内置包 feed**（src-link 供给，见 config/feeds.custom.conf）
# 政策：vendor 包必须锁定来源 commit 并在此登记；升级 = 显式 bump + 记 FIXES.md。

# ── luci-app-airoha-recovery ──
# LuCI 面板一键进入 U-Boot HTTP 恢复环境（配合 HTTP U-Boot 主路径，FLASHING.md）
# 来源：naoki66/ImmortalWrt-for-Gemtek-XR1710G，分支 master
#   锁定 commit：dd9ecfeefa268b764efebee0d76f3149b3c01f12（2026-08-12）
#   路径：package/luci-app-airoha-recovery/（fetched 2026-08-17，7 文件）
# 依赖：+luci-base +uboot-envtools（官方）
# 升级：对比上游新 commit 后整体替换本目录，并在 FIXES.md F12 记录。