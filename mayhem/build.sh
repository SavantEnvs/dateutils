#!/usr/bin/env bash
#
# mayhem/build.sh — build dateutils' fuzz harness + the behavioral-oracle binary.
#
# Fuzz targets (one mayhem/Mayhemfile_* each, ALL built here):
#   CLI tools — dateutils' PUBLIC interface: nine of the ten command-line tools src/
#               ships (strptime dadd dconv ddiff dgrep dround dseq dtest dzone), built
#               by the project's own automake rules in the sanitized VPATH tree
#               (build-fuzz/, $SANITIZER_FLAGS + $DEBUG_FLAGS + -fsanitize=fuzzer-no-link
#               so Mayhem derives edge coverage) and installed at /mayhem/cli/<tool>.
#               RAW (non-libFuzzer, process-per-input) targets: the tools read their date
#               stream on stdin exactly as in production; Mayhem stages the input as `@@`
#               and the wrapper opens it as stdin (the shell's `tool < file`, in-process).
#               Upstream's main() is renamed in the FUZZ build only (-Dmain=dateutils_tool_main
#               via CFLAGS — no upstream file is edited) and called by the input adapter
#               mayhem/harnesses/stdin_main.c (argv otherwise unchanged). dseq, dtest and dzone
#               take their only untrusted input on the command line, so those three are linked
#               with mayhem/harnesses/argv_main.c instead (the `@@` file becomes argv, one
#               argument per line). Neither adapter has a timer: the hang bound is Mayhem's
#               explicit per-input `timeout: 5` in each Mayhemfile (`dgrep EXPR < random-bytes`
#               was observed never to return and is reported by Mayhem as a timeout).
#               The tenth tool, dsort, gets NO target: it is a thin wrapper that vfork()+
#               execvp()s the external sort(1) and cut(1) and pipes its lines through them
#               (src/dsort.c spawn_sort/spawn_cut). Under Mayhem's tracer every test case
#               timed out (run #1: "the target times out on every test case ... and on the
#               default test case"), i.e. a process-spawning pipeline is not fuzzable there,
#               while its own date parsing is the same prchunk + dt_strpdt() path the other
#               nine tools exercise. Recorded as `dropped-target:dsort` in repos/dateutils.yaml.
#   fuzz_strpdt — in-process libFuzzer harness over dt_strpdt()/dt_strpdtdur()
#                 (lib/dt-core.c), dateutils' format-autodetecting date/time
#                 string parser — the engine behind dconv/strptime/dseq. Kept
#                 alongside the CLI targets: it fuzzes the parser byte-for-byte
#                 without the line/chunk framing and has run history + a confirmed
#                 defect (mayhem/fuzz_strpdt/known-findings/).
#
# LeakSanitizer is switched off at BUILD time for every ASan-built binary via
# mayhem/lsan_off.cc (__lsan_is_turned_off hook, fleet policy — PORTING.md); ASan +
# UBSan stay on and halting. (Without it dgrep/dround abort on LSan reports on
# ordinary input.)
#
# dateutils is a GNU autotools project. It is NOT built with a bundled tarball's
# pre-generated files, so we run `autoreconf -i` and configure it from scratch.
# Extra host tools required (installed as root in mayhem/Dockerfile): gperf
# (generates lib/fmt-special.c), libtool + libltdl-dev (LT_INIT / ltdl m4 macros
# used by configure.ac), and the bundled `yuck` codegen tool (built from
# build-aux/ during the build). Everything is baked into the image, so the
# offline PATCH re-run needs no network.
#
# Two independent VPATH builds keep the source tree pristine (no in-source
# configure, so a second VPATH configure does not error with "source directory
# already configured"):
#   build-oracle/ — the project's NORMAL flags -> a CLEAN, dynamically-linked
#                   `dconv` used by mayhem/test.sh as the behavioral oracle.
#   build-fuzz/   — libdut.a compiled with $SANITIZER_FLAGS + $DEBUG_FLAGS +
#                   -fsanitize=fuzzer-no-link (coverage) for the fuzz target.
#
# SANITIZERS: base default is ASan + UBSan, both halting. We relax exactly TWO
# UBSan checks for the fuzz build, each a benign pattern that would otherwise
# abort essentially every input (PORTING.md "benign UB that floods under
# halting UBSan"):
#   * `signed-integer-overflow` — lib/strops.c's integer scanners (strtoi32 etc.)
#     seed their accumulator with INT32_MIN as a sentinel and immediately do
#     `res *= 10`, a deliberate two's-complement wrap that fires on essentially
#     EVERY numeric input (the documented xdelta/gfatools coverage-starvation
#     pattern).
#   * `shift-base` — lib/tzraw.c's big-endian reader assembles zoneinfo header
#     words as `b0 << 24 | ...` in a signed int; any Olson zone file with a high
#     byte in a header word (Asia/Tokyo, America/New_York, ...) trips "left shift
#     of 255 by 24 places cannot be represented in type 'int'" — the intended
#     two's-complement value, not a memory bug — so every dzone conversion into
#     such a zone would abort before parsing anything.
# ASan and the rest of UBSan (alignment, pointer-overflow, bounds, etc.) stay
# halting so real memory/UB defects are still caught. Asserts are left ENABLED (no -DNDEBUG) to match dateutils' own
# build; a reachable assert/abort in the bizda business-day parser is a genuine
# finding (see mayhem/fuzz_strpdt/known-findings/).
set -euo pipefail

