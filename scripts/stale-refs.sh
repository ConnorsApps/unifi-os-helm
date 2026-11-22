#!/usr/bin/env bash
# List tracked files that still mention a UniFi OS version, except the pin,
# Chart.yaml, CHANGELOG.md, fixtures, the skill and comment lines. Used by
# bump-uos-version.sh (warning) and upgrade.sh (needs_review).
#
# Usage: scripts/stale-refs.sh <version>    # prints path:line:text; exit 0 either way
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:?usage: stale-refs.sh <version>}"
# Whole token: matches v5.1.42 and "5.1.42.", not 15.1.42, 5.1.420 or 5.1.42.1.
re="(^|[^0-9.])${version//./\\.}([^0-9.]|\\.([^0-9]|\$)|\$)"

git -C "$ROOT" grep -n -E "$re" -- \
  ':!uos-version.env' ':!charts/unifi-os/Chart.yaml' ':!CHANGELOG.md' \
  ':!scripts/testdata' ':!.claude/skills' 2>/dev/null \
  | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' || true
