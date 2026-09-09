#!/usr/bin/env bash
#
# etl.sh — Simple ETL pipeline for the NZ Annual Enterprise Survey (2023).
#
#   Extract   : download the source CSV into ./raw
#   Transform : rename `Variable_code` -> `variable_code`, keep only
#               Year, Value, Units, variable_code, write ./Transformed/2023_year_finance.csv
#   Load      : copy the transformed file into ./Gold and verify it
#
# The source URL is read from the CSV_URL environment variable (see .env.example).
#
# Usage:  ./etl.sh
#

# --- Shell safety options -----------------------------------------------------
# -E : ERR trap is inherited by functions and subshells
# -e : exit immediately if any command fails
# -u : treat unset variables as an error
# -o pipefail : a pipeline fails if ANY command in it fails, not just the last
set -Eeuo pipefail

# --- Resolve paths ------------------------------------------------------------
# cron runs with a minimal environment and an unpredictable working directory,
# so every path is anchored to the directory this script lives in.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- Load environment variables ----------------------------------------------
# `set -a` marks everything defined afterwards for export, so sourcing .env
# turns its KEY=value lines into real environment variables.
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi

# ${VAR:?message} aborts with `message` if VAR is unset or empty.
: "${CSV_URL:?CSV_URL is not set. Copy .env.example to .env or run: export CSV_URL=...}"

# Directory layout (overridable from .env, with sensible defaults)
RAW_DIR="${RAW_DIR:-$SCRIPT_DIR/raw}"
TRANSFORMED_DIR="${TRANSFORMED_DIR:-$SCRIPT_DIR/Transformed}"
GOLD_DIR="${GOLD_DIR:-$SCRIPT_DIR/Gold}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"

RAW_FILE="$RAW_DIR/annual-enterprise-survey-2023.csv"
OUT_FILE="2023_year_finance.csv"

# --- Logging helpers ----------------------------------------------------------
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/etl.log"

