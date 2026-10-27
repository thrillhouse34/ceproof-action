#!/usr/bin/env bash
#
# The action's entire behaviour. action.yml calls this, and scripts/simulate.sh
# calls it with a faked GitHub environment — one script so the local test cannot
# drift from what the action really does.
#
# Reads INPUT_* env vars, writes report.json + summary.md, appends the summary to
# $GITHUB_STEP_SUMMARY and the outputs to $GITHUB_OUTPUT, and exits with the
# CLI's own exit code so --fail-on controls the job.
set -uo pipefail

PROJECT_PATH="${INPUT_PATH:-.}"
FAIL_ON="${INPUT_FAIL_ON:-human-required}"
VERSION="${INPUT_VERSION:-0.3.3}"
OUT_DIR="${INPUT_OUT:-}"
[ -n "$OUT_DIR" ] || OUT_DIR="${RUNNER_TEMP:-/tmp}/ceproof-report"

case "$FAIL_ON" in
  human-required|partial|never) ;;
  *)
    echo "ceproof-action: fail-on must be human-required, partial or never (got '$FAIL_ON')" >&2
    exit 2
    ;;
esac

# ceproof treats an explicitly-given but missing --config path as "no config
# present": no warning, no error. A typo in this input would silently discard
# every answer you wrote and then fail the job on the items that config was
# answering. Catch it here instead.
if [ -n "${INPUT_CONFIG:-}" ] && [ ! -f "$INPUT_CONFIG" ]; then
  echo "ceproof-action: config file not found at '$INPUT_CONFIG' (resolved from the workspace). Fix the path, or leave the input empty to use <path>/ceproof.config.json." >&2
  exit 2
fi

mkdir -p "$OUT_DIR" || exit 2
REPORT="$OUT_DIR/report.json"
SUMMARY="$OUT_DIR/summary.md"
OUTPUTS="$OUT_DIR/outputs.txt"

args=(scan "$PROJECT_PATH" --format json --fail-on "$FAIL_ON" --no-color)
[ "${INPUT_INCLUDE_DEV:-false}" = "true" ] && args+=(--include-dev)
[ -n "${INPUT_CONFIG:-}" ] && args+=(--config "$INPUT_CONFIG")
[ -n "${INPUT_PROJECT_LICENSE:-}" ] && args+=(--project-license "$INPUT_PROJECT_LICENSE")

echo "ceproof@$VERSION ${args[*]}"
npx -y "ceproof@$VERSION" "${args[@]}" > "$REPORT"
SCAN_RC=$?

# Exit 2 (usage/tool error) prints a plain-text message, not JSON. Surface it
# as-is rather than letting the renderer choke on it.
if ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$REPORT" >/dev/null 2>&1; then
  echo "ceproof-action: the scan produced no JSON report (ceproof exit $SCAN_RC). Its output was:" >&2
  cat "$REPORT" >&2
  [ "$SCAN_RC" -eq 0 ] && SCAN_RC=2
  exit "$SCAN_RC"
fi

node "$(dirname "$0")/summary.js" "$REPORT" "$SCAN_RC" "$FAIL_ON" "$OUTPUTS" > "$SUMMARY" || exit 2

cat "$SUMMARY"

if [ "${INPUT_SUMMARY:-true}" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$SUMMARY" >> "$GITHUB_STEP_SUMMARY"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  cat "$OUTPUTS" >> "$GITHUB_OUTPUT"
  {
    echo "report-path=$REPORT"
    echo "summary-path=$SUMMARY"
  } >> "$GITHUB_OUTPUT"
fi

exit "$SCAN_RC"
