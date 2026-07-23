#!/usr/bin/env bash
# Renders the unifi-os chart across the values matrix in .render-test/values/
# into the given output directory. Used to diff the HULL-based chart's output
# against the plain-Helm rewrite's output for backwards-compatibility testing.
#
# Usage: scripts/test-render-compat.sh <output-dir>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$ROOT/charts/unifi-os"
MATRIX_DIR="$ROOT/.render-test/values"
BASE="$MATRIX_DIR/00-base.yaml"
OUT_DIR="${1:?usage: test-render-compat.sh <output-dir>}"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.yaml "$OUT_DIR"/*.stderr

status=0
for values_file in "$MATRIX_DIR"/[0-9][0-9]-*.yaml; do
  name="$(basename "$values_file" .yaml)"
  [ "$name" = "00-base" ] && continue
  if helm template unifi "$CHART" --namespace unifi -f "$BASE" -f "$values_file" \
      > "$OUT_DIR/$name.yaml" 2>"$OUT_DIR/$name.stderr"; then
    rm -f "$OUT_DIR/$name.stderr"
  else
    echo "RENDER FAILED: $name (see $OUT_DIR/$name.stderr)" >&2
    status=1
  fi
done
exit "$status"