# clang rejects an empty SOURCE_DATE_EPOCH.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"

SRC="${SRC:-/mayhem}"
cd "$SRC"

HDIR="$SRC/mayhem/harnesses"
# Fuzz build: base sanitizers + our DWARF<4 flags + coverage instrumentation,
# with signed-integer-overflow relaxed (see header comment). $DEBUG_FLAGS comes
# AFTER $SANITIZER_FLAGS so its -gdwarf-3 wins over the base's trailing plain -g.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize=signed-integer-overflow,shift-base -fsanitize=fuzzer-no-link"

echo "== build.sh: SANITIZER_FLAGS=[$SANITIZER_FLAGS] DEBUG_FLAGS=[$DEBUG_FLAGS] =="

# Build-time LSan off-switch + the two CLI input-adapter mains (compiled once, linked below).
MBUILD="$SRC/mayhem-build"
mkdir -p "$MBUILD" /mayhem/cli
LSAN_OFF="$MBUILD/lsan_off.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OFF"
STDIN_MAIN="$MBUILD/stdin_main.o"
ARGV_MAIN="$MBUILD/argv_main.o"
# The stdin adapter is compiled in STDIN_FROM_LAST_ARG mode: every tool it wraps reads its date stream
# on stdin, and the Mayhemfile stages the input as `@@`, which the adapter opens as stdin (see the
# header of mayhem/harnesses/stdin_main.c for why file-staged input is used instead of raw stdin).
$CC $FUZZ_CFLAGS -DSTDIN_FROM_LAST_ARG -c "$HDIR/stdin_main.c" -o "$STDIN_MAIN"
$CC $FUZZ_CFLAGS -c "$HDIR/argv_main.c" -o "$ARGV_MAIN"

# Generate configure + Makefile.in etc. from the checked-out sources (idempotent).
autoreconf -i

# ---------------------------------------------------------------------------
# 1) ORACLE build (clean, normal flags) — produces a dynamically-linked dconv.
# ---------------------------------------------------------------------------
rm -rf "$SRC/build-oracle"
mkdir -p "$SRC/build-oracle"
( cd "$SRC/build-oracle"
  "$SRC/configure" CC="$CC"
  make -C build-aux -j"$MAYHEM_JOBS"   # bundled yuck codegen tool
  make -C lib       -j"$MAYHEM_JOBS"
  make -C src       -j"$MAYHEM_JOBS" )

install -m0755 "$SRC/build-oracle/src/dconv" /mayhem/dconv
install -m0755 "$SRC/build-oracle/src/ddiff" /mayhem/ddiff

