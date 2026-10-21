# ApmonD

ApmonD is an access point monitoring daemon for OpenWrt. It is a standalone port of the
apmond functionality in [mesh11sd](https://github.com/openNDS/mesh11sd), for networks that
do not use mesh11sd.

Access points (client role) periodically collect wireless and wired client usage data and
send it to a central collector (server role), which keeps the latest report from each AP.

ApmonD is fully compatible with static UCI / LuCI configuration: it never writes to UCI at runtime.

License: GPL-2.0-only (see LICENSE).
