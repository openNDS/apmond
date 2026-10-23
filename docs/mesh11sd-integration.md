# Design note: mesh11sd using ApmonD for AP monitoring

Status: **for later consideration**. Nothing here is implemented. Written Oct 23, 2026, at ApmonD 0.1.0-r9.

## Background

ApmonD started as a port of the access point monitoring code built into mesh11sd (apmon). The two still share:

- the report format (System / phy / node_status / clients JSON),
- the chunked send to `apmon.cgi` on the collector,
- the CLI style (`show_ap_data`, `read_log`, `debuglevel`, ...).

They have already started to diverge. ApmonD signs its reports with a passphrase-derived secret, uses a passphrase-derived ULA for the collector, reports `apmond_protocol`, and (from r9) checks the protocol on the collector. mesh11sd reports are unsigned, and its `node_status` carries `mesh11sd_version` but no protocol field.

Standing rule: ApmonD and mesh11sd must stay inter-compatible, so they don't drift apart. mesh11sd can be updated as needed.

## Goal

A single implementation of AP monitoring (collection, transport, signing, storage, collector) in ApmonD, with mesh11sd supplying only the mesh-specific information it alone knows.

## Proposed approach, in three stages

### 1. Optional handoff

- If ApmonD is installed and enabled, mesh11sd skips its own AP data collection and sending, and leaves it to ApmonD.
- If ApmonD is not installed, mesh11sd behaves exactly as today. Nothing breaks for existing users.
- Detection could be as simple as `[ -x /usr/sbin/apmond ] && /etc/init.d/apmond enabled`.

### 2. Mesh data through a hook

mesh11sd knows things ApmonD does not, such as portal or node role, mesh peers and mesh-specific link data.

- mesh11sd writes this to a small JSON file in the runtime directory, for example `/tmp/run/mesh11sd/apmond_mesh.json`, each time it updates its state.
- ApmonD, if the file exists, adds it to each report as an extra block, for example `"mesh@<mac>": { ... }`.
- Mesh logic stays in mesh11sd, while transport, signing and storage stay in ApmonD.
- The file lives in `/tmp/run`, so it is cleared on reboot, which matches the ApmonD rule that runtime state never goes to log_mountpoint.
- A version field in the hook file (for example `"mesh_hook_version": "1"`) lets either side change independently.

### 3. Remove the duplicate

- Once the handoff is proven, mesh11sd's built-in apmon code can be removed and ApmonD made a dependency (or a recommended package).
- This resolves the compatibility problem for good, because there is then only one implementation.

## Interim compatibility (before stage 1)

For a mixed network, where some nodes run mesh11sd's built-in apmon and some run ApmonD:

1. **Protocol field.** mesh11sd adds `"apmond_protocol": "1"` to the `node_status` block it sends, and the same comparison in its collector. ApmonD r9 already treats a report that has `mesh11sd_version` and no protocol field as protocol 1, with a single debug note per node and no warning.
2. **Signing (the real gap).** mesh11sd reports are unsigned, and the ApmonD collector rejects unsigned reports before the protocol check runs. So a mesh11sd node cannot currently report to an ApmonD collector. Options:
   - mesh11sd adopts ApmonD's signing (same passphrase-derived secret, same signature format), or
   - the ApmonD collector gets an opt-in option to accept unsigned reports (off by default, with a stern warning like the default-passphrase one), or
   - skip interim compatibility and go straight to stage 1.

## Topologies to consider

mesh11sd supports more than a simple mesh:

- **Island mesh**: a mesh segment out of radio range of the main mesh, joined to it by cable.
- **Cabled AP groups**: groups of wired APs hanging off any mesh node.

Implications:

- Mixed versions can appear anywhere, so the protocol check must warn rather than reject, which is what r9 does.
- Each island, or cabled group, must still reach the one collector ULA over the bridge. Role detection (router or collector, versus AP) must cope with several cabled paths and must not let an island elect its own collector unless that is intended.
- Wired clients may be seen through several bridges. `bridge` is already a UCI list in ApmonD, and from r14 the default (unset or `'auto'`) scans every non-WAN bridge, as mesh11sd's `get_ethernet_clients` already does (all bridges from `brctl show`, ports from UCI, `vxlan` ports skipped).
- Speed reporting must work on both swconfig and DSA switches. ApmonD r5 handles swconfig VLAN ports, and mesh11sd still needs the same fix.

## Open questions

1. Should ApmonD be a hard dependency of mesh11sd eventually, or stay optional?
2. Which mesh fields belong in the hook file?
3. Should the collector UI or CLI show mesh topology (islands, cabled groups) built from the hook data?
4. Accept unsigned mesh11sd reports at all, or require signing?
5. Bump `apmond_protocol` to 2 when the mesh block is added?
