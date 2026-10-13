#!/bin/sh
# Test harness for tailscale-next-update: serves tests/fixtures/pkgs over a
# local HTTP server and runs each case from tests/test_update.sh in a
# sandbox (TS_* path overrides). No root, no network access required.
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SRC="$ROOT/luci-app-tailscale-next/root/usr/libexec/tailscale-next-update"
FIXSRC="$ROOT/tests/fixtures"
TESTDIR="$ROOT/tests/tmp"
FIXTURES="$TESTDIR/fixtures"
PORT=""
SERVER_PID=""

[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

# ---- assertions (used by sourced test cases) ------------------------------
assert_contains() { # <haystack> <needle>
	case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}
assert_not_contains() { # <haystack> <needle>
	case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac
}

# ---- per-case sandbox ------------------------------------------------------
setup_case() { # <name>
	CASE_DIR="$TESTDIR/$1"
	BINDIR="$CASE_DIR/bin"
	CASE_ARCH="amd64"
	export TS_BINDIR="$BINDIR"
	export TS_CONFDIR="$CASE_DIR/conf"
	export TS_INITD="$CASE_DIR/init.d/tailscale"
	export TS_WORKDIR="$CASE_DIR/work"
	export TS_LOG="$CASE_DIR/update.log"
	export TS_RC="$CASE_DIR/update.rc"
	export TS_UI_STATUS="$CASE_DIR/update.status"
	export TS_LOCKDIR="$CASE_DIR/lock"
	export TS_GH_DL_BASE="http://127.0.0.1:$PORT"
	export TS_VANILLA_DL_BASE="http://127.0.0.1:$PORT"
	# vanilla mode off unless a case opts in (df on the test host always
	# looks roomy - ~95TB threshold)
	export TS_VANILLA_MIN_KB=99999999999
	unset TS_GH_MIRRORS
	export TS_NO_COLOR=1
	unset TS_NO_SERVICE
	INITD_LOG="$CASE_DIR/initd.log"
	rm -rf "$CASE_DIR"
	mkdir -p "$BINDIR" "$TS_CONFDIR" "$CASE_DIR/init.d" "$TS_WORKDIR"
	cp "$FIXSRC/bin/tailscale" "$FIXSRC/bin/tailscaled" "$BINDIR/"
	cat > "$TS_INITD" <<EOF
#!/bin/sh
echo "\$1" >> "$INITD_LOG"
exit 0
EOF
	chmod 755 "$TS_INITD"
}

run_update() { # [source] [args...]  (default: official fixture for back-compat)
	_src="official"
	case "${1:-}" in official|github) _src="$1"; shift ;; esac
	_base=""
	[ "$_src" = official ] && _base="--base-url http://127.0.0.1:$PORT/stable"
	# shellcheck disable=SC2086
	"$SRC" --source "$_src" $_base --arch "$CASE_ARCH" "$@" \
		> "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"
}
stdout() { cat "$CASE_DIR/stdout"; }
stderr() { cat "$CASE_DIR/stderr"; }

installed_version() { "$1/tailscale" version | head -n1; }

