# Test cases for tests/run_tests.sh — sourced, uses its helpers/env.
# Each t_<name> runs against a fresh per-case sandbox made by setup_case.

TEST_CASES="backup_skip_space gh_mirror_version gh_mirror_binary gh_mirror_all_fail gh_vanilla scratch_check_message gh_update gh_rollback gh_rollback_symlink gh_corrupt gh_no_checksum gh_no_version gh_riscv64_refused check_json check_json_not_installed dry_run full_update corrupt_sha rollback prune_backups internal_rollback guard_blocks guard_stale start_honors_base_url no_checksum_refused start_failure_rc lock_blocks_update lock_blocks_start lock_stale_stolen"

t_check_json() {
	setup_case check_json
	run_update --check --json || fail "exit code $?"
	_out="$(stdout)"
	assert_contains "$_out" '"installed":"1.80.3"' || fail "installed field: $_out"
	assert_contains "$_out" '"latest":"9.9.9"'   || fail "latest field: $_out"
	assert_contains "$_out" '"update_available":true' || fail "update_available field: $_out"
}

t_check_json_not_installed() {
	setup_case check_json_not_installed
	rm -f "$BINDIR/tailscale" "$BINDIR/tailscaled"
	run_update --check --json || fail "exit code $?"
	_out="$(stdout)"
	assert_contains "$_out" '"installed":""'        || fail "installed field: $_out"
	assert_contains "$_out" '"update_available":false' || fail "update_available field: $_out"
}

t_dry_run() {
	setup_case dry_run
	run_update --dry-run || fail "exit code $?"
	_out="$(stdout)"
	assert_contains "$_out" "DRY RUN"     || fail "missing DRY RUN marker: $_out"
	assert_contains "$_out" "1. download" || fail "missing step list: $_out"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified by dry-run"
}

t_full_update() {
	setup_case full_update
	run_update --yes || fail "exit code $?"
	[ "$(installed_version "$BINDIR")" = "9.9.9" ] || fail "version not updated: $(installed_version "$BINDIR")"
	[ "$(backup_count)" = "1" ] || fail "expected 1 backup, got $(backup_count)"
	assert_contains "$(cat "$TS_CONFDIR"/.update-backup/*/meta)" "version=1.80.3" \
		|| fail "backup meta missing old version"
	grep -q '^stop$' "$INITD_LOG"  || fail "init stub never stopped"
	grep -q '^start$' "$INITD_LOG" || fail "init stub never started"
	assert_contains "$(cat "$TS_CONFDIR/.update-state")" "version=9.9.9" \
		|| fail "state file missing new version"
}

t_corrupt_sha() {
	setup_case corrupt_sha
	_sd="$FIXTURES/stable"
	mv "$_sd/tailscale_9.9.9_amd64.tgz" "$_sd/tailscale_9.9.9_amd64.tgz.good"
	mv "$_sd/tailscale_9.9.9_amd64.bad.tgz" "$_sd/tailscale_9.9.9_amd64.tgz"
	run_update --yes && fail "corrupt tarball unexpectedly succeeded"
	mv "$_sd/tailscale_9.9.9_amd64.tgz" "$_sd/tailscale_9.9.9_amd64.bad.tgz"
	mv "$_sd/tailscale_9.9.9_amd64.tgz.good" "$_sd/tailscale_9.9.9_amd64.tgz"
	assert_contains "$(stderr)" "checksum" || fail "no checksum error: $(stderr)"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified despite checksum failure"
	if grep -q '^stop$' "$INITD_LOG" 2>/dev/null; then
		fail "service stopped despite checksum failure"
	fi
}

t_rollback() {
	setup_case rollback
	run_update --yes || fail "update failed"
	run_update --rollback || fail "rollback exit code $?"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "rollback did not restore 1.80.3"
}

t_prune_backups() {
	setup_case prune_backups
	run_update --yes || fail "first update failed"
	_i=0
	while [ "$_i" -lt 3 ]; do
		run_update --yes --force || fail "force update $((_i + 2)) failed"
		_i=$((_i + 1))
	done
	[ "$(backup_count)" = "3" ] || fail "expected 3 backups after prune, got $(backup_count)"
}

