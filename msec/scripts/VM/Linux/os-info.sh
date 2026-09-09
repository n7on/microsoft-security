#!/usr/bin/env bash
# Example script - print basic OS / kernel / uptime info.
# Read-only; safe to run anywhere.
set -euo pipefail

echo "hostname:      $(hostname)"
echo "kernel:        $(uname -r)"
echo "uptime:        $(uptime -p)"

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "distribution:  ${PRETTY_NAME:-unknown}"
fi
