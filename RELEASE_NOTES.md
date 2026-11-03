# apmond 2.0.0 — release notes

Released Tue, 03 Nov 2026. Tag `v2.0.0` in [openNDS/apmond](https://github.com/openNDS/apmond).

## Overview

apmond monitors several OpenWrt access points on one LAN, however they are linked: cabled (the most common
setup), mesh, point-to-point, fibre or anything else. The link type does not matter to apmond.

Every access point runs the same daemon. It collects its radios, Wi-Fi clients and wired clients and reports
them, encrypted with AES-256-GCM, to one **collector**, where the data of every access point is available on
ubus, the `apmond` command line and LuCI. The other access points are **senders**.

2.0 is a rewrite in C: a shared library (libapmon) and the `apmond` daemon. It uses a new wire protocol
(protocol 2, docs/PROTOCOL.md: configurable port, PBKDF2 passphrase stretching, no compression).
**It is not wire compatible with 1.x: all access points must run 2.x.** The 1.x shell version stays in
openNDS/apmond.

## New in 2.0

### Collector / sender model and automatic election
- With `option role 'auto'` (the default) an access point is a **collector candidate** only when it has an
  upstream gateway (router) on its WAN: netifd `wan` or `wan6` up with a default route, not bridged into
  another device, and not a bridge with several ports or a Wi-Fi port (r18). `role 'collector'` or
  `'sender'` can be set instead.
- Candidates elect the collector by claiming the collector ULA `<prefix>:<subnet>::1` with duplicate address
  detection: first come wins, after a random 0..`claim_delay_max` (10 s) delay. A candidate that finds `::1`
  answering **backs off** and works as a sender.
- The holder re-runs DAD on `::1` every `collector_recheck` (10) cycles and gives way if another access point
  holds it.
- A candidate checks that it can open the collector listener before it claims `::1`, and gives `::1` up if the
  listener fails later (r25, r26). The listener is bound to the LAN device only.

### Failover and handback
- A backed-off candidate takes over `::1` after `router_takeover_misses` (3) checks without an answer.
- When the old collector comes back it finds `::1` in use and stays a sender: **there is no automatic
  handback**; the new collector keeps the role until it fails. Two holders were never seen in testing.
- Senders that lose the collector alternate between the collector ULA and the LAN IPv4 gateway and return to
  the ULA by themselves once a collector answers.

### Identity: factory MAC and node ULA
- An access point is identified by its factory (label) MAC, `node_mac`, from a six-step chain (device tree
  `label-mac-device`, board.json, uci `label_macaddr`, WAN permanent MAC, eth1/eth0/lan0/lan1,
  lowest-ifindex ethernet) (r15, r29). Only permanent MACs are used, so a MAC changed at runtime by other
  software never becomes the id. If nothing fits, apmond does not start.
- Each access point adds its own node ULA (EUI-64 from its id); the prefix is derived from `apmon_seed`.
- Under the newer ujail that hides `/sys/firmware`, the init script copies the device tree label MAC files to
  `/tmp/apmond/devicetree` before starting the jail (r30).

### Security: ujail, user apmond, CAP_NET_ADMIN only
- apmond runs as user `apmond` (468) with only `CAP_NET_ADMIN` and no_new_privs: under procd ujail where the
  kernel supports it, otherwise by dropping privileges itself (eg ramips/mt76x8) (r14).
- Fail closed when user apmond is missing; the init script recreates it (r25, r26).
- `/etc/config/apmond` is root:apmond 0640. Reports are encrypted and authenticated; stale, replayed and
  tampered messages are rejected.

### Crypto variants
- `apmond` (mbedTLS, default and recommended, especially on 16 MB flash devices) and `apmond-openssl`
  (OpenSSL 3 libcrypto). Wire compatible, can be mixed on one LAN, same test vectors; they conflict with each
  other and share the config (r21). `ubus call apmond status` shows `crypto`.

### Command line and status
- `apmond status|nodes|node|clients|forget|block|debuglevel|read_log|bench|run`, JSON (jq style) or `-t`
  tables.
- Build identity on every access point: `package_version`, `build_commit`, `running_sha256`,
  `installed_sha256`, `restart_needed` (r13). The package restarts apmond on upgrade (r12).
- Sender summary line, always present: `reports sent N  failed N  time sync failed N  last HTTP status N  last
  error E`, plus a pointer to `lost_reports` on the collector (r31, r33).
- Status fields `time_sync_failed` and `last_error` (`no connection`, `key rejected`,
  `time or replay rejected`, `bad reply`, `HTTP NNN`, empty after success) (r33).
- The collector logs authentication failures at notice level, rate limited (r33).
- Extension blocks: other programs can attach JSON to an access point's reports (`ubus call apmond add_block`).
- VLAN of APs and clients from the bridge port PVID; optional VXLAN details where a bridge has a VXLAN port.
  Wi-Fi data from nl80211 (no iwinfo) (r6, r19).
- TIME_REQ and 409-rejected sequence numbers count as used, not lost (r27).

### Collector address: ULA first, LAN-only IPv4 fallback
- Senders send to the collector ULA. At start a sender waits up to 30 s for its own node ULA to pass DAD
  before choosing (r32).
- If the ULA is still not ready, or a ULA send fails, it uses the **LAN-side IPv4 gateway only** (netifd
  `lan`: its DHCP server, else its default-route nexthop) and retries the ULA after 10 IPv4 reports or a failed
  IPv4 send. **The WAN / kernel default route is never used as the collector**; with no LAN gateway the sender
  stays on the ULA (r34).

### Collector-candidate wait
- A collector candidate (an access point with an upstream gateway) that does not hold `::1` never falls back
  to IPv4: it waits for its node ULA however long DAD takes and keeps trying to claim each cycle (r34). Logged
  as `portal candidate: waiting for node ULA ... (no IPv4 fallback)`.

### luci-app-apmond 2.0
- Rewritten for apmond 2.x over ubus (rpcd), no ucode, CGI or rpcd plugin: Status, Access points
  (ok/late/lost, restart needed, radios, VLAN/VXLAN, Forget), new Clients page, Settings for 2.x options, Log
  with Follow. 2.0.0_beta-r2 adds wired link speed; r3 easier-to-read Access points and Clients.
- 2.0.0_beta-r4: on a sender, Status, Access points and Clients show "This node reports to the collector at
  <collector ULA>" with a **Go to collector** button (opens the collector's Access points page in a new tab);
  the collector shows a small "This node is the collector." note.
- **Getting the data:** open LuCI on any access point (eg the address you already use, often the upstream
  router's) and follow the collector link. The collector can move after a failover and there is no automatic
  handback, so the link always follows the access point that holds the collector ULA now.

## Upgrade notes

- **From 1.x:** upgrade every access point; 1.x and 2.x do not talk to each other. `apk add` of the 2.0
  package over 1.0.1 was tested and keeps `/etc/config/apmond`. Upgrade the collector last.
- **Config handling:** `/etc/config/apmond` is a conffile. If it was edited, apk keeps it and installs the new
  default as `/etc/config/apmond.apk-new`; this is normal. Compare and remove it after upgrading.
- **Id change from early betas:** upgrading from 2.0 beta r28 or older can change the id on boards that used
  an interface MAC; the access point appears once as new (`apmond forget <old node_mac>`).
- **ULAs change on a downgrade to 1.x:** 1.0.1 derives the node ULA differently (eg `...:9683:c4ff:fe52:6873`
  under 2.x became `...:9483:c4ff:fe52:6873` under 1.0.1). Anything that reaches access points by ULA (SSH,
  monitoring) must use the new address. Upgrading back to 2.x restores the 2.x ULA.
- If a new `apmon_seed` is set, set it on every access point together (and `key_epoch` if used).
- With mesh11sd, see also "Using apmond with mesh11sd" below.

## Compatibility

- OpenWrt **25.12 or later, apk packages only** (also tested on OpenWrt snapshot/master).
- Kernel 5.7+ for the jailed listener (all 25.12 targets run 6.x).
- Dependencies: libubox, libubus, libuci, libblobmsg-json, libmicrohttpd-no-ssl, plus libmbedtls or libopenssl.
- Any way of linking the access points into one LAN works: apmond only needs the LAN between them.
- Tested targets: aarch64_cortex-a53 (25.12 and snapshot), mips_24kc, mipsel_24kc.

## Using apmond with mesh11sd

mesh11sd is one optional, supported setup; apmond does not need it.

- **Optional in both directions:** apmond is an optional extra to mesh11sd, never a dependency, and mesh11sd
  does not depend on apmond. apmond 2.x does not conflict with mesh11sd.
- **Turn off mesh11sd's built-in apmond:** `uci set mesh11sd.setup.apmond_enable='0'`, so only one monitoring
  system runs (mesh11sd's built-in one speaks the 1.x protocol).
- **1.x conflicts with mesh11sd:** apmond 1.0.1 has `CONFLICTS:=mesh11sd`, so a downgrade to 1.x is only
  possible on access points without mesh11sd.
- **Node id:** the factory MAC chain is the same one mesh11sd 8.0.0 will use (`mesh11sd_factory_mac()`), kept
  in agreement by shared test vectors. MACs rewritten by mesh11sd are never used as the id.
- **VXLAN:** where mesh11sd builds its trunk as a VXLAN (`vxlan<tun_id>` in `br-tun<tun_id>`), APs and clients
  on that bridge carry `"vxlan": {"vni": N, "device": ...}`.
- **LuCI on mesh11sd 7.x portals:** with mesh11sd auto configuration, LuCI is disabled on a portal until
  `mesh11sd commit_all commit` is run there (revert with `mesh11sd revert_all revert`). Until then the
  **Go to collector** link lands on the mesh11sd status page instead of the collector's Access points page.
- **Known mesh11sd behaviour seen in testing (not apmond issues):**
  - With two portals, peers can switch their active portal. On a switch mesh11sd 7.3.1's
    DHCP renew starts a second udhcpc with the busybox default script, which can flush the peer's br-lan IPv4
    address or leave a different one than netifd reports; LuCI then shows IPv4 `-` for that access point.
    apmond reports the kernel's addresses correctly.
  - With two portals on one upstream, duplicate-address warnings for the same delegated upstream prefixes
    were logged.

## Known issues

- Collector counters (reports, `lost_reports`) are in RAM: after a collector restart or failover they start
  from zero, so reports lost during an outage show only in the senders' `failed` counts.
- After the collector disappears, senders took roughly 1–1.5 minutes to reach the new collector in testing (3
  takeover misses plus the ULA/IPv4 alternation); the access points farthest from the new collector were
  slowest.
- After a cold boot a collector candidate's own node ULA was seen taking 30–60 s or more to pass DAD, and the
  WAN can come up after apmond starts, so the access point first runs as a sender before claiming or backing
  off.
- Plugging the upstream into an access point's LAN port instead of its WAN port bridges the upstream router
  into the LAN (its RA and DHCP reach every access point); not an apmond bug, but worth a note in the docs.

## Testing done

All tests ran on a test network of 8 access points (linked by a mesh11sd mesh), plus 2 separate GL-MT300N-V2
for the upgrade/downgrade test.

- **Unit tests:** 266 host tests pass with both mbedTLS and OpenSSL backends at r34 (256 at r33).
- **8-access-point soak:** r33 on the test network (GL-MT6000, GL-AXT1800, GL-BE10000, GL-MT3600BE,
  and mips_24kc; one access point on apmond-openssl, on OpenWrt 25.12.4–25.12.6 and snapshot), all ok
  with 0 lost. An earlier 14-hour soak of r23 on 8 access points (56 samples each) showed no restarts,
  0 failed reports, flat file descriptors and RSS growth of at most about 2 KB per hour. r34 rolled out to the same 8, all ok with 0 lost.
- **Upgrade/downgrade (2× GL-MT300N-V2, mipsel_24kc, no mesh11sd):** r14 → r33 → r14 → 1.0.1 → r33. Config kept
  on every step (md5 unchanged), service enabled and running, collector upgraded last, all ok with 0 lost on
  2.x. The 1.0.1 step showed the ULA change noted above.
- **Roaming test:** passed — clients tracked by SSID and time as they moved between access points, including
  a wired client.
- **LuCI pass:** passed with luci-app-apmond 2.0.0_beta-r4 — the "Go to collector" banner on senders and the
  "This node is the collector." note on the collector both confirmed.
- **Load test:** about 1,500 junk requests per minute against the collector; CPU stayed near 0%, RSS and fds
  flat. A test with many valid simulated senders has not been done.
- **Failover test 1 (r33, collector power cut ~5 min, no other collector candidate):** all senders handled
  the outage cleanly (ULA/IPv4 alternation, no crash, no reboot, no duplicate collector) and recovered within
  ~0–60 s of the collector reclaiming `::1`. No takeover was possible because no other access point had an
  upstream. This test found the WAN-gateway fallback fixed in r34.
- **Failover test 2 (r34, a second access point given a WAN upstream):** the second candidate backed off while
  the collector held `::1`. Collector power cut ~21:00 GMT: the second candidate took over at 21:01:09
  ("not answering for 3 checks, taking over"); all 7 live access points ok on it by 21:02:31. The old
  collector powered back ~21:04: it used the collector ULA (no IPv4 via WAN), backed off at 21:06:15 and stayed
  a sender. Exactly one `::1` holder throughout; no new sender failures after it returned.
