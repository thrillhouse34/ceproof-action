#!/usr/bin/env bash
#
# Re-pin this action to a new published ceproof release.
#
#   ./scripts/bump.sh 0.3.4
#
# The pinned version appears in four places (action.yml's `version` input
# default, scripts/run.sh's fallback, scripts/report.sh's fallback, and the
# README — twice). Bumping them by hand means the day someone misses one, the
# action's documented version and its actual version disagree and nobody finds
# out until a customer reports it. So: one command, one old string, one new one.
#
# action.yml's default is the single source of truth for "what is this action
# pinned to"; everything else is derived from it, including this script's idea
# of the current version. Nothing here pushes, tags, or publishes — it prints
# those commands for a human to run.
set -euo pipefail

PKG='ceproof'
cd "$(dirname "$0")/.."

NEW="${1:-}"
if [ -z "$NEW" ]; then
  echo "usage: ./scripts/bump.sh <version>    e.g. ./scripts/bump.sh 0.3.4" >&2
  exit 2
fi
NEW="${NEW#v}"

# The version input's `default:` — the first `default:` line after `  version:`.
CURRENT=$(awk '/^  version:/{f=1; next} f && /^    default:/{gsub(/[^0-9A-Za-z.\-+]/, "", $2); print $2; exit}' action.yml)
if [ -z "$CURRENT" ]; then
  echo "bump.sh: could not read the current version from action.yml's version input. Did the input get renamed?" >&2
  exit 2
fi
echo "current: $CURRENT"
echo "new:     $NEW"

if [ "$NEW" = "$CURRENT" ]; then
  echo "bump.sh: already pinned to $NEW. Nothing to do." >&2
  exit 0
fi

# Refuse to pin to something npx cannot fetch. Without this check the bump
# looks like it worked, the commit lands, and the action then breaks for every
# user on their next run — the worst possible place to discover a typo'd or
# not-yet-published version.
echo "==> Checking $PKG@$NEW is published..."
PUBLISHED=$(npm view "$PKG@$NEW" version 2>/dev/null | tr -d '[:space:]' || true)
if [ "$PUBLISHED" != "$NEW" ]; then
  echo "bump.sh: $PKG@$NEW is not published to npm (npm view returned '${PUBLISHED:-nothing}')." >&2
  echo "         Publish it first, then re-run. Nothing has been changed." >&2
  exit 1
fi
echo "    ok — $PKG@$NEW is on npm"

FILES=(action.yml README.md scripts/run.sh scripts/report.sh)
echo "==> Re-pinning $CURRENT -> $NEW in: ${FILES[*]}"
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  # BSD and GNU sed disagree about -i's argument; -i.bak then removing the
  # backup is the one form that behaves identically on macOS and on a runner.
  sed -i.bak "s/${CURRENT//./\\.}/$NEW/g" "$f"
  rm -f "$f.bak"
done

# Belt and braces: prove no stale pin survived anywhere that matters, including
# a file this script does not know about yet.
STALE=$(grep -rlF "$CURRENT" . --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null || true)
if [ -n "$STALE" ]; then
  echo
  echo "bump.sh: WARNING — '$CURRENT' still appears in:" >&2
  echo "$STALE" >&2
  echo "Check whether those are stale pins (add them to FILES in this script) or" >&2
  echo "legitimate history, e.g. a changelog entry." >&2
fi

echo
echo "==> Changed:"
git --no-pager diff --stat || true

cat <<EOF

==> Next, in order:

  1. Re-run the local test (needs network — npx fetches the new version):

       ./scripts/simulate.sh

  2. Review and commit:

       git --no-pager diff
       git add -A && git commit -m "Pin $PKG $NEW"

  3. Push and release (nothing above pushed anything):

       git push

       gh release create v1.0.X --title v1.0.X --notes "Wraps $PKG $NEW"

     ...or draft it in the GitHub UI, ticking "Publish this Action to the
     GitHub Marketplace" if this is the first release.

  4. Move the floating v1 tag that the README tells customers to use. GitHub
     does NOT do this for you:

       git tag -fa v1 -m v1 v1.0.X
       git push -f origin v1

EOF
