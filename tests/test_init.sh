#!/bin/sh
# Tests for root/etc/init.d/tailscale-next (owns the daemon lifecycle:
# procd tailscaled instance, one-shot `tailscale up` instance, updater
# bootstrap, cron maintenance).
set -u

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INIT="$ROOT/luci-app-tailscale-next/root/etc/init.d/tailscale-next"
TESTDIR="$ROOT/tests/tmp/init-tests"
FAILED=0

[ -f "$INIT" ] || { echo "FAIL: init script missing" >&2; exit 1; }

run_case() { # <name> <fixture-content> <func>  (binary absent if <name>.no_binary pre-exists)
	_d="$TESTDIR/$1"
	rm -rf "$_d"; mkdir -p "$_d"
	printf '%s\n' "$2" > "$_d/fixture"
	: > "$_d/out"; : > "$_d/cleanup.log"; : > "$_d/updater.log"
	# tailscaled binary stub: records --cleanup invocations
	if [ ! -f "$_d.no_binary" ]; then
		cat > "$_d/tailscaled.bin" <<EOF
#!/bin/sh
echo "\$*" >> "$_d/cleanup.log"
exit 0
EOF
		chmod 755 "$_d/tailscaled.bin"
	fi
	# updater stub: installs the binary only when the control file exists
	cat > "$_d/updater.stub" <<EOF
#!/bin/sh
echo "updater \$*" >> "$_d/updater.log"
if [ -f "$_d/updater_should_install" ]; then
	printf '#!/bin/sh\nexit 0\n' > "$_d/tailscaled.bin"
	chmod 755 "$_d/tailscaled.bin"
fi
exit 0
EOF
	chmod 755 "$_d/updater.stub"
	cat > "$_d/cron.init" <<EOF
#!/bin/sh
echo "cron \$1" >> "$_d/cron.log"
exit 0
EOF
	chmod 755 "$_d/cron.init"
	FIXTURE="$_d/fixture" OUT="$_d/out" \
		TAILSCALE_BIN="$_d/tailscaled.bin" \
		UPDATER="$_d/updater.stub" \
		CRONTAB_FILE="$_d/crontabs.root" \
		CRON_INITD="$_d/cron.init" \
		SOCKET_WAIT=1 env ${EXTRA_ENV:-} \
		sh -c ". \"$ROOT/tests/stub_rc.common\"; . \"$INIT\"; $3"
	# NB: start_service legitimately returns 1 when disabled or bootstrap
	# fails; assertions below are the source of truth, not the exit status.
	return 0
}

check() { # <case> <desc> <file> <needle>
	if ! grep -q "$4" "$TESTDIR/$1/$3" 2>/dev/null; then
		echo "FAIL: $1: $2 (missing '$4' in $3)" >&2
		[ -f "$TESTDIR/$1/$3" ] && { echo "--- $3:" >&2; cat "$TESTDIR/$1/$3" >&2; }
		FAILED=1
	fi
}

check_absent() { # <case> <desc> <file> <needle>
	if grep -q "$4" "$TESTDIR/$1/$3" 2>/dev/null; then
		echo "FAIL: $1: $2 (unexpected '$4' in $3)" >&2
		FAILED=1
	fi
}

FULL_FIXTURE='enabled=1
acceptRoutes=1
advertiseRoutes=192.168.9.0/24
hostname=testnode
loginServer=https://hs.example.com
authkey=tskey-fake
autoUpdate=1'

rm -rf "$TESTDIR"

