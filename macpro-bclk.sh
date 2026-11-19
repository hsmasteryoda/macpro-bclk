#!/bin/bash
# macpro-bclk.sh - read or step the 2013 Mac Pro 6,1 BCLK via its clock generator.
#
# Chip: ICS 932SQL435AL (CK420BQ family) on the PCH SMBus (i801), address 0x69.
# Confirmed on this machine 2026-11-19: block read = ff fe 8f 14 03 00 13 01 0a 35
#   byte9=0x35 -> "435" device id ; byte7=0x01 -> ICS/IDT vendor ; byte6=0x13 -> freq bits[2:0]=011=100 MHz
# Frequency select is byte6 bits[2:0], SQL420 table: 000=97 .. 011=100(default) .. 111=104 MHz (1 MHz steps).
# The 435's exact table is UNVERIFIED (no public datasheet); treat the first write as experimental.
#
# READ-ONLY by default. `write`/`restore` change the LIVE clock and can hang the box, glitch IO
# (PCIe/DMI/SATA/TB and RAM all scale with BCLK), and skew timekeeping. Run writes only with no players
# on and the ability to power-cycle. The setting is volatile: a full power-off restores 100 MHz.
#
# Usage:
#   ./macpro-bclk.sh read                 # safe: dump + decode the clock gen register block
#   ./macpro-bclk.sh measure              # safe: measure effective CPU/TSC MHz (before/after a write)
#   ./macpro-bclk.sh write <100..104>     # LIVE: set BCLK to N MHz (one small step at a time!)
#   ./macpro-bclk.sh restore              # LIVE: write 100 MHz (stock) back
set -uo pipefail

BUS="${BCLK_BUS:-0}"          # i801 SMBus adapter (i2cdetect -l); 0 on this machine
ADDR="0x69"
EXPECT_DEV="0x35"            # byte9 must be this (the 435) or we refuse to write
LOG="${BCLK_LOG:-/var/log/macpro-bclk.log}"
BK="$(dirname "$0")/bclk-stock-block.txt"

log(){ printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }
need(){ command -v "$1" >/dev/null || { echo "missing tool: $1 (apt install i2c-tools)"; exit 1; }; }

read_block(){ # prints the block bytes space-separated, e.g. "0xff 0xfe ... 0x35"
  modprobe i2c-i801 2>/dev/null; modprobe i2c-dev 2>/dev/null
  i2cget -y "$BUS" "$ADDR" 0x00 s 2>/dev/null
}

decode(){ # args: block bytes
  local -a b=("$@")
  local n=${#b[@]}
  (( n < 10 )) && { echo "short/failed read ($n bytes): ${b[*]:-none}"; return 1; }
  local b6=$((${b[6]})) b7=$((${b[7]})) b9=$((${b[9]}))
  local fsel=$(( b6 & 0x7 )) mhz=$(( 97 + (b6 & 0x7) ))
  printf 'clockgen block (%d bytes): %s\n' "$n" "${b[*]}"
  printf '  byte6=0x%02x  freq sel[2:0]=%d -> ~%d MHz (SQL420 table)\n' "$b6" "$fsel" "$mhz"
  printf '  byte7=0x%02x  vendor nibble=%d (%s)\n' "$b7" "$((b7 & 0xf))" "$([ $((b7 & 0xf)) -eq 1 ] && echo ICS/IDT || echo '?')"
  printf '  byte9=0x%02x  device id (%s)\n' "$b9" "$([ "$b9" -eq $((EXPECT_DEV)) ] && echo '932SQL435' || echo '?')"
}

measure(){ # effective MHz via aperf/mperf if turbostat present, else /proc/cpuinfo
  if command -v turbostat >/dev/null; then
    turbostat --quiet --show Bzy_MHz,TSC_MHz --num_iterations 1 --interval 1 2>/dev/null | head -3
  else
    log "turbostat not installed; falling back to /proc/cpuinfo (less precise)"
    grep -m1 'cpu MHz' /proc/cpuinfo
    log "TSC: $(dmesg 2>/dev/null | grep -m1 -i 'tsc.*MHz' || echo 'n/a')"
  fi
}

do_write(){ # arg: target MHz 100..104
  local target="$1"
  [[ "$target" =~ ^(100|101|102|103|104)$ ]] || { echo "target must be 100..104 MHz"; exit 1; }
  need i2cget; need i2cset
  mapfile -t B < <(read_block | tr ' ' '\n')
  (( ${#B[@]} < 10 )) && { log "ABORT: clock gen read failed (${#B[@]} bytes)"; exit 1; }
  local b6=$((${B[6]})) b9=$((${B[9]}))
  (( b9 != $((EXPECT_DEV)) )) && { log "ABORT: device id byte9=0x$(printf %02x $b9) != $EXPECT_DEV (not the expected 435); refusing to write"; exit 1; }
  local cur=$(( 97 + (b6 & 0x7) ))
  (( cur < 97 || cur > 104 )) && { log "ABORT: current freq sel out of range (byte6=0x$(printf %02x $b6))"; exit 1; }
  local delta=$(( target - cur )); local ad=${delta#-}
  (( ad > 1 )) && { log "ABORT: refusing a $delta MHz jump from ${cur}. Step 1 MHz at a time."; exit 1; }
  # back up the stock block once
  [ -f "$BK" ] || { printf '%s\n' "${B[*]}" > "$BK"; log "saved stock block to $BK: ${B[*]}"; }
  # new byte6: keep high bits, set freq sel = target-97 ; set byte1 latch bit 0x80 (per firmware)
  local nsel=$(( target - 97 ))
  local nb6=$(( (b6 & ~0x7) | nsel ))
  B[6]=$(printf '0x%02x' "$nb6")
  B[1]=$(printf '0x%02x' $(( $((${B[1]})) | 0x80 )))
  log "WRITE: BCLK ${cur}->${target} MHz  byte6 0x$(printf %02x $b6)->${B[6]}  block=${B[*]}"
  log "effective MHz BEFORE:"; measure | while read -r l; do log "   $l"; done
  # SMBus block write: command 0x00, then the data bytes, mode s (count is auto-prepended)
  i2cset -y "$BUS" "$ADDR" 0x00 "${B[@]}" s
  local rc=$?
  (( rc != 0 )) && { log "i2cset returned $rc"; }
  sleep 1
  local -a R; mapfile -t R < <(read_block | tr ' ' '\n')
  log "readback: ${R[*]}"
  decode "${R[@]}" | while read -r l; do log "   $l"; done
  log "effective MHz AFTER:"; measure | while read -r l; do log "   $l"; done
  log "If the box is stable, verify the AFTER MHz rose ~${target}% and watch journalctl -k for IO/MCE errors."
  log "To revert: ./macpro-bclk.sh restore  (or just power-cycle - the change is volatile)."
}

case "${1:-read}" in
  read)    need i2cget; decode $(read_block) ;;
  measure) measure ;;
  write)   do_write "${2:-}" ;;
  restore) do_write 100 ;;
  *) echo "usage: $0 {read|measure|write <100..104>|restore}"; exit 1 ;;
esac
