# ApmonD

ApmonD is an access point monitoring daemon for OpenWrt. It is a standalone port of the
apmond functionality in [mesh11sd](https://github.com/openNDS/mesh11sd), for networks that
do not use mesh11sd.

Access points (client role) periodically collect wireless and wired client usage data and
send it to a central collector (server role), which keeps the latest report from each AP.

## Features

* Fully compatible with static UCI / LuCI - apmond never writes configuration at runtime
* Shared secret authentication (BusyBox `sha256sum` only, no openssl)
* IPv4 and IPv6 collector addresses
* Same hex-encoded chunked HTTPS transport as mesh11sd (protocol v1)
* Conflicts with mesh11sd (`CONFLICTS:=mesh11sd` in the OpenWrt Makefile)

## Roles

| Role | Runs on | What it does |
|---|---|---|
| Client | Each access point | Collects AP and wired client stats, sends them to the collector |
| Server | The collector | Receives signed reports via `/cgi-bin/apmon.cgi`, stores the latest per AP |

Both roles may be enabled on the same node.

## Quick start

1. Install the package on the collector and on every access point.
2. Put the **same** shared secret in `/etc/config/apmond` on every node.
3. On the collector: enable the server role.
4. On each access point: enable the client role and set `option server` to the collector.
5. `service apmond restart` on each node.
6. On the collector: `apmond show_ap_data` / `apmond show_ap_data all`.

See `linux_openwrt/apmond/files/etc/config/apmond` for every option.

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

GPL-2.0-only. Copyright (C) BlueWave Projects and Services.
