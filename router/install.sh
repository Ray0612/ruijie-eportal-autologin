#!/bin/sh
# ============================================================================
#  install.sh  --  one-shot installer for the router-side daemon
#
#  Recommended instead of copying files by hand: it puts everything in the
#  right place, fixes permissions, verifies ASCII/LF and sets up cron.
#
#  Usage (run ON the router):
#    sh install.sh
#
#  If your persistent partition is not /etc/storage, edit DIR below.
#  ASCII-only on purpose.
# ============================================================================

set -u

DIR="/etc/storage/campus"
DIAG="/etc/storage/diag"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

echo "============================================================"
echo " campus-login installer"
echo "============================================================"
echo " source dir : $HERE"
echo " install dir: $DIR"
echo

# ---- 0) sanity ----
if [ ! -d /etc/storage ]; then
    echo "[!] /etc/storage does not exist on this firmware."
    echo "    Edit DIR in this script to point at your persistent partition"
    echo "    (common choices: /data  /jffs  /overlay)"
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "[!] curl not found. Install it first, e.g.: opkg update && opkg install curl"
    exit 1
fi

# ---- 1) create dirs ----
mkdir -p "$DIR" "$DIAG" || { echo "[!] cannot create $DIR"; exit 1; }

# ---- 2) copy files ----
for f in campus-login.sh start.sh; do
    if [ -f "$HERE/$f" ]; then
        cp "$HERE/$f" "$DIR/$f" || { echo "[!] copy $f failed"; exit 1; }
        echo "  [ok] $DIR/$f"
    else
        echo "  [!] missing $HERE/$f"
    fi
done

if [ -f "$HERE/diag/reboot-watch.sh" ]; then
    cp "$HERE/diag/reboot-watch.sh" "$DIAG/reboot-watch.sh"
    echo "  [ok] $DIAG/reboot-watch.sh"
fi

chmod +x "$DIR/campus-login.sh" "$DIR/start.sh" 2>/dev/null
chmod +x "$DIAG/reboot-watch.sh" 2>/dev/null

# ---- 3) verify: ASCII only, no CR ----
echo
echo "---- verification ----"
for f in "$DIR/campus-login.sh" "$DIR/start.sh"; do
    nonascii=$(tr -d '\0-\177' < "$f" 2>/dev/null | wc -c)
    cr=$(tr -d '\n' < "$f" 2>/dev/null | tr -cd '\r' | wc -c)
    syntax=$(sh -n "$f" 2>/dev/null && echo OK || echo ERROR)
    printf "  %-30s nonascii=%-4s CR=%-4s syntax=%s\n" "$(basename "$f")" "$nonascii" "$cr" "$syntax"
    [ "$nonascii" -ne 0 ] && echo "     [!] contains non-ASCII bytes -- fix before use"
    [ "$cr" -ne 0 ]       && echo "     [!] contains CR characters -- fix before use (dos2unix)"
done

# ---- 4) config ----
if [ ! -f "$DIR/campus-login.conf" ]; then
    cat > "$DIR/campus-login.conf" <<'EOF'
# ---- campus-login configuration ----
# Fill these in. This file is read by campus-login.sh.

# Portal address, WITHOUT http://
PORTAL_IP="10.0.0.1"

# Your account
ACCOUNT="YOUR_ACCOUNT"

# Your password (plaintext is expected when passwordEncrypt=false)
PASSWORD="YOUR_PASSWORD"

# WAN interface name -- check with: ip addr  /  ifconfig
WAN_IF="eth0"

# Polling interval in seconds. NEVER go below 120. 300 is recommended.
# (seconds-level polling can hang small routers -- see docs/04)
INTERVAL=300
EOF
    chmod 600 "$DIR/campus-login.conf"
    echo "  [ok] created $DIR/campus-login.conf  (EDIT IT with your account!)"
else
    echo "  [ok] $DIR/campus-login.conf already exists, left untouched"
fi

# ---- 5) cron ----
echo
echo "---- cron ----"
if ! grep -q 'campus/start.sh' /etc/crontabs/root 2>/dev/null; then
    echo '* * * * * /etc/storage/campus/start.sh' >> /etc/crontabs/root
    echo "  [ok] added campus/start.sh to crontab"
else
    echo "  [ok] crontab entry already present"
fi

if ! grep -q 'diag/reboot-watch.sh' /etc/crontabs/root 2>/dev/null; then
    echo '*/1 * * * * /etc/storage/diag/reboot-watch.sh >/dev/null 2>&1' >> /etc/crontabs/root
    echo "  [ok] added reboot-watch.sh to crontab"
fi

/etc/init.d/cron restart 2>/dev/null && echo "  [ok] cron restarted"

# ---- 6) start ----
echo
echo "---- start ----"
"$DIR/start.sh"
sleep 3
PID=$(pgrep -f 'campus-login.sh' | head -1)
if [ -n "$PID" ]; then
    echo "  [ok] daemon running (pid $PID)"
else
    echo "  [!] daemon not running -- check $DIR/start.log"
fi

echo
echo "============================================================"
echo " done."
echo " NEXT STEP: edit $DIR/campus-login.conf with your account,"
echo "            then run: $DIR/start.sh"
echo " logs: /tmp/campus-login.log  and  $DIR/start.log"
echo "============================================================"
