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
check start_full "daemon cmd"    out "procd set command $TESTDIR/start_full/tailscaled.bin --statedir=/etc/tailscale"
check start_full "daemon respawn" out "procd set respawn"
check start_full "pre-start cleanup" cleanup.log '^--cleanup '
check start_full "up instance" out "procd set command /etc/init.d/tailscale-next up"
check_absent start_full "no inline up command" out "up --reset"
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

# mk_cli_stub <BackendState> <case>: fake tailscale CLI; records each
# invocation to <case>/cli-stub.log, path on stdout
mk_cli_stub() {
	_p="$TESTDIR/cli-stub-$1-$2.sh"
	cat > "$_p" <<EOF
#!/bin/sh
echo "\$*" >> "$TESTDIR/$2/cli-stub.log"
[ "\$1" = "status" ] && echo '{"BackendState":"$1"}'
exit 0
EOF
	chmod 755 "$_p"
	printf '%s\n' "$_p"
}

# --- exit node flags reach the up command ------------------------------------
EN_FIXTURE='enabled=1
acceptRoutes=0
advertiseExitNode=1
exitNode=ts-exit-1
exitNodeAllowLan=1
authkey=tskey-fake'
EXTRA_ENV="TAILSCALE=$(mk_cli_stub Running exit_node)"
run_case exit_node "$EN_FIXTURE" up || { echo "FAIL: exit_node crashed" >&2; exit 1; }
check exit_node "name exit node kept out of up" cli-stub.log '^up --reset --authkey tskey-fake --advertise-exit-node --accept-dns=false$'
check exit_node "name applied after Running" cli-stub.log '^set --exit-node ts-exit-1 --exit-node-allow-lan-access$'
EXTRA_ENV=

# --- exit node given as an IP literal goes into the up command directly ------
EN2_FIXTURE='exitNode=100.64.0.1
exitNodeAllowLan=1
authkey=tskey-fake'
EXTRA_ENV="TAILSCALE=$(mk_cli_stub Running exit_node_ip)"
run_case exit_node_ip "$EN2_FIXTURE" up || { echo "FAIL: exit_node_ip crashed" >&2; exit 1; }
check exit_node_ip "ip exit node inline in up" cli-stub.log '^up --reset --authkey tskey-fake --exit-node 100.64.0.1 --exit-node-allow-lan-access --accept-dns=false$'
check_absent exit_node_ip "no deferred set" cli-stub.log '^set '
EXTRA_ENV=

# --- up action: waits for the daemon, then applies every preference ---------
EXTRA_ENV="TAILSCALE=$(mk_cli_stub Running up_full)"
run_case up_full "$FULL_FIXTURE" up || { echo "FAIL: up_full crashed" >&2; exit 1; }
check up_full "all prefs reach the CLI" cli-stub.log 'up --reset --login-server https://hs.example.com --authkey tskey-fake --hostname testnode --accept-routes --advertise-routes 192.168.9.0/24 --accept-dns=false'
EXTRA_ENV=

# --- unauthenticated + no authkey: up instance skipped; trigger forces it ---

UA_FIXTURE='enabled=1
acceptRoutes=0
advertiseRoutes=
hostname=
loginServer=
authkey=
autoUpdate=0'

# the skip now happens inside the up action (start_service always declares
# the instance): an unauthenticated node must not run `tailscale up`
EXTRA_ENV="TAILSCALE=$(mk_cli_stub NeedsLogin up_skipped)"
run_case up_skipped "$UA_FIXTURE" up || { echo "FAIL: up_skipped crashed" >&2; exit 1; }
check up_skipped "backend state probed" cli-stub.log '^status --json$'
check_absent up_skipped "up not run while unauthenticated" cli-stub.log '^up '
EXTRA_ENV=

: > "$TESTDIR/login-trigger"
EXTRA_ENV="TAILSCALE=$(mk_cli_stub NeedsLogin up_trigger) LOGIN_TRIGGER=$TESTDIR/login-trigger"
run_case up_trigger "$UA_FIXTURE" up || { echo "FAIL: up_trigger crashed" >&2; exit 1; }
check up_trigger "trigger forces login flow" cli-stub.log '^up --reset'
[ ! -f "$TESTDIR/login-trigger" ] || { echo "FAIL: login trigger not consumed" >&2; FAILED=1; }
EXTRA_ENV=

# --- disabled: no instances, no cron ----------------------------------------
run_case start_disabled 'enabled=0
autoUpdate=1' start_service || { echo "FAIL: start_disabled crashed" >&2; exit 1; }
check_absent start_disabled "no procd" out "procd set command"
check start_disabled "cleanup on stop" cleanup.log '^--cleanup '
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
check bootstrap_install "daemon after bootstrap" out "procd set command $TESTDIR/bootstrap_install/tailscaled.bin --statedir=/etc/tailscale"

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
check stop_removes_cron "cleanup on stop" cleanup.log '^--cleanup '

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

# --- service lock -------------------------------------------------------------
# A: a lock whose holder died is taken over at once (no 3-minute wait)
rm -rf "$TESTDIR/lock.stale"; mkdir "$TESTDIR/lock.stale"
sleep 0 & _dead=$!; wait "$_dead"
echo "$_dead" > "$TESTDIR/lock.stale/pid"
EXTRA_ENV="SERVICE_LOCK=$TESTDIR/lock.stale LOCK_WAIT=0"
run_case lock_stale "$FULL_FIXTURE" start_service || { echo "FAIL: lock_stale crashed" >&2; exit 1; }
check lock_stale "daemon declared after takeover" out "procd set command $TESTDIR/lock_stale/tailscaled.bin"
[ ! -d "$TESTDIR/lock.stale" ] || { echo "FAIL: taken-over lock not released" >&2; FAILED=1; }
EXTRA_ENV=

# B: a live holder blocks start_service, which then declares nothing. rc.common
# would still commit the instance set, so the give-up must be side-effect free.
sleep 30 & _live=$!
rm -rf "$TESTDIR/lock.live"; mkdir "$TESTDIR/lock.live"; echo "$_live" > "$TESTDIR/lock.live/pid"
EXTRA_ENV="SERVICE_LOCK=$TESTDIR/lock.live LOCK_WAIT=0"
run_case lock_live_start "$FULL_FIXTURE" start_service || { echo "FAIL: lock_live_start crashed" >&2; exit 1; }
check_absent lock_live_start "no instance declared while locked out" out "procd set command"
check_absent lock_live_start "no cleanup while locked out" cleanup.log '--cleanup'

# C: the same for stop_service - and rc.common's unconditional procd_kill that
# follows it must be defused, or an overlapping restart kills the daemon.
run_case lock_live_stop "$FULL_FIXTURE" 'stop_service; type procd_kill >/dev/null 2>&1 && echo kill-defused >> $OUT' || { echo "FAIL: lock_live_stop crashed" >&2; exit 1; }
check lock_live_stop "procd_kill defused when giving up" out '^kill-defused$'
check_absent lock_live_stop "no cleanup while locked out" cleanup.log '--cleanup'
EXTRA_ENV=
[ -d "$TESTDIR/lock.live" ] || { echo "FAIL: lock of a live holder was removed" >&2; FAILED=1; }
kill "$_live" 2>/dev/null

if [ "$FAILED" -ne 0 ]; then
	echo "INIT TESTS FAILED" >&2
	exit 1
fi
echo "INIT TESTS PASSED"
