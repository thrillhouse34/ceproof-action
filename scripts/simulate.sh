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

# ── case 5: the upsell appears for someone with no key, and only for them
echo
echo "== case 5: upsell in the job summary (no license key) =="
RUN_DIR="$TMP/upsell"
mkdir -p "$RUN_DIR"
export GITHUB_STEP_SUMMARY="$RUN_DIR/step-summary.md"
export GITHUB_OUTPUT="$RUN_DIR/outputs.txt"
export RUNNER_TEMP="$RUN_DIR"
: > "$GITHUB_STEP_SUMMARY"
: > "$GITHUB_OUTPUT"
unset INPUT_CONFIG

INPUT_PATH="fixtures/sample-repo" INPUT_FAIL_ON="never" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2>&1

if grep -q "Get the full report" "$GITHUB_STEP_SUMMARY"; then ok "upsell shown without a key"; else fail "upsell missing from the job summary"; fi
if grep -q "ceproof.dev" "$GITHUB_STEP_SUMMARY"; then ok "upsell links the existing purchase page"; else fail "upsell has no ceproof.dev link"; fi
if grep -q "Annex V" "$GITHUB_STEP_SUMMARY"; then ok "upsell names what you actually get"; else fail "upsell does not name the deliverable"; fi
# The upsell must not displace the disclaimer, which has to be on every surface.
if grep -q "not a Declaration of Conformity" "$GITHUB_STEP_SUMMARY"; then ok "disclaimer still present"; else fail "the disclaimer went missing"; fi

echo
echo "== case 6: no upsell once a key is configured =="
RUN_DIR="$TMP/no-upsell"
mkdir -p "$RUN_DIR"
export GITHUB_STEP_SUMMARY="$RUN_DIR/step-summary.md"
export GITHUB_OUTPUT="$RUN_DIR/outputs.txt"
export RUNNER_TEMP="$RUN_DIR"
: > "$GITHUB_STEP_SUMMARY"
: > "$GITHUB_OUTPUT"

# A boolean, not a key — this is exactly what action.yml passes run.sh.
INPUT_PATH="fixtures/sample-repo" INPUT_FAIL_ON="never" INPUT_HAS_LICENSE_KEY="true" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2>&1

if grep -q "Get the full report" "$GITHUB_STEP_SUMMARY"; then fail "a paid customer was shown the upsell"; else ok "upsell suppressed with a key configured"; fi
if grep -q "Annex VII" "$GITHUB_STEP_SUMMARY"; then ok "the rest of the summary is unchanged"; else fail "the summary lost its checklist content"; fi
if grep -q "not a Declaration of Conformity" "$GITHUB_STEP_SUMMARY"; then ok "disclaimer still present"; else fail "the disclaimer went missing"; fi

# ── case 7: the paid path refuses a bad key cleanly, and never echoes it
echo
echo "== case 7: paid report with an invalid key (expect exit 3, nothing written, no key leak) =="
RUN_DIR="$TMP/badkey"
mkdir -p "$RUN_DIR"
export RUNNER_TEMP="$RUN_DIR"
export GITHUB_OUTPUT="$RUN_DIR/outputs.txt"
unset GITHUB_STEP_SUMMARY
: > "$GITHUB_OUTPUT"

# Deliberately not a real key, and not a real key's shape beyond being a
# plausible-looking string. Nothing in this repo ever holds a working key.
FAKE_KEY="not-a-real-ceproof-key-cafef00d"
REPORT_OUT="$RUN_DIR/full-report"

CEPROOF_KEY="$FAKE_KEY" INPUT_PATH="fixtures/sample-repo" INPUT_REPORT_OUT="$REPORT_OUT" \
  bash "$ROOT/scripts/report.sh" > "$RUN_DIR/stdout.txt" 2> "$RUN_DIR/stderr.txt"
RC=$?
sed 's/^/    | /' "$RUN_DIR/stderr.txt"

check "exit code" "$RC" "3"
if grep -q "license key was not accepted" "$RUN_DIR/stderr.txt"; then ok "the refusal says what went wrong"; else fail "the refusal message is missing"; fi
if grep -q "ceproof.dev" "$RUN_DIR/stderr.txt"; then ok "the refusal points at the purchase page"; else fail "the refusal has no purchase link"; fi

# The one thing that must never happen. The ::add-mask:: line is the single
# deliberate exception and is excluded here: that line HAS to carry the key
# verbatim — it is how the runner learns what string to redact — and the runner
# strips it from the visible log. Every OTHER occurrence would be a real leak.
grep -v "^::add-mask::" "$RUN_DIR/stdout.txt" > "$RUN_DIR/stdout-unmasked.txt"
if grep -qF "$FAKE_KEY" "$RUN_DIR/stdout-unmasked.txt" "$RUN_DIR/stderr.txt" "$GITHUB_OUTPUT" 2>/dev/null; then
  fail "THE KEY LEAKED into stdout, stderr or \$GITHUB_OUTPUT"
else
  ok "the key appears nowhere but the ::add-mask:: line"
fi
if [ -n "$(ls -A "$REPORT_OUT" 2>/dev/null)" ]; then fail "artifacts were written despite the bad key"; else ok "nothing written on refusal"; fi
if grep -q "^report-generated=" "$GITHUB_OUTPUT" 2>/dev/null; then fail "report-generated was set despite the refusal"; else ok "report-generated not set"; fi

# The masking directive has to be the first thing the runner sees, before any
# other line exists that could contain the key.
if [ "$(head -1 "$RUN_DIR/stdout.txt")" = "::add-mask::$FAKE_KEY" ]; then
  ok "::add-mask:: is emitted first, before any other output"
else
  fail "::add-mask:: is not the first line of stdout (got: $(head -1 "$RUN_DIR/stdout.txt"))"
fi

# ── case 8: report.sh called with no key at all is a bug, not a silent pass
echo
echo "== case 8: report.sh with an empty key (expect exit 2) =="
CEPROOF_KEY="" INPUT_PATH="fixtures/sample-repo" INPUT_REPORT_OUT="$TMP/nokey-out" \
  bash "$ROOT/scripts/report.sh" > /dev/null 2>&1
check "exit code" "$?" "2"

# ── case 9: the paid path will not render an Annex VII pack from a config path
#            that is not there. A compliance document missing the answers it is
#            supposed to carry is worse than no document.
echo
echo "== case 9: paid report with a missing --config path (expect exit 2, before any key work) =="
RUN_DIR="$TMP/badkey-badconfig"
mkdir -p "$RUN_DIR"
export RUNNER_TEMP="$RUN_DIR"
CEPROOF_KEY="$FAKE_KEY" INPUT_PATH="fixtures/sample-repo" \
INPUT_CONFIG="$RUN_DIR/does-not-exist.json" INPUT_REPORT_OUT="$RUN_DIR/out" \
  bash "$ROOT/scripts/report.sh" > "$RUN_DIR/stdout.txt" 2> "$RUN_DIR/stderr.txt"
check "exit code" "$?" "2"
if grep -q "config file not found" "$RUN_DIR/stderr.txt"; then ok "stderr names the missing config"; else fail "stderr does not explain the missing config"; fi
if [ -n "$(ls -A "$RUN_DIR/out" 2>/dev/null)" ]; then fail "artifacts written despite the missing config"; else ok "nothing written"; fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
fi
echo "$FAILURES CHECK(S) FAILED"
exit 1
