#!/usr/bin/env bash
# last-updated: when did this machine last install/upgrade packages, regardless of
# whether Azure Update Manager or in-guest auto-update did it? Read-only.
#
# Emits a single JSON object on stdout (PascalCase keys), e.g.:
#   {"NowUtc":"2026-06-15T08:00:00Z","LastUpdate":"2026-05-12T03:14:00Z",
#    "LastUpdatePackage":"openssl:amd64","DaysSinceUpdate":34,"UpdateCount30d":12,
#    "Source":"dpkg.log"}
#
# No strict mode - we want partial results (nulls) if a log/tool is missing rather
# than a hard failure that yields no row.

now_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
last_local=""      # newest install/upgrade timestamp, in the VM's LOCAL time
last_pkg=""
count30d=""        # left null unless we can compute it (dpkg path)
source=""

# Concatenate current + rotated dpkg logs (plain and gzipped) to one stream.
dpkg_stream() {
    local f
    for f in /var/log/dpkg.log /var/log/dpkg.log.1; do
        [ -r "$f" ] && cat "$f"
    done
    for f in /var/log/dpkg.log.*.gz; do
        [ -r "$f" ] && zcat "$f" 2>/dev/null
    done
}

if command -v dpkg >/dev/null 2>&1 && ls /var/log/dpkg.log* >/dev/null 2>&1; then
    source="dpkg.log"
    # dpkg lines:  YYYY-MM-DD HH:MM:SS <action> <pkg:arch> <oldver> <newver>
    # State changes that mean "the box got patched" are install + upgrade.
    line="$(dpkg_stream | awk '$3=="upgrade" || $3=="install"' | sort | tail -n1)"
    if [ -n "$line" ]; then
        last_local="$(echo "$line" | awk '{print $1" "$2}')"
        last_pkg="$(echo "$line" | awk '{print $4}')"
    fi
    cutoff="$(date -d '30 days ago' +%Y-%m-%d 2>/dev/null)"
    if [ -n "$cutoff" ]; then
        # ISO dates compare correctly as plain strings, so a lexical >= works.
        count30d="$(dpkg_stream | awk -v c="$cutoff" '($3=="upgrade" || $3=="install") && $1 >= c' | wc -l | tr -d ' ')"
    fi
elif command -v rpm >/dev/null 2>&1; then
    source="rpm"
    # rpm -qa --last prints newest first: "<name-version>   <Day Mon DD HH:MM:SS YYYY>"
    last_line="$(rpm -qa --last 2>/dev/null | head -n1)"
    if [ -n "$last_line" ]; then
        last_pkg="$(echo "$last_line" | awk '{print $1}')"
        last_local="$(echo "$last_line" | sed 's/^[^ ]* *//')"
    fi
fi

# Convert the local timestamp to UTC and compute elapsed days. `date -d` parses the
# naive string in the VM's local TZ; `-u` then renders it as UTC, so no manual offset.
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

printf '{"NowUtc":"%s","LastUpdate":%s,"LastUpdatePackage":%s,"DaysSinceUpdate":%s,"UpdateCount30d":%s,"Source":%s}\n' \
    "$now_utc" \
    "$(jstr "$last_utc")" \
    "$(jstr "$last_pkg")" \
    "${days:-null}" \
    "${count30d:-null}" \
    "$(jstr "$source")"
