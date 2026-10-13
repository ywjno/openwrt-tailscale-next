#!/bin/sh
# i18n drift check: the set of _('...') msgids in the JS view must equal the
# msgid sets in po/templates and every po/<lang>; msgids must stay English
# (no CJK) per LuCI convention.
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JS="$ROOT/luci-app-tailscale-next/htdocs/luci-static/resources/view/tailscale-next.js"
PODIR="$ROOT/luci-app-tailscale-next/po"
TMP="$ROOT/tests/tmp/i18n"
FAILED=0

[ -f "$JS" ] || { echo "FAIL: view missing" >&2; exit 1; }

rm -rf "$TMP"; mkdir -p "$TMP"

# msgids used by the view, one per line
grep -o "_('[^']*')" "$JS" | sed "s/^_(//; s/)$//; s/^'//; s/'\$//" | sort -u > "$TMP/js.msgids"

if grep -P '[\x{4e00}-\x{9fff}]' "$TMP/js.msgids" >/dev/null 2>&1; then
	echo "FAIL: msgids must be English (CJK found):" >&2
	grep -P '[\x{4e00}-\x{9fff}]' "$TMP/js.msgids" >&2
	FAILED=1
fi

check_po() { # <po file>
	_lang="$(basename "$(dirname "$1")")"
	sed -n 's/^msgid "\(.*\)"/\1/p' "$1" | grep -v '^$' | sort -u > "$TMP/po.$_lang.msgids"
	if ! diff -u "$TMP/js.msgids" "$TMP/po.$_lang.msgids" > "$TMP/diff.$_lang" 2>&1; then
		echo "FAIL: msgid mismatch between view and $1:" >&2
		cat "$TMP/diff.$_lang" >&2
		FAILED=1
	fi
}

[ -f "$PODIR/templates/tailscale-next.pot" ] || { echo "FAIL: template missing" >&2; FAILED=1; }

po_count=0
for d in "$PODIR"/*/; do
	_lang="$(basename "$d")"
	[ "$_lang" = "templates" ] && continue
	[ -f "$d/tailscale-next.po" ] || { echo "FAIL: $_lang po missing" >&2; FAILED=1; continue; }
	po_count=$((po_count + 1))
done
[ "$po_count" -gt 0 ] || { echo "FAIL: no translations under po/" >&2; FAILED=1; }

[ "$FAILED" -eq 0 ] || { echo "I18N TESTS FAILED" >&2; exit 1; }

check_po "$PODIR/templates/tailscale-next.pot"
for d in "$PODIR"/*/; do
	_lang="$(basename "$d")"
	[ "$_lang" = "templates" ] && continue
	check_po "$d/tailscale-next.po"
done

if [ "$FAILED" -ne 0 ]; then
	echo "I18N TESTS FAILED" >&2
	exit 1
fi
echo "I18N TESTS PASSED"
