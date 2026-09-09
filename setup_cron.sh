#!/usr/bin/env bash
#
# setup_cron.sh — Install the daily 12:00 AM cron job for etl.sh.
#
# Cron field order:  minute hour day-of-month month day-of-week  command
#                    0      0    *            *     *
#                    ^ minute 0 of hour 0 = 00:00 (midnight), every day.
#
# Run:  ./setup_cron.sh
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETL="$SCRIPT_DIR/etl.sh"
LOG="$SCRIPT_DIR/logs/cron.log"

[[ -x "$ETL" ]] || { echo "ERROR: $ETL is missing or not executable (chmod +x etl.sh)."; exit 1; }
mkdir -p "$SCRIPT_DIR/logs"

# >> appends stdout, 2>&1 redirects stderr to the same place, so nothing is lost.
CRON_LINE="0 0 * * * $ETL >> $LOG 2>&1"

# Read the current crontab (|| true so an empty crontab is not an error),
# strip any previous entry for this script, then append the new one.
( crontab -l 2>/dev/null || true ) | grep -Fv "$ETL" | { cat; echo "$CRON_LINE"; } | crontab -

echo "Cron job installed:"
echo "  $CRON_LINE"
echo
echo "Verify with:  crontab -l"
echo "Remove with:  crontab -l | grep -Fv '$ETL' | crontab -"