# --- full start: daemon instance + up instance + cron -----------------------
run_case start_full "$FULL_FIXTURE" start_service || { echo "FAIL: start_full crashed" >&2; exit 1; }
check start_full "daemon cmd"    out "procd set command $TESTDIR/start_full/tailscaled.bin"
check start_full "daemon respawn" out "procd set respawn"
check start_full "pre-start cleanup" cleanup.log '^--cleanup$'
check start_full "up base command" out "procd set command /usr/sbin/tailscale up --reset"
check start_full "login server"  out "procd append command --login-server https://hs.example.com"
check start_full "authkey"       out "procd append command --authkey tskey-fake"
check start_full "hostname"      out "procd append command --hostname testnode"
check start_full "accept routes" out "procd append command --accept-routes"
check start_full "advertise"     out "procd append command --advertise-routes 192.168.9.0/24"
check start_full "accept dns"    out "procd append command --accept-dns=false"
check_absent start_full "no bootstrap" updater.log "updater"
check start_full "cron cmd"      crontabs.root '/usr/libexec/tailscale-next-update --yes >>/tmp/tailscale-next-update.log 2>&1'
check start_full "cron tag"      crontabs.root '# tailscale-next-auto-update$'
if grep -q 'base-url' "$TESTDIR/start_full/crontabs.root" 2>/dev/null; then
	echo "FAIL: cron line still carries --base-url" >&2; FAILED=1
fi
check start_full "cron restart"  cron.log '^cron restart$'

# --- keepBackups value reaches the cron line ---------------------------------
KB_FIXTURE='enabled=1
acceptRoutes=0
advertiseRoutes=
hostname=
loginServer=
authkey=
autoUpdate=1
keepBackups=2'
run_case start_kb "$KB_FIXTURE" start_service || { echo "FAIL: start_kb crashed" >&2; exit 1; }
check start_kb "cron keep value" crontabs.root "TS_KEEP_BACKUPS=2 "

# --- exit node flags reach the up command ------------------------------------
EN_FIXTURE='enabled=1
acceptRoutes=0
advertiseExitNode=1
exitNode=ts-exit-1
exitNodeAllowLan=1
authkey=tskey-fake'
run_case exit_node "$EN_FIXTURE" start_service || { echo "FAIL: exit_node crashed" >&2; exit 1; }
check exit_node "advertise exit node" out "procd append command --advertise-exit-node"
check exit_node "exit node" out "procd append command --exit-node ts-exit-1"
check exit_node "allow lan" out "procd append command --exit-node-allow-lan-access"

# --- unauthenticated + no authkey: up instance skipped; trigger forces it ---
# mk_cli_stub <BackendState>: fake tailscale CLI (status probe), path on stdout
mk_cli_stub() {
	_p="$TESTDIR/cli-stub-$1.sh"
	cat > "$_p" <<EOF
#!/bin/sh
[ "\$1" = "status" ] && echo '{"BackendState":"$1"}'
exit 0
EOF
	chmod 755 "$_p"
	printf '%s\n' "$_p"
}

UA_FIXTURE='enabled=1
acceptRoutes=0
advertiseRoutes=
hostname=
loginServer=
authkey=
autoUpdate=0'

EXTRA_ENV="TAILSCALE=$(mk_cli_stub NeedsLogin)"
run_case up_skipped "$UA_FIXTURE" start_service || { echo "FAIL: up_skipped crashed" >&2; exit 1; }
check up_skipped "daemon still declared" out "procd set command $TESTDIR/up_skipped/tailscaled.bin"
check_absent up_skipped "up instance skipped" out "up --reset"
EXTRA_ENV=

: > "$TESTDIR/login-trigger"
EXTRA_ENV="TAILSCALE=$(mk_cli_stub NeedsLogin) LOGIN_TRIGGER=$TESTDIR/login-trigger"
run_case up_trigger "$UA_FIXTURE" start_service || { echo "FAIL: up_trigger crashed" >&2; exit 1; }
check up_trigger "trigger forces up instance" out "up --reset"
[ ! -f "$TESTDIR/login-trigger" ] || { echo "FAIL: login trigger not consumed" >&2; FAILED=1; }
EXTRA_ENV=

# --- disabled: no instances, no cron ----------------------------------------
run_case start_disabled 'enabled=0
autoUpdate=1' start_service || { echo "FAIL: start_disabled crashed" >&2; exit 1; }
check_absent start_disabled "no procd" out "procd set command"
check start_disabled "cleanup on stop" cleanup.log '^--cleanup$'
check_absent start_disabled "no cron entry" crontabs.root 'tailscale-next-auto-update'
check_absent start_disabled "no bootstrap" updater.log 'updater'

