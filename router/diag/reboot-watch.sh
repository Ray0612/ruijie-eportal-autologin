#!/bin/sh
# ============================================================================
#  reboot-watch.sh  --  minimal reboot / stall diagnostics
#
#  Why: a hardware watchdog reset is SILENT (no shutdown sequence, no log).
#  All you see is "last log line" ... gap ... "new boot". This script makes
#  that gap measurable.
#
#  What it records (both on a PERSISTENT partition, so they survive reboots):
#    reboots.log    one line per boot  -> how many times it rebooted
#    heartbeat.log  one line per minute -> where the timeline went dark
#
#  Install:
#    */1 * * * * /etc/storage/diag/reboot-watch.sh >/dev/null 2>&1
#
#  ASCII-only on purpose.
# ============================================================================

DIR="/etc/storage/diag"
BOOTS="$DIR/reboots.log"
BEAT="$DIR/heartbeat.log"
MAXLINES=2000

mkdir -p "$DIR" 2>/dev/null

NOW=$(date '+%Y-%m-%d %H:%M:%S')
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)

# ---- 1) record each distinct boot exactly once ----
if [ -n "$BID" ]; then
    if ! grep -q "$BID" "$BOOTS" 2>/dev/null; then
        echo "$NOW  BOOT  boot_id=$BID" >> "$BOOTS"
    fi
fi

# ---- 2) heartbeat once per minute ----
UP=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)
LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
MEMFREE=$(awk '/MemFree/{print $2}' /proc/meminfo 2>/dev/null)
PROCS=$(ps 2>/dev/null | wc -l)

echo "$NOW  uptime=${UP}s  load=$LOAD  memfree=${MEMFREE}KB  procs=$PROCS" >> "$BEAT"

# ---- 3) trim ----
for f in "$BOOTS" "$BEAT"; do
    if [ "$(wc -l < "$f" 2>/dev/null)" -gt "$MAXLINES" ]; then
        tail -n 1000 "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
    fi
done
