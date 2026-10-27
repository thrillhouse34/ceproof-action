#!/usr/bin/env bash
#
# Local test. Runs scripts/run.sh — the same script action.yml runs — against
# fixtures/sample-repo with a faked runner environment ($GITHUB_STEP_SUMMARY,
# $GITHUB_OUTPUT, $RUNNER_TEMP), then asserts on what it wrote.
#
#   ./scripts/simulate.sh
#
# Needs node and network access on the first run (npx fetches the pinned ceproof
# from npm; later runs hit the npx cache). The only thing it cannot cover is the
# actions/upload-artifact step, which has no local equivalent.
#
# Prefers `act` when it is installed, since that runs the real action.yml.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
FAILURES=0

if command -v act >/dev/null 2>&1; then
  echo "== act detected: running the real workflow =="
  act -W .github/workflows/test.yml || FAILURES=$((FAILURES + 1))
  echo
fi

TMP="$(mktemp -d)" || exit 1
echo "scratch: $TMP"

ok()   { echo "  ok   — $1"; }
fail() { echo "  FAIL — $1"; FAILURES=$((FAILURES + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else fail "$1: expected '$3', got '$2'"; fi; }
get() { grep -m1 "^$1=" "$GITHUB_OUTPUT" | cut -d= -f2-; }

# ── case 1: the default fail-on human-required, with no config answering anything
echo "== case 1: fail-on human-required, no config (expect the job to fail) =="
RUN_DIR="$TMP/human"
mkdir -p "$RUN_DIR"
export GITHUB_STEP_SUMMARY="$RUN_DIR/step-summary.md"
export GITHUB_OUTPUT="$RUN_DIR/outputs.txt"
export RUNNER_TEMP="$RUN_DIR"
: > "$GITHUB_STEP_SUMMARY"
: > "$GITHUB_OUTPUT"

INPUT_PATH="fixtures/sample-repo" \
  bash "$ROOT/scripts/run.sh" > "$RUN_DIR/stdout.txt" 2> "$RUN_DIR/stderr.txt"
RC=$?
sed 's/^/    | /' "$RUN_DIR/stderr.txt"

check "exit code" "$RC" "1"
check "outcome output" "$(get outcome)" "fail"
check "total-items output" "$(get total-items)" "21"
check "config-present output" "$(get config-present)" "false"
check "config-valid output" "$(get config-valid)" "unknown"

# The derived/partial split moves with the surrounding git state (tags, dirty
# worktree), so assert the invariant rather than frozen numbers.
DERIVED="$(get derived-count)"; PARTIAL="$(get partial-count)"; HUMAN="$(get needs-human-input-count)"
check "derived + partial + needs-human = total" "$((DERIVED + PARTIAL + HUMAN))" "21"
if [ "$HUMAN" -gt 0 ]; then ok "needs-human-input-count > 0 ($HUMAN)"; else fail "no human-required items — the fixture answers nothing, so there should be some"; fi

if [ -s "$(get report-path)" ]; then ok "report.json written ($(get report-path))"; else fail "report.json missing"; fi
if [ -s "$(get summary-path)" ]; then ok "summary.md written"; else fail "summary.md missing"; fi

if [ -s "$GITHUB_STEP_SUMMARY" ]; then ok "job summary written"; else fail "job summary is empty"; fi
for want in "CEProof" "Annex VII" "Annex V" "Still open" "ceproof init"; do
  if grep -q "$want" "$GITHUB_STEP_SUMMARY"; then ok "job summary mentions $want"; else fail "job summary is missing '$want'"; fi
done
if grep -q '^## ❌' "$GITHUB_STEP_SUMMARY"; then ok "job summary marked failed"; else fail "job summary not marked failed"; fi
# The citations are long; the renderer must clip, not emit a megabyte.
SUMMARY_BYTES=$(wc -c < "$GITHUB_STEP_SUMMARY")
if [ "$SUMMARY_BYTES" -lt 1048576 ]; then ok "job summary under GitHub's 1 MiB limit ($SUMMARY_BYTES bytes)"; else fail "job summary is $SUMMARY_BYTES bytes, over the 1 MiB limit"; fi

# ── case 2: fail-on never always passes, and still reports
echo
echo "== case 2: fail-on never (expect the job to pass) =="
RUN_DIR="$TMP/never"
mkdir -p "$RUN_DIR"
export GITHUB_STEP_SUMMARY="$RUN_DIR/step-summary.md"
export GITHUB_OUTPUT="$RUN_DIR/outputs.txt"
export RUNNER_TEMP="$RUN_DIR"
: > "$GITHUB_STEP_SUMMARY"
: > "$GITHUB_OUTPUT"

INPUT_PATH="fixtures/sample-repo" INPUT_FAIL_ON="never" \
  bash "$ROOT/scripts/run.sh" > "$RUN_DIR/stdout.txt" 2> "$RUN_DIR/stderr.txt"
RC=$?
check "exit code" "$RC" "0"
check "outcome output" "$(get outcome)" "pass"
check "total-items still reported" "$(get total-items)" "21"
if grep -q '^## ✅' "$GITHUB_STEP_SUMMARY"; then ok "job summary marked passed"; else fail "job summary not marked passed"; fi

# ── case 3: a bad fail-on value is rejected, not silently defaulted
echo
echo "== case 3: invalid fail-on (expect exit 2) =="
INPUT_PATH="fixtures/sample-repo" INPUT_FAIL_ON="eventually" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2>&1
check "exit code" "$?" "2"

# ── case 4: a config path that does not exist must not be silently ignored
echo
echo "== case 4: missing --config path (expect exit 2, not a silent miss) =="
RUN_DIR="$TMP/badconfig"
mkdir -p "$RUN_DIR"
export RUNNER_TEMP="$RUN_DIR"
unset GITHUB_STEP_SUMMARY GITHUB_OUTPUT
INPUT_PATH="fixtures/sample-repo" INPUT_CONFIG="$RUN_DIR/does-not-exist.json" \
  bash "$ROOT/scripts/run.sh" > "$RUN_DIR/stdout.txt" 2> "$RUN_DIR/stderr.txt"
# Exit 2, specifically: ceproof itself would quietly carry on with no config
# (exit 1 from fail-on), which is the failure mode the guard in run.sh exists
# to turn into a loud one.
check "exit code" "$?" "2"
if grep -q "config file not found" "$RUN_DIR/stderr.txt"; then ok "stderr names the missing config"; else fail "stderr does not explain the missing config"; fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
fi
echo "$FAILURES CHECK(S) FAILED"
exit 1
