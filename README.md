# ApmonD

ApmonD is an access point monitoring daemon for OpenWrt. It is a standalone port of the
apmond functionality in [mesh11sd](https://github.com/openNDS/mesh11sd), for networks that
do not use mesh11sd.

Every node (access points and the router) runs the same daemon with an identical
`/etc/config/apmond`. As in mesh11sd, a shared IPv6 ULA prefix and the report signing secret
are derived from one memorable passphrase (`apmon_seed`). The node with an upstream wan gateway
detects itself as the router, takes `<ula_prefix>:<subnet>::1` at runtime and becomes the
collector; every node sends its report there. Addresses are applied with `ip` at runtime and
removed on stop; they are never written to UCI. ApmonD never leaves uncommitted UCI changes: a
CLI setting such as `apmond debuglevel <n>` is committed straight away, so nothing is left pending
for LuCI to pick up.

## Features

* Fully compatible with static UCI / LuCI - one section, `config apmond 'setup'`, never written at runtime
* Works out of the box: every option is optional. Without `apmon_seed` a built-in default passphrase
  is used, with a critical syslog warning at start and every 6 hours (set your own!)
* Shared secret authentication (BusyBox `sha256sum` only, no openssl)
* Same hex-encoded chunked HTTPS transport as mesh11sd (protocol v1, signed)
* Conflicts with mesh11sd (`CONFLICTS:=mesh11sd`)

## Quick start

1. Install the package on every node.
2. On every node: `uci set apmond.setup.apmon_seed='my private passphrase'; uci commit apmond; service apmond restart`
3. On the router: `apmond show_ap_data` / `apmond show_ap_data all`. `apmond status` on any node shows its role.

`apmond status` reports `checksum` (sha256 of the script the running daemon started from, or of
`/usr/sbin/apmond` when no daemon runs) and `installed_checksum` (sha256 of `/usr/sbin/apmond` on disk now).
If they differ while the daemon runs, `checksum_warning` is added: restart apmond to run the installed version.

See `linux_openwrt/apmond/files/etc/config/apmond` for every option.

## Wired client bridges

With `list bridge` unset (or set to `'auto'`, alone or with other entries) every bridge on the node is
detected on each report pass and scanned for wired clients, e.g. both `br-lan` and `br-guest` in a home +
guest setup; bridges added later are picked up automatically. Excluded: the upstream bridge (the
`network.wan` / `wan6` device, or a bridge with that device as a member, unless wan is disabled), and
bridges with no members other than a mesh11sd `vxlan` tunnel port. Wireless ports are reported from the
station dump and `vxlan` ports are never scanned (their MACs are other nodes' clients). To scan only
particular bridges, list them: `list bridge 'br-lan'`. The ULA addresses stay on `device` only.

Upgrading: if your `/etc/config/apmond` has been changed (e.g. by `apmond debuglevel`), apk keeps it and
installs the new default beside it as `/etc/config/apmond.apk-new`; compare the two to see new option comments.

## Storage

As mesh11sd's `log_mountpoint`, the optional `apmond.setup.log_mountpoint` (default `/tmp`) selects where
AP data is kept, e.g. a USB stick. If it is not mounted (or not writable) apmond falls back to `/tmp`.

```
<log_mountpoint>/apmond/              # package top level directory
  apmond_data/<mac12>                 # latest report from each AP (collector)
  apmond_log.log                      # apmond log (apmond read_log [-f]), as mesh11sd_log.log

/var/run/apmond/                      # volatile runtime state (/tmp/run/apmond on OpenWrt): role, ULA addresses, wifidetect, staging/, last_ts/
```

## Layout

```
Makefile                                 # OpenWrt package Makefile
src/apmond                               # The daemon and CLI
linux_openwrt/apmond/files/
  etc/config/apmond                      # UCI defaults
  etc/init.d/apmond                      # procd init
  www/cgi-bin/apmon.cgi                  # Receiver CGI (installed, not generated)
tests/                                   # Mock end-to-end tests (host with busybox)
```

## License

Released under the GNU General Public License version 2 or any later version, as mesh11sd (see LICENSE; the OpenWrt package metadata says `PKG_LICENSE:=GPL-2.0-only`, as mesh11sd's does). Copyright (C) BlueWave Projects and Services.
