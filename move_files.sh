#!/usr/bin/env bash
#
# move_files.sh — Move every CSV and JSON file from a source folder into a
#                 destination folder named `json_and_CSV`.
#
# Usage:
#   ./move_files.sh <source_dir> [destination_dir]
#
# Examples:
#   ./move_files.sh sample_data
#   ./move_files.sh ~/Downloads /data/json_and_CSV
#
# Handles: one or many files, filenames containing spaces, upper/lower case
# extensions (.CSV / .Csv / .json), name collisions, and empty source folders.
#

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '[%s] %s\n'       "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { printf '[%s] ERROR %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") <source_dir> [destination_dir]

  source_dir        folder to search for .csv and .json files
  destination_dir   where to move them (default: ./json_and_CSV)
EOF
    exit 1
}

# --- Arguments ----------------------------------------------------------------
[[ $# -ge 1 && $# -le 2 ]] || usage

SRC_DIR="$1"
DEST_DIR="${2:-$SCRIPT_DIR/json_and_CSV}"

[[ -d "$SRC_DIR" ]] || die "Source directory does not exist: $SRC_DIR"

# Resolve both to absolute paths so we can safely compare them.
SRC_DIR="$(cd "$SRC_DIR" && pwd)"
mkdir -p "$DEST_DIR"
DEST_DIR="$(cd "$DEST_DIR" && pwd)"

[[ "$SRC_DIR" != "$DEST_DIR" ]] || die "Source and destination are the same directory."

log "Source      : $SRC_DIR"
log "Destination : $DEST_DIR"
log "--------------------------------------------------------------"

# --- Find the files -----------------------------------------------------------
# -maxdepth 1 : top level only (drop this line to recurse into subfolders)
# -iname       : case-insensitive, so .CSV and .Csv are caught too
# -print0 / read -d '' : NUL-separated, the only safe way to handle filenames
#                        that contain spaces or newlines
moved=0
skipped=0
renamed=0

while IFS= read -r -d '' file; do
    base="$(basename "$file")"
    target="$DEST_DIR/$base"

    # Collision handling: never silently overwrite an existing file.
    if [[ -e "$target" ]]; then
        stem="${base%.*}"
        ext="${base##*.}"
        n=1
        while [[ -e "$DEST_DIR/${stem}_$n.$ext" ]]; do
            n=$((n + 1))
        done
        target="$DEST_DIR/${stem}_$n.$ext"
        log "RENAME  $base -> $(basename "$target")  (name already taken)"
        renamed=$((renamed + 1))
    fi

    if mv -- "$file" "$target"; then
        log "MOVED   $base"
        moved=$((moved + 1))
    else
        log "FAILED  $base"
        skipped=$((skipped + 1))
    fi
done < <(find "$SRC_DIR" -maxdepth 1 -type f \( -iname '*.csv' -o -iname '*.json' \) -print0)

# --- Report -------------------------------------------------------------------
log "--------------------------------------------------------------"
if [[ $moved -eq 0 ]]; then
    log "No .csv or .json files found in $SRC_DIR — nothing to move."
else
    log "Done. Moved $moved file(s); $renamed renamed to avoid collisions; $skipped failed."
    log "Contents of $DEST_DIR:"
    ls -lh "$DEST_DIR" | tail -n +2 | while read -r line; do log "  $line"; done
fi

exit 0
