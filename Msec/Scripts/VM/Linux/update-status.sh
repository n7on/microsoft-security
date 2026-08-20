#!/usr/bin/env bash
# update-status: the full patch picture for this machine in one shot -
#   * when it last installed packages (history, from dpkg.log / rpm)
#   * how many SECURITY vs OTHER updates are pending NOW
#   * whether a reboot is pending
#
# Read-MOSTLY: on apt systems it runs `apt-get update` first (refreshes package
# METADATA only - never installs anything) so the pending counts line up with Azure
# Update Manager, which also refreshes before assessing. A guest check that skips this
# reads a stale cache and under-reports - the usual reason it disagrees with Update
# Manager. AssessedFresh reports whether that refresh succeeded.
#
# Emits a single JSON object on stdout. No strict mode - we want partial results
# (nulls) if a tool/log is missing rather than a hard failure.

now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
last_local=""        # newest install/upgrade timestamp, in the VM's LOCAL time
last_pkg=""
count30d=""          # installs/upgrades in the last 30 days
sec_pending=""       # pending SECURITY updates
other_pending=""     # pending non-security updates
reboot="false"
assessed_fresh="false"
source=""

dpkg_stream() {
    local f
    for f in /var/log/dpkg.log /var/log/dpkg.log.1; do [ -r "$f" ] && cat "$f"; done
    for f in /var/log/dpkg.log.*.gz; do [ -r "$f" ] && zcat "$f" 2>/dev/null; done
}

if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    source="apt"

    # ---- history: last install/upgrade from dpkg's log ----
    if ls /var/log/dpkg.log* >/dev/null 2>&1; then
        line="$(dpkg_stream | awk '$3=="upgrade" || $3=="install"' | sort | tail -n1)"
        if [ -n "$line" ]; then
            last_local="$(echo "$line" | awk '{print $1" "$2}')"
            last_pkg="$(echo "$line" | awk '{print $4}')"
        fi
        cutoff="$(date -d '30 days ago' +%Y-%m-%d 2>/dev/null)"
        if [ -n "$cutoff" ]; then
            count30d="$(dpkg_stream | awk -v c="$cutoff" '($3=="upgrade"||$3=="install") && $1 >= c' | wc -l | tr -d ' ')"
        fi
    fi

    # ---- pending: refresh metadata (like Update Manager), then simulate a full upgrade ----
    if apt-get update -qq >/dev/null 2>&1; then assessed_fresh="true"; fi
    # 'Inst' lines list every package that WOULD be upgraded; security upgrades carry the
    # security archive name (e.g. '...-security') in the source, so a case-insensitive
    # 'security' match counts them. dist-upgrade matches Update Manager's broader semantics.
    upg="$(apt-get -s -o Debug::NoLocking=true dist-upgrade 2>/dev/null | grep '^Inst')"
    if [ -n "$upg" ]; then
        total=$(printf '%s\n' "$upg" | grep -c '^Inst')
        sec_pending=$(printf '%s\n' "$upg" | grep -ci 'security')
        other_pending=$(( total - sec_pending ))
    else
        sec_pending=0
        other_pending=0
    fi
    [ -f /var/run/reboot-required ] && reboot="true"

elif command -v rpm >/dev/null 2>&1; then
    # RHEL/SUSE family: report last install only. Pending counts are left null rather than
    # risk a fragile/inaccurate parse - the target fleet here is Ubuntu + Windows.
    source="rpm"
    last_line="$(rpm -qa --last 2>/dev/null | head -n1)"
    if [ -n "$last_line" ]; then
        last_pkg="$(echo "$last_line" | awk '{print $1}')"
        last_local="$(echo "$last_line" | sed 's/^[^ ]* *//')"
    fi
    { command -v needs-restarting >/dev/null 2>&1 && ! needs-restarting -r >/dev/null 2>&1; } && reboot="true"
fi

# Convert the local timestamp to UTC and compute elapsed days. `date -d` parses the naive
# string in the VM's local TZ; `-u` then renders it as UTC, so no manual offset.
last_utc=""
days=""
if [ -n "$last_local" ]; then
    if epoch="$(date -d "$last_local" +%s 2>/dev/null)"; then
        last_utc="$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)"
        days=$(( ( $(date +%s) - epoch ) / 86400 ))
    fi
fi

# Emit JSON by hand (jq isn't guaranteed present). Empty string -> JSON null.
jstr() { if [ -z "$1" ]; then printf 'null'; else printf '"%s"' "$1"; fi; }
jnum() { if [ -z "$1" ]; then printf 'null'; else printf '%s' "$1"; fi; }

printf '{"NowUtc":"%s","LastUpdate":%s,"LastUpdatePackage":%s,"DaysSinceUpdate":%s,"UpdateCount30d":%s,"SecurityPending":%s,"OtherPending":%s,"RebootRequired":%s,"AssessedFresh":%s,"Source":%s}\n' \
    "$now_utc" \
    "$(jstr "$last_utc")" \
    "$(jstr "$last_pkg")" \
    "$(jnum "$days")" \
    "$(jnum "$count30d")" \
    "$(jnum "$sec_pending")" \
    "$(jnum "$other_pending")" \
    "$reboot" \
    "$assessed_fresh" \
    "$(jstr "$source")"
