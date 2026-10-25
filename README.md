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
   `apmond get_ap_data` on any node (router or peer) prints that node's own current access point data as JSON
   (the same `System@<mac>` document it would send, as mesh11sd `get_ap_data`) without sending anything;
   it prints nothing when the node has no clients.

`apmond status` reports `checksum` (sha256 of the script the running daemon started from, or of
`/usr/sbin/apmond` when no daemon runs) and `installed_checksum` (sha256 of `/usr/sbin/apmond` on disk now).
If they differ while the daemon runs, `checksum_warning` is added: restart apmond to run the installed version.

Every report also carries `"apmond_checksum"` in its `node_status` block, after `apmond_protocol`: the sha256
(BusyBox `sha256sum`) of the apmond script that produced the report, so a collector can see which build each
node runs. It appears in each node's entry in `apmond show_ap_data` on the collector and in `apmond get_ap_data`
output. A report sent by the daemon carries the hash of the script the daemon started from (the same value as
status `checksum`); `apmond get_ap_data` run by hand gives the hash of `/usr/sbin/apmond` as installed (status
`installed_checksum`). mesh11sd reports the same value as `mesh11sd_checksum`; `apmond_checksum` is the shared
field name for mesh11sd to add later, purely additive. A collector should accept reports without it.

See `linux_openwrt/apmond/files/etc/config/apmond` for every option.

## Wired client bridges

With `list bridge` unset (or set to `'auto'`, alone or with other entries) every bridge on the node is
detected on each report pass and scanned for wired clients, e.g. both `br-lan` and `br-guest` in a home +
guest setup; bridges added later are picked up automatically. Excluded: the upstream bridge (the
`network.wan` / `wan6` device, or a bridge with that device as a member, unless wan is disabled), and
bridges with no members other than a mesh11sd `vxlan` tunnel port. Wireless ports are reported from the
station dump and `vxlan` ports are never scanned (their MACs are other nodes' clients). To scan only
particular bridges, list them: `list bridge 'br-lan'`. The ULA addresses stay on `device` only.

Every MAC learned on a wired bridge port is listed under `<port>@<bridge>`, including other APs and mesh
nodes (several APs can share a port); they are ordinary devices, as in mesh11sd. The bridge does not count
traffic per MAC, so a wired entry's `rx_bytes` / `tx_bytes` are the port's totals and `rx_bitrate` /
`tx_bitrate` its link speed (Mb/s), shared by every MAC on that port. Each wired entry says so with
`"stats_scope": "port"`. Wireless station entries are per station and have no `stats_scope`. A collector
should treat a wired entry without `stats_scope` (e.g. from a mesh11sd version that does not add it yet)
as `"port"`.

## VLAN-aware bridges (vlan_filtering)

A bridge with `option vlan_filtering '1'` (e.g. home and guest VLANs trunked over a mesh or cable:
`network.lan.device='br-lan.10'`, `network.guest.device='br-lan.20'`) has no VLAN membership of its own, so
ULA traffic on `br-lan` itself would not pass. When `device` (default `br-lan`) is such a bridge, ApmonD uses
the lan network's L3 device instead (`network.lan.device`, else `ifstatus lan` `l3_device`) if it is a VLAN
subinterface `<bridge>.<vid>` of it: the ULA addresses, the collector `::1` claim and send/listen use
`br-lan.10`, and status `device` / `ula_addresses` show it. It is resolved when ApmonD starts. An explicit
`option device 'br-lan.10'` also works as an override. Bridge detection and MAC tables still use the parent
`br-lan`; VLAN subinterfaces are never treated as separate bridges.

Wired client entries on a vlan_filtering bridge get `"vlan": "<vid>"` after `stats_scope`. No extra package
is needed: for an access port (a member of exactly one VLAN, untagged, e.g. `list ports 'eth0.1:u*'`; a port
listed without a suffix counts as untagged) the VID comes from the UCI `bridge-vlan` sections of that bridge
and is set on every client of the port. A trunk or multi-VLAN port can't be resolved per MAC from UCI, so
its clients have no `vlan` key, unless the optional `ip-bridge` package is installed: then `bridge fdb show`
gives each MAC's own VLAN(s), which take precedence, on any port. ApmonD does not depend on ip-bridge.
The bridge keeps one fdb entry per MAC and VLAN, but a JSON key can't repeat, so there is one entry per MAC
and a MAC seen in several VLANs gets its VIDs comma-joined in ascending order, e.g. `"vlan": "10,20"`. On a
bridge without vlan_filtering the key is never present.

Wireless client entries get the same optional `"vlan": "<vid>"`, after `connected_time` and before
`timestamp`, worked out per AP interface: if the wifi-iface's `option network` (e.g. `guest`) has a device
`<bridge>.<N>` (e.g. `br-lan.20`) on a vlan_filtering bridge, the VID is N; otherwise, if the AP interface
is a port of a vlan_filtering bridge with a single untagged VLAN in its UCI `bridge-vlan` sections, that VID.
Without vlan_filtering the key is omitted. Only `mode 'ap'` wifi-ifaces are reported, never the mesh
interface. No ip-bridge needed.

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

## Receiver CGI (cgi_dir)

As in mesh11sd, `apmon.cgi` is not shipped as a package file: the daemon generates it at startup on every
node, in the directory set by the optional `apmond.setup.cgi_dir` (default `/www/cgi-bin`, mesh11sd's
`apmond_cgi_dir`). Change it only if a web server package other than uhttpd serves `/cgi-bin/` from another
directory. A trailing slash is optional and the directory is created if missing. The daemon writes the CGI
to its run directory, compares the sha256 with the live copy and replaces the live copy only if it differs
or is missing, so an identical copy is left untouched and an edited or broken one is repaired on the next
restart. If `cgi_dir` is moved away from the default, an apmond-generated copy left at
`/www/cgi-bin/apmon.cgi` is removed (only if it is exactly the generated file). `apmond status` shows
`cgi_dir`. The collector URL path stays `/cgi-bin/apmon.cgi`.

On package removal (`apk del apmond`) the removal hook deletes `apmon.cgi` from the configured `cgi_dir`
and from `/www/cgi-bin`, but only a file carrying the "generated by apmond" marker line. Upgrades keep it.

## Layout

```
ChangeLog                                # Release notes
Makefile                                 # OpenWrt package Makefile
src/apmond                               # The daemon and CLI
linux_openwrt/apmond/files/
  etc/config/apmond                      # UCI defaults
  etc/init.d/apmond                      # procd init
tests/                                   # Mock end-to-end tests (host with busybox)

<cgi_dir>/apmon.cgi                      # Receiver CGI, generated by the daemon at startup (not a package file)
```

## License

Released under the GNU General Public License version 2 or any later version, as mesh11sd (see LICENSE; the OpenWrt package metadata says `PKG_LICENSE:=GPL-2.0-only`, as mesh11sd's does). Copyright (C) BlueWave Projects and Services.
