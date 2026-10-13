#!/bin/sh
# luci-app-tailscale-next — one line installer for OpenWrt
#   wget -qO- https://github.com/ywjno/openwrt-tailscale-next/releases/latest/download/install-tailscale-next.sh | sh
# Behind the GFW? put a GitHub proxy in front:
#   wget -qO- https://<proxy>/https://github.com/ywjno/openwrt-tailscale-next/releases/latest/download/install-tailscale-next.sh | PROXY=https://<proxy>/ sh

REPO=${REPO:-ywjno/openwrt-tailscale-next}
P=${PROXY:-}
TMP=/tmp/tsn-install.$$

say() { printf 'O %s\n' "$*"; }
die() { printf 'X %s\n' "$*"; rm -rf "$TMP"; exit 1; }
get()  {
	if command -v uclient-fetch >/dev/null 2>&1; then uclient-fetch -q -O "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1"
	elif command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"
	else return 1; fi
}

[ -f /etc/openwrt_release ] || die "not an OpenWrt system"

# opkg (OpenWrt 21.02-24.10) installs the .ipk, apk (25.12+) the .apk
if command -v opkg >/dev/null 2>&1; then
	FMT=ipk
elif command -v apk >/dev/null 2>&1; then
	FMT=apk
else
	die "neither opkg nor apk found"
fi

say "fetching latest release info..."
get "${P}https://api.github.com/repos/$REPO/releases/latest" "$TMP/rel.json" \
	|| die "download failed - check the network, or set PROXY and retry"

TAG=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$TMP/rel.json" | head -n1)
[ -n "$TAG" ] || die "could not read the latest release (rate limit or network?)"

# pick the main app package from the release assets; the luci-i18n-*
# companions, tailscale-next.pem and SHA256SUMS.txt are listed too and
# excluded by the name patterns
if [ "$FMT" = ipk ]; then
	PAT='^luci-app-tailscale-next_[^"]*_all\.ipk$'
else
	PAT='^luci-app-tailscale-next-[0-9][^"]*\.apk$'
fi
PKG=$(grep -o '"name": *"[^"]*"' "$TMP/rel.json" | sed 's/.*: "//;s/"$//' \
	| grep -E "$PAT" | head -n1)
[ -n "$PKG" ] || die "no .$FMT package found in release $TAG"

say "installing $PKG ($TAG)"
get "${P}https://github.com/$REPO/releases/download/$TAG/$PKG" "$TMP/$PKG" \
	|| die "download failed - check the network, or set PROXY and retry"

if [ "$FMT" = ipk ]; then
	opkg install "$TMP/$PKG" || die "opkg install failed"
else
	# unsigned CI build: --allow-untrusted until the device trusts
	# tailscale-next.pem (copy it to /etc/apk/keys/ to drop the flag)
	apk add --allow-untrusted "$TMP/$PKG" || die "apk install failed"
fi

rm -rf "$TMP" /tmp/luci-indexcache* /tmp/luci-modulecache/ 2>/dev/null

say "installed $PKG ($TAG)."
say "Next steps:"
say "  1. re-login to LuCI, open Services -> Tailscale Next"
say "  2. tick Enable and hit Save & Apply - the Tailscale binaries"
say "     bootstrap automatically on the first service start"
say "  3. tip: the release also ships tailscale-next.pem (apk signing key)"
say "     and per-language luci-i18n-tailscale-next-* packages"
