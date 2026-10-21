#!/bin/sh
# Mock end to end test for apmond, run on a Linux host with busybox installed (and sudo for the bridges).
#  - every tool resolves to a busybox applet, or a mock for uci/iw/ubus/logger/ip
#  - two simulated nodes with IDENTICAL /etc/config/apmond:
#      R: wan up with a gateway neighbour -> detected router, takes <ula>::1, is the collector
#      C: no wan gateway -> peer, sends to <ula>::1
#  - the collector is busybox httpd running the packaged apmon.cgi, listening on the router's ::1
#    (the test adds that address to lo with sudo; apmond's own ip calls go to the mock)
# Usage: sh tests/run-mock-test.sh

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d /tmp/apmond-test.XXXXXX)
PORT=${PORT:-18088}
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
ko() { echo "FAIL: $1"; fail=$((fail+1)); }

BB=$(command -v busybox); PY=$(command -v python3)
SUDO="sudo -n"
if ! $SUDO true 2>/dev/null; then echo "this test needs sudo (bridges, lo address)"; exit 1; fi
mkdir -p "$W/bb" "$W/mock" "$W/www/cgi-bin" "$W/uci-R" "$W/uci-C"
for a in busybox $(busybox --list); do ln -sf "$BB" "$W/bb/$a"; done
for m in uci iw ubus logger ip ping; do cp "$REPO/tests/mock-bin-$m" "$W/mock/$m"; done
JF=$(command -v jsonfilter || command -v jsonpath || true)
[ -n "$JF" ] && ln -sf "$JF" "$W/mock/jsonfilter"

# Two real bridges give two distinct node MACs; apmbr0 also gets a wired client
for b in apmbr0 apmbr1 apmbr2; do $SUDO ip link add $b type bridge 2>/dev/null; $SUDO ip link set $b up; done
$SUDO ip link add apmdum0 type veth peer name apmdum1 2>/dev/null
$SUDO ip link set apmdum0 master apmbr0; $SUDO ip link set apmdum0 up; $SUDO ip link set apmdum1 up
$SUDO bridge fdb add 02:aa:bb:cc:dd:01 dev apmdum0 master static 2>/dev/null
SPATH="$PATH"
export PATH="$W/mock:$W/bb"
export MOCK_LOG="$W/log" MOCK_NET="$W/net"

SEED="correct horse battery staple $(date +%s)"
for n in R C; do
	cat > "$W/uci-$n/apmond" <<EOC
apmond.setup=apmond
apmond.setup.apmon_seed='$SEED'
apmond.setup.claim_delay_max='1'
EOC
	cat > "$W/uci-$n/wireless" <<'EOC'
wireless.radio0=wifi-device
wireless.default_radio0=wifi-iface
wireless.default_radio0.mode='ap'
wireless.default_radio0.ssid='OpenWrt'
wireless.default_radio1=wifi-iface
wireless.default_radio1.mode='ap'
wireless.default_radio1.ssid='OpenWrt5'
wireless.guest=wifi-iface
wireless.guest.mode='ap'
wireless.guest.ssid='Guest'
wireless.off=wifi-iface
wireless.off.mode='ap'
wireless.off.ssid='Off'
wireless.off.disabled='1'
EOC
	echo "network.wan.device='wan-mock'" > "$W/uci-$n/network"
done
echo "system.@system[0].hostname='router1'" > "$W/uci-R/system"
echo "system.@system[0].hostname='ap1'" > "$W/uci-C/system"
# Only the device differs, and only because two nodes share one test host (real nodes all use the default br-lan)
echo "apmond.setup.device='apmbr1'" >> "$W/uci-R/apmond"
echo "apmond.setup.device='apmbr0'" >> "$W/uci-C/apmond"

