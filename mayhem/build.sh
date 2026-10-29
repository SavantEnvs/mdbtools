#!/usr/bin/env bash
# mayhem/build.sh — builds (1) the sanitized libmdb + the fuzz_mdb libFuzzer harness and its
# -standalone reproducer, then (2) the project's normal (unsanitized) build that test.sh exercises.
# Idempotent and offline: autotools state is wiped between the two builds and before each re-run.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
: "${COVERAGE_FLAGS=}"

NORMAL_CONFIGURE_FLAGS="--disable-man"

# autotools bootstrap (generated files are all gitignored upstream)
[ -f Makefile ] && make distclean >/dev/null 2>&1 || true
autoreconf -fi

# 1) Sanitized project build (static libmdb) with DWARF 3, plus libFuzzer coverage instrumentation
#    (fuzzer-no-link) so the fuzzer sees edges inside libmdb, not just the harness. LeakSanitizer
#    would abort configure's conftest programs and break feature detection, so only configure runs leak-free.
ASAN_OPTIONS=detect_leaks=0 \
./configure CC="$CC" CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" LDFLAGS="$SANITIZER_FLAGS" \
    --disable-shared --enable-static $NORMAL_CONFIGURE_FLAGS
make -C src/libmdb -j"$MAYHEM_JOBS"

GLIB_CFLAGS="$(pkg-config --cflags glib-2.0)"
GLIB_LIBS="$(pkg-config --libs glib-2.0)"

# 2) Fuzz harness (upstream's own src/fuzz/fuzz_mdb.c, the OSS-Fuzz target), twice: libFuzzer + standalone.
#    LeakSanitizer is switched off at build time via lsan_off.c; ASan and UBSan stay on and halting.
#    The harness uses uint8_t without including <stdint.h> (nothing in mdbtools.h pulls it in), so force it.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -include stdint.h -Iinclude $GLIB_CFLAGS \
    src/fuzz/fuzz_mdb.c /tmp/lsan_off.o src/libmdb/.libs/libmdb.a $GLIB_LIBS -lm \
    -o /mayhem/fuzz_mdb
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -include stdint.h -Iinclude $GLIB_CFLAGS \
    src/fuzz/fuzz_mdb.c /tmp/standalone_main.o /tmp/lsan_off.o src/libmdb/.libs/libmdb.a $GLIB_LIBS -lm \
    -o /mayhem/fuzz_mdb-standalone

# 3) Test build: normal flags, left in-tree where upstream's test_script.sh / test_sql.sh expect it.
make distclean >/dev/null
./configure CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" $NORMAL_CONFIGURE_FLAGS
make -j"$MAYHEM_JOBS"