t_internal_rollback() {
	# Regression: post-install version verification failure must roll back
	# automatically. do_rollback used to see do_update's own fresh lock and
	# bail out with exit 0 (broken binaries kept, failure reported as success).
	setup_case internal_rollback
	# build a tarball named 9.9.9 whose binaries report 8.8.8
	_d="$TESTDIR/mismatch-tarball"
	rm -rf "$_d"; mkdir -p "$_d/tailscale_9.9.9_amd64"
	for _b in tailscale tailscaled; do
		cat > "$_d/tailscale_9.9.9_amd64/$_b" <<EOF
#!/bin/sh
case "\$1" in
	version) echo "8.8.8" ;;
	*) exit 0 ;;
esac
EOF
		chmod 755 "$_d/tailscale_9.9.9_amd64/$_b"
	done
	( cd "$_d" && tar czf "$_d/tailscale_9.9.9_amd64.tgz" tailscale_9.9.9_amd64 ) \
		|| fail "tarball build failed"
	( cd "$_d" && sha256sum tailscale_9.9.9_amd64.tgz > tailscale_9.9.9_amd64.tgz.sha256 ) \
		|| fail "sha256 build failed"
	# swap the mismatched tarball in for this case only
	_sd="$FIXTURES/stable"
	mv "$_sd/tailscale_9.9.9_amd64.tgz" "$_sd/tailscale_9.9.9_amd64.tgz.keep"
	mv "$_sd/tailscale_9.9.9_amd64.tgz.sha256" "$_sd/tailscale_9.9.9_amd64.tgz.sha256.keep"
	cp "$_d/tailscale_9.9.9_amd64.tgz" "$_sd/tailscale_9.9.9_amd64.tgz"
	cp "$_d/tailscale_9.9.9_amd64.tgz.sha256" "$_sd/tailscale_9.9.9_amd64.tgz.sha256"
	run_update --yes && fail "mismatched build unexpectedly reported success"
	mv -f "$_sd/tailscale_9.9.9_amd64.tgz.keep" "$_sd/tailscale_9.9.9_amd64.tgz"
	mv -f "$_sd/tailscale_9.9.9_amd64.tgz.sha256.keep" "$_sd/tailscale_9.9.9_amd64.tgz.sha256"
	assert_contains "$(stderr)" "previous version restored" \
		|| fail "no rollback message: $(stderr)"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] \
		|| fail "binaries not restored after verification failure: $(installed_version "$BINDIR")"
	grep -q '^stop$' "$INITD_LOG"  || fail "service never stopped"
	grep -q '^start$' "$INITD_LOG" || fail "service never restarted after rollback"
}

t_guard_blocks() {
	setup_case guard_blocks
	printf 'running\n' > "$TS_UI_STATUS"
	: > "$TS_LOG"   # fresh log => a run is live; no rc file
	run_update --check && fail "guard should have skipped with exit 3"
	assert_not_contains "$(stdout)" "latest stable" || fail "guard did not block: $(stdout)"
	[ "$(cat "$TS_UI_STATUS")" = "running" ] || fail "guard modified status file"
}

t_guard_stale() {
	setup_case guard_stale
	printf 'running\n' > "$TS_UI_STATUS"
	printf 'old log\n' > "$TS_LOG"
	touch -d '31 minutes ago' "$TS_LOG" 2>/dev/null || touch -t "$(date -d '31 minutes ago' +%Y%m%d%H%M 2>/dev/null || echo 0101000000)" "$TS_LOG"
	run_update --check || fail "stale guard run exit code $?"
	assert_contains "$(stdout)" "9.9.9" || fail "stale guard blocked the run: $(stdout)"
	[ ! -f "$TS_UI_STATUS" ] || fail "stale status file not cleared"
}

t_start_honors_base_url() {
	setup_case start_honors_base_url
	run_update --start || fail "--start exit code $?"
	_i=0
	while [ ! -s "$TS_RC" ]; do
		_i=$((_i + 1))
		[ "$_i" -gt 100 ] && fail "background update did not finish in time"
		sleep 0.3
	done
	[ "$(cat "$TS_RC")" = "0" ] || fail "background update rc=$(cat "$TS_RC"): $(cat "$TS_LOG")"
	[ "$(installed_version "$BINDIR")" = "9.9.9" ] || fail "--start ignored --base-url: $(installed_version "$BINDIR")"
}

