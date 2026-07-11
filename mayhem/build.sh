#!/usr/bin/env bash
#
# libconfig/mayhem/build.sh — build hyperrealm/libconfig's single OSS-Fuzz harness as a sanitized
# libFuzzer target (+ a standalone reproducer), AND libconfig's own check-based test suite for
# mayhem/test.sh.
#
# The fuzzed surface is libconfig's config PARSER/WRITER on attacker-controlled bytes. The harness
# input is RAW bytes (config text): the fuzzer NUL-terminates the input and passes it directly to
# config_read_string().  There is no fuzz_data_t struct, no custom mutator, and no minimum-size
# gate — Mayhem's raw-byte engine can exercise the parser on every input.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile libconfig ITSELF with $SANITIZER_FLAGS so the parser/writer code
# (not just the harness) is instrumented. OSS-Fuzz's $OUT maps to /mayhem.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# LIB_CFLAGS: compile the fuzzed library WITH SanitizerCoverage so Mayhem sees edges.
# -fsanitize=fuzzer-no-link injects __sanitizer_cov_* callbacks without pulling in the
# libFuzzer runtime (which must only appear in the final link of the fuzzer binary).
LIB_CFLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
INC="-I$SRC/lib"

# libconfig's C library sources (the parser/scanner/grammar live in lib/). scanner.c and grammar.c
# are checked into the repo, so no flex/bison run is needed for the fuzzer build.
LIBSRCS="lib/libconfig.c lib/scanctx.c lib/strbuf.c lib/strvec.c lib/util.c lib/wincompat.c lib/scanner.c lib/grammar.c"

# ── 1) Build the libconfig static library WITH sanitizers (the fuzzed parser is instrumented) ──────
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"
OBJS=()
for s in $LIBSRCS; do
  obj="$BUILD/$(basename "${s%.c}").o"
  # NDEBUG: the OSS-Fuzz fuzz target is built without assertions (matches fuzz/CMakeLists.txt).
  # Use LIB_CFLAGS (includes -fsanitize=fuzzer-no-link) so the library objects have SanitizerCoverage.
  $CC $LIB_CFLAGS $DEBUG_FLAGS -DNDEBUG $INC -c "$s" -o "$obj"
  OBJS+=("$obj")
done
LIBCONFIG="$BUILD/libconfig.a"
rm -f "$LIBCONFIG"; ar rcs "$LIBCONFIG" "${OBJS[@]}"

# Standalone driver (the org base ships StandaloneFuzzTargetMain.c).
# No LLVMFuzzerMutate stub needed — the harness has no LLVMFuzzerCustomMutator.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# ── 2) Build the OSS-Fuzz harness twice: libFuzzer (-> /mayhem/<name>) + standalone reproducer ─────
# The harness is a single file now (raw-byte form, no fuzz_data_t).
HARNESS_SRCS="$HARNESS_DIR/fuzz_config_read.c"
for fuzzer in config_read_fuzzer; do
  # libFuzzer target -> /mayhem/<name>
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -DNDEBUG $INC \
      $HARNESS_SRCS $LIB_FUZZING_ENGINE "$LIBCONFIG" \
      -o "/mayhem/$fuzzer"

  # standalone reproducer (no libFuzzer runtime) -> /mayhem/<name>-standalone
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -DNDEBUG $INC \
      $HARNESS_SRCS "$BUILD/standalone_main.o" "$LIBCONFIG" \
      -o "/mayhem/$fuzzer-standalone"

  echo "built $fuzzer (+ standalone)"
done

# ── 3) Build libconfig's OWN test suite with NORMAL flags (clean autotools tree) so test.sh only
#       RUNS it. libconfig uses autotools + a bundled tinytest harness; `make check` builds & runs
#       tests/libconfig_tests against tests/testdata/*.cfg golden files. ──────────────────────────
TESTTREE="$SRC/mayhem-tests"
rm -rf "$TESTTREE"; mkdir -p "$TESTTREE"
if command -v autoreconf >/dev/null 2>&1; then
  # Generate the autotools build system in the source tree (idempotent) with normal flags, then
  # configure+build out-of-tree in mayhem-tests/. env -u keeps sanitizer/benign-UB noise out so
  # test.sh stays an honest PATCH oracle.
  ( cd "$SRC" && env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS autoreconf -fi ) \
    || echo "WARNING: autoreconf failed" >&2
  ( cd "$TESTTREE" && env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS CC=cc CXX=c++ \
      "$SRC/configure" --disable-shared --enable-static ) \
    || echo "WARNING: configure failed" >&2
  # Build only the subdirs the test suite needs (lib + the bundled tinytest harness + tests).
  # Skip doc/ — it invokes makeinfo (texinfo), which we don't install and which is irrelevant to
  # the functional tests.
  for sub in lib tinytest tests; do
    env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -C "$TESTTREE/$sub" -j"$MAYHEM_JOBS" \
      || echo "WARNING: building $sub failed" >&2
  done
  echo "built libconfig autotools tree (lib/tinytest/tests) in mayhem-tests/"
else
  echo "WARNING: autoreconf not found — test suite not built (mayhem/test.sh will fail loudly)" >&2
fi

echo "build.sh complete:"
ls -la /mayhem/config_read_fuzzer /mayhem/config_read_fuzzer-standalone 2>&1 || true
