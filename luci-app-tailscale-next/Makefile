#
# luci-app-tailscale-next — LuCI support for Tailscale (with binary updater)
#
# Drop this directory into your OpenWrt SDK's package/ tree (or add this
# repo as a feed) and build with:
#     ./scripts/feeds update -a && ./scripts/feeds install -a
#     make package/luci-app-tailscale-next/compile V=s
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-tailscale-next
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=openwrt-tailscale-next

LUCI_TITLE:=LuCI support for Tailscale (with binary updater)
LUCI_DEPENDS:=+luci-base +kmod-tun
LUCI_PKGARCH:=all

define Package/luci-app-tailscale-next/conffiles
/etc/config/tailscale-next
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
