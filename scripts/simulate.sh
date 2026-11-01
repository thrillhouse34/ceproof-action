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
# WHILE THE PINNED VERSION IS UNPUBLISHED — which is the state the FDA-mode
# commit lands in, because the action is pinned to 0.4.0 before 0.4.0 goes to
# npm — cases 1, 2, 5 and 6 cannot run: `npx -y ceproof@0.4.0` fails with
# ETARGET and there is nothing this script can do about that. Run them against
# the last published release instead:
#
#   INPUT_VERSION=0.3.5 ./scripts/simulate.sh
#
# and run it plain, with no override, the moment the pinned version is on npm.
# A plain run that reports ETARGET is the pin being ahead of npm, not a bug in
# the action; anything else red is real. Cases 12-17 (FDA) use a stub CLI and
# pass either way.
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

# ── case 0: no ${{ }} in action.yml outside runs: and outputs.*.value
#
# The runner evaluates the expressions in action.yml's metadata before the
# action runs, and `secrets` is not in scope there. So a `${{ secrets.X }}`
# written into an input description as documentation is not an example — it is
# an expression the runner tries and cannot resolve, and the action then fails
# to load for every user ("Unrecognized named-value: 'secrets'"). That shipped
# once. This catches it before a commit does.
#
# Valid: anything under `runs:`, and the `value:` of each output. Everywhere
# else in the file, a `${{` is a bug — quote the expression as plain text.
echo "== case 0: action.yml has no \${{ }} outside runs: and outputs.*.value =="
STRAY=$(awk '
  /^outputs:/ { section = "outputs"; next }
  /^runs:/    { section = "runs";    next }
  section == "runs"                             { next }
  index($0, "${{") == 0                         { next }
  section == "outputs" && $0 ~ /^    value: /   { next }
  { printf "%d: %s\n", NR, $0 }
' "$ROOT/action.yml")
if [ -z "$STRAY" ]; then
  ok "no expressions outside runs: and outputs.*.value"
else
  fail "action.yml has \${{ }} where the runner cannot evaluate it:"
  echo "$STRAY" | sed 's/^/         /'
fi
echo

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
# Price and sample link: the two things that turn "there is a paid tier" into a
# decision someone can actually make from the job summary. -F, because '$99'
# would otherwise be a positional-parameter expansion away from matching "9".
if grep -qF '$99' "$GITHUB_STEP_SUMMARY"; then ok "upsell quotes the price"; else fail "upsell does not name the price"; fi
if grep -qF 'https://ceproof.dev/report-sample' "$GITHUB_STEP_SUMMARY"; then ok "upsell links the sample pack"; else fail "upsell has no sample-pack link"; fi
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

# ── case 10: a key with surrounding whitespace must not trip the leak tripwire
#
# This is the one place the test has to fake the CLI. Every case above stops at
# the CLI's own refusal (exit 3) and so never reaches the code that runs AFTER a
# successful render — which is exactly where the trailing-newline bug lived: the
# leak check handed `grep -F` a pattern with an embedded newline, grep read that
# as a second EMPTY pattern, the empty pattern matched the freshly written
# report, and the action refused to upload with exit 2 having leaked nothing.
# A stub `npx` first on $PATH renders a plausible artifact, exits 0, and records
# the key it was handed, so this can assert both the trim and the upload path.
# What it cannot prove is that the real CLI accepts the key; the real-key E2E
# does that.
STUB_BIN="$TMP/fake-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/npx" <<'STUB'
#!/usr/bin/env bash
OUT=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--out" ]; then OUT="$2"; shift 2; continue; fi
  shift
done
[ -n "$OUT" ] || { echo "fake npx: no --out in the args" >&2; exit 64; }
mkdir -p "$OUT" || exit 64
printf 'fake report body, no key anywhere in it\n' > "$OUT/report.html"
# Byte for byte, so the caller can see any whitespace that survived the trim.
printf '%s' "${CEPROOF_KEY:-}" > "$FAKE_NPX_KEY_FILE"
exit 0
STUB
chmod +x "$STUB_BIN/npx"

echo
echo "== case 10: key with a trailing newline / CRLF (expect the paid path to proceed) =="
unset INPUT_CONFIG
IDX=0
for PADDED in "$FAKE_KEY"$'\n' "$FAKE_KEY"$'\r\n' $'  \t'"$FAKE_KEY"$'  \r\n'; do
  IDX=$((IDX + 1))
  case $IDX in
    1) LABEL="trailing LF" ;;
    2) LABEL="trailing CRLF" ;;
    3) LABEL="padded both ends" ;;
  esac
  RUN_DIR="$TMP/padded-$IDX"
  mkdir -p "$RUN_DIR"
  export RUNNER_TEMP="$RUN_DIR"
  export GITHUB_OUTPUT="$RUN_DIR/outputs.txt"
  export FAKE_NPX_KEY_FILE="$RUN_DIR/key-the-cli-saw.txt"
  : > "$GITHUB_OUTPUT"
  : > "$FAKE_NPX_KEY_FILE"
  REPORT_OUT="$RUN_DIR/full-report"

  PATH="$STUB_BIN:$PATH" CEPROOF_KEY="$PADDED" INPUT_PATH="fixtures/sample-repo" \
  INPUT_REPORT_OUT="$REPORT_OUT" \
    bash "$ROOT/scripts/report.sh" > "$RUN_DIR/stdout.txt" 2> "$RUN_DIR/stderr.txt"
  RC=$?
  sed 's/^/    | /' "$RUN_DIR/stderr.txt"

  check "$LABEL: exit code" "$RC" "0"
  check "$LABEL: report-generated output" "$(get report-generated)" "true"
  if grep -q "REFUSING TO UPLOAD" "$RUN_DIR/stderr.txt"; then
    fail "$LABEL: the leak tripwire fired on a report that contains no key"
  else
    ok "$LABEL: no false leak refusal"
  fi
  # The CLI must get the trimmed key, byte for byte — $(cat) alone would hide a
  # trailing newline, so the length is checked too.
  SEEN_BYTES=$(wc -c < "$FAKE_NPX_KEY_FILE" | tr -d ' ')
  if [ "$(cat "$FAKE_NPX_KEY_FILE")" = "$FAKE_KEY" ] && [ "$SEEN_BYTES" = "${#FAKE_KEY}" ]; then
    ok "$LABEL: the CLI was handed the trimmed key ($SEEN_BYTES bytes)"
  else
    fail "$LABEL: the CLI was handed $SEEN_BYTES bytes, expected ${#FAKE_KEY}"
  fi
  check "$LABEL: ::add-mask:: carries the trimmed key" "$(head -1 "$RUN_DIR/stdout.txt")" "::add-mask::$FAKE_KEY"