t_no_checksum_refused() {
	setup_case no_checksum_refused
	_sd="$FIXTURES/stable"
	mv "$_sd/tailscale_9.9.9_amd64.tgz.sha256" "$_sd/tailscale_9.9.9_amd64.tgz.sha256.hidden"
	run_update --yes && fail "update without checksum unexpectedly succeeded"
	mv "$_sd/tailscale_9.9.9_amd64.tgz.sha256.hidden" "$_sd/tailscale_9.9.9_amd64.tgz.sha256"
	assert_contains "$(stderr)" "checksum" || fail "no checksum error: $(stderr)"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified without checksum"
	if grep -q '^stop$' "$INITD_LOG" 2>/dev/null; then
		fail "service stopped despite missing checksum"
	fi
}

t_start_failure_rc() {
	setup_case start_failure_rc
	_sd="$FIXTURES/stable"
	mv "$_sd/tailscale_9.9.9_amd64.tgz" "$_sd/tailscale_9.9.9_amd64.tgz.good"
	mv "$_sd/tailscale_9.9.9_amd64.bad.tgz" "$_sd/tailscale_9.9.9_amd64.tgz"
	run_update --start || fail "--start exit code $?"
	_i=0
	while [ ! -s "$TS_RC" ]; do
		_i=$((_i + 1))
		[ "$_i" -gt 100 ] && fail "background update did not finish in time"
		sleep 0.3
	done
	mv "$_sd/tailscale_9.9.9_amd64.tgz" "$_sd/tailscale_9.9.9_amd64.bad.tgz"
	mv "$_sd/tailscale_9.9.9_amd64.tgz.good" "$_sd/tailscale_9.9.9_amd64.tgz"
	[ "$(cat "$TS_RC")" != "0" ] || fail "failed background update wrote rc=0"
	[ "$(cat "$TS_UI_STATUS")" = "failed" ] || fail "status not failed: $(cat "$TS_UI_STATUS")"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified by failed update"
}

t_lock_blocks_update() {
	setup_case lock_blocks_update
	mkdir -p "$TS_LOCKDIR"
	touch "$TS_LOCKDIR/held"
	run_update --yes && fail "blocked update should have exited 3"
	assert_contains "$(stdout)" "in progress" || fail "not reported as blocked: $(stdout)"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified despite lock"
	[ -d "$TS_LOCKDIR" ] || fail "foreign lock was removed"
}

t_lock_blocks_start() {
	setup_case lock_blocks_start
	mkdir -p "$TS_LOCKDIR"
	touch "$TS_LOCKDIR/held"
	printf 'sentinel\n' > "$TS_LOG"
	run_update --start && fail "blocked --start should have exited 3"
	[ "$(cat "$TS_LOG")" = "sentinel" ] || fail "--start truncated the log despite lock"
	[ ! -s "$TS_RC" ] || fail "--start wrote an rc despite lock"
	[ -d "$TS_LOCKDIR" ] || fail "foreign lock was removed"
}

t_lock_stale_stolen() {
	setup_case lock_stale_stolen
	mkdir -p "$TS_LOCKDIR"
	touch "$TS_LOCKDIR/held"
	touch -d '31 minutes ago' "$TS_LOCKDIR/held" 2>/dev/null
	run_update --yes || fail "stale lock not stolen, exit $?"
	[ "$(installed_version "$BINDIR")" = "9.9.9" ] || fail "update blocked by stale lock"
	[ ! -d "$TS_LOCKDIR" ] || fail "lock not released after update"
}

t_gh_vanilla() {
	# plenty of flash: the uncompressed variant from the vanilla base is
	# used instead of the UPX one (no per-invocation decompress)
	setup_case gh_vanilla
	export TS_VANILLA_MIN_KB=0
	run_update github --yes || fail "exit $?"
	unset TS_VANILLA_MIN_KB
	assert_contains "$(stdout)" "uncompressed" || fail "vanilla mode not announced: $(stdout)"
	[ -f "$BINDIR/tailscaled" ] && [ ! -L "$BINDIR/tailscaled" ] || fail "tailscaled not installed as real file"
	[ -L "$BINDIR/tailscale" ] || fail "tailscale is not a symlink to the combined binary"
	[ "$(installed_version "$BINDIR")" = "9.9.9" ] || fail "version: $(installed_version "$BINDIR")"
}

