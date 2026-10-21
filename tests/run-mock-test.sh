#!/bin/sh
# Mock end to end test for apmond, run on a Linux host with busybox installed.
#  - every tool resolves to a busybox applet (or a mock for uci/iw/ubus/logger)
#  - the collector is busybox httpd running the packaged apmon.cgi
#  - optional: a real kernel bridge with a dummy port and a static fdb entry (needs sudo) for the wired client scan
# Usage: sh tests/run-mock-test.sh

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
W=$(mktemp -d /tmp/apmond-test.XXXXXX)
PORT=${PORT:-18088}
pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
ko() { echo "FAIL: $1"; fail=$((fail+1)); }

# busybox applets first in PATH
mkdir -p "$W/bb" "$W/mock" "$W/www/cgi-bin" "$W/uci-client" "$W/uci-server"
BB=$(command -v busybox); PY=$(command -v python3)
for a in busybox $(busybox --list); do ln -sf "$BB" "$W/bb/$a"; done
for m in uci iw ubus logger; do cp "$REPO/tests/mock-bin-$m" "$W/mock/$m"; done
JF=$(command -v jsonfilter || command -v jsonpath || true)
[ -n "$JF" ] && ln -sf "$JF" "$W/mock/jsonfilter"
BR=""
if sudo -n true 2>/dev/null; then
	BR=apmbr0
	sudo ip link add $BR type bridge 2>/dev/null; sudo ip link add apmdum0 type veth peer name apmdum1 2>/dev/null; sudo ip link set apmdum1 up
	sudo ip link set apmdum0 master $BR; sudo ip link set apmdum0 up; sudo ip link set $BR up
	sudo bridge fdb add 02:aa:bb:cc:dd:01 dev apmdum0 master static 2>/dev/null
fi

export PATH="$W/mock:$W/bb"
export MOCK_LOG="$W/log"

SECRET="s3cret-$(date +%s)"
cat > "$W/uci-client/apmond" <<EOC
apmond.client=apmond
apmond.client.enabled='1'
apmond.client.server='127.0.0.1'
apmond.client.port='$PORT'
apmond.client.secret='$SECRET'
apmond.client.device='${BR:-lo}'
apmond.client.bridge='${BR:-br-lan}'
apmond.common.debuglevel='3'
EOC
cat > "$W/uci-client/wireless" <<'EOC'
wireless.radio0=wifi-device
wireless.default_radio0=wifi-iface
wireless.default_radio0.device='radio0'
wireless.default_radio0.network='lan'
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
echo "system.@system[0].hostname='test-ap1'" > "$W/uci-client/system"
echo "network.lan=interface" > "$W/uci-client/network"
cat > "$W/uci-server/apmond" <<EOC
apmond.server=apmond
apmond.server.enabled='1'
apmond.server.secret='$SECRET'
apmond.server.max_age='120'
apmond.common.debuglevel='3'
EOC

# Collector: the packaged CGI, pointed at the script under test
sed "s#/usr/sbin/apmond#busybox sh $REPO/src/apmond#" "$REPO/linux_openwrt/apmond/files/www/cgi-bin/apmon.cgi" > "$W/www/cgi-bin/apmon.cgi.real"
cat > "$W/www/cgi-bin/apmon.cgi" <<EOC
#!/bin/sh
export PATH="$PATH" MOCK_UCI_DIR="$W/uci-server" APMOND_TMPDIR="$W/server" MOCK_LOG="$W/log"
. "$W/www/cgi-bin/apmon.cgi.real"
EOC
chmod 755 "$W/www/cgi-bin/apmon.cgi"
busybox httpd -f -p "127.0.0.1:$PORT" -h "$W/www" & HTTPD=$!
busybox httpd -f -p "[::1]:$PORT" -h "$W/www" 2>/dev/null & HTTPD6=$!
sleep 1

client() { MOCK_UCI_DIR="$W/uci-client" APMOND_TMPDIR="$W/client" APMOND_TEST_SCHEME=http busybox sh "$REPO/src/apmond" "$@"; }
server() { MOCK_UCI_DIR="$W/uci-server" APMOND_TMPDIR="$W/server" busybox sh "$REPO/src/apmond" "$@"; }
raw() { busybox wget -q -O - -U "$1" "http://127.0.0.1:$PORT/cgi-bin/apmon.cgi${2:+?$2}" 2>/dev/null; }
json_ok() { "$PY" -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }
apfile() { ls "$W/server/ap/" 2>/dev/null | head -n 1; }

echo "== syntax"
busybox sh -n "$REPO/src/apmond" && ok "busybox sh -n src/apmond" || ko "syntax"

echo "== 1. valid signed report is stored"
client send; rc=$?
MAC=$(apfile)
[ "$rc" -eq 0 ] && [ -n "$MAC" ] && ok "report stored for $MAC" || ko "valid report (rc=$rc)"
server show_ap_data "$MAC" > "$W/report.json"
json_ok < "$W/report.json" && ok "show_ap_data <mac> is valid JSON" || ko "show_ap_data JSON"
grep -q '"OpenWrt@phy0-ap0"' "$W/report.json" && grep -q '"OpenWrt5@phy1-ap0"' "$W/report.json" && ok "AP ifnames resolved without ifname in wireless config" || ko "ifname resolution"
grep -q '"Guest@' "$W/report.json" || grep -q '"Off@' "$W/report.json" && ko "down/disabled ifaces included" || ok "down/disabled wifi-ifaces skipped"
if [ -n "$BR" ]; then grep -q '"apmdum0@apmbr0"' "$W/report.json" && grep -q '02:aa:bb:cc:dd:01' "$W/report.json" && ok "wired client found on bridge without any mesh interface" || ko "wired client scan"; fi
server show_ap_data all | json_ok && ok "show_ap_data all is valid JSON" || ko "show_ap_data all JSON"

