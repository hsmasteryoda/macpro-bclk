#!/bin/bash
# macpro-bclk-apply.sh - apply the BCLK overclock at EARLY boot (before game containers, while idle).
#
# A live BCLK step can hang the box and drop an in-flight disk write (the PLL relock collides with in-flight
# FS I/O). To make the step BOTH reliable and glitch-free, each step FREEZES the mounted filesystems for the
# brief relock window (fsfreeze) so there is no in-flight I/O to collide with, then unfreezes.
#
# Because fsfreeze and its libraries live ON the filesystems being frozen, every tool used inside the frozen
# window is staged into tmpfs (/dev/shm) and run from there, with a tmpfs watchdog that force-unfreezes if
# anything stalls. Crash-loop guarded: if a boot ever hangs mid-step, the next boot SKIPS (never boot-loops).
#
# Config: /etc/default/macpro-bclk (TARGET=104).  Disable: rm /var/lib/macpro-bclk/enabled.
set -u
TARGET=104
[ -r /etc/default/macpro-bclk ] && . /etc/default/macpro-bclk
BUS="${BCLK_BUS:-0}"; ADDR=0x69; EXPECT_DEV=$((0x35))
STATE=/var/lib/macpro-bclk; MARK="$STATE/last-attempt"; LOG=/var/log/macpro-bclk.log
mkdir -p "$STATE"
log(){ printf '%s apply: %s\n' "$(date -Is)" "$*" >>"$LOG" 2>/dev/null; echo "macpro-bclk: $*" >/dev/kmsg 2>/dev/null || true; }

[ -e "$STATE/enabled" ] || { log "disabled (no $STATE/enabled); not applying"; exit 0; }

# crash-loop guard: an unfinished attempt from last boot means a hang -> skip this boot.
if [ "$(cat "$MARK" 2>/dev/null)" = attempting ]; then
  echo skipped-after-hang > "$MARK"; sync
  log "previous boot did NOT finish applying (likely hung) -> SKIPPING. 'echo ready > $MARK' to re-arm."
  exit 0
fi

modprobe i2c-i801 2>/dev/null; modprobe i2c-dev 2>/dev/null
for t in i2cget i2cset fsfreeze sleep; do command -v "$t" >/dev/null || { log "missing tool: $t"; exit 0; }; done

# --- stage frozen-window tools into tmpfs so the step never touches a frozen FS ---
STAGE=/dev/shm/macpro-bclk.$$
mkdir -p "$STAGE"
_stage(){ for b in "$@"; do cp -f "$b" "$STAGE/" 2>/dev/null
  ldd "$b" 2>/dev/null | sed -n 's/.*=> \(\/[^ ]*\).*/\1/p; s/^[[:space:]]*\(\/[^ ]*ld-linux[^ ]*\).*/\1/p' | while read -r l; do cp -n "$l" "$STAGE/" 2>/dev/null; done
done; }
_stage "$(command -v i2cget)" "$(command -v i2cset)" "$(command -v fsfreeze)" "$(command -v sleep)"
LD=$(ls "$STAGE"/ld-linux* 2>/dev/null | head -1)
[ -n "$LD" ] || { log "could not stage loader into tmpfs; abort"; rm -rf "$STAGE"; exit 0; }
rr(){ local b="$1"; shift; "$LD" --library-path "$STAGE" "$STAGE/$b" "$@"; }   # run a staged tool from tmpfs

# rw real filesystems to freeze during each step
FZ=$(awk '$3 ~ /^(ext4|xfs)$/ && $4 ~ /(^|,)rw(,|$)/ {print $2}' /proc/mounts)
FROZEN=""; WD=""
cleanup(){ for m in $FROZEN; do rr fsfreeze -u "$m" 2>/dev/null; done; FROZEN=""; [ -n "$WD" ] && kill "$WD" 2>/dev/null; rm -rf "$STAGE"; }
trap cleanup EXIT INT TERM

read_blk(){ i2cget -y "$BUS" "$ADDR" 0x00 s 2>/dev/null; }

# sanity (BEFORE any freeze)
blk=$(read_blk); [ "$(echo "$blk"|wc -w)" -ge 10 ] || { log "clockgen read failed; abort"; exit 0; }
b9=$(echo "$blk"|cut -d' ' -f10); [ "$((b9))" -eq "$EXPECT_DEV" ] || { log "device id $b9 != 0x35; abort"; exit 0; }
cur=$(( 97 + ($(echo "$blk"|cut -d' ' -f7) & 7) ))
case "$TARGET" in 100) log "target 100 (stock); nothing to do"; exit 0 ;; 101|102|103|104) ;; *) log "bad target $TARGET"; exit 0 ;; esac
[ "$cur" -ge "$TARGET" ] && { log "already at ${cur} MHz (>= target ${TARGET})"; echo ok > "$MARK"; exit 0; }

# pre-page the tmpfs tools so the first frozen use never page-faults off a frozen FS
for t in i2cget i2cset fsfreeze; do rr "$t" --help >/dev/null 2>&1 || true; done; rr sleep 0 2>/dev/null || true

echo attempting > "$MARK"; sync
log "fsfreeze-protected apply: ${cur} -> ${TARGET} MHz (freeze:${FZ// /,})"

# watchdog backstop: force-unfreeze everything after 15s no matter what (runs entirely from tmpfs)
( rr sleep 15; for m in $FZ; do rr fsfreeze -u "$m" 2>/dev/null; done ) & WD=$!

while [ "$cur" -lt "$TARGET" ]; do
  nxt=$((cur+1))
  blk=$(read_blk); [ "$(echo "$blk"|wc -w)" -ge 10 ] || { log "read failed mid-step at ${cur}"; break; }
  out=""; idx=0
  for x in $blk; do
    case "$idx" in
      1) x=$(printf '0x%02x' $(( x | 0x80 ))) ;;                 # byte1: latch bit
      6) x=$(printf '0x%02x' $(( (x & ~7) | (nxt-97) ))) ;;       # byte6: freq sel
    esac
    out="$out $x"; idx=$((idx+1))
  done
  # ---- critical window: quiesce FS, do the relock, settle, resume ----
  sync
  FROZEN=""
  for m in $FZ; do rr fsfreeze -f "$m" 2>/dev/null && FROZEN="$FROZEN $m"; done
  rr i2cset -y "$BUS" "$ADDR" 0x00 $out s 2>/dev/null
  rr sleep 1                                    # hold the freeze across the PLL relock
  for m in $FROZEN; do rr fsfreeze -u "$m" 2>/dev/null; done
  FROZEN=""
  # ---- end window; FS resumed ----
  cur=$(( 97 + ($(read_blk|cut -d' ' -f7) & 7) ))
  log "  stepped to ${cur} MHz (FS frozen during relock)"
done
kill "$WD" 2>/dev/null; WD=""
echo ok > "$MARK"; sync
log "done: BCLK now ${cur} MHz"
