#!/usr/bin/env bash
#
# The OPTIONAL paid-report step. Runs only when the `license-key` input is
# non-empty; action.yml skips this script entirely otherwise, so the free path
# never touches a key and never needs one.
#
# Renders the paid artifacts (the Annex VII technical documentation pack as HTML
# and PDF, the Annex V Declaration of Conformity draft as HTML and PDF, and both
# SBOM formats) into their own directory under the runner temp dir and leaves
# them for action.yml's upload step. Exits non-zero — and says why in one line —
# when the key is missing, rejected, or expired.
#
# THE KEY. Handling rules, in order of how badly each one bites:
#   * It arrives in $CEPROOF_KEY and is NEVER put on a command line. argv is
#     world-readable through `ps` for the life of the process, and the CLI reads
#     $CEPROOF_KEY natively, so --key is pure downside here.
#   * ::add-mask:: is emitted before anything else runs, so any later line that
#     somehow contains the key is redacted in the log by the runner.
#   * Nothing here echoes $CEPROOF_KEY, and nothing writes it to $GITHUB_OUTPUT
#     or $GITHUB_STEP_SUMMARY. The rendered artifacts are grepped for it before
#     the upload step can see them (see the tripwire below).
set -uo pipefail

KEY="${CEPROOF_KEY:-}"

# First line out of this script, before any other output exists to leak into.
# Masking an empty string is both pointless and an error, hence the guard.
[ -n "$KEY" ] && echo "::add-mask::$KEY"

if [ -z "$KEY" ]; then
  echo "ceproof-action: report.sh ran with no license key. This is a bug in the action — action.yml should have skipped this step." >&2
  exit 2
fi

PROJECT_PATH="${INPUT_PATH:-.}"
VERSION="${INPUT_VERSION:-0.3.3}"
FORMATS="${INPUT_REPORT_FORMATS:-annex7,annex7-pdf,doc,doc-pdf,sbom-cyclonedx,sbom-spdx}"
REPORT_DIR="${INPUT_REPORT_OUT:-}"
[ -n "$REPORT_DIR" ] || REPORT_DIR="${RUNNER_TEMP:-/tmp}/ceproof-full-report"

# Same missing-config guard the scan step applies. Worth repeating rather than
# assuming the scan already caught it: the two steps can be reached with
# different inputs if someone edits action.yml, and a report rendered without
# the answers the customer wrote is a silently wrong compliance document — much
# worse than a loud failure.
if [ -n "${INPUT_CONFIG:-}" ] && [ ! -f "$INPUT_CONFIG" ]; then
  echo "ceproof-action: config file not found at '$INPUT_CONFIG' (resolved from the workspace). Refusing to render an Annex VII pack without the answers it is supposed to contain." >&2
  exit 2
fi

mkdir -p "$REPORT_DIR" || exit 2

args=(report "$PROJECT_PATH" --format "$FORMATS" --out "$REPORT_DIR")
[ "${INPUT_INCLUDE_DEV:-false}" = "true" ] && args+=(--include-dev)
[ -n "${INPUT_CONFIG:-}" ] && args+=(--config "$INPUT_CONFIG")
[ -n "${INPUT_PROJECT_LICENSE:-}" ] && args+=(--project-license "$INPUT_PROJECT_LICENSE")

# Safe to echo: the key is not in args, by construction.
echo "ceproof@$VERSION ${args[*]}"
CEPROOF_KEY="$KEY" npx -y "ceproof@$VERSION" "${args[@]}"
RC=$?

if [ "$RC" -eq 3 ]; then
  cat >&2 <<'MSG'
ceproof-action: the license key was not accepted, so no paid report was
generated. Nothing was written. Check that:
  * the secret you fed into the `license-key` input is set on THIS repository
    (a secret that is not set arrives as an empty string, and an empty string
    means "free scan only" — you would not be seeing this message);
  * you pasted the whole key from the purchase email, with no stray newline;
  * the key is a ceproof key, not a licenseproof one.
Buy or re-send a key at https://ceproof.dev
The free scan above is unaffected and its result still stands.
MSG
  exit 3
fi

if [ "$RC" -ne 0 ]; then
  echo "ceproof-action: ceproof report exited $RC. Its own message is above." >&2
  exit "$RC"
fi

# Tripwire, not decoration. "Never write the key to an artifact" is a promise
# this action makes on someone else's secret, and the only way to keep it
# honestly is to check rather than assume: a future CLI release that decided to
# stamp the key (or a licenseId derived from it) into a report footer would
# otherwise publish it to every artifact downloader, silently. grep -r reads the
# PDFs as binary too, which is exactly what we want.
if grep -rqF -- "$KEY" "$REPORT_DIR" 2>/dev/null; then
  echo "ceproof-action: REFUSING TO UPLOAD — the license key appears inside a generated report artifact in $REPORT_DIR. This is a bug; please report it at https://github.com/thrillhouse34/ceproof-action/issues (do not attach the artifact)." >&2
  exit 2
fi

echo
echo "Paid report artifacts in $REPORT_DIR:"
ls -1 "$REPORT_DIR"
echo
echo "Informational — not legal advice. Not a conformity assessment and not a"
echo "Declaration of Conformity until a responsible person reviews, completes"
echo "and signs it."

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "report-dir=$REPORT_DIR"
    echo "report-generated=true"
  } >> "$GITHUB_OUTPUT"
fi
