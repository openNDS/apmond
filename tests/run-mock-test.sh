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
n=0; for b in apmbr0 apmbr1 apmbr2; do $SUDO ip link add $b type bridge 2>/dev/null; $SUDO ip link set $b address 02:00:00:0a:00:0$n; $SUDO ip link set $b up; n=$((n+1)); done  # MACs with zero bytes exercise canonical IPv6 forms
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

node() { n=$1; shift; MOCK_NODE=$n MOCK_UCI_DIR="$W/uci-$n" MOCK_IP_DIR="$W/ip-$n" APMOND_TMPDIR="$W/run-$n" APMOND_TMP_DATADIR="$W/tmp-$n" APMOND_TEST_SCHEME=http APMOND_TEST_PORT=$PORT busybox sh "$REPO/src/apmond" "$@"; }
R() { MOCK_WAN_UP=${WAN:-1} node R "$@"; }
C() { MOCK_WAN_UP=0 node C "$@"; }
S() { MOCK_WAN_UP=1 node S "$@"; }
# status is JSON: jv KEY < status  prints apmond_status.KEY (lists space separated, objects as JSON)
jv() { "$PY" -c 'import json,sys
v=json.load(sys.stdin)["apmond_status"].get(sys.argv[1],"")
print(" ".join(v) if isinstance(v,list) else (json.dumps(v) if isinstance(v,dict) else v))' "$1"; }
st() { "$@" status | jv "$KEY"; }
json_ok() { "$PY" -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }

echo "== syntax"
busybox sh -n "$REPO/src/apmond" && ok "busybox sh -n src/apmond" || ko "syntax"

echo "== 0. UCI layout and built-in default seed"
CF="$REPO/linux_openwrt/apmond/files/etc/config/apmond"
[ "$(grep -c '^config' "$CF")" -eq 1 ] && grep -qx "config apmond 'setup'" "$CF" && ok "shipped config has exactly one section: config apmond 'setup' (as config mesh11sd 'setup' / config opennds 'setup')" || ko "section layout"
[ -z "$(grep -o 'get_option [a-z_]*' "$REPO/src/apmond" | grep -v 'get_option setup' | grep -v 'get_option()')" ] && ! grep -q "apmond\.\(client\|server\|common\)" "$REPO/src/apmond" "$REPO/linux_openwrt/apmond/files/etc/init.d/apmond" && ok "code reads only apmond.setup.<option>" || ko "non setup options read"
[ "$(grep -c '^[[:space:]]*option' "$CF")" -eq 0 ] && ok "shipped config: every option commented out" || ko "shipped config has active options"
! grep -q "option apmon_seed" "$CF" && ! grep -qi "apmon_seed[[:space:]]*['\"]" "$CF" && ! grep -q "apmon_seed=" "$CF" && ok "shipped config contains no passphrase (no apmon_seed value, active or commented)" || ko "shipped config contains a passphrase"
grep -q "DEFAULT passphrase" "$CF" && grep -q "add an apmon_seed option" "$CF" && ok "shipped config explains the default passphrase and how to set apmon_seed" || ko "config seed comment"
sed -n '/^ipv6_canon() {/,/^}/p' "$REPO/src/apmond" > "$W/canon.sh"
cv=$(busybox sh -c ". $W/canon.sh; ipv6_canon fd46:cfe5:34c5:6ddd:5254:00ff:fe12:3401/64; ipv6_canon fd46:0cfe:0000:6ddd::1/64; ipv6_canon fd46:0:0:1:0:0:0:1; ipv6_canon fd46:1:0:0:5254:0:0:1" | tr '\n' ' ')
[ "$cv" = "fd46:cfe5:34c5:6ddd:5254:ff:fe12:3401/64 fd46:cfe:0:6ddd::1/64 fd46:0:0:1::1 fd46:1::5254:0:0:1 " ] && ok "ipv6_canon gives the kernel (RFC 5952) form" || ko "ipv6_canon: $cv"
grep -q "INSTALL_DATA.*etc/config/apmond" "$REPO/linux_openwrt/Makefile" && ! grep -q "INSTALL_CONF" "$REPO/linux_openwrt/Makefile" && ok "Makefile installs /etc/config/apmond 0644 (INSTALL_DATA)" || ko "config install mode"
mkdir -p "$W/uci-N"; echo "apmond.setup=apmond" > "$W/uci-N/apmond"; echo "network.wan.device='wan-mock'" > "$W/uci-N/network"
N() { MOCK_UCI_DIR="$W/uci-N" MOCK_IP_DIR="$W/ip-N" APMOND_TMPDIR="$W/run-N" APMOND_TMP_DATADIR="$W/tmp-N" busybox sh "$REPO/src/apmond" "$@"; }
: > "$W/log"
echo "apmond.setup.startup_delay='0'" >> "$W/uci-N/apmond"; echo "apmond.setup.claim_delay_max='0'" >> "$W/uci-N/apmond"; echo "apmond.setup.device='apmbr1'" >> "$W/uci-N/apmond"
echo "apmond.setup.default_seed_warn_interval='1'" >> "$W/uci-N/apmond"; echo "apmond.setup.interval='10'" >> "$W/uci-N/apmond"
MOCK_WAN_UP=0 busybox timeout 14 busybox sh -c "MOCK_UCI_DIR=$W/uci-N MOCK_IP_DIR=$W/ip-N APMOND_TMPDIR=$W/run-N APMOND_TMP_DATADIR=$W/tmp-N busybox sh $REPO/src/apmond daemon" 2>/dev/null
nw=$(grep -c "daemon.crit .*\*\*\* WARNING \*\*\* apmond is using the DEFAULT" "$W/log")
[ "$nw" -ge 2 ] && ok "default seed: crit warning at daemon start and repeated periodically ($nw times in 14 s with a 1 s test interval)" || ko "default seed warnings ($nw)"
grep -q "daemon.crit .*READ and INJECT" "$W/log" && grep -q "daemon.crit .*option apmon_seed in /etc/config/apmond" "$W/log" && ok "warning explains the risk and how to set option apmon_seed" || ko "warning text"
[ "$(grep -c "daemon.crit apmond\[[0-9]*\]: \[[0-9]*\] \*\*\* WARNING \*\*\* apmond is using the DEFAULT" "$W/tmp-N/apmond_log.log")" -ge 2 ] && ok "default passphrase warning also written to the apmond log file" || ko "crit not in log file"
grep -q "add fd" "$W/ip-N/log" 2>/dev/null && ok "default seed: daemon runs normally (ULA applied, report attempted)" || ko "default seed daemon did not run"
[ "$(N status | jv default_passphrase)" = yes ] && N status | jv passphrase_warning | grep -q INSECURE && ok "status shows the default passphrase is in use" || ko "status default"
echo "apmond.setup.apmon_seed='--__'" >> "$W/uci-N/apmond"
[ "$(N status | jv default_passphrase)" = yes ] && ok "seed explicitly set to the default is treated as default" || ko "explicit default"
: > "$W/log"; sed -i "s/apmon_seed='--__'/apmon_seed='private'/" "$W/uci-N/apmond"
[ "$(N status | jv default_passphrase)" = no ] && ! N status | grep -q "private\|passphrase_warning" && ok "custom seed: status shows custom" || ko "custom status"
N cleanup
R0=$(printf '%s' '--__' | busybox sha256sum | awk '{printf "%s", $1}' | tail -c55 | head -c30)
R0P="fd$(echo "$R0" | cut -c10-11):$(echo "$R0" | cut -c12-15):$(echo "$R0" | cut -c16-19)::/48"
[ "$R0P" = "$(MOCK_UCI_DIR="$W/uci-O0" MOCK_IP_DIR="$W/ip-O0" APMOND_TMPDIR="$W/run-O0" APMOND_TMP_DATADIR="$W/tmp-O0" busybox sh "$REPO/src/apmond" status | jv ula_prefix)" ] && ok "default seed is the mesh11sd auto_mesh_id default \"--__\"" || ko "default seed value"

echo "== 1. derivation from apmon_seed (mirrors mesh11sd auto_mesh_id / set_ula_prefix)"
REF=$("$PY" - "$SEED" <<'EOP'
import hashlib,sys,ipaddress
h=hashlib.sha256(sys.argv[1].encode()).hexdigest()
i=h[-55:][:30]                      # tail -c55 | head -c30
base="fd%s:%s:%s"%(i[9:11],i[11:15],i[15:19])
print(i, base+"::/48", i[19:23], ipaddress.IPv6Address(base+":"+i[19:23]+"::1").compressed)   # kernel (RFC 5952) form
EOP
)
set -- $REF
KEY=ula_prefix; p=$(st R); KEY=ula_subnet; sn=$(st R); KEY=collector; col=$(st C)
! R status | grep -q "$1" && ! R status | grep -q "$(printf '%s' "$SEED" | busybox sha256sum | cut -c1-16)" && ! R status | grep -qF "$SEED" && ok "status JSON never shows the passphrase, the secret or apmon_id" || ko "status leaks seed/secret"
[ "$p" = "$2" ] && ok "ula_prefix = fd\${id:9:2}:\${id:11:4}:\${id:15:4}::/48 ($p)" || ko "ula_prefix $p != $2"
[ "$sn" = "$3" ] && ok "ula_subnet = \${id:19:4} ($sn)" || ko "subnet $sn != $3"
[ "$col" = "$4" ] && ok "peer collector address = $col" || ko "collector $col != [$4]"
RULA=$4
sed "s/apmon_seed='.*'/apmon_seed='another seed'/" "$W/uci-C/apmond" > "$W/other"; mkdir -p "$W/uci-O"; cp "$W/other" "$W/uci-O/apmond"
KEY=collector; o=$(MOCK_UCI_DIR="$W/uci-O" APMOND_TMPDIR="$W/run-O" APMOND_TMP_DATADIR="$W/tmp-O" busybox sh "$REPO/src/apmond" status | jv collector)
[ -n "$o" ] && [ "$o" != "$RULA" ] && ok "a different seed gives a different collector ULA ($o)" || ko "other seed same ULA"

echo "== 2. identical config on every node, role selected at runtime"
diff <(grep -v "\.device=" "$W/uci-R/apmond") <(grep -v "\.device=" "$W/uci-C/apmond") >/dev/null 2>&1 || true
[ "$(grep -v '\.device=' "$W/uci-R/apmond" | busybox md5sum)" = "$(grep -v '\.device=' "$W/uci-C/apmond" | busybox md5sum)" ] && ok "R and C /etc/config/apmond identical (apart from the test-only device)" || ko "configs differ"
r=$(R detect); c=$(C detect)
[ "$r" = "router" ] && ok "R (wan up, gateway neighbour) detected as router" || ko "R role $r"
[ "$c" = "peer" ] && ok "C (no wan gateway) detected as peer" || ko "C role $c"
grep -q "inet6 $RULA/64 " "$W/ip-R/addr_apmbr1" && ok "router took $RULA/64 at runtime (ip -6 addr add)" || ko "router ::1"
grep -q "::1/64" "$W/ip-C/addr_apmbr0" 2>/dev/null && ko "peer took ::1" || ok "peer did not take ::1"
CMAC=$(cat /sys/class/net/apmbr0/address); CIID=$(echo "$CMAC" | tr -d : | sed 's/^\(.\{6\}\)\(.\{6\}\)$/\1fffe\2/; s/\(....\)/\1:/g; s/:$//')
CNULA=$("$PY" -c "import ipaddress,sys; print(ipaddress.IPv6Address(sys.argv[1]).compressed)" "${RULA%::1}:$CIID")
grep -q "inet6 $CNULA/64 " "$W/ip-C/addr_apmbr0" && ok "peer took its EUI-64 node ULA $CNULA" || ko "peer node ULA $CNULA"
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
[ "$(S status | jv role)" = backed-off ] && S status | jv role_reason | grep -q "already in use" && ok "status shows role=backed-off and why" || ko "S status"
grep -q "role change \[ none \] -> \[ backed-off \]" "$W/log" && ok "role change logged to syslog" || ko "role change log"
# Failover: R goes away
R cleanup
r1=$(S detect); r2=$(S detect)
[ "$r1" = "backed-off" ] && [ "$r2" = "backed-off" ] && S status | jv role_reason | grep -q "not answering (2/3)" && ok "R gone: S waits (misses 1/3, 2/3)" || ko "S wait $r1 $r2"
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
R status | jv role_reason | grep -q "^DAD failed" && ok "status reason: DAD failed" || ko "DAD status"
# DAD failure after claiming (flag appears later on the holder)
sed -i "s#inet6 $RULA/64 scope global\$#inet6 $RULA/64 scope global dadfailed#" "$W/ip-S/addr_apmbr2"
r=$(S detect)
[ "$r" = "backed-off" ] && ! grep -q "$RULA/64" "$W/ip-S/addr_apmbr2" && ok "DAD failed after claiming: S drops $RULA and backs off" || ko "late DAD $r"
# Restore R as the collector for the end to end tests
S cleanup; R cleanup
[ "$(R detect)" = "router" ] && ok "R claims again once $RULA is free" || ko "R reclaim"
for f in R C; do ls "$W/uci-$f" | grep -qv -e apmond -e wireless -e network -e system && ko "unexpected uci file"; done
grep -E '^[[:space:]]*(echo .*\| *)?uci( -q)? +(set|commit|batch|add|add_list|del|delete|del_list|rename|revert)' "$REPO/src/apmond" "$REPO/linux_openwrt/apmond/files/etc/init.d/apmond" | grep -v 'uci set apmond.setup.debuglevel="$1" && uci commit apmond' && ko "uci write in src/apmond" || ok "no uci set/batch/commit in src/apmond except the debuglevel CLI"

echo "== 3. end to end over the collector ULA"
PATH="$SPATH" $SUDO ip -6 addr add "$RULA/128" dev lo 2>/dev/null
sed "s#/usr/sbin/apmond#busybox sh $REPO/src/apmond#" "$REPO/linux_openwrt/apmond/files/www/cgi-bin/apmon.cgi" > "$W/www/cgi-bin/apmon.cgi.real"
cat > "$W/www/cgi-bin/apmon.cgi" <<EOC
#!/bin/sh
export PATH="$PATH" MOCK_UCI_DIR="$W/uci-R" MOCK_IP_DIR="$W/ip-R" APMOND_TMPDIR="$W/run-R" APMOND_TMP_DATADIR="$W/tmp-R" MOCK_LOG="$W/log"
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
awk '/"apmdum0@apmbr0"/{f=1} f&&/"tx_bitrate"/{getline n; print n; exit}' "$W/report.json" | grep -qx '          "stats_scope": "port",' && ok "wired client: stats_scope \"port\" right after tx_bitrate" || ko "wired stats_scope placement"
awk '/"apmdum0@apmbr0"/{f=1} f&&/"stats_scope"/{getline n; print n; exit}' "$W/report.json" | grep -q '^          "timestamp": ' && ok "wired client: timestamp follows stats_scope" || ko "wired stats_scope before timestamp"
for k in rx_bytes tx_bytes rx_bitrate tx_bitrate timestamp date_time; do awk '/"apmdum0@apmbr0"/{f=1} f' "$W/report.json" | grep -q "\"$k\": " || { ko "wired key $k missing"; k=x; break; }; done; [ "$k" != x ] && ok "wired client: existing keys unchanged"
[ "$(awk '/@phy[0-9]-ap[0-9]"/{f=1} /@apmbr0"/{f=0} f' "$W/report.json" | grep -c stats_scope)" -eq 0 ] && ok "wireless stations carry no stats_scope" || ko "stats_scope on wireless"
JQ1=$(command -v jq || true); { [ -z "$JQ1" ] || { "$JQ1" . "$W/report.json" | cmp -s - "$W/report.json"; }; } && ok "show_ap_data with stats_scope byte-identical to jq ." || ko "report vs jq"
cp "$W/uci-C/apmond" "$W/cb.bak"; echo "apmond.setup.bridge='apmbr2' 'apmbr0'" >> "$W/uci-C/apmond"
[ "$(C status | jv bridges)" = "apmbr2 apmbr0" ] && ok "list bridge: status shows both bridges" || ko "list bridge status"
C send && R show_ap_data "$CID" | grep -q '"apmdum0@apmbr0"' && ok "list bridge: wired client still found on 2nd list bridge" || ko "list bridge wired scan"
cp "$W/cb.bak" "$W/uci-C/apmond"; echo "apmond.setup.bridge='apmbr0'" >> "$W/uci-C/apmond"
[ "$(C status | jv bridges)" = "apmbr0" ] && ok "legacy single option bridge still works" || ko "legacy option bridge"
cp "$W/cb.bak" "$W/uci-C/apmond"; [ "$(C status | jv bridges | awk '{print $1}')" = "apmbr0" ] && [ "$(C status | jv bridge_detect)" = "auto" ] && ! C status | jv bridges | grep -qw "apmbr1\|apmbr2" && ok "no list bridge: auto-detected, device first, member-less bridges skipped" || ko "bridge default $(C status | jv bridges)"
[ "$(C status | jv ula_addresses | "$PY" -c 'import json,sys; print(" ".join(json.load(sys.stdin)))')" = "apmbr0" ] && ok "auto bridges: ula_addresses still only on device" || ko "auto ula_addresses $(C status | jv ula_addresses)"
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
[ -z "$(ls "$W/run-R/staging/")" ] && [ "$before" = "$(busybox sha256sum < "$W/tmp-R/apmond_data/$CID")" ] && ok "nothing buffered or stored" || ko "bad secret left data"
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
. "$W/run-C/last_send"
R show_ap_data "$CID" > "$W/big.json"
n=$(grep -c '"02:00:00:00:' "$W/big.json")
[ "$rc" -eq 0 ] && [ "$n" -eq 151 ] && json_ok < "$W/big.json" && ok "large report: $last_bytes hex chars in $(( (last_bytes + 2047) / 2048 )) chunks, 151 stations, valid JSON" || ko "large report rc=$rc stations=$n"

echo "== 5b. storage location (log_mountpoint, as mesh11sd)"
RID=$(cat /sys/class/net/apmbr1/address | tr -d :)
[ "$(R status | jv log_mountpoint)" = /tmp ] && [ "$(R status | jv ap_data_dir)" = "$W/tmp-R/apmond_data" ] && [ -f "$W/tmp-R/apmond_data/$CID" ] && ok "default: log_mountpoint=/tmp, store in /tmp/apmond/apmond_data (test override $W/tmp-R)" || ko "default storage"
mkdir -p "$W/usb"
PATH="$SPATH" $SUDO mount -t tmpfs -o "size=4m,uid=$(id -u),gid=$(id -g)" apmtest "$W/usb"
cp "$W/uci-R/apmond" "$W/r.bak"
echo "apmond.setup.log_mountpoint='$W/usb'" >> "$W/uci-R/apmond"
sleep 1
C send; R send
[ -f "$W/usb/apmond/apmond_data/$CID" ] && [ -f "$W/usb/apmond/apmond_data/$RID" ] && ok "custom mountpoint: CGI stores reports in <log_mountpoint>/apmond/apmond_data/<mac>" || ko "custom store"
[ "$(R status | jv log_mountpoint)" = "$W/usb" ] && [ "$(R status | jv ap_data_dir)" = "$W/usb/apmond/apmond_data" ] && ok "status shows the custom storage path" || ko "custom status"
R show_ap_data | grep -q "$CID" && R show_ap_data "$CID" | json_ok && ok "show_ap_data reads from the custom mountpoint" || ko "custom show"
PATH="$SPATH" $SUDO mount -o remount,ro "$W/usb"
R status | jv storage_warning | grep -q "log_mountpoint \[ $W/usb \] is not writable - falling back to /tmp" && [ "$(R status | jv ap_data_dir)" = "$W/tmp-R/apmond_data" ] && ok "mounted but read-only: falls back to /tmp with a warning" || ko "ro fallback"
PATH="$SPATH" $SUDO umount "$W/usb"
R status | jv storage_warning | grep -q "log_mountpoint \[ $W/usb \] is not mounted - falling back to /tmp" && ok "media removed (not mounted): falls back to /tmp, as mesh11sd" || ko "unmounted fallback"
sed -i "s#log_mountpoint=.*#log_mountpoint='$W/does-not-exist'#" "$W/uci-R/apmond"
R status | jv storage_warning | grep -q "is not mounted - falling back to /tmp" && [ ! -d "$W/does-not-exist" ] && ok "missing mountpoint: falls back to /tmp, nothing created" || ko "missing fallback"
sleep 1; C send && [ -f "$W/tmp-R/apmond_data/$CID" ] && ok "reports still stored after fallback" || ko "store after fallback"
cp "$W/r.bak" "$W/uci-R/apmond"
grep -q "^[[:space:]]*#option log_mountpoint '/tmp'" "$REPO/linux_openwrt/apmond/files/etc/config/apmond" && ok "shipped config has a commented log_mountpoint example" || ko "config example"

echo "== 5c. runtime state in the volatile run directory"
[ -f "$W/run-R/role" ] && [ -f "$W/run-R/ula_addrs" ] && [ -f "$W/run-C/last_send" ] && [ -d "$W/run-R/staging" ] && [ -d "$W/run-R/last_ts" ] && ok "role, ULA list, last_send, staging/, last_ts/ in the run dir" || ko "run dir contents"
[ ! -e "$W/tmp-R/role" ] && [ ! -e "$W/tmp-R/staging" ] && [ ! -e "$W/tmp-R/last_ts" ] && [ ! -e "$W/tmp-R/ula_addrs" ] && ok "data dir holds only apmond_data/" || ko "state in data dir: $(ls "$W/tmp-R")"
grep -q 'tmpdir="${APMOND_TMPDIR:-/var/run/apmond}"' "$REPO/src/apmond" && grep -q "mkdir -p /var/run/apmond" "$REPO/linux_openwrt/apmond/files/etc/init.d/apmond" && ok "default run dir /var/run/apmond, created at start" || ko "run dir default"
[ "$(R status | jv runtime_dir)" = "$W/run-R" ] && ok "status shows the run dir" || ko "status run dir"
[ -z "$(ls -A "$W/tmp-R/apmond_data" | grep '^\.')" ] && ok "no temp or partial files left in apmond_data" || ko "temp files in apmond_data"
grep -q '> "$datadir/apmond_data/.$node_mac.tmp" && mv "$datadir/apmond_data/.$node_mac.tmp" "$datadir/apmond_data/$node_mac"' "$REPO/src/apmond" && ok "verified report written to a temp file inside apmond_data, then renamed (atomic for readers)" || ko "atomic write"
# A half-received report leaves nothing in apmond_data, only in the run dir staging
. "$REPO/tests/sign.sh"; sleep 1
TS=$(date +%s); D2=$(printf '{"half":1}' | busybox hexdump -v -e '1/1 "%02x"'); H2=$(printf '%s' "$D2" | busybox sha256sum | cut -c1-64)
before=$(busybox sha256sum < "$W/tmp-R/apmond_data/$CID")
raw "apmond;half;$CMAC;begin;0;$TS;$H2;$(sign "$SECRET" "$CMAC" "$TS" "$H2")" "$D2" >/dev/null
[ -f "$W/run-R/staging/$CID.data" ] && [ "$before" = "$(busybox sha256sum < "$W/tmp-R/apmond_data/$CID")" ] && ok "half-received report: staged in the run dir only, stored report untouched" || ko "half report"

echo "== 5d. logging (mesh11sd write_to_syslog / write_log / read_log)"
LF="$W/tmp-R/apmond_log.log"
[ -f "$LF" ] && head -n 1 "$LF" | grep -q "New log file created" && ok "log file <log_mountpoint>/apmond/apmond_log.log created by the CGI, first line 'New log file created'" || ko "log file"
grep -q "^.* daemon\.warn apmond\[[0-9]*\]: \[[0-9]*\] apmond - Bad signature" "$LF" && ok "line format: '<date> daemon.<level> apmond[pid]: [n] message'" || ko "log line format"
! grep -q "Bad signature" "$W/log" && ok "warn level messages go to the log file only, not syslog" || ko "warn reached syslog"
grep -q "role change" "$LF" && grep -q "daemon.notice.*role change" "$W/log" && ok "notice (router role changes) go to syslog AND the log file" || ko "notice split"
[ "$(R status | jv log_file)" = "$LF" ] && ok "status shows the log path" || ko "status log path"
[ "$(R read_log | busybox md5sum)" = "$(busybox md5sum < "$LF")" ] && ok "read_log prints the log file (CLI resolves the same path as the CGI)" || ko "read_log"
MOCK_UCI_DIR="$W/uci-O0" MOCK_IP_DIR="$W/ip-O0" APMOND_TMPDIR="$W/run-O0" APMOND_TMP_DATADIR="$W/empty-O0" busybox sh "$REPO/src/apmond" read_log; [ $? -eq 1 ] && ok "read_log with no log file exits 1" || ko "read_log no file"
cp "$LF" "$W/lf.bak"
busybox timeout 3 busybox sh -c "MOCK_UCI_DIR=$W/uci-R MOCK_IP_DIR=$W/ip-R APMOND_TMPDIR=$W/run-R APMOND_TMP_DATADIR=$W/tmp-R busybox sh $REPO/src/apmond read_log -f" > "$W/follow.out" 2>/dev/null & FPID=$!
sleep 1; raw "apmond;x;$CMAC;begin;0;1;$(printf %064d 0);$(printf %064d 0)" "00" >/dev/null; sleep 1; wait $FPID
grep -q "New log file created" "$W/follow.out" && grep -q "Stale timestamp\|Bad signature" "$W/follow.out" && [ "$(grep -c "New log file created" "$LF")" -le 1 ] && ! grep -q "Bad signature from \[ evil" "$LF" && ok "read_log -f prints, deletes the old log and follows new entries" || ko "read_log -f"
# Same path for daemon, CGI and CLI on a custom mount, and the free space check
mkdir -p "$W/small"; PATH="$SPATH" $SUDO mount -t tmpfs -o "size=96k,uid=$(id -u),gid=$(id -g)" apmsmall "$W/small"
cp "$W/uci-R/apmond" "$W/r2.bak"; echo "apmond.setup.log_mountpoint='$W/small'" >> "$W/uci-R/apmond"
raw "apmond;evil2;$CMAC;begin;0;1;$(printf %064d 0);$(printf %064d 0)" "00" >/dev/null
[ "$(R status | jv log_file)" = "$W/small/apmond/apmond_log.log" ] && grep -q "evil2\|Stale\|signature" "$W/small/apmond/apmond_log.log" && ok "custom mount: CGI and CLI use <log_mountpoint>/apmond/apmond_log.log" || ko "custom mount log"
busybox dd if=/dev/zero of="$W/small/fill" bs=1k count=200 2>/dev/null
avail=$(busybox df "$W/small" | awk 'NR>1 {print $(NF-2)}')
: > "$W/log"; sz=$(wc -c < "$W/small/apmond/apmond_log.log")
raw "apmond;evil3;$CMAC;begin;0;1;$(printf %064d 0);$(printf %064d 0)" "00" >/dev/null
grep -q "daemon.err.*Log file too big, please archive contents and reduce max_log_entries" "$W/log" && [ "$sz" -eq "$(wc -c < "$W/small/apmond/apmond_log.log")" ] && ok "free space ${avail} KB <= 10 KB: entry refused, 'Log file too big' to syslog" || ko "free space refusal (avail $avail)"
PATH="$SPATH" $SUDO umount "$W/small"
# Not a mountpoint: data falls back to /tmp, file logging disabled (as mesh11sd)
sed -i "s#log_mountpoint=.*#log_mountpoint='$W/not-mounted'#" "$W/uci-R/apmond"
: > "$W/log"; before=$(wc -l < "$LF")
raw "apmond;evil4;$CMAC;begin;0;1;$(printf %064d 0);$(printf %064d 0)" "00" >/dev/null
[ "$(grep -c "daemon.err.*Log location is NOT a mountpoint - logs would fill storage space - logging disabled" "$W/log")" -eq 1 ] && [ "$before" -eq "$(wc -l < "$LF")" ] && ok "not a mountpoint: 'logging disabled' to syslog once, nothing written to the file" || ko "not a mountpoint"
R status | jv logging | grep -q "DISABLED: Log location is NOT a mountpoint" && ok "status shows logging disabled" || ko "status disabled"
cp "$W/r2.bak" "$W/uci-R/apmond"
# max_log_entries truncation
echo "apmond.setup.max_log_entries='5'" >> "$W/uci-R/apmond"
for i in 1 2 3 4 5 6 7 8; do raw "apmond;t$i;$CMAC;begin;0;1;$(printf %064d 0);$(printf %064d 0)" "00" >/dev/null; done
[ "$(wc -l < "$LF")" -le 6 ] && ok "max_log_entries: log truncated to the last N lines" || ko "truncation $(wc -l < "$LF")"
cp "$W/r2.bak" "$W/uci-R/apmond"

echo "== 6. CLI and cleanup"
C version | grep -q "apmond version" && ok "version" || ko "version"
[ "$(C status | jv role)" = peer ] && [ "$(R status | jv role)" = router ] && ok "status shows role" || ko "status"
R status | "$PY" -m json.tool >/dev/null && C status | "$PY" -m json.tool >/dev/null && ok "status output is valid JSON (python json.tool)" || ko "status not JSON"
{ [ -z "$JF" ] || [ "$(R status | jsonfilter -e '@.apmond_status.role')" = router ]; } && ok "status JSON readable with jsonfilter (if present)" || ko "jsonfilter status"
R detect >/dev/null; R status | jv ula_addresses | grep -q "$RULA/64" && ok "status lists the ULA addresses on the bridges (collector ::1 on R)" || ko "status ula_addresses $(R status | jv ula_addresses)"
R status | grep -q '^    "apmond_version": ' && R status | grep -q '^  "apmond_status": {' && ok "status uses the node_status style (2-space indent, string keys)" || ko "status style"
[ "$(R status | jv daemon_running)" = no ] && [ "$(R status | jv daemon_pid)" = none ] && ok "status: daemon not running -> daemon_running no, pid none" || ko "daemon_running"
R show_ap_data | grep -q "$CID" && ok "show_ap_data list" || ko "list"
R cleanup; C cleanup
[ -z "$(grep inet6 "$W/ip-R/addr_apmbr1" "$W/ip-C/addr_apmbr0" 2>/dev/null)" ] && ok "cleanup removed every runtime ULA address" || ko "cleanup"
! grep -h "failed to add ULA" "$W"/*log* "$W"/*/apmond/apmond_log.log 2>/dev/null | grep -q . && ok "no 'failed to add ULA address' errors when re-checking addresses (kernel prints canonical form)" || ko "ULA re-add errors: $(grep -rh "failed to add ULA" "$W" 2>/dev/null | head -2)"

echo "== 7. Wired link speed (sysfs / swconfig VLAN / unknown)"
SW="$W/swmock"; mkdir -p "$SW/bin" "$SW/net/eth0.1" "$SW/net/eth9"
awk '/^swconfig_vlan_speed\(\) \{/,/^}/; /^get_link_speed\(\) \{/,/^}/' "$REPO/src/apmond" > "$SW/fns.sh"
cat > "$SW/bin/swconfig" <<'EOS'
#!/bin/sh
case "$*" in
	list) echo "Found: switch0 - mt7628";;
	"dev switch0 vlan 1 get ports") echo "$SW_V1";;
	"dev switch0 port 0 get link") echo "$SW_P0";;
	"dev switch0 port 1 get link") echo "$SW_P1";;
	"dev switch0 port 2 get link") echo "$SW_P2";;
	"dev switch0 get arl_table") echo 'Unknown attribute "arl_table"'; exit 1;;
	*) exit 1;;