t_gh_update() {
	setup_case gh_update
	run_update github --yes || fail "exit $?"
	[ -f "$BINDIR/tailscaled" ] && [ ! -L "$BINDIR/tailscaled" ] || fail "tailscaled not installed as real file"
	[ -L "$BINDIR/tailscale" ] || fail "tailscale is not a symlink to the combined binary"
	[ "$(installed_version "$BINDIR")" = "9.9.9" ] || fail "version: $(installed_version "$BINDIR")"
	[ "$(backup_count)" = "1" ] || fail "expected 1 backup, got $(backup_count)"
	grep -q '^stop$' "$INITD_LOG"  || fail "init stub never stopped"
	grep -q '^start$' "$INITD_LOG" || fail "init stub never started"
	assert_contains "$(cat "$TS_CONFDIR/.update-state")" "version=9.9.9" || fail "state file"
}

t_gh_rollback() {
	setup_case gh_rollback
	run_update github --yes || fail "gh update failed"
	run_update github --rollback || fail "rollback exit $?"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "rollback did not restore 1.80.3"
}

t_gh_rollback_symlink() {
	# rollback of a github-layout backup must restore the tailscale symlink,
	# not a duplicate regular file (make_backup records the layout in meta)
	setup_case gh_rollback_symlink
	run_update github --yes || fail "first gh update failed"
	run_update github --yes --force || fail "second gh update failed"
	_b="$(ls -1d "$TS_CONFDIR"/.update-backup/*/ 2>/dev/null | sort | tail -n1)"
	grep -q '^symlink=1$' "$_b/meta" || fail "symlink layout not recorded in backup meta"
	run_update github --rollback || fail "rollback exit $?"
	[ -L "$BINDIR/tailscale" ] || fail "rollback did not restore the tailscale symlink"
	[ "$(installed_version "$BINDIR")" = "9.9.9" ] \
		|| fail "version after rollback: $(installed_version "$BINDIR")"
}

t_gh_corrupt() {
	setup_case gh_corrupt
	_d="$GH_DIR"
	mv "$_d/tailscaled-linux-amd64" "$_d/tailscaled-linux-amd64.good"
	mv "$_d/tailscaled-linux-amd64.bad" "$_d/tailscaled-linux-amd64"
	run_update github --yes && fail "corrupt binary unexpectedly accepted"
	mv "$_d/tailscaled-linux-amd64" "$_d/tailscaled-linux-amd64.bad"
	mv "$_d/tailscaled-linux-amd64.good" "$_d/tailscaled-linux-amd64"
	assert_contains "$(stderr)" "checksum" || fail "no checksum error: $(stderr)"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified"
	if grep -q '^stop$' "$INITD_LOG" 2>/dev/null; then
		fail "service stopped despite checksum failure"
	fi
}

t_gh_no_checksum() {
	setup_case gh_no_checksum
	_d="$GH_DIR"
	mv "$_d/SHA256SUMS.txt" "$_d/SHA256SUMS.hidden"
	run_update github --yes && fail "update without SHA256SUMS unexpectedly succeeded"
	mv "$_d/SHA256SUMS.hidden" "$_d/SHA256SUMS.txt"
	assert_contains "$(stderr)" "checksum" || fail "no checksum error: $(stderr)"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified without checksum"
}

t_gh_no_version() {
	setup_case gh_no_version
	_d="$GH_DIR"
	mv "$_d/version.txt" "$_d/version.hidden"
	run_update github --yes && fail "update without version.txt unexpectedly succeeded"
	mv "$_d/version.hidden" "$_d/version.txt"
	assert_contains "$(stderr)" "github source" || fail "no version error: $(stderr)"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified despite missing version"
}

t_gh_riscv64_refused() {
	setup_case gh_riscv64_refused
	CASE_ARCH=riscv64
	run_update github --yes && fail "riscv64 unexpectedly accepted by github source"
	assert_contains "$(stderr)" "riscv64" || fail "no arch error: $(stderr)"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified"
}