# --- bootstrap: binary missing, updater installs it --------------------------
touch "$TESTDIR/bootstrap_install.no_binary"
run_case bootstrap_install 'enabled=1' start_service || { echo "FAIL: bootstrap crashed" >&2; exit 1; }
touch "$TESTDIR/bootstrap_install/updater_should_install"
_d="$TESTDIR/bootstrap_install"
FIXTURE="$_d/fixture" OUT="$_d/out" \
	TAILSCALE_BIN="$_d/tailscaled.bin" \
	UPDATER="$_d/updater.stub" \
	CRONTAB_FILE="$_d/crontabs.root" \
	CRON_INITD="$_d/cron.init" \
	SOCKET_WAIT=1 \
	sh -c ". \"$ROOT/tests/stub_rc.common\"; . \"$INIT\"; start_service"
check bootstrap_install "updater ran" updater.log 'updater --yes'
check bootstrap_install "daemon after bootstrap" out "procd set command $TESTDIR/bootstrap_install/tailscaled.bin"

# --- bootstrap failure: updater cannot install -> no instances ---------------
touch "$TESTDIR/bootstrap_fail.no_binary"
run_case bootstrap_fail 'enabled=1' start_service || { echo "FAIL: bootstrap_fail crashed" >&2; exit 1; }
check bootstrap_fail "updater ran" updater.log 'updater --yes'
check_absent bootstrap_fail "no daemon" out "procd set command"

# --- stop after full start removes the cron entry ----------------------------
run_case stop_removes_cron "$FULL_FIXTURE" start_service || { echo "FAIL: stop crashed" >&2; exit 1; }
_d="$TESTDIR/stop_removes_cron"
FIXTURE="$_d/fixture" OUT="$_d/out" \
	TAILSCALE_BIN="$_d/tailscaled.bin" \
	UPDATER="$_d/updater.stub" \
	CRONTAB_FILE="$_d/crontabs.root" \
	CRON_INITD="$_d/cron.init" \
	SOCKET_WAIT=1 \
	sh -c ". \"$ROOT/tests/stub_rc.common\"; . \"$INIT\"; stop_service"
check_absent stop_removes_cron "cron removed" crontabs.root 'tailscale-next-auto-update'
check stop_removes_cron "cleanup on stop" cleanup.log '^--cleanup$'

# --- stop vs restart trigger handling ----------------------------------------
# plain stop cancels a pending login; restart preserves it (regression:
# stop+start deleted the trigger before start_service could consume it)
run_case stop_trigger "$FULL_FIXTURE" start_service || { echo "FAIL: stop_trigger crashed" >&2; exit 1; }
_d="$TESTDIR/stop_trigger"
: > "$_d/login-trigger"
FIXTURE="$_d/fixture" OUT="$_d/out" \
	TAILSCALE_BIN="$_d/tailscaled.bin" \
	UPDATER="$_d/updater.stub" \
	CRONTAB_FILE="$_d/crontabs.root" \
	CRON_INITD="$_d/cron.init" \
	LOGIN_TRIGGER="$_d/login-trigger" \
	SOCKET_WAIT=1 \
	sh -c ". \"$ROOT/tests/stub_rc.common\"; . \"$INIT\"; stop_service"
[ ! -f "$_d/login-trigger" ] || { echo "FAIL: plain stop must cancel the login trigger" >&2; FAILED=1; }
: > "$_d/login-trigger"
FIXTURE="$_d/fixture" OUT="$_d/out" \
	TAILSCALE_BIN="$_d/tailscaled.bin" \
	UPDATER="$_d/updater.stub" \
	CRONTAB_FILE="$_d/crontabs.root" \
	CRON_INITD="$_d/cron.init" \
	LOGIN_TRIGGER="$_d/login-trigger" \
	TSN_KEEP_TRIGGER=1 \
	SOCKET_WAIT=1 \
	sh -c ". \"$ROOT/tests/stub_rc.common\"; . \"$INIT\"; stop_service"
[ -f "$_d/login-trigger" ] || { echo "FAIL: restart-preserved trigger was deleted" >&2; FAILED=1; }

if [ "$FAILED" -ne 0 ]; then
	echo "INIT TESTS FAILED" >&2
	exit 1
fi
echo "INIT TESTS PASSED"
