#!/bin/sh
# macpro-bclk-rearm.sh - re-arm the BCLK boot apply after the crash-loop guard skipped it.
# Run once per boot by macpro-bclk-rearm.timer, 2 h after boot. If this boot was a guarded skip
# ("skipped-after-hang") and the box has stayed up that long, the skip did its job (no boot loop), so set the
# marker back to "ready": the NEXT boot tries the target again instead of staying at the partial clock until
# someone notices. Seen 2026-11-20: a power cut, the cold-boot step hung at 101, and the host ran 101 for a week.
MARK=/var/lib/macpro-bclk/last-attempt; LOG=/var/log/macpro-bclk.log
[ -e /var/lib/macpro-bclk/enabled ] || exit 0
[ "$(cat "$MARK" 2>/dev/null)" = skipped-after-hang ] || exit 0
echo ready > "$MARK"; sync
msg="re-armed after a guarded skip (stable for 2 h); the next boot steps to the target again"
printf '%s rearm: %s\n' "$(date -Is)" "$msg" >>"$LOG" 2>/dev/null
echo "macpro-bclk: $msg"