done

# ── case 11: a key that is nothing but whitespace is no key at all
echo
echo "== case 11: whitespace-only key (expect exit 2, and no empty ::add-mask::) =="
RUN_DIR="$TMP/ws-only"
mkdir -p "$RUN_DIR"
export RUNNER_TEMP="$RUN_DIR"
CEPROOF_KEY=$' \r\n\t ' INPUT_PATH="fixtures/sample-repo" INPUT_REPORT_OUT="$RUN_DIR/out" \
  bash "$ROOT/scripts/report.sh" > "$RUN_DIR/stdout.txt" 2> "$RUN_DIR/stderr.txt"
check "exit code" "$?" "2"
if grep -q "no license key" "$RUN_DIR/stderr.txt"; then ok "stderr says the key was empty or whitespace"; else fail "stderr does not explain the empty key"; fi
if grep -q "^::add-mask::" "$RUN_DIR/stdout.txt"; then fail "masked a whitespace-only string"; else ok "nothing masked"; fi
if [ -n "$(ls -A "$RUN_DIR/out" 2>/dev/null)" ]; then fail "artifacts written for a whitespace-only key"; else ok "nothing written"; fi

# ── cases 12-17: the FDA profile ──────────────────────────────────────────────
#
# These run against a STUB ceproof, not the real one, and the reason is dated:
# the FDA profile first exists in ceproof 0.4.0, which is not published yet, so
# `npx -y ceproof@0.4.0` cannot resolve. What the stub makes testable is this
# repo's half — the flags run.sh builds, the per-profile --fail-on default, the
# guards, and summary.js's rendering of a real FDA report. What it cannot prove
# is that the CLI accepts those flags; that was checked by running the 0.4.0 CLI
# directly, and the real end-to-end belongs in the post-publish E2E.
#
# fixtures/fda-report.json is REAL 0.4.0 output (`scan --profile fda --sbom
# fixtures/sample-sbom.cdx.json --format json`), not a hand-written shape. The
# day it is hand-edited this stops being a test of anything.
#
# DELETE THE STUB AND SWITCH THESE TO THE REAL CLI once 0.4.0 is on npm.
FDA_BIN="$TMP/fda-bin"
mkdir -p "$FDA_BIN"
cat > "$FDA_BIN/npx" <<'FDASTUB'
#!/usr/bin/env bash
# Records the args it was handed, then serves the committed real FDA report.
printf '%s\n' "$@" > "$FAKE_ARGS_FILE"
cat "$FDA_FIXTURE"
exit "${FAKE_EXIT:-0}"
FDASTUB
chmod +x "$FDA_BIN/npx"
export FDA_FIXTURE="$ROOT/fixtures/fda-report.json"

