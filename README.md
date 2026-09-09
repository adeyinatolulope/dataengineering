# Linux and Git Project — CoreDataEngineers

A Bash-only data pipeline for CoreDataEngineers: a scheduled ETL job over the
New Zealand Annual Enterprise Survey (2023 financial year, provisional), plus a
file-organisation utility. Everything is written in Bash — no Python, no pandas.

---

## Contents

| File | Purpose |
|---|---|
| `etl.sh` | Task 1 — Extract, Transform, Load |
| `setup_cron.sh` | Task 2 — installs the daily 12:00 AM cron job |
| `move_files.sh` | Task 3 — moves CSV and JSON files into `json_and_CSV/` |
| `.env.example` | Template for the environment variables |
| `.gitignore` | Keeps `.env`, `logs/` and `raw/` out of version control |

Directories created at runtime: `raw/`, `Transformed/`, `Gold/`, `logs/`, `json_and_CSV/`.

---

## Quick start

```bash
git clone <your-repo-url>
cd <repo>

# 1. Configure the source URL
cp .env.example .env

# 2. Make the scripts executable
chmod +x etl.sh move_files.sh setup_cron.sh

# 3. Run the pipeline
./etl.sh

# 4. Schedule it for midnight, daily
./setup_cron.sh
```

**Requirements:** Bash 4+, `curl` (or `wget`), `awk`, `coreutils`. All standard on
Ubuntu/Debian/RHEL and on macOS.

---

## Task 1 — The ETL script (`etl.sh`)

### Environment variables

The source URL is never hardcoded. It is read from `CSV_URL`, which `etl.sh`
loads from `.env`:

```bash
CSV_URL="https://www.stats.govt.nz/assets/Uploads/Annual-enterprise-survey/Annual-enterprise-survey-2023-financial-year-provisional/Download-data/annual-enterprise-survey-2023-financial-year-provisional.csv"
```

The script aborts with a clear message if `CSV_URL` is unset. `RAW_DIR`,
`TRANSFORMED_DIR`, `GOLD_DIR` and `LOG_DIR` can also be overridden the same way,
and fall back to defaults when they aren't.

`.env` is git-ignored; `.env.example` is committed so the repo stays reproducible
without leaking anything machine-specific.

### Extract

Downloads the CSV into `raw/annual-enterprise-survey-2023.csv`.

- Downloads to a temp file first, then moves it into place, so a half-finished
  download can never overwrite a good previous extract.
- `curl -f` fails loudly on HTTP errors instead of saving an HTML error page as
  if it were data. Retries 3 times for transient network problems.
- Falls back to `wget` if `curl` isn't installed.
- **Confirmation:** checks the file exists and is non-empty, then prints its
  path, human-readable size, and row count.

### Transform

Renames `Variable_code` to `variable_code`, selects `Year, Value, Units,
variable_code`, and writes `Transformed/2023_year_finance.csv`.

**Why this uses `awk` and not `cut -d,`:** this is the part of the task that
quietly goes wrong. The source CSV contains quoted fields with embedded commas:

```
2023,Level 2,AA,"Agriculture, Forestry and Fishing",Dollars (millions),H04,...
```

Splitting on every comma shifts every column after that field. Compare, on the
same input:

```
# cut -d, -f1,5,6,9  →  WRONG
2023, Forestry and Fishing",Dollars (millions), government funding

# this script          →  CORRECT
2023,56451,Dollars (millions),H04
```

`cut` also can't reorder columns — it always emits them in file order,
regardless of the order you list them.

So the transform step embeds a small RFC-4180 CSV parser in `awk` that tracks
quote state, treats `""` as an escaped quote, and re-quotes output fields that
need it (a `Value` like `875,166` comes back out as `"875,166"`).

Two more details:

- Column lookup is **case-insensitive**, so the script works whether the header
  says `Year` or `year`, `Variable_code` or `variable_code`. It also fails
  explicitly and names the missing column rather than emitting a silently
  truncated file.
- Output is written to a temp file and moved into place only after `awk` exits
  successfully. Redirecting straight into `Transformed/` would truncate
  yesterday's good file the moment `awk` started — so a failed run would destroy
  valid data. (This bug was in the first draft; the test that caught it is in
  "Testing" below.)

**Confirmation:** verifies the file is non-empty, then prints the path, row
count, the resulting header, and a sample row.

### Load

Copies the transformed file into `Gold/2023_year_finance.csv`.

**Confirmation:** verifies the file exists *and* compares MD5 checksums between
`Transformed/` and `Gold/`, so a truncated copy is caught rather than reported
as a success.

### Sample output

```
[2026-09-09 20:08:50] ==============================================================
[2026-09-09 20:08:50] ETL run started.
[2026-09-09 20:08:50] Directories ready: raw/, Transformed/, Gold/
[2026-09-09 20:08:50] STEP 1/3  EXTRACT — downloading source CSV...
[2026-09-09 20:08:50] SUCCESS: file saved to raw/
[2026-09-09 20:08:50]          rows : 4 (excluding header)
[2026-09-09 20:08:50] STEP 2/3  TRANSFORM — renaming column and selecting fields...
[2026-09-09 20:08:50] Renamed column : Variable_code -> variable_code
[2026-09-09 20:08:50] SUCCESS: 2023_year_finance.csv saved to Transformed/
[2026-09-09 20:08:50]          header: Year,Value,Units,variable_code
[2026-09-09 20:08:50] STEP 3/3  LOAD — publishing to Gold/...
[2026-09-09 20:08:50] SUCCESS: 2023_year_finance.csv loaded into Gold/
[2026-09-09 20:08:50]          checksum : ea77ff56... (matches Transformed/)
[2026-09-09 20:08:50] ETL run completed successfully.
```

