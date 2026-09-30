#!/bin/sh
# Deploy a staged Dooyong RBF + MRAs (+ ROM zips if missing) to the MiSTer.
#   tools/deploy_mister.sh releases/Arcade-Dooyong_YYYYMMDD.rbf [mra ...]
# With MRA arguments only those are copied (for a build that does not run
# every game in releases/mra yet); otherwise all of releases/mra.
# The MiSTer is usually on DHCP, so it is found by its MAC address on the
# local subnet: set MISTER_MAC (and MISTER_SUBNET, default 192.168.1), or
# give MISTER_IP directly. Root password: MISTER_PASS (MiSTer default 1).
# Copies are new files
# only (existing files with different content are reported, not replaced).
# MD5 is checked on both sides for every copied file.
set -eu
RBF=$1
shift
MAC=${MISTER_MAC:-}
NET=${MISTER_SUBNET:-192.168.1}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no"

# locate the MiSTer: ping sweep to fill the ARP cache, then match the MAC
if [ -n "${MISTER_IP:-}" ]; then IP=$MISTER_IP; else
[ -n "$MAC" ] || { echo "set MISTER_MAC or MISTER_IP"; exit 1; }
for i in $(seq 1 254); do ping -c1 -W 200 $NET.$i >/dev/null 2>&1 & done; wait
IP=$(arp -an | awk -v m="$MAC" 'tolower($4)==m {gsub(/[()]/,"",$2); print $2}' | head -1)
[ -n "$IP" ] || { echo "MiSTer (MAC $MAC) not found on $NET.0/24"; exit 1; }
fi
echo "MiSTer at $IP"
M="root@$IP"
PASS=${MISTER_PASS:-1}

rsh() {  # rsh <command> [< input]: ssh with retries (the MiSTer's sshd refuses logins intermittently, 09-29)
  for k in 1 2 3 4 5; do
    if [ -t 0 ] || [ -z "$RSH_IN" ]; then out=$(sshpass -p "$PASS" ssh $SSHO "$M" "$1" 2>/dev/null) && { printf '%s' "$out"; return 0; }
    else sshpass -p "$PASS" ssh $SSHO "$M" "$1" < "$RSH_IN" 2>/dev/null && return 0; fi
    sleep 3
  done
  echo "ssh failed: $1" >&2; exit 1
}

put() {  # put <local file> <remote path>
  lsum=$(md5 -q "$1")
  q=$(printf '%s' "$2" | sed "s/'/'\\\\''/g")     # quote for the remote shell (Gun Dealer '94)
  sleep 1                                            # the MiSTer's sshd refuses rapid logins
  rsum=$(RSH_IN= rsh "[ -f '$q' ] && md5sum '$q' | cut -d' ' -f1 || true")
  if [ -n "$rsum" ]; then
    [ "$rsum" = "$lsum" ] && { echo "same    $2"; return 0; }
    echo "DIFFERS $2 (left as is)"; return 0
  fi
  # streamed over ssh: sshpass + scp is refused by the MiSTer (09-29)
  sleep 1
  RSH_IN="$1" rsh "cat > '$q'"
  sleep 1
  rsum=$(RSH_IN= rsh "md5sum '$q' | cut -d' ' -f1")
  [ "$rsum" = "$lsum" ] && echo "copied  $2 ($lsum)" || { echo "MD5 MISMATCH $2"; exit 1; }
}

put "$RBF" "/media/fat/_Arcade/cores/$(basename "$RBF")"
if [ $# -gt 0 ]; then
  for f in "$@"; do put "$f" "/media/fat/_Arcade/$(basename "$f")"; done
else
  # releases/ layout: parents to _Arcade/, clones to _Arcade/_alternatives/_<game>/
  for f in "$ROOT"/releases/*.mra; do
    put "$f" "/media/fat/_Arcade/$(basename "$f")"
  done
  for d in "$ROOT"/releases/_alternatives/*/; do
    g=$(basename "$d")
    RSH_IN= rsh "mkdir -p '/media/fat/_Arcade/_alternatives/$(printf '%s' "$g" | sed "s/'/'\\\\''/g")'" >/dev/null
    for f in "$d"*.mra; do
      put "$f" "/media/fat/_Arcade/_alternatives/$g/$(basename "$f")"
    done
  done
fi
for z in lastday gulfstrm pollux flytiger bluehawk sadari gundl94 superx rshark popbingo; do
  put "$ROOT/roms/$z.zip" "/media/fat/games/mame/$z.zip"
done
