#!/usr/bin/env bash
# NTP / system time sync status. ISO 27001 evidence for A.8.17 (clock synchronisation).
#
# Read-only. Detects which time-sync daemon is in use (systemd-timesyncd, chrony,
# or ntpd) and dumps its detail. Output is plain text grouped by section so an auditor
# can read it as-is.
#
# Intentionally no `set -e` - we want partial output even if a sub-tool isn't installed.

echo "=== System time ==="
date -u "+now (UTC):   %Y-%m-%d %H:%M:%S"
date    "+now (local): %Y-%m-%d %H:%M:%S %Z"

echo
echo "=== timedatectl status ==="
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl status 2>&1
else
    echo "(timedatectl not available on this host)"
fi

echo
echo "=== Active time-sync daemon ==="
if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    echo "daemon: systemd-timesyncd (active)"
    echo
    echo "-- timedatectl show-timesync --"
    timedatectl show-timesync --all 2>&1 || timedatectl timesync-status 2>&1 || true

elif systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
    echo "daemon: chrony (active)"
    if command -v chronyc >/dev/null 2>&1; then
        echo
        echo "-- chronyc tracking --"
        chronyc tracking 2>&1
        echo
        echo "-- chronyc sources --"
        chronyc sources 2>&1
    fi

elif systemctl is-active --quiet ntpd 2>/dev/null || systemctl is-active --quiet ntp 2>/dev/null; then
    echo "daemon: ntpd (active)"
    if command -v ntpq >/dev/null 2>&1; then
        echo
        echo "-- ntpq -p --"
        ntpq -p 2>&1
    fi

else
    echo "WARNING: no recognised time-sync daemon is active"
    echo "         (systemd-timesyncd / chrony / ntpd / ntp)."
    echo
    echo "Service states:"
    for unit in systemd-timesyncd chronyd chrony ntpd ntp; do
        state=$(systemctl is-active "$unit" 2>/dev/null || echo "n/a")
        enabled=$(systemctl is-enabled "$unit" 2>/dev/null || echo "n/a")
        printf "  %-20s active=%-10s enabled=%s\n" "$unit" "$state" "$enabled"
    done
fi
