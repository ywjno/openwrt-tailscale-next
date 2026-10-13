#!/bin/sh
# Sign APK v3 packages built by the SDK (the 25.12 buildroot cannot sign
# packages itself) and verify the result against the published public key.
# Runs inside an alpine (apk-tools 3) container, no network.
# Usage: sh scripts/sign-apk.sh PRIVATE_KEY PUBLIC_KEY PACKAGE.apk [...]
set -eu

[ "$#" -ge 3 ] || { echo "Usage: $0 PRIVATE_KEY PUBLIC_KEY PACKAGE.apk [...]" >&2; exit 1; }
private_key=$1
public_key=$2
shift 2
[ -s "$private_key" ] && [ -s "$public_key" ] || { echo "signing key is missing" >&2; exit 1; }

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/keys"
cp "$public_key" "$work/keys/pub.pem"

for package in "$@"; do
	[ -s "$package" ] || { echo "APK file is missing: $package" >&2; exit 1; }
	case "$package" in *.apk) ;; *) echo "Expected an .apk file: $package" >&2; exit 1 ;; esac
	# sign a copy so a failed attempt leaves the input untouched
	cp "$package" "$work/package.apk"
	apk adbsign --allow-untrusted --reset-signatures --sign-key "$private_key" "$work/package.apk"
	# verify with ONLY the published public key: aborts the release when the
	# private key does not match it
	apk --keys-dir "$work/keys" --repositories-file /dev/null --no-network verify "$work/package.apk"
	cat "$work/package.apk" > "$package"
	echo "signed+verified: $package"
done
