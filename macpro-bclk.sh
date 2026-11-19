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
# (PCIe/DMI/SATA/TB and RAM all scale with BCLK), and skew timekeeping. The setting is volatile: a full
# power-off restores 100 MHz.
#
# HARD-WON SAFETY RULES (2026-11-19 live run - see LAB-NOTES.md):
#   * NEVER write BCLK while the box is under load. A live write under load HUNG the box instantly; the
#     SAME frequency written at idle was rock-stable. This script refuses upward writes when load is high
#     (override with BCLK_FORCE=1 only if you know the box is actually idle).
#   * Unclean crash-reboots from a bad write CORRUPTED the root filesystem. Overclocking a host that boots
#     from the same disk is a real data-integrity risk. Have backups; prefer applying at idle boot.
#   * Validated ceiling is 104 MHz (+4%). byte6>=0x18 hangs. 100-104 all stable at idle; CPU had headroom
#     to spare - we ran out of register range, not silicon. Watch dmesg for I/O errors, not just ECC.
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

measure(){ # actual all-core clock (= ratio x BCLK under load), CPU + RAM temps, and I/O-error watch
  awk '/cpu MHz/{s+=$4;n++} END{if(n)printf "all-core avg MHz (current load): %.0f\n", s/n}' /proc/cpuinfo
  printf 'single-core peak MHz: %s\n' "$(awk '/cpu MHz/{print $4}' /proc/cpuinfo | sort -n | tail -1)"
  if command -v sensors >/dev/null; then
    sensors 2>/dev/null | awk '/Package id 0/{print "pkg temp: "$4}'
    sensors 2>/dev/null | grep -E '^TM0P:|^TM1P:' | sed 's/:  */: /;s/^/RAM temp /'
  fi
  local io; io=$(dmesg --notime 2>/dev/null | grep -ciE 'i/o error|EXT4-fs error|nvme.*(timeout|reset)')
  printf 'kernel I/O/FS errors in dmesg: %s%s\n' "${io:-?}" "$([ "${io:-0}" -gt 0 ] 2>/dev/null && echo '  <-- STOP: storage is erroring, restore 100 and check the disk')"
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
  # LOAD GUARD: a live upward BCLK write under load HUNG the box (and the crash corrupted the FS).
  # Refuse upward writes when load is high; downward/restore always allowed. Override: BCLK_FORCE=1.
  if (( target > cur )); then
    local load1 ncpu; load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null); ncpu=$(nproc 2>/dev/null || echo 4)
    if [ "${BCLK_FORCE:-0}" != 1 ] && awk "BEGIN{exit !(${load1:-0} > $ncpu*0.5)}"; then
      log "ABORT: load ${load1} too high (> ${ncpu}/2 cores) for a live upward BCLK write."
      log "       A live write under load crashed this box before. Quiesce it, or set BCLK_FORCE=1 if truly idle."
      exit 1
    fi
  fi
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