echo "== 2. bad secret rejected"
before=$(cat "$W/server/ap/$MAC" | busybox sha256sum)
sed -i "s/secret='.*'/secret='wrong'/" "$W/uci-client/apmond"
sleep 1; client send; rc=$?
. "$W/client/last_send"
after=$(cat "$W/server/ap/$MAC" | busybox sha256sum)
[ "$rc" -ne 0 ] && [ "$last_status" = "nack" ] && [ "$before" = "$after" ] && ok "bad secret: nack, stored report untouched" || ko "bad secret (rc=$rc status=$last_status)"
[ -z "$(ls "$W/server/staging/")" ] && ok "bad secret: nothing buffered" || ko "bad secret buffered data"
sed -i "s/secret='wrong'/secret='$SECRET'/" "$W/uci-client/apmond"

echo "== 3. stale and replayed reports rejected"
. "$REPO/tests/sign.sh"
DMAC=$(echo "$MAC" | sed 's/../&:/g; s/:$//')
DATA=$(printf '{"x":1}' | busybox hexdump -v -e '1/1 "%02x"')
H=$(printf '%s' "$DATA" | busybox sha256sum | cut -c1-64)
TS=$(( $(date +%s) - 1000 )); SIG=$(sign "$SECRET" "$DMAC" "$TS" "$H")
r=$(raw "apmond;stale;$DMAC;begin;0;$TS;$H;$SIG" "$DATA")
case "$r" in nack*Stale*) ok "stale timestamp rejected";; *) ko "stale: $r";; esac
TS=$(( $(date +%s) + 1000 )); SIG=$(sign "$SECRET" "$DMAC" "$TS" "$H")
r=$(raw "apmond;future;$DMAC;begin;0;$TS;$H;$SIG" "$DATA")
case "$r" in nack*Stale*) ok "future timestamp rejected";; *) ko "future: $r";; esac
# A captured valid session, sent once (accepted) then replayed (rejected)
sleep 1
TS=$(date +%s); SIG=$(sign "$SECRET" "$DMAC" "$TS" "$H")
r1=$(raw "apmond;cap;$DMAC;begin;0;$TS;$H;$SIG" "$DATA"); r2=$(raw "apmond;cap;$DMAC;end;${#DATA};$TS;$H;$SIG")
[ "$r1" = "*begin" ] && [ "$r2" = "*end" ] && ok "hand signed session accepted" || ko "hand signed session: $r1 $r2"
r=$(raw "apmond;cap;$DMAC;begin;0;$TS;$H;$SIG" "$DATA")
case "$r" in nack*Replayed*) ok "replayed session rejected";; *) ko "replay: $r";; esac
# Tampered payload (signature over hash of other data)
sleep 1
TS=$(date +%s); SIG=$(sign "$SECRET" "$DMAC" "$TS" "$H")
EVIL=$(printf '{"x":2}' | busybox hexdump -v -e '1/1 "%02x"')
raw "apmond;evil;$DMAC;begin;0;$TS;$H;$SIG" "$EVIL" >/dev/null
r=$(raw "apmond;evil;$DMAC;end;${#EVIL};$TS;$H;$SIG")
case "$r" in nack*hash*) ok "tampered payload rejected at end";; *) ko "tamper: $r";; esac
server show_ap_data "$MAC" | grep -q '"x":2' && ko "tampered data stored" || ok "tampered data not stored"
# Missing signature (old mesh11sd style user agent)
r=$(raw "apmond;meshnode-1234;$DMAC;begin;0" "$DATA")
case "$r" in nack*) ok "unsigned mesh11sd style report rejected";; *) ko "unsigned: $r";; esac

echo "== 4. large report, chunked"
sleep 1
export MOCK_STATIONS=150
client send; rc=$?
. "$W/client/last_send"
chunks=$(( (last_bytes + 2047) / 2048 ))
server show_ap_data "$MAC" > "$W/big.json"
n=$(grep -c '"02:00:00:00:' "$W/big.json")
[ "$rc" -eq 0 ] && [ "$n" -eq 151 ] && json_ok < "$W/big.json" && ok "large report: $last_bytes hex chars in $chunks chunks, 151 stations, valid JSON" || ko "large report rc=$rc stations=$n"
unset MOCK_STATIONS

echo "== 5. IPv6 server address"
sleep 1
sed -i "s/server='127.0.0.1'/server='::1'/" "$W/uci-client/apmond"
if kill -0 $HTTPD6 2>/dev/null; then
	client send && ok "report sent to [::1]" || ko "ipv6 send"
else
	echo "SKIP: busybox httpd could not listen on [::1]"
fi

echo "== 6. CLI"
client version | grep -q "apmond version" && ok "version" || ko "version"
client status | grep -q "Client role:  enabled=1" && ok "status" || ko "status"
server show_ap_data | grep -q "$MAC" && ok "show_ap_data list" || ko "list"

kill $HTTPD $HTTPD6 2>/dev/null
[ -n "$BR" ] && { PATH=/usr/sbin:/usr/bin:/sbin:/bin sudo ip link del apmdum0; sudo ip link del $BR; } 2>/dev/null
echo
echo "Result: $pass passed, $fail failed (work dir $W)"
[ "$fail" -eq 0 ]
