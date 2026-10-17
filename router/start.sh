#!/bin/sh
# ============================================================================
#  start.sh  --  watchdog launcher for campus-login.sh
#
#  Why this exists:
#    Many OpenWrt-like firmwares have neither setsid nor nohup, and busybox
#    cron does not support @reboot. So instead of "start once at boot", we run
#    this every minute from cron: if the daemon is not alive, start it.
#
#  Install:
#    echo '* * * * * /etc/storage/campus/start.sh' >> /etc/crontabs/root
#    /etc/init.d/cron restart
#
#  ASCII-only on purpose.
# ============================================================================

DIR="/etc/storage/campus"
DAEMON="$DIR/campus-login.sh"
LOG="$DIR/start.log"
MAXLOG=200

mkdir -p "$DIR" 2>/dev/null

say() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    if [ "$(wc -l < "$LOG" 2>/dev/null)" -gt "$MAXLOG" ]; then
        tail -n 100 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    fi
}

if [ ! -f "$DAEMON" ]; then
    say "start.sh: daemon missing at $DAEMON"
    exit 1
fi

# pgrep -f matches the whole command line; busybox killall matches the process
# NAME only (which would be just "sh"), so pgrep -f is the correct check here.
if pgrep -f 'campus-login.sh' >/dev/null 2>&1; then
    exit 0                      # already alive, nothing to do
fi

chmod +x "$DAEMON" 2>/dev/null

# busybox firmware usually lacks setsid/nohup; plain & plus a redirect is enough
sh "$DAEMON" >/dev/null 2>&1 &

sleep 2
PID=$(pgrep -f 'campus-login.sh' | head -1)
if [ -n "$PID" ]; then
    say "start.sh: daemon started (pid $PID)"
else
    say "start.sh: FAILED to start daemon"
fi