fda_run() {   # fda_run <label> <run-dir-name> [extra env assignments via caller]
  RUN_DIR="$TMP/$1"
  mkdir -p "$RUN_DIR"
  export GITHUB_STEP_SUMMARY="$RUN_DIR/step-summary.md"
  export GITHUB_OUTPUT="$RUN_DIR/outputs.txt"
  export RUNNER_TEMP="$RUN_DIR"
  export FAKE_ARGS_FILE="$RUN_DIR/args.txt"
  : > "$GITHUB_STEP_SUMMARY"
  : > "$GITHUB_OUTPUT"
  : > "$FAKE_ARGS_FILE"
}
# <flag> <value>: true only when VALUE is the line immediately after FLAG.
# Both halves matter — "--fail-on and never both appear somewhere" would pass on
# `--fail-on human-required --sbom never`, which is not the same statement. The
# `--` before "$1" is not optional: without it grep reads --profile as its own
# option and reports a usage error as a test failure.
args_pair() {
  awk -v flag="$1" -v val="$2" '
    prev == flag && $0 == val { found = 1 }
    { prev = $0 }
    END { exit found ? 0 : 1 }
  ' "$FAKE_ARGS_FILE"
}

echo
echo "== case 12: fda: true, nothing else set (expect --profile fda, --fail-on never, exit 0) =="
unset INPUT_CONFIG INPUT_FAIL_ON INPUT_FDA_SBOM
fda_run fda-default
PATH="$FDA_BIN:$PATH" INPUT_PATH="fixtures/sample-repo" INPUT_FDA="true" \
  bash "$ROOT/scripts/run.sh" > "$RUN_DIR/stdout.txt" 2> "$RUN_DIR/stderr.txt"
RC=$?
sed 's/^/    | /' "$RUN_DIR/stderr.txt"
check "exit code" "$RC" "0"
if args_pair "--profile" "fda"; then ok "--profile fda passed to the CLI"; else fail "--profile fda missing from $(tr '\n' ' ' < "$FAKE_ARGS_FILE")"; fi
if args_pair "--fail-on" "never"; then ok "--fail-on defaulted to never (report-only)"; else fail "--fail-on is not never: $(tr '\n' ' ' < "$FAKE_ARGS_FILE")"; fi
check "outcome output" "$(get outcome)" "pass"
check "total-items output" "$(get total-items)" "13"
check "config-present output" "$(get config-present)" "unknown"
check "config-valid output" "$(get config-valid)" "unknown"
DERIVED="$(get derived-count)"; PARTIAL="$(get partial-count)"; HUMAN="$(get needs-human-input-count)"
check "derived + partial + needs-human = 13" "$((DERIVED + PARTIAL + HUMAN))" "13"
if grep -q '^## ✅' "$GITHUB_STEP_SUMMARY"; then ok "job summary marked passed"; else fail "job summary not marked passed"; fi
for want in "FDA premarket SBOM" "13 FDA content items" "report-only by default" "Still open" "Components"; do
  if grep -qF "$want" "$GITHUB_STEP_SUMMARY"; then ok "job summary mentions '$want'"; else fail "job summary is missing '$want'"; fi
done
# The FDA profile must NOT be sold the CRA product, and must not carry the CRA disclaimer.
if grep -qF 'Annex VII technical documentation pack' "$GITHUB_STEP_SUMMARY"; then fail "the CRA upsell leaked into an FDA run"; else ok "no CRA upsell on an FDA run"; fi
if grep -qF 'not a Declaration of Conformity' "$GITHUB_STEP_SUMMARY"; then fail "the CRA disclaimer leaked into an FDA run"; else ok "no CRA disclaimer on an FDA run"; fi
if grep -qF 'not reviewed or endorsed by FDA or by CISA' "$GITHUB_STEP_SUMMARY"; then ok "the FDA disclaimer is present"; else fail "the FDA disclaimer is missing"; fi
if grep -qF 'ceproof.dev/fda' "$GITHUB_STEP_SUMMARY"; then ok "the FDA upsell links the FDA page"; else fail "the FDA upsell has no /fda link"; fi
# These are the wording bans ceproof's own tests/fda/forbiddenClaims.test.ts
# enforces on the artifacts. The job summary is a surface too.
for banned in "FDA-approved" "FDA approved" "submission-ready" "compliant"; do
  if grep -qiF "$banned" "$GITHUB_STEP_SUMMARY"; then fail "the job summary says '$banned'"; else ok "no '$banned' claim"; fi
done

echo
echo "== case 13: fda: true with an explicit fail-on (expect failing CI to be opt-in and to work) =="
fda_run fda-optin
PATH="$FDA_BIN:$PATH" INPUT_PATH="fixtures/sample-repo" INPUT_FDA="true" INPUT_FAIL_ON="human-required" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2> "$RUN_DIR/stderr.txt"
# The stub always exits 0, so this asserts what run.sh SENDS, which is the half
# this repo owns. The CLI's own arithmetic is covered by ceproof's test suite.
if args_pair "--fail-on" "human-required"; then ok "an explicit fail-on overrides the per-profile default"; else fail "explicit fail-on was dropped: $(tr '\n' ' ' < "$FAKE_ARGS_FILE")"; fi

