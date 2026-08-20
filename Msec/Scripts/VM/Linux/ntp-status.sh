#!/usr/bin/env bash
# NTP / system time-sync status as JSON.
# ISO 27001 evidence for A.8.17 (clock synchronisation).
#
# Read-only. Probes whichever time-sync daemon is in use (systemd-timesyncd, chrony,
# ntpd) and emits a single JSON object on stdout:
#
#   { "NowUtc", "TimeZone", "Synchronized", "NtpEnabled", "Daemon", "Source", "Compliant" }
#
# Synchronized is the authoritative "is time being kept correct?" answer - true means
# the kernel reports the clock as in sync with an NTP source.
#
# Compliant is the policy verdict for A.8.17: synchronized AND configured against a
# non-empty (i.e. real, not local) time source. This is what an auditor scans for.

ntp_synced=false
ntp_enabled=false
daemon=""
source=""
timezone=""
now_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if command -v timedatectl >/dev/null 2>&1; then
    timezone=$(timedatectl show --value -p Timezone 2>/dev/null)
    [ "$(timedatectl show --value -p NTPSynchronized 2>/dev/null)" = "yes" ] && ntp_synced=true
fi

if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    ntp_enabled=true
    daemon="systemd-timesyncd"
    source=$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)
elif systemctl is-active --quiet chronyd 2>/dev/null || systemctl is-active --quiet chrony 2>/dev/null; then
    ntp_enabled=true
    daemon="chrony"
    if command -v chronyc >/dev/null 2>&1; then
        # "Reference ID    : 8E3D8E48 (time.cloudflare.com)" -> "time.cloudflare.com"
        # Falls back to the bare ID if no name is present.
        source=$(chronyc tracking 2>/dev/null |
                 awk -F'[()]' '/^Reference ID/ { if (NF>1) print $2; else print $0 }' |
                 head -1 |
                 awk '{ if (NF>=4 && index($0,"(")==0) print $4; else print $0 }')
    fi
elif systemctl is-active --quiet ntpd 2>/dev/null || systemctl is-active --quiet ntp 2>/dev/null; then
    ntp_enabled=true
    daemon="ntpd"
fi

# Escape any quotes/backslashes that snuck into source/timezone (rare but possible).
escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# A.8.17 policy verdict: clock is synchronized AND configured against a real (non-empty)
# upstream source. The CSV/dashboard layer treats this as the headline pass/fail column.
compliant=false
[ "$ntp_synced" = "true" ] && [ -n "$source" ] && compliant=true

cat <<EOF
{
  "NowUtc": "$now_utc",
  "TimeZone": "$(escape "$timezone")",
  "Synchronized": $ntp_synced,
  "NtpEnabled": $ntp_enabled,
  "Daemon": "$(escape "$daemon")",
  "Source": "$(escape "$source")",
  "Compliant": $compliant
}
EOF