t_scratch_check_message() {
	setup_case scratch_check_message
	mkdir -p "$CASE_DIR/dfstub"
	cat > "$CASE_DIR/dfstub/df" <<'DFFAKE'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "tmpfs 100000 90000 10000 90% /tmp"
DFFAKE
	chmod 755 "$CASE_DIR/dfstub/df"
	unset TS_WORKDIR   # force the auto-pick path (normally bypassed by the override)
	PATH="$CASE_DIR/dfstub:$PATH" "$SRC" --source github --arch amd64 --yes \
		> "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr" && fail "update should have been refused"
	assert_contains "$(stderr)" ">=30MB" || fail "message lacks actual 30MB requirement: $(stderr)"
	if grep -q '150' "$CASE_DIR/stderr"; then
		fail "message still claims 150MB for the github source: $(stderr)"
	fi
}

t_backup_skip_space() {
	setup_case backup_skip_space
	mkdir -p "$CASE_DIR/dfstub"
	cat > "$CASE_DIR/dfstub/df" <<'DFFAKE'
#!/bin/sh
echo "Filesystem 1K-blocks Used Available Use% Mounted on"
echo "overlayfs:/overlay 100000 99900 100 100% /"
DFFAKE
	chmod 755 "$CASE_DIR/dfstub/df"
	PATH="$CASE_DIR/dfstub:$PATH" run_update github --yes || fail "update failed: $(stderr)"
	assert_contains "$(stdout)" "backup skipped (only" \
		|| fail "no space-skip message: $(stdout)"
	[ "$(installed_version "$BINDIR")" = "9.9.9" ] || fail "version: $(installed_version "$BINDIR")"
	grep -q '^backup=$' "$TS_CONFDIR/.update-state" \
		|| fail "state does not record the skipped backup"
}

t_gh_mirror_version() {
	setup_case gh_mirror_version
	export TS_GH_MIRRORS="http://127.0.0.1:$PORT/mirror"
	mv "$GH_DIR/version.txt" "$GH_DIR/version.hidden"
	run_update github --yes || fail "mirror fallback for version.txt failed: $(stderr)"
	mv "$GH_DIR/version.hidden" "$GH_DIR/version.txt"
	unset TS_GH_MIRRORS
	[ "$(installed_version "$BINDIR")" = "9.9.9" ] || fail "version: $(installed_version "$BINDIR")"
}

t_gh_mirror_binary() {
	setup_case gh_mirror_binary
	export TS_GH_MIRRORS="http://127.0.0.1:$PORT/mirror"
	mv "$GH_DIR/tailscaled-linux-amd64" "$GH_DIR/tailscaled-linux-amd64.good"
	mv "$GH_DIR/tailscaled-linux-amd64.bad" "$GH_DIR/tailscaled-linux-amd64"
	run_update github --yes || fail "mirror fallback for binary failed: $(stderr)"
	mv "$GH_DIR/tailscaled-linux-amd64" "$GH_DIR/tailscaled-linux-amd64.bad"
	mv "$GH_DIR/tailscaled-linux-amd64.good" "$GH_DIR/tailscaled-linux-amd64"
	unset TS_GH_MIRRORS
	[ "$(installed_version "$BINDIR")" = "9.9.9" ] || fail "version: $(installed_version "$BINDIR")"
}

t_gh_mirror_all_fail() {
	setup_case gh_mirror_all_fail
	export TS_GH_MIRRORS="http://127.0.0.1:$PORT/mirror"
	for _d in "$GH_DIR" "$GH_MIRROR_DIR"; do
		mv "$_d/tailscaled-linux-amd64" "$_d/tailscaled-linux-amd64.good"
		mv "$_d/tailscaled-linux-amd64.bad" "$_d/tailscaled-linux-amd64"
	done
	run_update github --yes && fail "update unexpectedly succeeded with all sources corrupt"
	for _d in "$GH_DIR" "$GH_MIRROR_DIR"; do
		mv "$_d/tailscaled-linux-amd64" "$_d/tailscaled-linux-amd64.bad"
		mv "$_d/tailscaled-linux-amd64.good" "$_d/tailscaled-linux-amd64"
	done
	unset TS_GH_MIRRORS
	assert_contains "$(stderr)" "checksum" || fail "no checksum error: $(stderr)"
	[ "$(installed_version "$BINDIR")" = "1.80.3" ] || fail "binaries modified"
}
