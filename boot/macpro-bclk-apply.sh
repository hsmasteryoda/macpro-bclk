#!/bin/bash
# macpro-bclk-apply.sh - apply the BCLK overclock at EARLY boot (before game containers, while idle).
# This is the only SAFE way to apply the OC: a live write on a loaded box hangs it. Crash-loop guarded:
# if a boot ever hangs mid-apply, the next boot SKIPS applying (so it can never boot-loop).
#
# Config: /etc/default/macpro-bclk  (TARGET=104)   Disable: rm /var/lib/macpro-bclk/enabled
set -u
TARGET=104
[ -r /etc/default/macpro-bclk ] && . /etc/default/macpro-bclk
BUS=0; ADDR=0x69; EXPECT_DEV=$((0x35))
STATE=/var/lib/macpro-bclk; MARK="$STATE/last-attempt"; LOG=/var/log/macpro-bclk.log
mkdir -p "$STATE"
log(){ printf '%s apply: %s\n' "$(date -Is)" "$*" >>"$LOG"; }

[ -e "$STATE/enabled" ] || { log "disabled (no $STATE/enabled); not applying"; exit 0; }

# crash-loop guard: an unfinished attempt from last boot means a hang - skip this boot.
if [ "$(cat "$MARK" 2>/dev/null)" = attempting ]; then
  echo skipped-after-hang > "$MARK"; sync
  log "previous boot did NOT finish applying (likely hung) -> SKIPPING. 'echo ready > $MARK' to re-arm."
  exit 0
fi

modprobe i2c-i801 2>/dev/null; modprobe i2c-dev 2>/dev/null
command -v i2cget >/dev/null && command -v i2cset >/dev/null || { log "i2c-tools missing"; exit 0; }
curfreq(){ local b6; b6=$(i2cget -y $BUS $ADDR 0x00 s 2>/dev/null | cut -d' ' -f7); [ -n "$b6" ] && echo $(( 97 + ($b6 & 7) )); }
read -a B < <(i2cget -y $BUS $ADDR 0x00 s 2>/dev/null; echo)
[ "${#B[@]}" -ge 10 ] || { log "clockgen read failed"; exit 0; }
[ "$((${B[9]}))" -eq "$EXPECT_DEV" ] || { log "device id 0x$(printf %02x $((${B[9]}))) != expected; refusing"; exit 0; }
cur=$(curfreq); [ -n "$cur" ] || { log "could not read current freq"; exit 0; }
[ "$TARGET" -ge 100 ] && [ "$TARGET" -le 104 ] || { log "TARGET $TARGET out of range 100-104; refusing"; exit 0; }
[ "$cur" -ge "$TARGET" ] && { log "already at ${cur} MHz (>= target ${TARGET})"; echo ok > "$MARK"; exit 0; }

echo attempting > "$MARK"; sync
log "boot apply: ${cur} -> ${TARGET} MHz (stepping)"
while [ "$cur" -lt "$TARGET" ]; do
  n=$((cur+1))
  read -a B < <(i2cget -y $BUS $ADDR 0x00 s 2>/dev/null; echo)
  B[6]=$(printf 0x%02x $(( (${B[6]} & ~7) | (n-97) )))
  B[1]=$(printf 0x%02x $(( ${B[1]} | 0x80 )))
  i2cset -y $BUS $ADDR 0x00 "${B[@]}" s
  sleep 1
  cur=$(curfreq); [ -n "$cur" ] || break
  log "  stepped to ${cur} MHz"
done
echo ok > "$MARK"; sync
log "boot apply done: BCLK now ${cur} MHz"