esac
EOS
chmod +x "$SW/bin/swconfig"
echo up > "$SW/net/eth0.1/operstate"; echo down > "$SW/net/eth9/operstate"
spd() { busybox env PATH="$SW/${3:-bin}:$W/bb" APMOND_SYSFS_NET="$SW/net" SW_V1="$1" SW_P0='port:0 link:up speed:1000baseT full-duplex' SW_P1="$2" SW_P2='port:2 link:down' busybox sh -c ". '$SW/fns.sh'; get_link_speed eth0.1"; }
[ "$(spd '1 6t' 'port:1 link:up speed:100baseT full-duplex')" = "100" ] && ok "swconfig: single untagged port up -> 100 (CPU 6t dropped)" || ko "swconfig single $(spd '1 6t' 'port:1 link:up speed:100baseT full-duplex')"
[ "$(spd '1 6t' 'port:1 link:down')" = "down" ] && ok "swconfig: single port link down -> down" || ko "swconfig down"
[ "$(spd '0 1 2 6t' 'port:1 link:up speed:100baseT full-duplex')" = "1000/100" ] && ok "swconfig: several ports -> up speeds joined (1000/100)" || ko "swconfig multi $(spd '0 1 2 6t' 'port:1 link:up speed:100baseT full-duplex')"
[ "$(spd '2 6t' x)" = "down" ] && ok "swconfig: no port up -> down" || ko "swconfig none up"
[ "$(spd '1 6t' x nobin)" = "unknown" ] && ok "no swconfig, VLAN up -> unknown (not down)" || ko "no swconfig $(spd '1 6t' x nobin)"
echo 100 > "$SW/net/eth0.1/speed"; [ "$(spd '1 6t' 'port:1 link:down')" = "100" ] && ok "sysfs speed wins when present" || ko "sysfs speed"
echo -1 > "$SW/net/eth0.1/speed"; [ "$(spd '1 6t' 'port:1 link:up speed:100baseT full-duplex')" = "100" ] && ok "sysfs -1 falls back to swconfig" || ko "sysfs -1"
[ "$(busybox env PATH="$W/bb" APMOND_SYSFS_NET="$SW/net" busybox sh -c ". '$SW/fns.sh'; get_link_speed eth9")" = "down" ] && ok "non-VLAN, operstate down -> down" || ko "operstate down"