### Error handling

`set -Eeuo pipefail` plus an `ERR` trap means the script stops at the first
failure instead of carrying on with bad data. Every failure prints a specific,
actionable message and exits non-zero, which is what makes the cron job
diagnosable:

| Situation | Behaviour |
|---|---|
| `CSV_URL` unset | Aborts before touching the network |
| Download fails / 404 | Aborts; previous `raw/` file untouched |
| Downloaded file empty | Aborts before transforming |
| Required column missing | Names the column; previous output intact |
| `Gold/` copy corrupted | Checksum mismatch reported as a failure |

---

## Task 2 — Scheduling with cron

`./setup_cron.sh` installs this entry:

```cron
0 0 * * * /absolute/path/to/etl.sh >> /absolute/path/to/logs/cron.log 2>&1
```

Reading the five fields left to right:

```
┌───────── minute       (0)
│ ┌─────── hour         (0)      → 0 minutes past hour 0 = 00:00, midnight
│ │ ┌───── day of month (*)
│ │ │ ┌─── month        (*)
│ │ │ │ ┌─ day of week  (*)      → every day
0 0 * * *  /path/to/etl.sh >> /path/to/logs/cron.log 2>&1
```

`>>` appends stdout to the log; `2>&1` sends stderr to the same place, so a
failed run leaves a trace instead of vanishing.

The install is idempotent — it strips any existing entry for `etl.sh` before
adding the new one, so running it twice doesn't schedule the job twice.

```bash
crontab -l                                  # verify
crontab -l | grep -Fv 'etl.sh' | crontab -  # remove
```

**Why cron needs absolute paths.** Cron runs with a minimal environment: a bare
`PATH`, no `.bashrc`, and an unpredictable working directory. Scripts that work
in a terminal and mysteriously fail at midnight are almost always relying on the
shell environment. `etl.sh` handles this by resolving `SCRIPT_DIR` from
`BASH_SOURCE` and anchoring every path to it, and by sourcing `.env` itself
rather than expecting the variables to be inherited.

To edit the schedule by hand instead: `crontab -e`.

---

## Task 3 — Moving CSV and JSON files (`move_files.sh`)

```bash
./move_files.sh <source_dir> [destination_dir]

./move_files.sh sample_data              # → ./json_and_CSV
./move_files.sh ~/Downloads /data/out    # → custom destination
```

Handles one file or many. Specifically:

- **Filenames with spaces** — `find -print0` with `read -d ''` (a plain
  `for f in $(ls)` splits `quarterly report 2023.csv` into two broken paths).
- **Mixed-case extensions** — `-iname` catches `.CSV`, `.Json`, `.csv` alike.
- **Name collisions** — never overwrites. `orders.csv` becomes `orders_1.csv`
  and the rename is logged.
- **Empty source** — reports "nothing to move" instead of failing.
- **Same source and destination** — refuses, rather than moving files onto
  themselves.

Non-matching files (`.txt`, etc.) are left where they are. Output lists every
file moved, then the final contents of the destination.

```
[2026-09-09 20:08:59] MOVED   empty_list.Json
[2026-09-09 20:08:59] MOVED   quarterly report 2023.CSV
[2026-09-09 20:08:59] RENAME  orders.csv -> orders_1.csv  (name already taken)
[2026-09-09 20:08:59] MOVED   orders.csv
[2026-09-09 20:08:59] MOVED   config.json
[2026-09-09 20:08:59] Done. Moved 4 file(s); 1 renamed to avoid collisions; 0 failed.
```

`-maxdepth 1` restricts the search to the top level; remove that flag in the
`find` call to recurse into subdirectories.

---

## Task 4 — Version control

The full history is in git, with each task committed separately:

```bash
git log --oneline
```

`.gitignore` excludes:

- `.env` — machine-specific configuration
- `logs/` — runtime output, regenerated every run
- `raw/` — downloaded source data, re-fetched by `etl.sh` on every run

`Transformed/` and `Gold/` are committed so the pipeline's output is visible in
the repo.

---

## Testing

The scripts were tested against a fixture reproducing the awkward parts of the
real dataset — quoted fields containing commas, a numeric value formatted as
`"875,166"`, and mixed-case headers.

Cases verified:

- Happy path end to end; `Gold/` matches `Transformed/` by checksum
- Quoted commas parsed correctly (and demonstrably wrong under `cut -d,`)
- `CSV_URL` unset → clean abort
- Unreachable URL → clean abort, no partial file in `raw/`
- Header missing a required column → named error, **previous good output in
  `Transformed/` left byte-identical**
- `move_files.sh` with spaces in filenames, `.CSV`/`.Json` casing, a
  pre-existing collision, and a `.txt` file that correctly stayed put

To reproduce without hitting the network, `CSV_URL` accepts a `file://` URL:

```bash
CSV_URL="file:///tmp/fixture/source.csv" ./etl.sh
```

---

## Design notes

**Idempotency.** Re-running `etl.sh` produces the same result and overwrites
cleanly. Safe for a daily schedule.

**Atomic writes.** Both the download and the transform write to a temp file and
move into place only on success. A failed run never leaves a truncated file
where a valid one used to be.

**Verification over assumption.** Each stage checks that its output actually
exists and is non-empty before reporting success — the difference between "the
command ran" and "the data is there".
