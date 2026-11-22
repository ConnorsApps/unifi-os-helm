#!/usr/bin/env bash
# List tracked files that still mention a UniFi OS version, outside the places
# that legitimately keep it (the pin, Chart.yaml, fixtures, the skill, the
# changelog) and outside comment lines. Used by bump-uos-version.sh (warning)
# and upgrade.sh (needs_review).
#
# Usage: scripts/stale-refs.sh <version>    # prints path:line:text; exit 0 either way
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${1:?usage: stale-refs.sh <version>}"

git -C "$ROOT" grep -n -w -F "$version" -- \
  ':!uos-version.env' ':!charts/unifi-os/Chart.yaml' ':!CHANGELOG.md' \
  ':!scripts/testdata' ':!.claude/skills' 2>/dev/null \
  | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' || true