# The oracle MUST be dynamically linked or the verify-repo sabotage shim
# (LD_PRELOAD) cannot neuter it and the behavioral oracle silently degrades.
for b in /mayhem/dconv /mayhem/ddiff; do
  if ! file "$b" | grep -q 'dynamically linked'; then
    echo "FATAL: $b is not dynamically linked — oracle would be un-neuterable" >&2
    file "$b" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 2) FUZZ build — sanitized + instrumented libdut.a (a separate VPATH tree so
#    the clean oracle build above is untouched). configure runs with CLEAN flags
#    (sanitizer CFLAGS break configure's feature-detection link tests); the
#    instrumentation is injected at compile time via `make CFLAGS=...`.
# ---------------------------------------------------------------------------
rm -rf "$SRC/build-fuzz"
mkdir -p "$SRC/build-fuzz"
( cd "$SRC/build-fuzz"
  "$SRC/configure" CC="$CC"
  make -C build-aux -j"$MAYHEM_JOBS"
  make -C lib -j"$MAYHEM_JOBS" CFLAGS="$FUZZ_CFLAGS" )

LIBDUT="$SRC/build-fuzz/lib/libdut.a"
[ -f "$LIBDUT" ] || { echo "FATAL: sanitized libdut.a not built" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2b) CLI TOOL targets — the project's own automake build of src/, sanitized +
#     instrumented, with upstream's main() renamed (fuzz build only) and the
#     stdin adapter main linked in via automake's $(LIBS) hook. Then dseq, dtest
#     and dzone are re-linked against the argv adapter instead (they read no stdin/file).
# ---------------------------------------------------------------------------
CLI_TOOLS="strptime dadd dconv ddiff dgrep dround dseq dtest dzone"
CLI_CFLAGS="$FUZZ_CFLAGS -Dmain=dateutils_tool_main"
( cd "$SRC/build-fuzz"
  make -C src -j"$MAYHEM_JOBS" CFLAGS="$CLI_CFLAGS" LIBS="$STDIN_MAIN $LSAN_OFF"
  # dseq/dtest/dzone: same objects, re-linked with the argv adapter (`@@` file -> argv) — they
  # read no stdin/file (dzone converts `now` when no DATE/TIME argument is given).
  rm -f src/dseq src/dtest src/dzone
  make -C src dseq dtest dzone CFLAGS="$CLI_CFLAGS" LIBS="$ARGV_MAIN $LSAN_OFF" )
for t in $CLI_TOOLS; do
  [ -x "$SRC/build-fuzz/src/$t" ] || { echo "FATAL: sanitized $t not built" >&2; exit 1; }
  install -m0755 "$SRC/build-fuzz/src/$t" "/mayhem/cli/$t"
done

# ---------------------------------------------------------------------------
# 3) Compile the harness once, then link it TWICE:
#    (a) the libFuzzer binary, (b) the standalone run-once reproducer.
# ---------------------------------------------------------------------------
$CC $FUZZ_CFLAGS -I"$SRC/lib" -c "$HDIR/fuzz_strpdt.c" -o "$SRC/build-fuzz/fuzz_strpdt.o"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize=signed-integer-overflow,shift-base $LIB_FUZZING_ENGINE \
    "$SRC/build-fuzz/fuzz_strpdt.o" "$LIBDUT" "$LSAN_OFF" \
    -o /mayhem/fuzz_strpdt

# Standalone (non-fuzzer) reproducer: StandaloneFuzzTargetMain is a C driver —
# compile it with -x c, then link the same harness object + sanitized lib.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize=signed-integer-overflow,shift-base -x c \
    -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/build-fuzz/standalone_main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize=signed-integer-overflow,shift-base \
    "$SRC/build-fuzz/standalone_main.o" "$SRC/build-fuzz/fuzz_strpdt.o" "$LIBDUT" "$LSAN_OFF" \
    -o /mayhem/fuzz_strpdt-standalone

# Every declared Mayhemfile target binary must exist — fail the build otherwise.
for mf in "$SRC"/mayhem/Mayhemfile_*; do
  bin="$(grep -m1 -E 'cmd:' "$mf" | sed 's/.*cmd:[[:space:]]*//' | awk '{print $1}')"
  [ -x "$bin" ] || { echo "FATAL: $(basename "$mf") target $bin was not built" >&2; exit 1; }
done

echo "== build.sh: OK =="
ls -l /mayhem/fuzz_strpdt /mayhem/fuzz_strpdt-standalone /mayhem/dconv /mayhem/ddiff /mayhem/cli