echo
echo "== case 14: fda off (the default) still sends no --profile and --fail-on human-required =="
fda_run fda-off
unset INPUT_FAIL_ON
PATH="$FDA_BIN:$PATH" INPUT_PATH="fixtures/sample-repo" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2>&1
if grep -qxF -- '--profile' "$FAKE_ARGS_FILE"; then fail "--profile was sent on a CRA run"; else ok "no --profile on a CRA run, exactly as before"; fi
if args_pair "--fail-on" "human-required"; then ok "CRA still defaults to --fail-on human-required"; else fail "the CRA default moved: $(tr '\n' ' ' < "$FAKE_ARGS_FILE")"; fi

echo
echo "== case 15: fda-sbom becomes one --sbom per path, comma- or newline-separated =="
fda_run fda-sbom
PATH="$FDA_BIN:$PATH" INPUT_PATH="fixtures/sample-repo" INPUT_FDA="true" \
INPUT_FDA_SBOM="fixtures/sample-sbom.cdx.json
  fixtures/sample-sbom.cdx.json" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2> "$RUN_DIR/stderr.txt"
RC=$?
sed 's/^/    | /' "$RUN_DIR/stderr.txt"
check "exit code" "$RC" "0"
check "--sbom passed twice" "$(grep -cxF -- '--sbom' "$FAKE_ARGS_FILE")" "2"
check "leading whitespace trimmed off the second path" "$(grep -cxF 'fixtures/sample-sbom.cdx.json' "$FAKE_ARGS_FILE")" "2"
fda_run fda-sbom-commas
PATH="$FDA_BIN:$PATH" INPUT_PATH="fixtures/sample-repo" INPUT_FDA="true" \
INPUT_FDA_SBOM="fixtures/sample-sbom.cdx.json,fixtures/sample-sbom.cdx.json" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2>&1
check "comma-separated also gives two --sbom" "$(grep -cxF -- '--sbom' "$FAKE_ARGS_FILE")" "2"

echo
echo "== case 16: an fda-sbom path that is not there is exit 2, not a silent empty scan =="
fda_run fda-sbom-missing
PATH="$FDA_BIN:$PATH" INPUT_PATH="fixtures/sample-repo" INPUT_FDA="true" \
INPUT_FDA_SBOM="fixtures/no-such-sbom.json" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2> "$RUN_DIR/stderr.txt"
check "exit code" "$?" "2"
if grep -q "SBOM file not found" "$RUN_DIR/stderr.txt"; then ok "stderr names the missing SBOM"; else fail "stderr does not explain the missing SBOM"; fi
if [ -s "$FAKE_ARGS_FILE" ]; then fail "the CLI ran despite the missing SBOM"; else ok "the CLI was never reached"; fi

echo
echo "== case 17: fda-sbom with fda off, a whitespace-only fda-sbom, and a bad fda value are all exit 2 =="
fda_run fda-guards
PATH="$FDA_BIN:$PATH" INPUT_PATH="fixtures/sample-repo" INPUT_FDA_SBOM="fixtures/sample-sbom.cdx.json" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2> "$RUN_DIR/stderr.txt"
check "fda-sbom with fda off" "$?" "2"
if grep -q "only read when fda: true" "$RUN_DIR/stderr.txt"; then ok "stderr says why"; else fail "stderr does not explain it"; fi
PATH="$FDA_BIN:$PATH" INPUT_PATH="fixtures/sample-repo" INPUT_FDA="true" INPUT_FDA_SBOM="  , ,  " \
  bash "$ROOT/scripts/run.sh" > /dev/null 2> "$RUN_DIR/stderr2.txt"
check "whitespace-only fda-sbom" "$?" "2"
if grep -q "held no path" "$RUN_DIR/stderr2.txt"; then ok "stderr says the input held no path"; else fail "stderr does not explain the empty fda-sbom"; fi
PATH="$FDA_BIN:$PATH" INPUT_PATH="fixtures/sample-repo" INPUT_FDA="yes" \
  bash "$ROOT/scripts/run.sh" > /dev/null 2> "$RUN_DIR/stderr3.txt"
check "fda: yes (not a boolean)" "$?" "2"
if grep -q "fda must be true or false" "$RUN_DIR/stderr3.txt"; then ok "stderr names the valid values"; else fail "stderr does not name the valid values"; fi
unset INPUT_FDA INPUT_FDA_SBOM

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
fi
echo "$FAILURES CHECK(S) FAILED"
exit 1