node() { n=$1; shift; MOCK_NODE=$n MOCK_UCI_DIR="$W/uci-$n" MOCK_IP_DIR="$W/ip-$n" APMOND_TMPDIR="$W/tmp-$n" APMOND_TEST_SCHEME=http APMOND_TEST_PORT=$PORT busybox sh "$REPO/src/apmond" "$@"; }
R() { MOCK_WAN_UP=${WAN:-1} node R "$@"; }
C() { MOCK_WAN_UP=0 node C "$@"; }
S() { MOCK_WAN_UP=1 node S "$@"; }
st() { "$@" status | awk -v k="$KEY=" '{for (i=1;i<=NF;i++) if (index($i,k)==1) print substr($i,length(k)+1)}'; }
json_ok() { "$PY" -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }

echo "== syntax"
busybox sh -n "$REPO/src/apmond" && ok "busybox sh -n src/apmond" || ko "syntax"

echo "== 0. UCI layout and built-in default seed"
CF="$REPO/linux_openwrt/apmond/files/etc/config/apmond"
[ "$(grep -c '^config' "$CF")" -eq 1 ] && grep -qx "config apmond 'setup'" "$CF" && ok "shipped config has exactly one section: config apmond 'setup' (as config mesh11sd 'setup' / config opennds 'setup')" || ko "section layout"
[ -z "$(grep -o 'get_option [a-z_]*' "$REPO/src/apmond" | grep -v 'get_option setup' | grep -v 'get_option()')" ] && ! grep -q "apmond\.\(client\|server\|common\)" "$REPO/src/apmond" "$REPO/linux_openwrt/apmond/files/etc/init.d/apmond" && ok "code reads only apmond.setup.<option>" || ko "non setup options read"
[ "$(grep -c '^[[:space:]]*option' "$CF")" -eq 0 ] && grep -q "^[[:space:]]*#option apmon_seed" "$CF" && ok "shipped config: every option (incl. apmon_seed) commented out" || ko "shipped config"
mkdir -p "$W/uci-N"; echo "apmond.setup=apmond" > "$W/uci-N/apmond"; echo "network.wan.device='wan-mock'" > "$W/uci-N/network"
N() { MOCK_UCI_DIR="$W/uci-N" MOCK_IP_DIR="$W/ip-N" APMOND_TMPDIR="$W/tmp-N" busybox sh "$REPO/src/apmond" "$@"; }
: > "$W/log"
echo "apmond.setup.startup_delay='0'" >> "$W/uci-N/apmond"; echo "apmond.setup.claim_delay_max='0'" >> "$W/uci-N/apmond"; echo "apmond.setup.device='apmbr1'" >> "$W/uci-N/apmond"
echo "apmond.setup.default_seed_warn_interval='1'" >> "$W/uci-N/apmond"; echo "apmond.setup.interval='10'" >> "$W/uci-N/apmond"
MOCK_WAN_UP=0 busybox timeout 14 busybox sh -c "MOCK_UCI_DIR=$W/uci-N MOCK_IP_DIR=$W/ip-N APMOND_TMPDIR=$W/tmp-N busybox sh $REPO/src/apmond daemon" 2>/dev/null
nw=$(grep -c "daemon.crit \*\*\* WARNING \*\*\* apmond is using the DEFAULT" "$W/log")
[ "$nw" -ge 2 ] && ok "default seed: crit warning at daemon start and repeated periodically ($nw times in 14 s with a 1 s test interval)" || ko "default seed warnings ($nw)"
grep -q "daemon.crit .*READ and INJECT" "$W/log" && grep -q "daemon.crit .*option apmon_seed in /etc/config/apmond" "$W/log" && ok "warning explains the risk and how to set option apmon_seed" || ko "warning text"
grep -q "add fd" "$W/ip-N/log" 2>/dev/null && ok "default seed: daemon runs normally (ULA applied, report attempted)" || ko "default seed daemon did not run"
N status | grep -q "seed=DEFAULT .*INSECURE" && ok "status shows the default passphrase is in use" || ko "status default"
echo "apmond.setup.apmon_seed='--__'" >> "$W/uci-N/apmond"
N status | grep -q "seed=DEFAULT" && ok "seed explicitly set to the default is treated as default" || ko "explicit default"
: > "$W/log"; sed -i "s/apmon_seed='--__'/apmon_seed='private'/" "$W/uci-N/apmond"
N status | grep -q "seed=custom" && ok "custom seed: status shows custom" || ko "custom status"
N cleanup
R0=$(printf '%s' '--__' | busybox sha256sum | awk '{printf "%s", $1}' | tail -c55 | head -c30)
[ "$R0" = "$(MOCK_UCI_DIR="$W/uci-O0" MOCK_IP_DIR="$W/ip-O0" APMOND_TMPDIR="$W/tmp-O0" busybox sh "$REPO/src/apmond" status | awk '{for(i=1;i<=NF;i++) if (index($i,"apmon_id=")==1) print substr($i,10)}')" ] && ok "default seed is the mesh11sd auto_mesh_id default \"--__\"" || ko "default seed value"

