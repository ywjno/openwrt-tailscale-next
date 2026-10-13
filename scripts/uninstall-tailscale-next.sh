#!/bin/sh
# luci-app-tailscale-next — uninstaller for OpenWrt
#   wget -qO- https://github.com/ywjno/openwrt-tailscale-next/releases/latest/download/uninstall-tailscale-next.sh | sh

# log out first if this device is logged in: logout needs the daemon still
# running, so it happens before the service is stopped and the package removed
if [ -x /usr/sbin/tailscale ]; then
	State=$(/usr/sbin/tailscale status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p')
	if [ "$State" = "Running" ]; then
		echo "Tailscale is logged in - logging out first..."
		/usr/sbin/tailscale logout >/dev/null 2>&1
	fi
fi

if command -v opkg >/dev/null 2>&1 && opkg status luci-app-tailscale-next 2>/dev/null | grep -q '^Status: .* installed'; then
	/etc/init.d/tailscale-next stop 2>/dev/null
	opkg remove luci-app-tailscale-next
elif command -v apk >/dev/null 2>&1 && apk info -e luci-app-tailscale-next >/dev/null 2>&1; then
	/etc/init.d/tailscale-next stop 2>/dev/null
	apk del luci-app-tailscale-next
else
	echo "luci-app-tailscale-next is not installed - nothing to remove."
	exit 0
fi

# remove transient updater state; the cron line is removed by the service stop
rm -f /tmp/tailscale-next-update.log /tmp/tailscale-next-update.rc \
	/tmp/tailscale-next-update.status /tmp/tailscale-next-update.lock \
	/tmp/tailscale-next-service.lock
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/ 2>/dev/null

echo "Uninstalled. Kept on purpose (remove manually if desired):"
echo "  /etc/config/tailscale-next                 UCI settings"
echo "  /etc/tailscale/                            login state + update backups"
echo "  /usr/sbin/tailscale /usr/sbin/tailscaled   updater-installed binaries"
echo "  /etc/apk/keys/tailscale-next.pem           apk signing public key (if installed)"
echo "Note: the binaries and login state form a working standalone Tailscale;"
echo "removing them also removes your connectivity."