echo "== 8. debuglevel CLI (committed at once) and live pickup by the daemon"
mkdir -p "$W/uci-D"; cp "$W/uci-N/apmond" "$W/uci-D/apmond"; cp "$W/uci-N/network" "$W/uci-D/network"
D() { MOCK_UCI_DIR="$W/uci-D" MOCK_IP_DIR="$W/ip-D" APMOND_TMPDIR="$W/run-D" APMOND_TMP_DATADIR="$W/tmp-D" busybox sh "$REPO/src/apmond" "$@"; }
[ "$(D debuglevel)" = "1" ] && ok "debuglevel: no argument shows the default 1" || ko "debuglevel default $(D debuglevel)"
dl_ok=1; for l in 0 1 2 3; do
	[ "$(D debuglevel $l)" = "$l" ] && [ "$(MOCK_UCI_DIR="$W/uci-D" uci -q get apmond.setup.debuglevel)" = "$l" ] && grep -q "^apmond.setup.debuglevel='$l'$" "$W/uci-D/apmond" && [ -z "$(MOCK_UCI_DIR="$W/uci-D" uci changes apmond)" ] && [ "$(D debuglevel)" = "$l" ] || dl_ok=0
done
[ $dl_ok -eq 1 ] && ok "debuglevel 0-3: set, printed, committed (no pending uci changes), shown back" || ko "debuglevel set/commit"
dl_ok=1; for l in 4 -1 abc; do o=$(D debuglevel "$l"); r=$?; [ "$o" = "Invalid debuglevel requested" ] && [ $r -eq 1 ] || dl_ok=0; done
[ $dl_ok -eq 1 ] && [ "$(D debuglevel)" = "3" ] && ok "debuglevel 4/-1/abc rejected with exit 1, level unchanged" || ko "debuglevel invalid"
[ "$(D status | jv debuglevel)" = "3" ] && D status | "$PY" -m json.tool >/dev/null && ok "status JSON includes debuglevel" || ko "status debuglevel"
D debuglevel 1 >/dev/null; : > "$W/log"
MOCK_WAN_UP=0 busybox timeout 16 busybox sh -c "MOCK_UCI_DIR=$W/uci-D MOCK_IP_DIR=$W/ip-D APMOND_TMPDIR=$W/run-D APMOND_TMP_DATADIR=$W/tmp-D busybox sh $REPO/src/apmond daemon" 2>/dev/null & DPID=$!
sleep 3; D debuglevel 3 >/dev/null; wait $DPID
grep -q "debuglevel changed to \[ 3 \]" "$W/log" "$W/tmp-D/apmond_log.log" 2>/dev/null && grep -q "daemon.debug" "$W/tmp-D/apmond_log.log" 2>/dev/null && ok "running daemon picks up the new debuglevel on its next loop pass (debug entries appear, no restart)" || ko "live debuglevel pickup"