echo "== 1. derivation from apmon_seed (mirrors mesh11sd auto_mesh_id / set_ula_prefix)"
REF=$("$PY" - "$SEED" <<'EOP'
import hashlib,sys
h=hashlib.sha256(sys.argv[1].encode()).hexdigest()
i=h[-55:][:30]                      # tail -c55 | head -c30
base="fd%s:%s:%s"%(i[9:11],i[11:15],i[15:19])
print(i, base+"::/48", i[19:23], base+":"+i[19:23]+"::1")
EOP
)
set -- $REF
KEY=apmon_id; a=$(st R); KEY=ula_prefix; p=$(st R); KEY=ula_subnet; sn=$(st R); KEY=collector; col=$(st C)
[ "$a" = "$1" ] && ok "apmon_id = sha256(seed) | tail -c55 | head -c30 ($a)" || ko "apmon_id $a != $1"
[ "$p" = "$2" ] && ok "ula_prefix = fd\${id:9:2}:\${id:11:4}:\${id:15:4}::/48 ($p)" || ko "ula_prefix $p != $2"
[ "$sn" = "$3" ] && ok "ula_subnet = \${id:19:4} ($sn)" || ko "subnet $sn != $3"
[ "$col" = "[$4]" ] && ok "peer collector address = $col" || ko "collector $col != [$4]"
RULA=$4
sed "s/apmon_seed='.*'/apmon_seed='another seed'/" "$W/uci-C/apmond" > "$W/other"; mkdir -p "$W/uci-O"; cp "$W/other" "$W/uci-O/apmond"
KEY=collector; o=$(MOCK_UCI_DIR="$W/uci-O" APMOND_TMPDIR="$W/tmp-O" busybox sh "$REPO/src/apmond" status | awk -F= '/collector=/ {print $2}' | cut -d' ' -f1)
[ "$o" != "[$RULA]" ] && ok "a different seed gives a different collector ULA ($o)" || ko "other seed same ULA"

