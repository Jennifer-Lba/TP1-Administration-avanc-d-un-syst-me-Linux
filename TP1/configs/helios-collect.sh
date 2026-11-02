#!/usr/bin/bash
# Collecteur de telemetrie Helios - boucle longue duree
set -euo pipefail
INTERVAL="${HELIOS_INTERVAL:-15}"
OUT=/var/lib/helios/telemetry.csv
while :; do
    printf '%s,%s,%s\n' "$(date --iso-8601=seconds)" \
        "$(awk '{print $1}' /proc/loadavg)" \
        "$(awk '/MemAvailable/ {print $2}' /proc/meminfo)" >> "$OUT"
    sleep "$INTERVAL"
done