log()  { printf '[%s] %s\n'        "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] WARN  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { printf '[%s] ERROR %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

# Fire on any unhandled failure so a cron run never fails silently.
trap 'die "Script failed at line $LINENO (exit code $?)."' ERR

# =============================================================================
# STEP 0 — Preparation
# =============================================================================
log "=============================================================="
log "ETL run started."
log "Source URL : $CSV_URL"

# -p creates parent directories as needed and does not error if they exist.
mkdir -p "$RAW_DIR" "$TRANSFORMED_DIR" "$GOLD_DIR"
log "Directories ready: raw/, Transformed/, Gold/"

# =============================================================================
# STEP 1 — EXTRACT: download the CSV into raw/
# =============================================================================
log "--------------------------------------------------------------"
log "STEP 1/3  EXTRACT — downloading source CSV..."

# Download to a temporary file first, then move it into place. That way a
# failed or partial download can never overwrite a good previous extract.
TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/etl_download.XXXXXX")"
# Clean the temp file up however the script exits.
trap 'rm -f "$TMP_FILE"' EXIT

if command -v curl >/dev/null 2>&1; then
    # -f fail on HTTP errors, -s silent, -S still show errors,
    # -L follow redirects, --retry survive transient network blips
    curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 \
         -o "$TMP_FILE" "$CSV_URL" \
        || die "Download failed. Check CSV_URL and your network connection."
elif command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 --timeout=30 -O "$TMP_FILE" "$CSV_URL" \
        || die "Download failed. Check CSV_URL and your network connection."
else
    die "Neither curl nor wget is installed. Install one of them and retry."
fi

# -s : file exists AND is larger than zero bytes.
[[ -s "$TMP_FILE" ]] || die "Downloaded file is empty — nothing to process."

mv "$TMP_FILE" "$RAW_FILE"
trap - EXIT   # temp file no longer exists, cancel the cleanup trap

# --- Confirm the file really landed in raw/ ---
if [[ -f "$RAW_FILE" ]]; then
    RAW_ROWS=$(($(wc -l < "$RAW_FILE") - 1))   # minus the header row
    RAW_SIZE=$(du -h "$RAW_FILE" | cut -f1)
    log "SUCCESS: file saved to raw/"
    log "         path : $RAW_FILE"
    log "         size : $RAW_SIZE"
    log "         rows : $RAW_ROWS (excluding header)"
else
    die "Expected file not found in $RAW_DIR after download."
fi

# =============================================================================
# STEP 2 — TRANSFORM: rename the column, select four columns
# =============================================================================
log "--------------------------------------------------------------"
log "STEP 2/3  TRANSFORM — renaming column and selecting fields..."

# WHY AWK AND NOT `cut -d,`:
# This CSV contains quoted fields with embedded commas, e.g.
#     "Agriculture, Forestry and Fishing"
# Splitting on every comma would shift the columns and silently produce
# wrong data. The awk program below implements a real RFC-4180 CSV parser:
# it tracks whether it is inside a quoted field, handles "" as an escaped
# quote, and re-quotes any output field that needs it.
#
# As with the download, output goes to a temp file first. Redirecting straight
# into Transformed/ would truncate the previous good file the instant awk was
# invoked — so a failed run would destroy yesterday's valid output.

TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/etl_transform.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

awk '
# ---- Parse one CSV line into arr[1..n]; returns n ----
function parse_csv(line, arr,    i, n, ch, nxt, field, in_quotes) {
    n = 0; field = ""; in_quotes = 0
    for (i = 1; i <= length(line); i++) {
        ch = substr(line, i, 1)
        if (in_quotes) {
            if (ch == "\"") {
                nxt = substr(line, i + 1, 1)
                if (nxt == "\"") { field = field "\""; i++ }   # escaped quote
                else             { in_quotes = 0 }             # closing quote
            } else {
                field = field ch
            }
        } else {
            if      (ch == "\"") { in_quotes = 1 }
            else if (ch == ",")  { arr[++n] = field; field = "" }
            else                 { field = field ch }
        }
    }
    arr[++n] = field
    return n
}

# ---- Re-quote a field for output only when necessary ----
function csv_quote(s) {
    if (s ~ /[",\r\n]/) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
    return s
}

function lower(s) { return tolower(s) }

BEGIN { FS = "\n" }

{
    sub(/\r$/, "", $0)          # strip Windows CR if the file is CRLF
}

# ---- Header row: locate the columns we want ----
NR == 1 {
    ncols = parse_csv($0, head)

    # Match column names case-insensitively so the script survives
    # `Year` vs `year` and `Variable_code` vs `variable_code`.
    for (i = 1; i <= ncols; i++) {
        key = lower(head[i])
        gsub(/^[ \t]+|[ \t]+$/, "", key)
        pos[key] = i
    }

    split("year,value,units,variable_code", want, ",")
    # The header we WRITE out — this is where the rename happens:
    # Variable_code becomes variable_code.
    split("Year,Value,Units,variable_code", out_names, ",")

    for (j = 1; j <= 4; j++) {
        if (!(want[j] in pos)) {
            printf("TRANSFORM ERROR: required column \"%s\" not found in header.\n", want[j]) > "/dev/stderr"
            exit 3
        }
        idx[j] = pos[want[j]]
    }

    printf("%s,%s,%s,%s\n", out_names[1], out_names[2], out_names[3], out_names[4])
    next
}

# ---- Data rows ----
{
    if ($0 ~ /^[ \t]*$/) next            # skip blank lines
    n = parse_csv($0, f)
    if (n < ncols) { skipped++; next }   # malformed / truncated row
    printf("%s,%s,%s,%s\n",
           csv_quote(f[idx[1]]), csv_quote(f[idx[2]]),
           csv_quote(f[idx[3]]), csv_quote(f[idx[4]]))
    kept++
}

END {
    printf("rows_kept=%d rows_skipped=%d\n", kept, skipped) > "/dev/stderr"
}
' "$RAW_FILE" > "$TMP_OUT" 2> "$LOG_DIR/transform_stats.txt" \
    || die "Transformation failed (previous output left intact). See $LOG_DIR/transform_stats.txt"

# Only now, with awk having exited 0, do we replace the published file.
[[ -s "$TMP_OUT" ]] || die "Transformation produced an empty file (previous output left intact)."
mv "$TMP_OUT" "$TRANSFORMED_DIR/$OUT_FILE"
trap - EXIT

log "Renamed column : Variable_code -> variable_code"
log "Selected columns: Year, Value, Units, variable_code"
log "Parser stats   : $(cat "$LOG_DIR/transform_stats.txt")"

# --- Confirm the file really landed in Transformed/ ---
if [[ -s "$TRANSFORMED_DIR/$OUT_FILE" ]]; then
    T_ROWS=$(($(wc -l < "$TRANSFORMED_DIR/$OUT_FILE") - 1))
    log "SUCCESS: $OUT_FILE saved to Transformed/"
    log "         path : $TRANSFORMED_DIR/$OUT_FILE"
    log "         rows : $T_ROWS (excluding header)"
    log "         header: $(head -n 1 "$TRANSFORMED_DIR/$OUT_FILE")"
    log "         sample: $(sed -n '2p' "$TRANSFORMED_DIR/$OUT_FILE")"
else
    die "Transformed file is missing or empty in $TRANSFORMED_DIR."
fi

# =============================================================================
# STEP 3 — LOAD: publish the transformed file into Gold/
# =============================================================================
log "--------------------------------------------------------------"
log "STEP 3/3  LOAD — publishing to Gold/..."

cp "$TRANSFORMED_DIR/$OUT_FILE" "$GOLD_DIR/$OUT_FILE"

# --- Confirm the file landed in Gold/ AND is byte-identical to the source ---
if [[ -f "$GOLD_DIR/$OUT_FILE" ]]; then
    SRC_SUM=$(md5sum "$TRANSFORMED_DIR/$OUT_FILE" | awk '{print $1}')
    DST_SUM=$(md5sum "$GOLD_DIR/$OUT_FILE"        | awk '{print $1}')
    if [[ "$SRC_SUM" == "$DST_SUM" ]]; then
        G_ROWS=$(($(wc -l < "$GOLD_DIR/$OUT_FILE") - 1))
        log "SUCCESS: $OUT_FILE loaded into Gold/"
        log "         path     : $GOLD_DIR/$OUT_FILE"
        log "         rows     : $G_ROWS (excluding header)"
        log "         checksum : $DST_SUM (matches Transformed/)"
    else
        die "Checksum mismatch — the copy in Gold/ does not match Transformed/."
    fi
else
    die "Expected file not found in $GOLD_DIR after load."
fi

# =============================================================================
# Summary
# =============================================================================
log "--------------------------------------------------------------"
log "ETL run completed successfully."
log "  raw/         $(basename "$RAW_FILE")   ($RAW_ROWS rows)"
log "  Transformed/ $OUT_FILE   ($T_ROWS rows)"
log "  Gold/        $OUT_FILE   ($G_ROWS rows)"
log "=============================================================="

exit 0