echo "== 2. identical config on every node, role selected at runtime"
diff <(grep -v "\.device=" "$W/uci-R/apmond") <(grep -v "\.device=" "$W/uci-C/apmond") >/dev/null 2>&1 || true
[ "$(grep -v '\.device=' "$W/uci-R/apmond" | busybox md5sum)" = "$(grep -v '\.device=' "$W/uci-C/apmond" | busybox md5sum)" ] && ok "R and C /etc/config/apmond identical (apart from the test-only device)" || ko "configs differ"
r=$(R detect); c=$(C detect)
[ "$r" = "router" ] && ok "R (wan up, gateway neighbour) detected as router" || ko "R role $r"
[ "$c" = "peer" ] && ok "C (no wan gateway) detected as peer" || ko "C role $c"
grep -q "inet6 $RULA/64 " "$W/ip-R/addr_apmbr1" && ok "router took $RULA/64 at runtime (ip -6 addr add)" || ko "router ::1"
grep -q "::1/64" "$W/ip-C/addr_apmbr0" 2>/dev/null && ko "peer took ::1" || ok "peer did not take ::1"
CMAC=$(cat /sys/class/net/apmbr0/address); CIID=$(echo "$CMAC" | tr -d : | sed 's/^\(.\{6\}\)\(.\{6\}\)$/\1fffe\2/; s/\(....\)/\1:/g; s/:$//')
grep -q "inet6 ${RULA%::1}:$CIID/64 " "$W/ip-C/addr_apmbr0" && ok "peer took its EUI-64 node ULA ${RULA%::1}:$CIID" || ko "peer node ULA"
cat "$W/uci-C/apmond" > "$W/c.bak"; echo "apmond.setup.router_detect='0'" >> "$W/uci-C/apmond"
[ "$(C detect)" = "backed-off" ] && ok "router_detect=0 forces router candidate (backs off: R already holds ::1)" || ko "force router"
cp "$W/c.bak" "$W/uci-C/apmond"; [ "$(C detect)" = "peer" ] && ! grep -q "$RULA/64" "$W/ip-C/addr_apmbr0" && ok "back to auto: peer again and ::1 removed" || ko "demote C"
echo "apmond.setup.router_detect='2'" >> "$W/uci-R/apmond"
[ "$(R detect)" = "peer" ] && ok "router_detect=2 forces peer" || ko "force peer"
sed -i '/router_detect/d' "$W/uci-R/apmond"
[ "$(WAN=0 R detect)" = "peer" ] && ! grep -q "$RULA/64" "$W/ip-R/addr_apmbr1" && ok "router losing its wan gateway drops ::1" || ko "R demote"
[ "$(R detect)" = "router" ] || ko "R re-promote"

echo "== 2b. two routers: first come wins, back off, failover, DAD failure"
# S: a second node with an upstream gateway and the same config
mkdir -p "$W/uci-S"; cp "$W/uci-R/"* "$W/uci-S/"; sed -i "s/device='apmbr1'/device='apmbr2'/" "$W/uci-S/apmond"
echo "system.@system[0].hostname='router2'" > "$W/uci-S/system"
r=$(S detect)
[ "$r" = "backed-off" ] && ! grep -q "$RULA/64" "$W/ip-S/addr_apmbr2" && ok "second router S sees $RULA answering and backs off without claiming" || ko "S backoff: $r"
S status | grep -q "role=backed-off" && S status | grep -q "role_reason: .*already in use" && ok "status shows role=backed-off and why" || ko "S status"
grep -q "role change \[ none \] -> \[ backed-off \]" "$W/log" && ok "role change logged to syslog" || ko "role change log"
# Failover: R goes away
R cleanup
r1=$(S detect); r2=$(S detect)
[ "$r1" = "backed-off" ] && [ "$r2" = "backed-off" ] && S status | grep -q "not answering (2/3)" && ok "R gone: S waits (misses 1/3, 2/3)" || ko "S wait $r1 $r2"
r3=$(S detect)
[ "$r3" = "router" ] && grep -q "inet6 $RULA/64 " "$W/ip-S/addr_apmbr2" && ok "after 3 consecutive misses S re-runs detection and claims $RULA" || ko "S takeover $r3"
grep -q "re-running router detection" "$W/log" && grep -q "role change \[ backed-off \] -> \[ router \]" "$W/log" && ok "takeover logged" || ko "takeover log"
# R returns: first come wins, S keeps ::1
r=$(R detect)
[ "$r" = "backed-off" ] && grep -q "$RULA/64" "$W/ip-S/addr_apmbr2" && ok "R returns and backs off, S keeps $RULA" || ko "R return $r"
# DAD failure on claim: R cannot ping S (race), claims, DAD fails, drops and backs off
R cleanup
r=$(MOCK_PING_BLOCK=1 R detect)
[ "$r" = "backed-off" ] && ! grep -q "$RULA/64" "$W/ip-R/addr_apmbr1" && grep -q "add $RULA/64 apmbr1 dadfailed" "$W/ip-R/log" && ok "claim with DAD failure: address dropped, R backs off" || ko "DAD claim $r"
R status | grep -q "role_reason: DAD failed" && ok "status reason: DAD failed" || ko "DAD status"
# DAD failure after claiming (flag appears later on the holder)
sed -i "s#inet6 $RULA/64 scope global\$#inet6 $RULA/64 scope global dadfailed#" "$W/ip-S/addr_apmbr2"
r=$(S detect)
[ "$r" = "backed-off" ] && ! grep -q "$RULA/64" "$W/ip-S/addr_apmbr2" && ok "DAD failed after claiming: S drops $RULA and backs off" || ko "late DAD $r"
# Restore R as the collector for the end to end tests
S cleanup; R cleanup
[ "$(R detect)" = "router" ] && ok "R claims again once $RULA is free" || ko "R reclaim"
for f in R C; do ls "$W/uci-$f" | grep -qv -e apmond -e wireless -e network -e system && ko "unexpected uci file"; done
grep -E '^[[:space:]]*(echo .*\| *)?uci( -q)? +(set|commit|batch|add|add_list|del|delete|del_list|rename|revert)' "$REPO/src/apmond" "$REPO/linux_openwrt/apmond/files/etc/init.d/apmond" && ko "uci write in src/apmond" || ok "no uci set/batch/commit anywhere in src/apmond"