backup_count() { ls -1d "$TS_CONFDIR"/.update-backup/*/ 2>/dev/null | wc -l; }

# ---- fixture tarball generation -------------------------------------------
gen_pkg() { # <version>: build tailscale_<ver>_amd64.tgz + .sha256
	_v="$1"
	_d="$TESTDIR/tarball-$_v"
	rm -rf "$_d"
	mkdir -p "$_d/tailscale_${_v}_amd64"
	cat > "$_d/tailscale_${_v}_amd64/tailscale" <<EOF
#!/bin/sh
case "\$1" in
	version) echo "$_v" ;;
	status)  echo '# fake'; echo '100.64.0.1 fake-node linux -' ;;
	*) exit 0 ;;
esac
EOF
	printf '#!/bin/sh\nexit 0\n' > "$_d/tailscale_${_v}_amd64/tailscaled"
	chmod 755 "$_d/tailscale_${_v}_amd64/tailscale" "$_d/tailscale_${_v}_amd64/tailscaled"
	( cd "$_d" && tar czf "$FIXTURES/stable/tailscale_${_v}_amd64.tgz" "tailscale_${_v}_amd64" ) \
		|| fail "tarball build failed for $_v"
	( cd "$FIXTURES/stable" && sha256sum "tailscale_${_v}_amd64.tgz" > "tailscale_${_v}_amd64.tgz.sha256" ) \
		|| fail "sha256 build failed for $_v"
}

# ---- github-source fixture (combined UPX-style binary) ----------------------
# Layout mirrors the real source: <root>/CH3NGYZ/<repo>/releases/latest/download/
# (TS_GH_DL_BASE = the root); a copy under /mirror is the mirror base for
# fallback tests.
GH_SUFFIX="/CH3NGYZ/small-tailscale-openwrt/releases/latest/download"
GH_DIR="$FIXTURES$GH_SUFFIX"
GH_MIRROR_DIR="$FIXTURES/mirror$GH_SUFFIX"

gen_gh_pkg() { # builds version.txt + combined binary + SHA256SUMS.txt (primary + mirror copy)
	_d="$GH_DIR"
	mkdir -p "$_d"
	printf 'v9.9.9\n' > "$_d/version.txt"
	cat > "$_d/tailscaled-linux-amd64" <<'EOF'
#!/bin/sh
# combined-binary fixture: behaves by argv[0] basename
case "$(basename "$0")" in
	tailscaled) exit 0 ;;
esac
case "$1" in
	version) echo "9.9.9" ;;
	status)  echo '# fake'; echo '100.64.0.1 fake-node linux -' ;;
	*) exit 0 ;;
esac
EOF
	chmod 755 "$_d/tailscaled-linux-amd64"
	( cd "$_d" && sha256sum tailscaled-linux-amd64 | sed 's|tailscaled-linux-amd64|  tailscaled-linux-amd64|' > SHA256SUMS.txt ) \
		|| fail "SHA256SUMS build failed"
	printf 'not the real binary\n' > "$_d/tailscaled-linux-amd64.bad"
	mkdir -p "$GH_MIRROR_DIR"
	cp "$_d/version.txt" "$_d/tailscaled-linux-amd64" "$_d/SHA256SUMS.txt" "$_d/tailscaled-linux-amd64.bad" "$GH_MIRROR_DIR/"
	# uncompressed variant served from the vanilla repo base (the updater
	# switches base in vanilla mode; clean name = plain binary).
	VANILLA_DIR="$FIXTURES/ywjno/openwrt-tailscale-next/releases/latest/download"
	mkdir -p "$VANILLA_DIR"
	cp "$_d/tailscaled-linux-amd64" "$VANILLA_DIR/tailscaled-linux-amd64"
	printf 'v9.9.9\n' > "$VANILLA_DIR/version-vanilla.txt"
	( cd "$VANILLA_DIR" && sha256sum tailscaled-linux-amd64 | sed 's|tailscaled-linux-amd64|  tailscaled-linux-amd64|' > SHA256SUMS-vanilla.txt ) \
		|| fail "vanilla SHA256SUMS build failed"
}

# ---- fixture HTTP server ---------------------------------------------------
start_server() {
	PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')"
	python3 -m http.server "$PORT" --directory "$FIXTURES" >/dev/null 2>&1 &
	SERVER_PID=$!
	_i=0
	while ! curl -fsS -o /dev/null "http://127.0.0.1:$PORT/stable/?mode=json" 2>/dev/null; do
		_i=$((_i + 1))
		[ "$_i" -gt 50 ] && fail "fixture server did not start on port $PORT"
		sleep 0.1
	done
}

stop_server() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	SERVER_PID=""
}

# ---- main ------------------------------------------------------------------
rm -rf "$TESTDIR"
mkdir -p "$FIXTURES/stable"
cp "$FIXSRC/pkgs/stable/index.html" "$FIXTURES/stable/index.html"
gen_pkg 9.9.9
gen_gh_pkg
printf 'this is not a tarball and must fail sha256\n' > "$FIXTURES/stable/tailscale_9.9.9_amd64.bad.tgz"

trap 'stop_server' EXIT INT TERM
start_server

. "$ROOT/tests/test_update.sh"

_failed=0
for _c in $TEST_CASES; do
	echo "=== $_c ==="
	if "t_$_c"; then
		echo "PASS: $_c"
	else
		echo "FAIL: $_c"
		_failed=1
		break
	fi
done

stop_server
[ "$_failed" -eq 0 ] || exit 1
echo "ALL TESTS PASSED"
