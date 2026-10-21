#!/bin/sh
# XR1710G DHCPv6 duplicate-client guard (default 档——只在冲突时生效，不改变默认行为)
#
# 背景：本仓 /etc/config/network 预置 `config interface 'wan6' { proto 'dhcpv6' }`；
#   用户按注释把 WAN 改成 PPPoE 后，PPP 的 ipv6=auto 会再建一个动态 DHCPv6 接口
#   （ppp6-up 的 AUTOIPV6 路径），两个 odhcp6c 跑在**同一 L3 设备**上：
#   odhcp6c 的 ubus 对象名固定为 `odhcp6c.<设备名>`（odhcp6c src/ubus.c: ubus_init(ifname)
#   → snprintf(ubus_name, 24, "odhcp6c.%s", interface)，ifname = cmdline 末参），
#   第二个进程 ubus_add_object 返回 EEXIST → 退出 → netifd 重启 → IPv6 间歇不可用。
#
# 策略（互斥，不重写用户配置）：
#   1) 冲突时**后到的** netifd 客户端不启动（proto_block_restart 停止重启循环）；
#      odhcp6c/dhcpv6.sh 与 PPP 的 ppp6-up 各查一次，谁先起谁占位。
#   2) **绝不杀**没有 INTERFACE= 的第三方 odhcp6c（手工/脚本起的）：无法归属即视为
#      非 netifd 管理，忽略它，不杀不采纳。
#   3) 配置视图读取全部放进**子 shell**（`xr_dhcpv6_has_explicit() (...)` 的圆括号）：
#      `config_load`/`config_get_*` 会改写 CONFIG_* 等变量，PPP hook 正靠这些变量
#      传 JSON 状态（netifd proto-shell 把 CONFIG_* 导出为环境），在父 shell 里 source
#      会污染 hook（FIXES F117）。
#
# 上游参考（目标树 f0d3e332 核对，见 patches/root/9056 头注释）：
#   - /lib/functions.sh 形态：package/base-files/files/lib/functions.sh
#     config_load:91 / config_get_bool:171 / config_foreach:186
#   - proto_notify_error / proto_block_restart：netifd 包自带 netifd-proto.sh
#     （pin 6088f7b3 scripts/netifd-proto.sh:387/401；树内消费者见
#     package/network/config/gre/files/gre.sh:63-64 等）
#   - ppp6-up 的 AUTOIPV6/PPP_IPPARAM：package/network/services/ppp/files/ppp.sh:154-155
#   - dhcpv6.sh 的 INTERFACE=$config：package/network/ipv6/odhcp6c/files/dhcpv6.sh:216

# 是否存在"另一个同设备的、启用的显式 dhcpv6 接口"。
# 参数：$1 = PPP 逻辑接口名（PPP_IPPARAM），$2 = PPP 的 L3 设备名（IFNAME）。
# 返回：0 = 存在（PPP 不应再建 auto IPv6），1 = 不存在（照常建）。
xr_dhcpv6_has_explicit() (
	. /lib/functions.sh
	local xr_parent="$1" xr_device="$2" xr_found=1
	[ -n "$xr_parent" ] && [ -n "$xr_device" ] || return 1
	config_load network || return 1
	xr_dhcpv6_match() {
		local section="$1" proto disabled auto device depth=0
		config_get proto "$section" proto
		[ "$proto" = dhcpv6 ] || return
		config_get_bool disabled "$section" disabled 0
		config_get_bool auto "$section" auto 1
		[ "$disabled" = 0 ] && [ "$auto" = 1 ] || return
		config_get device "$section" device
		[ -n "$device" ] || config_get device "$section" ifname
		while [ "$depth" -lt 16 ]; do
			case "$device" in
				"@$xr_parent"|"$xr_device") xr_found=0; return ;;
				@*) section="${device#@}"
					config_get device "$section" device
					[ -n "$device" ] || config_get device "$section" ifname ;;
				*) return ;;
			esac
			depth=$((depth + 1))
		done
	}
	config_foreach xr_dhcpv6_match interface
	return "$xr_found"
)

# Separate these small readers so regression tests can supply process fixtures
# without starting a DHCP client or touching a network interface.
xr_dhcpv6_pids() { pidof odhcp6c 2>/dev/null; }
xr_dhcpv6_device() { tr '\000' '\n' < "/proc/$1/cmdline" 2>/dev/null | tail -n 1; }
xr_dhcpv6_owner() { tr '\000' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n 's/^INTERFACE=//p'; }

# 是否已有**另一个 netifd 接口**的 odhcp6c 占着同一 L3 设备。
# 参数：$1 = 本接口 UCI 名（即 INTERFACE= 的值），$2 = 本接口的 L3 设备名。
# 返回：0 = 冲突（调用方应拒绝启动 / 打断自动建），1 = 无冲突。
xr_dhcpv6_conflict() {
	local config="$1" device="$2" pid owner
	[ -n "$config" ] && [ -n "$device" ] || return 1
	for pid in $(xr_dhcpv6_pids); do
		case "$pid" in ''|*[!0-9]*) continue ;; esac
		[ "$(xr_dhcpv6_device "$pid")" = "$device" ] || continue
		owner="$(xr_dhcpv6_owner "$pid")"
		# An exiting process, or a process outside netifd ownership, cannot
		# safely identify another logical interface. Never kill or adopt it.
		[ -n "$owner" ] && [ "$owner" != "$config" ] || continue
		# Recheck after reading environ to tolerate ordinary process exit.
		[ "$(xr_dhcpv6_device "$pid")" = "$device" ] || continue
		return 0
	done
	return 1
}