echo "== 3. end to end over the collector ULA"
PATH="$SPATH" $SUDO ip -6 addr add "$RULA/128" dev lo 2>/dev/null
sed "s#/usr/sbin/apmond#busybox sh $REPO/src/apmond#" "$REPO/linux_openwrt/apmond/files/www/cgi-bin/apmon.cgi" > "$W/www/cgi-bin/apmon.cgi.real"
cat > "$W/www/cgi-bin/apmon.cgi" <<EOC
#!/bin/sh
export PATH="$PATH" MOCK_UCI_DIR="$W/uci-R" MOCK_IP_DIR="$W/ip-R" APMOND_TMPDIR="$W/tmp-R" MOCK_LOG="$W/log"
. "$W/www/cgi-bin/apmon.cgi.real"
EOC
chmod 755 "$W/www/cgi-bin/apmon.cgi"
busybox httpd -f -p "[$RULA]:$PORT" -h "$W/www" & HTTPD=$!
sleep 1
raw() { busybox wget -q -O - -U "$1" "http://[$RULA]:$PORT/cgi-bin/apmon.cgi${2:+?$2}" 2>/dev/null; }
C send && ok "peer C sent its report to [$RULA]" || ko "C send"
R send && ok "router R sent its own report to itself" || ko "R send"
n=$(ls "$W/tmp-R/apmond_data" | wc -l)
[ "$n" -eq 2 ] && ok "collector holds 2 APs" || ko "collector holds $n APs"
CID=$(echo "$CMAC" | tr -d :)
R show_ap_data "$CID" > "$W/report.json"
json_ok < "$W/report.json" && ok "show_ap_data <mac> is valid JSON" || ko "show_ap_data JSON"
grep -q '"OpenWrt@phy0-ap0"' "$W/report.json" && grep -q '"OpenWrt5@phy1-ap0"' "$W/report.json" && ok "AP ifnames resolved without ifname in wireless config" || ko "ifname resolution"
grep -q -e '"Guest@' -e '"Off@' "$W/report.json" && ko "down/disabled ifaces included" || ok "down/disabled wifi-ifaces skipped"
grep -q '"apmdum0@apmbr0"' "$W/report.json" && grep -q '02:aa:bb:cc:dd:01' "$W/report.json" && ok "wired client found on bridge without any mesh interface" || ko "wired client scan"
R show_ap_data all > "$W/all.json"; json_ok < "$W/all.json" && [ "$(grep -c '"clients@' "$W/all.json")" -eq 2 ] && ok "show_ap_data all: valid JSON, 2 APs" || ko "show_ap_data all"
C show_ap_data | grep -q "$CID" && ko "peer stored data" || ok "peer stores nothing (reports only go to the router)"

echo "== 4. authentication"
. "$REPO/tests/sign.sh"
SECRET=$(printf '%s' "$SEED" | busybox sha256sum | cut -c1-64)
DMAC="$CMAC"
DATA=$(printf '{"x":1}' | busybox hexdump -v -e '1/1 "%02x"')
H=$(printf '%s' "$DATA" | busybox sha256sum | cut -c1-64)
before=$(busybox sha256sum < "$W/tmp-R/apmond_data/$CID")
TS=$(date +%s); SIG=$(sign "wrong-secret" "$DMAC" "$TS" "$H")
r=$(raw "apmond;evil;$DMAC;begin;0;$TS;$H;$SIG" "$DATA")
case "$r" in nack*signature*) ok "wrong secret rejected";; *) ko "wrong secret: $r";; esac
SIG=$(sign "$(printf '%s' 'another seed' | busybox sha256sum | cut -c1-64)" "$DMAC" "$TS" "$H")
r=$(raw "apmond;evil;$DMAC;begin;0;$TS;$H;$SIG" "$DATA")
case "$r" in nack*signature*) ok "secret derived from a different seed rejected";; *) ko "other seed: $r";; esac
[ -z "$(ls "$W/tmp-R/staging/")" ] && [ "$before" = "$(busybox sha256sum < "$W/tmp-R/apmond_data/$CID")" ] && ok "nothing buffered or stored" || ko "bad secret left data"
TS=$(( $(date +%s) - 1000 )); SIG=$(sign "$SECRET" "$DMAC" "$TS" "$H")
r=$(raw "apmond;stale;$DMAC;begin;0;$TS;$H;$SIG" "$DATA"); case "$r" in nack*Stale*) ok "stale timestamp rejected";; *) ko "stale: $r";; esac
TS=$(( $(date +%s) + 1000 )); SIG=$(sign "$SECRET" "$DMAC" "$TS" "$H")
r=$(raw "apmond;future;$DMAC;begin;0;$TS;$H;$SIG" "$DATA"); case "$r" in nack*Stale*) ok "future timestamp rejected";; *) ko "future: $r";; esac
sleep 1
TS=$(date +%s); SIG=$(sign "$SECRET" "$DMAC" "$TS" "$H")
r1=$(raw "apmond;cap;$DMAC;begin;0;$TS;$H;$SIG" "$DATA"); r2=$(raw "apmond;cap;$DMAC;end;${#DATA};$TS;$H;$SIG")
[ "$r1" = "*begin" ] && [ "$r2" = "*end" ] && ok "hand signed session with the derived secret accepted" || ko "hand signed: $r1 $r2"
r=$(raw "apmond;cap;$DMAC;begin;0;$TS;$H;$SIG" "$DATA"); case "$r" in nack*Replayed*) ok "replayed session rejected";; *) ko "replay: $r";; esac
sleep 1
TS=$(date +%s); SIG=$(sign "$SECRET" "$DMAC" "$TS" "$H")
EVIL=$(printf '{"x":2}' | busybox hexdump -v -e '1/1 "%02x"')
raw "apmond;evil;$DMAC;begin;0;$TS;$H;$SIG" "$EVIL" >/dev/null
r=$(raw "apmond;evil;$DMAC;end;${#EVIL};$TS;$H;$SIG"); case "$r" in nack*hash*) ok "tampered payload rejected at end";; *) ko "tamper: $r";; esac
r=$(raw "apmond;meshnode-1234;$DMAC;begin;0" "$DATA"); case "$r" in nack*) ok "unsigned mesh11sd style report rejected";; *) ko "unsigned: $r";; esac

