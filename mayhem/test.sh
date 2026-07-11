#!/usr/bin/env bash
#
# libconfig/mayhem/test.sh — RUN libconfig's own check-based test suite (built by mayhem/build.sh
# with normal flags in the out-of-tree mayhem-tests/ autotools tree) and emit a CTRF summary.
# exit 0 iff no test failed.
#
# PATCH-grade oracle: libconfig's tests (tests/tests.c, run via the bundled tinytest harness) are
# real round-trip / golden-output tests — ParsingAndFormatting parses tests/testdata/input_N.cfg,
# writes it back, and compares BYTE-EXACT against testdata/output_N.cfg; ParseInvalidFiles asserts
# specific parse-error text; BigInt/EscapedStrings/BinaryAndHex/SettingLookups assert exact values.
# A no-op / "return 0" patch (or any change that alters parsing or formatting) cannot pass. This
# script only RUNS the pre-built binary; it never compiles.
#
# The test binary uses relative paths ("testdata/..."), so it MUST run with CWD = $SRC/tests.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

TESTTREE="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

# Locate the built test binary (out-of-tree autotools build).
BIN=""
for cand in \
  "$TESTTREE/tests/libconfig_tests" \
  "$TESTTREE/tests/.libs/libconfig_tests" \
  "$TESTTREE/tests/libconfig_tests.exe"; do
  [ -x "$cand" ] && { BIN="$cand"; break; }
done
if [ -z "$BIN" ]; then
  BIN="$(find "$TESTTREE" -name 'libconfig_tests' -type f -perm -u+x 2>/dev/null | head -1)"
fi

if [ -z "$BIN" ]; then
  echo "missing libconfig_tests binary under $TESTTREE — run mayhem/build.sh first" >&2
  emit_ctrf "tinytest" 0 1 0; exit 2
fi

echo "=== running $BIN (CWD=$SRC/tests) ==="
# The test reads testdata/*.cfg via relative paths — run from the source tests dir.
out="$(cd "$SRC/tests" && "$BIN" 2>&1)"; rc=$?
echo "$out"

# tinytest prints a summary line:  "N tests; P passed, F failed"
SUMMARY="$(printf '%s\n' "$out" | sed -n 's/^\([0-9][0-9]*\) tests; \([0-9][0-9]*\) passed, \([0-9][0-9]*\) failed.*/\1 \2 \3/p' | tail -1)"
if [ -n "$SUMMARY" ]; then
  read -r TOTAL PASSED FAILED <<<"$SUMMARY"
  : "${TOTAL:=0}" "${PASSED:=0}" "${FAILED:=0}"
  emit_ctrf "tinytest" "$PASSED" "$FAILED"
  # honor the binary's exit code too (defensive: any failure -> non-zero)
  [ "$FAILED" -eq 0 ] && [ "$rc" -eq 0 ]
  exit $?
fi

# No parseable summary — fall back to the binary's exit code.
echo "could not parse tinytest summary; using exit code $rc" >&2
if [ "$rc" -eq 0 ]; then emit_ctrf "tinytest" 1 0 0; exit 0; fi
emit_ctrf "tinytest" 0 1 0; exit 1
