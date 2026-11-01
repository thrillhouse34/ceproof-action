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
VERSION="${INPUT_VERSION:-0.4.0}"
OUT_DIR="${INPUT_OUT:-}"
[ -n "$OUT_DIR" ] || OUT_DIR="${RUNNER_TEMP:-/tmp}/ceproof-report"

FDA="${INPUT_FDA:-false}"
case "$FDA" in
  true|false) ;;
  *)
    echo "ceproof-action: fda must be true or false (got '$FDA')" >&2
    exit 2
    ;;
esac

# --fail-on's default is resolved HERE, per profile, exactly the way the CLI
# resolves it (DEFAULT_FAIL_ON in ceproof's src/cli/scan.ts): human-required for
# the CRA scan, never — report-only, exit 0 — for fda. So action.yml leaves the
# input EMPTY rather than defaulting it to human-required.
#
# Why that matters: three of the FDA profile's thirteen items can only ever be
# answered by a human, so human-required fails every FDA run forever no matter
# how complete the SBOM. An input default of human-required would hand everyone
# who flips `fda: true` a red build on a flawless run, which is how people learn
# to stop reading exit codes. Failing a build on the FDA profile is opt-in.
#
# Nothing about the CRA path moves: with fda off and fail-on untouched this
# still resolves to human-required and still passes it to the CLI explicitly,
# which is byte-for-byte what it did before.
FAIL_ON="${INPUT_FAIL_ON:-}"
if [ -z "$FAIL_ON" ]; then
  if [ "$FDA" = "true" ]; then FAIL_ON='never'; else FAIL_ON='human-required'; fi
fi

case "$FAIL_ON" in
  human-required|partial|never) ;;
  *)
    echo "ceproof-action: fail-on must be human-required, partial or never (got '$FAIL_ON')" >&2
    exit 2
    ;;
esac

# --sbom paths, one per line or comma-separated. Checked for existence here, for
# the same reason the config path below is: a missing SBOM would leave the FDA
# view reporting on whatever a repo scan happened to find, which for device
# firmware is nothing at all, and the run would look like it worked.
SBOM_ARGS=()
if [ -n "${INPUT_FDA_SBOM:-}" ]; then
  if [ "$FDA" != "true" ]; then
    echo "ceproof-action: fda-sbom is only read when fda: true, so the file(s) would have been ignored. Set fda: true, or drop fda-sbom." >&2
    exit 2
  fi
  while IFS= read -r sbom_path; do
    sbom_path="$(printf '%s' "$sbom_path" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$sbom_path" ] || continue
    if [ ! -f "$sbom_path" ]; then
      echo "ceproof-action: SBOM file not found at '$sbom_path' (resolved from the workspace). Fix the path in fda-sbom, or drop the input." >&2
      exit 2
    fi
    SBOM_ARGS+=(--sbom "$sbom_path")
  done <<EOF
$(printf '%s' "$INPUT_FDA_SBOM" | tr ',' '\n')
EOF
  if [ "${#SBOM_ARGS[@]}" -eq 0 ]; then
    echo "ceproof-action: fda-sbom was set but held no path (only whitespace or commas). Give it a file, or leave it empty." >&2
    exit 2
  fi
fi

# An explicitly-given --config path that is not there is caught HERE, before the
# CLI runs, and before the paid report step is ever reached.
#
# Older ceproof releases (including the one pinned by default) treated such a
# path as "no config present": no warning, no error. A typo in this input
# silently discarded every answer you wrote and then failed the job on the very
# items that config was answering. The CLI refuses properly now as well, so this
# is belt and braces — kept because the `version` input lets anyone pin back to
# a release that still has the hole, and because this message names the input
# rather than the flag.
if [ -n "${INPUT_CONFIG:-}" ] && [ ! -f "$INPUT_CONFIG" ]; then
  echo "ceproof-action: config file not found at '$INPUT_CONFIG' (resolved from the workspace). Fix the path, or leave the input empty to use <path>/ceproof.config.json." >&2
  exit 2
fi

mkdir -p "$OUT_DIR" || exit 2
REPORT="$OUT_DIR/report.json"
SUMMARY="$OUT_DIR/summary.md"
OUTPUTS="$OUT_DIR/outputs.txt"

args=(scan "$PROJECT_PATH" --format json --fail-on "$FAIL_ON" --no-color)
[ "$FDA" = "true" ] && args+=(--profile fda)
[ "${#SBOM_ARGS[@]}" -gt 0 ] && args+=("${SBOM_ARGS[@]}")
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

# INPUT_HAS_LICENSE_KEY is a bare "true"/"false", never the key itself — this
# script has no business holding key material. It only decides whether the job
# summary carries the upsell block.
node "$(dirname "$0")/summary.js" "$REPORT" "$SCAN_RC" "$FAIL_ON" "$OUTPUTS" "${INPUT_HAS_LICENSE_KEY:-false}" > "$SUMMARY" || exit 2

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
