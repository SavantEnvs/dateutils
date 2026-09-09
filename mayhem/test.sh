#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral oracle for dateutils.
#
# Runs the CLEAN (non-sanitized), dynamically-linked `dconv`/`ddiff` binaries
# (built by mayhem/build.sh from the real lib/*.c) on fixed date inputs and
# asserts EXACT computed outputs — known-answer tests over the calendar engine
# (weekday, leap-day weekday, format reformatting, day-of-year, ISO week date,
# Unix epoch, day count). A PATCH that neuters the program to a no-op (or the
# verify-repo sabotage shim that LD_PRELOADs a constructor which _exit(0)s the
# binary before it computes anything) produces empty output, so every assertion
# FAILS. bash/coreutils do the comparison and are whitelisted by the shim, so
# the check happens where sabotage cannot hide.
#
# Emits a CTRF summary + a compact `CTRF {...}` stdout marker; exit non-zero iff
# failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
SRC="${SRC:-/mayhem}"
cd "$SRC"

DCONV=/mayhem/dconv
DDIFF=/mayhem/ddiff

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

# Fail loudly if build.sh did not produce the oracle binaries (a build bug, not a skip).
for b in "$DCONV" "$DDIFF"; do
  if [ ! -x "$b" ]; then
    echo "FATAL: $b missing/not executable — mayhem/build.sh did not build the oracle" >&2
    emit_ctrf "dateutils-kat" 0 1 0
    exit 1
  fi
done

passed=0
failed=0

# kat <label> <expected-exact-output> <cmd...>
kat() {
  local label="$1" want="$2"; shift 2
  local got
  got="$("$@" 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    echo "PASS  $label -> '$got'"
    passed=$((passed + 1))
  else
    echo "FAIL  $label : want='$want' got='$got'"
    failed=$((failed + 1))
  fi
}

# Known-answer tests (values verified against the built dconv/ddiff):
kat "weekday 2024-01-01"        "Monday"     "$DCONV" -i '%Y-%m-%d' -f '%A' 2024-01-01
kat "weekday 2000-02-29(leap)"  "Tuesday"    "$DCONV" -i '%Y-%m-%d' -f '%A' 2000-02-29
kat "reformat 2024-03-15"       "15.03.2024" "$DCONV" -i '%Y-%m-%d' -f '%d.%m.%Y' 2024-03-15
kat "day-of-year 2024-03-01"    "061"        "$DCONV" -i '%Y-%m-%d' -f '%j' 2024-03-01
kat "iso-week 2021-01-04"       "2021-W01-1" "$DCONV" -i '%Y-%m-%d' -f '%Y-W%V-%u' 2021-01-04
kat "unix-epoch"                "0"          "$DCONV" -i '%Y-%m-%dT%H:%M:%S' -f '%s' 1970-01-01T00:00:00
kat "ddiff days 2024"           "365"        "$DDIFF" 2024-01-01 2024-12-31

emit_ctrf "dateutils-kat" "$passed" "$failed" 0