echo "== 9. Collector checks apmond_protocol"
PT="$W/proto"; mkdir -p "$PT/run"
awk '/^check_node_protocol\(\) \{/,/^}/' "$REPO/src/apmond" > "$PT/fns.sh"
hx() { printf '%s' "$1" | busybox hexdump -v -e '1/1 "%02x"'; }
rep() { hx "{ \"System@02:00:00:0a:00:09\": { \"node_status\": { \"apmond_version\": \"0.1.0\",$1 \"factory_mac\": \"x\" } } }" > "$PT/rep"; }
chk() { busybox env PATH="$W/bb" busybox sh -c "tmpdir='$PT/run'; protocol_version=1
log_error() { echo \"ERR \$1\" >> '$PT/log'; }; log_notice() { echo \"NOTICE \$1\" >> '$PT/log'; }; log_debug() { echo \"DEBUG \$1\" >> '$PT/log'; }
. '$PT/fns.sh'; check_node_protocol 020000aa0009 '$PT/rep'"; }
: > "$PT/log"; rep ' "apmond_protocol": "1",'; chk; [ ! -s "$PT/log" ] && [ ! -f "$PT/run/protocol_mismatch/020000aa0009" ] && ok "protocol match: nothing logged, no mismatch state" || ko "protocol match $(cat "$PT/log")"
rep ' "apmond_protocol": "2",'; chk; chk; chk
[ "$(grep -c "^ERR apmond - WARNING node \[ 020000aa0009 \] protocol \[ 2 \] differs from collector protocol \[ 1 \] - upgrade apmond on all nodes" "$PT/log")" -eq 1 ] && [ "$(cat "$PT/run/protocol_mismatch/020000aa0009")" = 2 ] && ok "protocol mismatch: err (syslog + file) logged once only for 3 reports" || ko "protocol mismatch $(cat "$PT/log")"
: > "$PT/log"; rep ''; chk; chk
[ "$(grep -c "^ERR .*node \[ 020000aa0009 \] sent no apmond_protocol (protocol 0/unknown)" "$PT/log")" -eq 1 ] && ok "missing apmond_protocol: treated as 0/unknown, warned once" || ko "protocol missing $(cat "$PT/log")"
chkm() { rm -f "$PT/run/protocol_mismatch/020000aa0009"; hx '{ "System@x": { "node_status": { "mesh11sd_version": "7.3.1", "factory_mac": "x" } } }' > "$PT/rep"; chk; }
cp "$PT/log" "$PT/log.keep"; : > "$PT/log"; chkm; chkm
[ "$(grep -c "^DEBUG .*mesh11sd node (no apmond_protocol), treated as protocol \[ 1 \]" "$PT/log")" -eq 1 ] && ! grep -q "^ERR" "$PT/log" && [ ! -f "$PT/run/protocol_mismatch/020000aa0009" ] && ok "mesh11sd-format report (mesh11sd_version, no apmond_protocol): compatible protocol 1, one debug note, no warning" || ko "mesh11sd report $(cat "$PT/log")"
cp "$PT/log.keep" "$PT/log"; rep ''; chk
: > "$PT/log"; rep ' "apmond_protocol": "1",'; chk; chk
[ "$(grep -c "^NOTICE .*node \[ 020000aa0009 \] protocol \[ 1 \] now matches collector protocol \[ 1 \]" "$PT/log")" -eq 1 ] && [ ! -f "$PT/run/protocol_mismatch/020000aa0009" ] && ok "back in line: notice logged once, mismatch state cleared" || ko "protocol back in line $(cat "$PT/log")"
[ -z "$(ls "$W/run-R/protocol_mismatch" 2>/dev/null)" ] && ! grep -q "differs from collector protocol" "$W/log" && ok "end to end: same-protocol reports from R and C raise no mismatch" || ko "e2e protocol"
R status | grep -q '^    "protocol_mismatch_nodes": \[\]$'  && mkdir -p "$W/run-R/protocol_mismatch" && echo 2 > "$W/run-R/protocol_mismatch/020000aa0009" && R status | grep -A2 '^    "protocol_mismatch_nodes": \[$' | tr -d '\n' | grep -q '^    "protocol_mismatch_nodes": \[      "020000aa0009"    \]$' && R status | "$PY" -m json.tool >/dev/null && ok "status: protocol_mismatch_nodes JSON array" || ko "status protocol_mismatch_nodes $(R status | jv protocol_mismatch_nodes)"
rm -rf "$W/run-R/protocol_mismatch"

echo "== 10. Log entry numbers: daemon counter shared with subshells"
D debuglevel 3 >/dev/null; rm -rf "$W/tmp-D" "$W/run-D"; : > "$W/log"
MOCK_WAN_UP=0 busybox timeout 14 busybox sh -c "MOCK_UCI_DIR=$W/uci-D MOCK_IP_DIR=$W/ip-D APMOND_TMPDIR=$W/run-D APMOND_TMP_DATADIR=$W/tmp-D busybox sh $REPO/src/apmond daemon" 2>/dev/null
nums=$(sed -n 's/.* apmond\[[0-9]*\]: \[\([0-9]*\)\] .*/\1/p' "$W/tmp-D/apmond_log.log")
n=$(echo "$nums" | wc -l)
echo "$nums" | awk 'NR==1 && $1!=1 {bad=1} NR>1 && $1<=p {bad=1} {p=$1} END {exit bad}' && [ "$n" -ge 8 ] && grep -q "factory MAC\|Factory MAC" "$W/tmp-D/apmond_log.log" && grep -q "connecting to server" "$W/tmp-D/apmond_log.log" && ok "daemon log entry numbers start at [1], strictly increasing, no duplicates across startup + first send ($n entries)" || ko "entry numbers: $(echo $nums)"
[ ! -f "$W/run-D/entrynum" ] && ok "shared counter file removed when the daemon stops" || ko "entrynum file left"
grep -q 'factory_mac=$(get_factory_mac)\|labelmac=$(get_factory_mac)' "$REPO/src/apmond" && ko "get_factory_mac still called in a subshell" || ok "get_factory_mac sets a global, not called in \$(...)"
: > "$W/tmp-D/apmond_log.log"; D send >/dev/null 2>&1; cn=$(sed -n 's/.* apmond\[[0-9]*\]: \[\([0-9]*\)\] .*/\1/p' "$W/tmp-D/apmond_log.log")
echo "$cn" | awk 'NR==1 && $1!=1 {bad=1} NR>1 && $1<=p {bad=1} {p=$1} END {exit bad}' && [ -n "$cn" ] && [ -z "$(ls "$W/run-D" | grep entrynum)" ] && ok "CLI has its own counter: starts at [1], no duplicates from subshells, per-process file removed on exit" || ko "CLI counter: $(echo $cn) $(ls "$W/run-D")"
D debuglevel 1 >/dev/null

echo "== 11. Script checksum (as mesh11sd checksum / mesh11sd_checksum)"
SUM=$(sha256sum "$REPO/src/apmond" | awk '{print $1}')
[ "$(R status | jv checksum)" = "$SUM" ] && R status | json_ok && ok "status JSON includes checksum = sha256 of the script" || ko "status checksum $(R status | jv checksum)"
C send >/dev/null 2>&1; R show_ap_data "$CID" > "$W/ck.json"; json_ok < "$W/ck.json" && grep -q "^ *\"apmond_checksum\": \"$SUM\",$" "$W/ck.json" && ok "show_ap_data node_status includes apmond_checksum" || ko "node_status apmond_checksum"
[ "$(grep -c 'sha256sum "$apmond_script"' "$REPO/src/apmond")" -eq 1 ] && ok "script hashed once per invocation (top level only)" || ko "checksum computed more than once"

echo "== 12. JSON output formatted as jq . (arrays one element per line, empty [] kept)"
JQ=$(command -v jq || true)
jqsame() { [ -z "$JQ" ] && return 0; "$JQ" . "$1" > "$1.jq" 2>/dev/null && cmp -s "$1" "$1.jq"; }
R detect >/dev/null; R status > "$W/st.json"; jqsame "$W/st.json" && ok "status output byte-identical to jq . (${JQ:-jq not installed, skipped})" || ko "status vs jq: $(diff "$W/st.json" "$W/st.json.jq" | head -20)"
C status > "$W/stc.json"; jqsame "$W/stc.json" && ok "peer status output byte-identical to jq ." || ko "peer status vs jq: $(diff "$W/stc.json" "$W/stc.json.jq" | head -20)"
grep -q '^    "protocol_mismatch_nodes": \[\]' "$W/st.json" && ok "empty array stays [] as in jq" || ko "empty array"
grep -A1 '^      "[^"]*": \[$' "$W/st.json" | grep -q '^        "fd' && ok "ula_addresses list: one address per line, indented one level deeper" || ko "ula_addresses layout $(grep -A3 ula_addresses "$W/st.json")"
mkdir -p "$W/run-R/protocol_mismatch"; echo 2 > "$W/run-R/protocol_mismatch/020000aa0009"; echo 0 > "$W/run-R/protocol_mismatch/020000aa000a"
R status > "$W/st2.json"; jqsame "$W/st2.json" && [ "$(R status | jv protocol_mismatch_nodes)" = "020000aa0009 020000aa000a" ] && ok "2-element array matches jq ." || ko "2 elem vs jq: $(diff "$W/st2.json" "$W/st2.json.jq")"
rm -rf "$W/run-R/protocol_mismatch"
C send >/dev/null 2>&1; R show_ap_data "$CID" > "$W/sd.json"; jqsame "$W/sd.json" && ok "show_ap_data <mac> (stored report, node_status, Bands/Standards) byte-identical to jq ." || ko "show_ap_data vs jq: $(diff "$W/sd.json" "$W/sd.json.jq" | head -20)"
R show_ap_data all > "$W/sa.json"; jqsame "$W/sa.json" && ok "show_ap_data all byte-identical to jq ." || ko "show_ap_data all vs jq: $(diff "$W/sa.json" "$W/sa.json.jq" | head -20)"
grep -q '"[a-z_]*":[^ ]' "$W/sd.json" && ko "key without space after colon" || ok "every key printed as \"key\": value"

rm -rf "$PT/run/protocol_mismatch"; : > "$PT/log"; rep ' "Bands": ["2.4GHz","5GHz"], "apmond_protocol": "1",'; chk; [ ! -s "$PT/log" ] && [ ! -f "$PT/run/protocol_mismatch/020000aa0009" ] && ok "older report with inline arrays: protocol still read, no mismatch" || ko "inline array report $(cat "$PT/log")"
hx "$(printf '{\n  "System@x": {\n    "Bands": [\n      "2.4GHz"\n    ],\n    "node_status": {\n      "apmond_protocol": "1",\n      "f": "x"\n    }\n  }\n}')" > "$PT/rep"; : > "$PT/log"; chk; [ ! -s "$PT/log" ] && [ ! -f "$PT/run/protocol_mismatch/020000aa0009" ] && ok "jq-style multi-line report: protocol read, no mismatch" || ko "multiline report $(cat "$PT/log")"

echo "== 13. Automatic bridge detection (list bridge unset)"
BD="$W/bd"; FS="$BD/net"; mkdir -p "$BD/uci"
mkb() { b=$1; shift; mkdir -p "$FS/$b/bridge" "$FS/$b/brif"; for m in "$@"; do mkdir -p "$FS/$m"; touch "$FS/$b/brif/$m"; done; }
mkb br-lan lan1 lan2 phy0-ap0; mkb br-guest lan3 phy0-ap1; mkb br-wan eth1; mkb br-empty; mkb br-tun69 vxlan69; mkb docker0 veth1
echo "network.wan.device='br-wan'" > "$BD/uci/network"
awk '/^wan_devices\(\) \{/,/^}/; /^detect_bridges\(\) \{/,/^}/' "$REPO/src/apmond" > "$BD/fns.sh"
bd() { busybox env PATH="$W/mock:$W/bb" MOCK_UCI_DIR="$BD/uci" APMOND_SYSFS_NET="$FS" busybox sh -c ". '$BD/fns.sh'; id_device='$1'; bridge_list='$2'; bridge_auto=\$([ -n '$2' ] && echo 0 || echo 1); detect_bridges; echo \"\$bridges\""; }
[ "$(bd br-lan '')" = "br-lan br-guest docker0" ] && ok "home + guest: both bridges scanned by default (device first)" || ko "auto home+guest: $(bd br-lan '')"
[ "$(bd br-lan 'br-guest')" = "br-guest" ] && [ "$(bd br-lan 'br-lan br-empty')" = "br-lan br-empty" ] && ok "list bridge limits the scan to the list, as configured" || ko "list bridge: $(bd br-lan br-guest)"
bd br-lan '' | grep -qw br-wan && ko "wan bridge scanned" || ok "upstream bridge (network.wan.device) excluded"
echo "network.wan.device='eth1'" > "$BD/uci/network"; bd br-lan '' | grep -qw br-wan && ko "bridge with wan member scanned" || ok "bridge with the wan device as a member excluded"
bd br-lan '' | grep -qw "br-empty\|br-tun69" && ko "empty/vxlan-only bridge scanned" || ok "bridges with no members, or only a mesh11sd vxlan port, skipped"
echo "network.wan.disabled='1'" >> "$BD/uci/network"; bd br-lan '' | grep -qw br-wan && ok "wan disabled (mesh11sd trunk: wan port moved to br-tun): that bridge is scanned" || ko "wan disabled: $(bd br-lan '')"
mkb br-iot lan4; bd br-lan '' | grep -qw br-iot && ok "re-detected each call: a bridge added later is picked up" || ko "new bridge"
cp "$W/uci-C/apmond" "$W/cb2.bak"; echo "apmond.setup.bridge='auto'" >> "$W/uci-C/apmond"; a1=$(C status | jv bridge_detect); sed -i "s/bridge='auto'/bridge='apmbr2' 'auto'/" "$W/uci-C/apmond"; a2=$(C status | jv bridge_detect); a3=$(C status | jv bridges | awk '{print $1}'); cp "$W/cb2.bak" "$W/uci-C/apmond"
[ "$a1" = auto ] && [ "$a2" = auto ] && [ "$a3" = apmbr0 ] && ok "list bridge 'auto' (alone or with other entries) = unset: auto-detect all non-wan bridges" || ko "list bridge auto: $a1 $a2 $a3"
grep -q 'case "$port" in vxlan\*) continue' "$REPO/src/apmond" && ok "wired scan skips mesh11sd vxlan ports (remote clients) as mesh11sd does" || ko "vxlan port skip"

echo "== 14. Running daemon checksum vs script on disk"
rm -rf "$W/run-D"; MOCK_WAN_UP=0 busybox timeout 20 busybox sh -c "MOCK_UCI_DIR=$W/uci-D MOCK_IP_DIR=$W/ip-D APMOND_TMPDIR=$W/run-D APMOND_TMP_DATADIR=$W/tmp-D busybox sh $REPO/src/apmond daemon" >/dev/null 2>&1 &
DP=$!; i=0; while [ ! -s "$W/run-D/daemon_checksum" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
[ "$(cat "$W/run-D/daemon_checksum" 2>/dev/null)" = "$SUM" ] && ok "daemon writes its own checksum to the run dir at start" || ko "daemon_checksum file: $(cat "$W/run-D/daemon_checksum" 2>/dev/null)"
D status > "$W/dc1.json"; [ "$(jv checksum < "$W/dc1.json" 2>/dev/null || D status | jv checksum)" = "$SUM" ] && [ "$(D status | jv installed_checksum)" = "$SUM" ] && ! grep -q checksum_warning "$W/dc1.json" && jqsame "$W/dc1.json" && ok "status: daemon running same script: checksum = installed_checksum, no warning, jq-identical" || ko "status same: $(grep checksum "$W/dc1.json")"
OLD=0000000000000000000000000000000000000000000000000000000000000abc; echo "$OLD" > "$W/run-D/daemon_checksum"
D status > "$W/dc2.json"; grep -qx "    \"checksum\": \"$OLD\"," "$W/dc2.json" && grep -qx "    \"installed_checksum\": \"$SUM\"," "$W/dc2.json" && grep -qx '    "checksum_warning": "running daemon differs from /usr/sbin/apmond - restart apmond",' "$W/dc2.json" && jqsame "$W/dc2.json" && json_ok < "$W/dc2.json" && ok "status after upgrade without restart: checksum = running daemon, installed_checksum = disk, checksum_warning" || ko "status differ: $(grep checksum "$W/dc2.json")"
kill $DP 2>/dev/null; pkill -TERM -f "$REPO/src/apmond daemon" 2>/dev/null; i=0; while [ -f "$W/run-D/daemon_checksum" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
[ ! -f "$W/run-D/daemon_checksum" ] && ok "daemon_checksum removed when the daemon stops" || ko "daemon_checksum left after stop"
echo "$OLD" > "$W/run-D/daemon_checksum"; D status > "$W/dc3.json"; grep -qx "    \"checksum\": \"$SUM\"," "$W/dc3.json" && ! grep -q checksum_warning "$W/dc3.json" && ok "no daemon running: checksum = script hash, stale file ignored, no warning" || ko "not running: $(grep checksum "$W/dc3.json")"
D cleanup >/dev/null 2>&1; [ ! -f "$W/run-D/daemon_checksum" ] && ok "cleanup removes daemon_checksum" || ko "cleanup daemon_checksum"
grep -q '"apmond_checksum\\": \\"$checksum\\"' "$REPO/src/apmond" && ok "node_status apmond_checksum = hash of the sending process's own script (daemon or CLI send)" || ko "apmond_checksum source"

echo "== 15. VLAN-aware bridge (vlan_filtering=1, lan on br-lan.10, guest on br-lan.20)"
VL="$W/vlmock"; N="$VL/net"; mkdir -p "$VL/bin" "$VL/uci" "$VL/run/apmond" "$N/br-lan/bridge" "$N/br-lan/brif/eth0.1" "$N/br-lan/brif/mesh0" "$N/br-lan.10" "$N/br-lan.20" "$N/eth0.1/statistics" "$N/mesh0/phy80211" "$N/br-plain/bridge" "$N/br-plain/brif/eth1"
echo 1 > "$N/br-lan/bridge/vlan_filtering"; echo 0 > "$N/br-plain/bridge/vlan_filtering"; echo 1 > "$N/br-lan/brif/eth0.1/port_no"; echo 2 > "$N/br-lan/brif/mesh0/port_no"
echo 100 > "$N/eth0.1/speed"; echo up > "$N/eth0.1/operstate"; echo 1111 > "$N/eth0.1/statistics/rx_bytes"; echo 2222 > "$N/eth0.1/statistics/tx_bytes"
cat > "$VL/bin/bridge" <<'EOS'
#!/bin/sh
[ "$*" = "fdb show br br-lan" ] || exit 1
cat <<EOF
33:33:00:00:00:01 dev br-lan self permanent
94:83:c4:52:68:73 dev br-lan vlan 10 master br-lan permanent
02:aa:00:00:00:01 dev eth0.1 vlan 20 master br-lan
02:aa:00:00:00:01 dev eth0.1 vlan 10 master br-lan
02:aa:00:00:00:02 dev eth0.1 vlan 10 master br-lan
02:aa:00:00:00:01 dev eth0.1 vlan 20 master br-lan
94:83:c4:2e:f9:d1 dev mesh0 vlan 10 master br-lan
aa:bb:cc:dd:ee:ff dev eth0.1 self permanent
EOF
EOS
chmod +x "$VL/bin/bridge"
cat > "$VL/uci/network" <<'EOS'
network.lan=interface
network.lan.device='br-lan.10'
network.guest=interface
network.guest.device='br-lan.20'
network.trunk=interface
network.trunk.device='br-lan'
network.trunk.proto='none'
EOS
echo "apmond.setup=apmond" > "$VL/uci/apmond"
awk '/^(get_option|resolve_id_device|port_access_vlan|ap_vlan|get_station_block|ms_to_dt|get_bridge_fdb|wan_devices|detect_bridges|get_ethernet_clients|get_eth_stats|get_link_speed|swconfig_vlan_speed|append_block|log_debug)\(\) \{/,/^}/' "$REPO/src/apmond" > "$VL/fns.sh"
vl() { busybox env PATH="$VL/bin:$W/mock:$W/bb" MOCK_UCI_DIR="$VL/uci" APMOND_SYSFS_NET="$N" busybox sh -c "bridge_auto=1; bridge_list=''; tmpdir='$VL/run'; . '$VL/fns.sh'; $1"; }
[ "$(vl 'resolve_id_device; echo $id_device $id_bridge')" = "br-lan.10 br-lan" ] && ok "vlan_filtering br-lan: id device = network.lan.device br-lan.10, parent bridge br-lan" || ko "resolve: $(vl 'resolve_id_device; echo $id_device $id_bridge')"
echo "apmond.setup.device='br-lan.10'" >> "$VL/uci/apmond"
[ "$(vl 'resolve_id_device; echo $id_device $id_bridge')" = "br-lan.10 br-lan" ] && ok "explicit option device 'br-lan.10' used as is (override), parent bridge br-lan" || ko "explicit vlan device"
echo "apmond.setup=apmond" > "$VL/uci/apmond"; echo "apmond.setup.device='br-plain'" >> "$VL/uci/apmond"
[ "$(vl 'resolve_id_device; echo $id_device $id_bridge')" = "br-plain br-plain" ] && ok "explicit device on a non-filtering bridge unchanged" || ko "explicit plain device"
echo "apmond.setup=apmond" > "$VL/uci/apmond"; sed -i "s/^network.lan.device=.*/network.lan.device='br-lan'/" "$VL/uci/network"
[ "$(vl 'resolve_id_device; echo $id_device')" = "br-lan" ] && ok "lan device not a VLAN subinterface: br-lan kept" || ko "non-subif lan device"
sed -i "s/^network.lan.device=.*/network.lan.device='br-lan.10'/" "$VL/uci/network"
[ "$(vl 'resolve_id_device; detect_bridges; echo $bridges')" = "br-lan br-plain" ] && ok "bridge detection: br-lan (parent) found, br-lan.10/.20 not taken as bridges" || ko "detect: $(vl 'resolve_id_device; detect_bridges; echo $bridges')"
vl 'resolve_id_device; bridge_auto=0; bridge_list=br-lan; first_block=1; eth_sta=0; get_ethernet_clients' >/dev/null 2>&1
{ echo "{"; cat "$VL/run/apmond/clients"; echo "}"; } > "$VL/c.json"
"$PY" - "$VL/c.json" <<'EOP' && ok "vlan key: one entry per MAC, VIDs comma-joined ascending, after stats_scope; mesh0 (wireless) port skipped" || ko "vlan clients: $(cat "$VL/c.json")"
import json,sys
t=open(sys.argv[1]).read(); d=json.loads(t)
assert list(d)==["eth0.1@br-lan"], d
p=d["eth0.1@br-lan"]; assert list(p)==["02:aa:00:00:00:01","02:aa:00:00:00:02"], p
assert p["02:aa:00:00:00:01"]["vlan"]=="10,20" and p["02:aa:00:00:00:02"]["vlan"]=="10"
assert list(p["02:aa:00:00:00:01"])==["rx_bytes","tx_bytes","rx_bitrate","tx_bitrate","stats_scope","vlan","timestamp","date_time"]
assert p["02:aa:00:00:00:02"]["rx_bytes"]=="1111" and p["02:aa:00:00:00:02"]["stats_scope"]=="port"
EOP
JQ2=$(PATH="$SPATH" command -v jq || true); { printf '{\n  "s": {\n    "c": {\n'; cat "$VL/run/apmond/clients"; printf '    }\n  }\n}\n'; } > "$VL/w.json"
{ [ -z "$JQ2" ] || "$JQ2" . "$VL/w.json" | cmp -s - "$VL/w.json"; } && ok "vlan clients block byte-identical to jq . (${JQ2:-jq not installed, skipped})" || ko "vlan block vs jq: $("$JQ2" . "$VL/w.json" | diff - "$VL/w.json" | head)"
! grep -q '"vlan"' "$W/report.json" && ok "no vlan key for wired clients on a non-filtering bridge (apmbr0)" || ko "vlan key on plain bridge"

echo "== 15b. VLAN of wired clients from UCI bridge-vlan (no ip-bridge)"
mkdir -p "$VL/nobr" "$N/br-lan/brif/eth0.2" "$N/eth0.2/statistics"; echo 3 > "$N/br-lan/brif/eth0.2/port_no"
echo 100 > "$N/eth0.2/speed"; echo up > "$N/eth0.2/operstate"; echo 5 > "$N/eth0.2/statistics/rx_bytes"; echo 6 > "$N/eth0.2/statistics/tx_bytes"
cat > "$VL/nobr/brctl" <<'EOS'
#!/bin/sh
[ "$*" = "showmacs br-lan" ] || exit 1
printf 'port no\tmac addr\t\tis local?\tageing timer\n'
printf '  1\t02:aa:00:00:00:01\tno\t\t   1.00\n  1\t02:aa:00:00:00:01\tno\t\t   1.00\n  1\t02:aa:00:00:00:02\tno\t\t   1.00\n'
printf '  3\t02:bb:00:00:00:01\tno\t\t   1.00\n  2\t94:83:c4:2e:f9:d1\tno\t\t   1.00\n  1\t94:83:c4:52:68:73\tyes\t\t   0.00\n'
EOS
chmod +x "$VL/nobr/brctl"
cat >> "$VL/uci/network" <<'EOS'
network.@bridge-vlan[0]=bridge-vlan
network.@bridge-vlan[0].device='br-lan'
network.@bridge-vlan[0].vlan='10'
network.@bridge-vlan[0].ports='eth0.1:u*' 'mesh0:t' 'eth0.2:t'
network.@bridge-vlan[1]=bridge-vlan
network.@bridge-vlan[1].device='br-lan'
network.@bridge-vlan[1].vlan='20'
network.@bridge-vlan[1].ports='mesh0:t' 'eth0.2'
network.@bridge-vlan[2]=bridge-vlan
network.@bridge-vlan[2].device='br-other'
network.@bridge-vlan[2].vlan='30'
network.@bridge-vlan[2].ports='eth0.1'
EOS
vn() { busybox env PATH="$VL/nobr:$W/mock:$W/bb" MOCK_UCI_DIR="$VL/uci" APMOND_SYSFS_NET="$N" busybox sh -c "bridge_auto=0; bridge_list=br-lan; tmpdir='$VL/run'; . '$VL/fns.sh'; $1"; }
[ "$(vn 'port_access_vlan br-lan eth0.1')" = 10 ] && [ -z "$(vn 'port_access_vlan br-lan eth0.2')" ] && [ -z "$(vn 'port_access_vlan br-lan mesh0')" ] && [ -z "$(vn 'port_access_vlan br-lan eth9')" ] && ok "port_access_vlan: access port 10; trunk, tagged-only and unlisted ports none" || ko "port_access_vlan"
sed 's/eth0.1:u\*/eth0.1/' "$VL/uci/network" > "$VL/n2"; cp "$VL/uci/network" "$VL/n1"; cp "$VL/n2" "$VL/uci/network"
[ "$(vn 'port_access_vlan br-lan eth0.1')" = 10 ] && ok "port listed without suffix counts as untagged" || ko "no-suffix port"
cp "$VL/n1" "$VL/uci/network"
command -v bridge >/dev/null 2>&1 && ko "test PATH unexpectedly has bridge" || true
rm -f "$VL/run/apmond/clients"; vn 'resolve_id_device; first_block=1; eth_sta=0; get_ethernet_clients' >/dev/null 2>&1
{ echo "{"; cat "$VL/run/apmond/clients"; echo "}"; } > "$VL/c2.json"
"$PY" - "$VL/c2.json" <<'EOP' && ok "no ip-bridge: access port clients get vlan from UCI, trunk port clients have no vlan key, one entry per MAC" || ko "uci vlan clients: $(cat "$VL/c2.json")"
import json,sys
d=json.load(open(sys.argv[1]))
assert list(d)==["eth0.1@br-lan","eth0.2@br-lan"], d
a=d["eth0.1@br-lan"]; assert list(a)==["02:aa:00:00:00:01","02:aa:00:00:00:02"], a
assert all(e["vlan"]=="10" for e in a.values())
assert list(a["02:aa:00:00:00:01"])==["rx_bytes","tx_bytes","rx_bitrate","tx_bitrate","stats_scope","vlan","timestamp","date_time"]
assert "vlan" not in d["eth0.2@br-lan"]["02:bb:00:00:00:01"]
EOP
{ printf '{\n  "s": {\n    "c": {\n'; cat "$VL/run/apmond/clients"; printf '    }\n  }\n}\n'; } > "$VL/w2.json"
{ [ -z "$JQ2" ] || "$JQ2" . "$VL/w2.json" | cmp -s - "$VL/w2.json"; } && ok "UCI vlan clients block byte-identical to jq ." || ko "uci vlan block vs jq"
rm -f "$VL/run/apmond/clients"; vl 'resolve_id_device; bridge_auto=0; bridge_list=br-lan; first_block=1; eth_sta=0; get_ethernet_clients' >/dev/null 2>&1
grep -A6 '"02:aa:00:00:00:01"' "$VL/run/apmond/clients" | grep -q '"vlan": "10,20"' && ok "bridge command present: per-MAC fdb VIDs override the UCI access VLAN" || ko "fdb override: $(cat "$VL/run/apmond/clients")"

echo "== 15c. VLAN of wireless clients (AP iface network device br-lan.N, or untagged bridge-vlan port)"
mkdir -p "$N/phy0-ap0" "$N/phy1-ap0" "$N/phy0-ap1" "$N/br-lan/brif/phy1-ap0" "$N/br-plain/brif/phy0-ap1"
ln -sfn ../br-lan "$N/phy1-ap0/master"; ln -sfn ../br-plain "$N/phy0-ap1/master"
cat >> "$VL/uci/network" <<'EOS'
network.plain=interface
network.plain.device='br-plain'
network.@bridge-vlan[3]=bridge-vlan
network.@bridge-vlan[3].device='br-lan'
network.@bridge-vlan[3].vlan='30'
network.@bridge-vlan[3].ports='phy1-ap0:u*'
EOS
cat > "$VL/uci/wireless" <<'EOS'
wireless.default_radio0=wifi-iface
wireless.default_radio0.mode='ap'
wireless.default_radio0.ssid='Home'
wireless.default_radio0.network='lan'
wireless.guest=wifi-iface
wireless.guest.mode='ap'
wireless.guest.ssid='Guest'
wireless.guest.network='guest'
wireless.trunkap=wifi-iface
wireless.trunkap.mode='ap'
wireless.trunkap.ssid='Trunk'
wireless.trunkap.network='trunk'
wireless.plainap=wifi-iface
wireless.plainap.mode='ap'
wireless.plainap.ssid='Plain'
wireless.plainap.network='plain'
wireless.mesh0=wifi-iface
wireless.mesh0.mode='mesh'
wireless.mesh0.network='trunk'
EOS
[ "$(vn 'ap_vlan default_radio0 phy0-ap0')" = 10 ] && [ "$(vn 'ap_vlan guest phy0-ap1x')" = 20 ] && ok "AP iface vlan from its network device (lan br-lan.10 -> 10, guest br-lan.20 -> 20)" || ko "ap_vlan network: $(vn 'ap_vlan default_radio0 phy0-ap0') $(vn 'ap_vlan guest x')"
[ "$(vn 'ap_vlan trunkap phy1-ap0')" = 30 ] && ok "AP iface on br-lan itself: untagged PVID port in bridge-vlan -> 30" || ko "ap_vlan bridge-vlan port: $(vn 'ap_vlan trunkap phy1-ap0')"
[ -z "$(vn 'ap_vlan plainap phy0-ap1')" ] && ok "no vlan for an AP on a bridge without vlan_filtering" || ko "ap_vlan plain"
APL=$(grep -m1 '^	aplist=' "$REPO/src/apmond" | sed 's/^	aplist=//')
[ "$(vn "echo $APL")" = "default_radio0 guest trunkap plainap" ] && ok "mesh wifi-iface (mode mesh) never reported as a client AP" || ko "aplist: $(vn "echo $APL")"
vn 'get_station_block phy1-ap0 Guest 20' >/dev/null 2>&1
{ printf '{\n  "s": {\n    "c": {\n'; cat "$VL/run/apmond_block"; printf '    }\n  }\n}\n'; } > "$VL/w3.json"
"$PY" - "$VL/w3.json" <<'EOP' && ok "wireless entry: whitelisted keys kept, vlan after connected_time and before timestamp" || ko "wireless vlan: $(cat "$VL/w3.json")"
import json,sys
d=json.load(open(sys.argv[1]))["s"]["c"]["Guest@phy1-ap0"]
e=list(d.values())[0]
assert list(e)==["rx_bytes","tx_bytes","tx_retries","signal_avg","tx_bitrate","rx_bitrate","avg_ack_signal","connected_time","vlan","timestamp","date_time"], list(e)
assert e["vlan"]=="20"
EOP
{ [ -z "$JQ2" ] || "$JQ2" . "$VL/w3.json" | cmp -s - "$VL/w3.json"; } && ok "wireless vlan block byte-identical to jq ." || ko "wireless vlan vs jq"
vn 'get_station_block phy1-ap0 Guest ""' >/dev/null 2>&1; ! grep -q '"vlan"' "$VL/run/apmond_block" && ok "no vlan key on wireless entries when the AP has no VLAN" || ko "wireless vlan without vid"

echo "== 15d. apmond get_ap_data (as mesh11sd get_ap_data, prints this node's data, sends nothing)"
RD=$(R status | jv ap_data_dir); [ -n "$(ls "$RD" 2>/dev/null)" ] && ok "collector data dir has data before get_ap_data (non-vacuous check)" || ko "collector data dir $RD empty"
snap() { { ls -l --full-time "$RD"; cat "$W"/run-C/last_send "$W"/run-R/last_send 2>/dev/null; md5sum "$RD"/* 2>/dev/null; } | md5sum; }
B=$(snap); C get_ap_data > "$W/gad-C.json" 2>"$W/gad-C.err"; RC=$?; R get_ap_data > "$W/gad-R.json" 2>/dev/null
[ "$RC" -eq 0 ] && [ ! -s "$W/gad-C.err" ] && json_ok < "$W/gad-C.json" && json_ok < "$W/gad-R.json" && ok "get_ap_data runs on peer and router: valid JSON, no stderr" || ko "get_ap_data: rc $RC $(head -3 "$W/gad-C.err")"
"$PY" - "$W/gad-C.json" "$CID" <<'EOP' && ok "get_ap_data shape: { System@<mac>: { ..., node_status, clients@<mac> } } like mesh11sd" || ko "get_ap_data shape"
import json,sys
d=json.load(open(sys.argv[1])); k=list(d); assert len(k)==1 and k[0].startswith("System@"), k
v=d[k[0]]; m=k[0][7:]; assert "node_status" in v and ("clients@"+m) in v, list(v)
EOP
{ [ -z "$JQ2" ] || { "$JQ2" . "$W/gad-C.json" | cmp -s - "$W/gad-C.json" && "$JQ2" . "$W/gad-R.json" | cmp -s - "$W/gad-R.json"; }; } && ok "get_ap_data output byte-identical to jq ." || ko "get_ap_data vs jq"
[ "$B" = "$(snap)" ] && ok "get_ap_data sent nothing (collector data and last_send unchanged)" || ko "get_ap_data changed collector data / last_send"
! ls "$W"/run-C/entrynum.* >/dev/null 2>&1 && [ ! -e "$W/run-C/apmond/clients.loc" ] && ok "get_ap_data: per-pid log counter removed, no lock left" || ko "get_ap_data leftovers"
C help | grep -q 'option: get_ap_data' && C help | grep -q 'Usage: apmond get_ap_data' && ok "get_ap_data in help" || ko "help get_ap_data"

echo "== 16. Race-safe /proc and file reads (no BusyBox \"can't open\" noise)"
! grep -nE '[^{] < "[^"]*" 2>/dev/null' "$REPO/src/apmond" | grep -v '^\s*#' | grep -q . && ok "no redirect-read whose 2>/dev/null misses ash's can't open (reads use { ...; } 2>/dev/null)" || ko "unguarded reads: $(grep -nE '[^{] < "[^"]*" 2>/dev/null' "$REPO/src/apmond")"
awk '/^daemon_pid\(\) \{/,/^}/' "$REPO/src/apmond" > "$W/dpid.sh"
( i=0; while [ $i -lt 400 ]; do busybox true; i=$((i+1)); done ) & CH=$!
: > "$W/dpid.err"; i=0; while [ $i -lt 30 ]; do busybox sh -c ". '$W/dpid.sh'; daemon_pid" >/dev/null 2>>"$W/dpid.err"; i=$((i+1)); done
wait $CH 2>/dev/null
[ ! -s "$W/dpid.err" ] && ok "daemon_pid /proc scan silent while processes exit mid-scan" || ko "daemon_pid stderr: $(head -3 "$W/dpid.err")"

kill $HTTPD 2>/dev/null
PATH="$SPATH"
$SUDO ip -6 addr del "$RULA/128" dev lo 2>/dev/null
mountpoint -q "$W/usb" 2>/dev/null && $SUDO umount "$W/usb"
mountpoint -q "$W/small" 2>/dev/null && $SUDO umount "$W/small"
$SUDO ip link del apmdum0 2>/dev/null; $SUDO ip link del apmbr0 2>/dev/null; $SUDO ip link del apmbr1 2>/dev/null; $SUDO ip link del apmbr2 2>/dev/null
echo
echo "Result: $pass passed, $fail failed (work dir $W)"
[ "$fail" -eq 0 ]