echo "== 5. large report, chunked"
sleep 1
MOCK_STATIONS=150 C send; rc=$?
. "$W/tmp-C/last_send"
R show_ap_data "$CID" > "$W/big.json"
n=$(grep -c '"02:00:00:00:' "$W/big.json")
[ "$rc" -eq 0 ] && [ "$n" -eq 151 ] && json_ok < "$W/big.json" && ok "large report: $last_bytes hex chars in $(( (last_bytes + 2047) / 2048 )) chunks, 151 stations, valid JSON" || ko "large report rc=$rc stations=$n"

echo "== 5b. storage location (log_mountpoint, as mesh11sd)"
RID=$(cat /sys/class/net/apmbr1/address | tr -d :)
R status | grep -q "storage: log_mountpoint=/tmp, AP data in $W/tmp-R/apmond_data" && [ -f "$W/tmp-R/apmond_data/$CID" ] && ok "default: log_mountpoint=/tmp, store in /tmp/apmond/apmond_data (test override $W/tmp-R)" || ko "default storage"
mkdir -p "$W/usb"
PATH="$SPATH" $SUDO mount -t tmpfs -o "size=4m,uid=$(id -u),gid=$(id -g)" apmtest "$W/usb"
cp "$W/uci-R/apmond" "$W/r.bak"
echo "apmond.setup.log_mountpoint='$W/usb'" >> "$W/uci-R/apmond"
sleep 1
C send; R send
[ -f "$W/usb/apmond/apmond_data/$CID" ] && [ -f "$W/usb/apmond/apmond_data/$RID" ] && ok "custom mountpoint: CGI stores reports in <log_mountpoint>/apmond/apmond_data/<mac>" || ko "custom store"
R status | grep -q "storage: log_mountpoint=$W/usb, AP data in $W/usb/apmond/apmond_data" && ok "status shows the custom storage path" || ko "custom status"
R show_ap_data | grep -q "$CID" && R show_ap_data "$CID" | json_ok && ok "show_ap_data reads from the custom mountpoint" || ko "custom show"
PATH="$SPATH" $SUDO mount -o remount,ro "$W/usb"
R status | grep -q "WARNING: log_mountpoint \[ $W/usb \] is not writable - falling back to /tmp" && R status | grep -q "AP data in $W/tmp-R/apmond_data" && ok "mounted but read-only: falls back to /tmp with a warning" || ko "ro fallback"
PATH="$SPATH" $SUDO umount "$W/usb"
R status | grep -q "WARNING: log_mountpoint \[ $W/usb \] is not mounted - falling back to /tmp" && ok "media removed (not mounted): falls back to /tmp, as mesh11sd" || ko "unmounted fallback"
sed -i "s#log_mountpoint=.*#log_mountpoint='$W/does-not-exist'#" "$W/uci-R/apmond"
R status | grep -q "is not mounted - falling back to /tmp" && [ ! -d "$W/does-not-exist" ] && ok "missing mountpoint: falls back to /tmp, nothing created" || ko "missing fallback"
sleep 1; C send && [ -f "$W/tmp-R/apmond_data/$CID" ] && ok "reports still stored after fallback" || ko "store after fallback"
cp "$W/r.bak" "$W/uci-R/apmond"
grep -q "^[[:space:]]*#option log_mountpoint '/tmp'" "$REPO/linux_openwrt/apmond/files/etc/config/apmond" && ok "shipped config has a commented log_mountpoint example" || ko "config example"

echo "== 6. CLI and cleanup"
C version | grep -q "apmond version" && ok "version" || ko "version"
C status | grep -q "role=peer" && R status | grep -q "role=router" && ok "status shows role" || ko "status"
R show_ap_data | grep -q "$CID" && ok "show_ap_data list" || ko "list"
R cleanup; C cleanup
[ -z "$(grep inet6 "$W/ip-R/addr_apmbr1" "$W/ip-C/addr_apmbr0" 2>/dev/null)" ] && ok "cleanup removed every runtime ULA address" || ko "cleanup"

kill $HTTPD 2>/dev/null
PATH="$SPATH"
$SUDO ip -6 addr del "$RULA/128" dev lo 2>/dev/null
mountpoint -q "$W/usb" 2>/dev/null && $SUDO umount "$W/usb"
$SUDO ip link del apmdum0 2>/dev/null; $SUDO ip link del apmbr0 2>/dev/null; $SUDO ip link del apmbr1 2>/dev/null; $SUDO ip link del apmbr2 2>/dev/null
echo
echo "Result: $pass passed, $fail failed (work dir $W)"
[ "$fail" -eq 0 ]
