#!/usr/bin/env bash
# Render the chart for every scenario in tests/values/ (each merged over
# 00-base.yaml) into <out-dir>. Diff two runs to catch template regressions.
#
# Usage: scripts/render-matrix.sh <out-dir> [chart-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:?usage: render-matrix.sh <out-dir> [chart-dir]}"
CHART="${2:-$ROOT/charts/unifi-os}"
VALUES="$ROOT/tests/values"

mkdir -p "$OUT"
status=0
for f in "$VALUES"/[0-9][0-9]-*.yaml; do
  name="$(basename "$f" .yaml)"
  if ! helm template unifi "$CHART" -n unifi -f "$VALUES/00-base.yaml" -f "$f" > "$OUT/$name.yaml" 2> "$OUT/$name.err"; then
    echo "FAIL $name: $(cat "$OUT/$name.err")" >&2
    status=1
  fi
  [ -s "$OUT/$name.err" ] || rm -f "$OUT/$name.err"
done
exit "$status"
