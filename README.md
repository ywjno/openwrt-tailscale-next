# openwrt-tailscale-next

**English** · [简体中文](README.zh-CN.md)

An OpenWrt Tailscale plugin: single-page LuCI app + self-updating Tailscale binaries (sha256-verified, backup / rollback) + optional scheduled auto-update. Self-contained — it does not use OpenWrt's `tailscale` feed package.

## Install

One line over SSH (auto-detects opkg/apk and picks the right package from the latest release):

```sh
wget -qO- https://github.com/ywjno/openwrt-tailscale-next/releases/latest/download/install-tailscale-next.sh | sh
```

Or grab the package from [Releases](https://github.com/ywjno/openwrt-tailscale-next/releases) (each run builds both formats; i18n packages are separate `luci-i18n-tailscale-next-<lang>` files):

| Format | Systems               | Install                                                                                          |
| ------ | --------------------- | ------------------------------------------------------------------------------------------------ |
| `.apk` | OpenWrt 25.12+        | install `tailscale-next.pem` once (next paragraph), then `apk add luci-app-tailscale-next-*.apk` |
| `.ipk` | OpenWrt 21.02 - 24.10 | `opkg install luci-app-tailscale-next_*.ipk`                                                     |

`.apk` files are **signed**. Devices trust them after installing our public key once — LuCI (System → Software → Configuration, Keys) or `cp tailscale-next.pem /etc/apk/keys/` — then no `--allow-untrusted` is ever needed. Until then: `apk add --allow-untrusted /tmp/upload.apk`.

After install, open "Services → Tailscale Next", tick **Enable**, Save & Apply: the service bootstraps the binaries itself (~10 MB download). Login state and update backups live in `/etc/tailscale/` (survives sysupgrade).

## Uninstall

```sh
wget -qO- https://github.com/ywjno/openwrt-tailscale-next/releases/latest/download/uninstall-tailscale-next.sh | sh
```

Logs out first if the node is logged in (logout needs the daemon running), stops the service and removes the package. On purpose it keeps `/etc/config/tailscale-next` (UCI settings), `/etc/tailscale/` (login state + update backups), the installed binaries under `/usr/sbin/` and the `tailscale-next.pem` key — together those form a working standalone Tailscale; remove them manually for a full wipe.

## Requirements

Measured on real hardware; the LuCI page shows the same checks live.

| Resource | Minimum     | Comfortable | Notes                                                              |
| -------- | ----------- | ----------- | ------------------------------------------------------------------ |
| RAM      | 128 MB      | 256 MB      | tailscaled ~35 MB resident after login                             |
| Flash    | ~10 MB free | ~37 MB free | 9 MB binary + up to 3 backups under `/etc/tailscale/`              |
| `/tmp`   | 30 MB free  | —           | updater scratch space (RAM); use `--workdir` on low-memory devices |

- **zram-swap is optional, not a dependency**, but it's the cheapest OOM insurance on tight boxes (`apk add zram-swap`; size via `zram_size_mb`, ~half of RAM is reasonable).
- Devices too small for tailscaled can still join the tailnet: run Tailscale on any always-on machine in the same network and advertise the subnet (`--advertise-routes=192.168.x.0/24`, approve in the admin console).

## Download sources

The updater fetches an **UPX-compressed combined binary** (8–11 MB, a third of the official tarball) from [CH3NGYZ/small-tailscale-openwrt](https://github.com/CH3NGYZ/small-tailscale-openwrt) releases: one file serves as both CLI and daemon (argv[0] dispatch), verified against the release's `SHA256SUMS.txt` (no sums → install refused). amd64 / 386 / arm / arm64 / mips / mipsle / mips64 / mips64le; **no riscv64** (use `--source official`).

- Devices with ≥ 60 MB free get the **uncompressed binary** automatically (no per-invocation decompress cost on weak CPUs); threshold: `TS_VANILLA_MIN_KB`.
- Mirror fallback: `TS_GH_MIRRORS` (space separated) or `--mirror-list <file>`; every mirror must be trusted to relay unmodified content.
- Escape hatch: `--source official [--base-url <mirror>]` (Tailscale's official tarballs, 40–90 MB).

## Usage

The page has six blocks: **Status** (enable switch, login/logout), **Global Settings** (subnet routes, exit node, hostname), **Custom Server** (Headscale URL + auth key), **Update Settings** (page-load check, backups, daily auto-update at 04:30), **Tailscale Update** (check / update / rollback + live log), **Device requirements** (live RAM/flash verdicts).

Save & Apply writes `/etc/config/tailscale-next` and restarts the service in the background; status settles within ~10 s of the page reloading.

## CLI

Works over SSH without LuCI (`/usr/libexec` is not on `PATH`):

```sh
/usr/libexec/tailscale-next-update --check            # installed vs latest
/usr/libexec/tailscale-next-update                    # interactive update
/usr/libexec/tailscale-next-update -y                 # no prompt
/usr/libexec/tailscale-next-update -v 1.104.1         # specific version
/usr/libexec/tailscale-next-update --rollback         # restore previous backup
/usr/libexec/tailscale-next-update --dry-run          # print steps only
/usr/libexec/tailscale-next-update --help             # all options
```

Exit codes: `0` ok, `1` error, `3` skipped (another update in progress). Notable env: `TS_KEEP_BACKUPS`, `TS_VANILLA_MIN_KB`, `TS_GH_MIRRORS` (plus `TS_BINDIR`/`TS_CONFDIR`/… for sandboxes, see `--help`).

## UI languages

English out of the box; `luci-i18n-tailscale-next-{zh-cn, zh-tw, de, es, fr, it, ja, ko, pt-br, ru}` match the LuCI language automatically. To add one, drop a translated `tailscale-next.po` into `luci-app-tailscale-next/po/<lang>/` — CI discovers it.

## Build & test

Fork and run the "build OpenWrt packages" workflow (manual version input, or push a `v*` tag) — one run builds `.ipk` (24.10.5 SDK) and `.apk` (25.12.5 SDK). Local build: copy `luci-app-tailscale-next/` into any SDK's `package/`, then `make package/luci-app-tailscale-next/compile V=s`.

Sandboxed tests on any Linux box (`sh tests/run_tests.sh`, `sh tests/test_init.sh`, `sh tests/test_i18n.sh`) — see `AGENTS.md` for the repo's agent-facing notes.

## FAQ

- **Update failed half-way?** Checksum mismatches refuse the install; a bad post-install verification rolls back to the previous backup automatically (kept in `/etc/tailscale/.update-backup/`, 0–3 generations).
- **Version shows a suffix like `1.104.7-dev20261112`?** Not a dev build — the fork stamps build dates; the updater compares base versions only.
- **Status flips to "Not running" after rapid saves on a low-RAM router?** Overlapping restarts can spawn two decompressed instances and OOM-kill the daemon; the init script serializes them (fail fast while a fresh lock is held). Space actions a few seconds apart.
- **"Another update is in progress" never clears?** A previous update was interrupted: confirm nothing is running, delete `/tmp/tailscale-next-update.status` and `/tmp/tailscale-next-update.lock` (stale states auto-clear after 30 min).
- **Do I need to re-login after updates?** No — login state lives in `/etc/tailscale/`, independent of the binaries.
- **Is the auth key safe?** It appears in the `tailscale up` command line (visible in `ps`), same as the upstream LuCI app; everything on a router runs as root anyway.
- **Who manages the binaries?** This plugin's updater, not opkg/apk (if the official tailscale package is also present, the updater holds it).

## Acknowledgements

Inspired by [openwrt-tailscale](https://github.com/Carseason/openwrt-tailscale) and [small-tailscale-openwrt](https://github.com/CH3NGYZ/small-tailscale-openwrt).

## License

MIT.
