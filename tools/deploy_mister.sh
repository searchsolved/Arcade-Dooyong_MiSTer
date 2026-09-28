#!/bin/sh
# Deploy a staged Dooyong RBF + MRAs (+ ROM zips if missing) to the MiSTer.
#   tools/deploy_mister.sh builds/Dooyong_YYYYMMDD.rbf
# The MiSTer is on DHCP: found by its MAC (<your MiSTer MAC>) on the
# 192.168.1.0/24 subnet, never by a remembered IP. Copies are new files
# only (existing files with different content are reported, not replaced).
# MD5 is checked on both sides for every copied file.
set -eu
RBF=$1
MAC=<your MiSTer MAC>
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SSHO="-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password,keyboard-interactive"

# locate the MiSTer: ping sweep to fill the ARP cache, then match the MAC
for i in $(seq 1 254); do ping -c1 -W 200 192.168.1.$i >/dev/null 2>&1 & done; wait
IP=$(arp -an | awk -v m="$MAC" 'tolower($4)==m {gsub(/[()]/,"",$2); print $2}' | head -1)
[ -n "$IP" ] || { echo "MiSTer (MAC $MAC) not found on 192.168.1.0/24"; exit 1; }
echo "MiSTer at $IP"
M="root@$IP"

put() {  # put <local file> <remote path>
  lsum=$(md5 -q "$1")
  rsum=$(sshpass -p 1 ssh $SSHO "$M" "[ -f '$2' ] && md5sum '$2' | cut -d' ' -f1 || true")
  if [ -n "$rsum" ]; then
    [ "$rsum" = "$lsum" ] && { echo "same    $2"; return 0; }
    echo "DIFFERS $2 (left as is)"; return 0
  fi
  sshpass -p 1 scp $SSHO "$1" "$M:$2"
  rsum=$(sshpass -p 1 ssh $SSHO "$M" "md5sum '$2' | cut -d' ' -f1")
  [ "$rsum" = "$lsum" ] && echo "copied  $2 ($lsum)" || { echo "MD5 MISMATCH $2"; exit 1; }
}

put "$RBF" "/media/fat/_Arcade/cores/$(basename "$RBF")"
for f in "$ROOT"/releases/mra/*.mra; do
  put "$f" "/media/fat/_Arcade/$(basename "$f")"
done
for z in flytiger bluehawk; do
  put "$ROOT/roms/$z.zip" "/media/fat/games/mame/$z.zip"
done
