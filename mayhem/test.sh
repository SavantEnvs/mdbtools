#!/usr/bin/env bash
# mayhem/test.sh — RUNS upstream's own regression suites (test_script.sh: CLI tools over the mdbtestdata
# databases + tests/cli golden outputs; test_sql.sh: tests/sql golden outputs through mdb-sql), against
# the in-tree normal build produced by mayhem/build.sh. exit 0 = pass. Does not compile.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


for b in mdb-json mdb-count mdb-prop mdb-schema mdb-tables mdb-ver mdb-queries mdb-sql; do
  [ -x "src/util/$b" ] || { echo "missing src/util/$b — mayhem/build.sh must build it" >&2; emit_ctrf "mdbtools-shell" 0 1 0; exit 1; }
done

# upstream's scripts read the mdbtestdata checkout from ./test (gitignored); stage it from the committed copy
rm -rf test
cp -r mayhem/testdata test

# upstream's script sets only LANG, which an inherited LC_ALL=C would override; the tests need UTF-8 argv
export LC_ALL=C.UTF-8

out_cli="$(sh ./test_script.sh -q 2>&1)"; rc_cli=$?
printf '%s\n' "$out_cli" | grep -E 'passed\.|failed' | tail -n 40
# a failing quiet-mode check prints no newline, so count "passed." occurrences, not lines
cli_pass=$(printf '%s\n' "$out_cli" | grep -o 'passed\.' | wc -l)
# the final "<script> passed." summary line is not a test
[ "$rc_cli" -eq 0 ] && cli_pass=$((cli_pass - 1))
cli_total=$(( $(grep -c 'testCommand mdb-' test_script.sh) + $(ls tests/cli/*.cmd | wc -l) ))
cli_fail=$((cli_total - cli_pass))
[ "$rc_cli" -ne 0 ] && [ "$cli_fail" -le 0 ] && cli_fail=1

out_sql="$(bash ./test_sql.sh 2>&1)"; rc_sql=$?
printf '%s\n' "$out_sql" | tail -n 40
sql_total=$(ls tests/sql/*.sql | wc -l)
sql_fail=$(printf '%s\n' "$out_sql" | grep -c '^FAILED: ' || true)
[ "$rc_sql" -ne 0 ] && [ "$sql_fail" -eq 0 ] && sql_fail=1
sql_pass=$((sql_total - sql_fail))
[ "$rc_sql" -eq 0 ] && ! printf '%s\n' "$out_sql" | grep -q 'SQL regression tests passed.' && { sql_pass=0; sql_fail=$sql_total; }

emit_ctrf "mdbtools-shell" $((cli_pass + sql_pass)) $((cli_fail + sql_fail)) 0
