#!/usr/bin/env bash
# Bump the pinned UniFi OS Server release: uos-version.env (read by the
# Makefile and publish-image workflow) and Chart.yaml appVersion + version
# (image.tag defaults to appVersion), then run the local chart checks.
#
# Usage:
#   scripts/bump-uos-version.sh --latest                  # query Ubiquiti (scripts/uos-latest.sh)
#   scripts/bump-uos-version.sh --from-file fw.json       # saved API response (offline)
#   scripts/bump-uos-version.sh 5.1.42 --url-amd64 URL [--sha256-amd64 SHA] \
#        [--url-arm64 URL] [--sha256-arm64 SHA] [--released YYYY-MM-DD]
#
# Options:
#   --minor           bump the chart's minor version instead of patch
#   --chart-version V set the chart version explicitly
#   --force           allow re-applying the current (or an older) version
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/uos-version.env"
CHART_FILE="$ROOT/charts/unifi-os/Chart.yaml"

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
die() { echo "ERROR: $*" >&2; exit 1; }

mode=""
new_version=""
url_amd64="" sha_amd64="" url_arm64="" sha_arm64="" released=""
from_file=""
chart_bump="patch"
chart_version=""
force=false
while [ $# -gt 0 ]; do
  case "$1" in
    --latest) mode=latest ;;
    --from-file) mode="file"; from_file="${2:?--from-file needs a path}"; shift ;;
    --url-amd64) url_amd64="${2:?}"; shift ;;
    --sha256-amd64) sha_amd64="${2:?}"; shift ;;
    --url-arm64) url_arm64="${2:?}"; shift ;;
    --sha256-arm64) sha_arm64="${2:?}"; shift ;;
    --released) released="${2:?}"; shift ;;
    --minor) chart_bump=minor ;;
    --chart-version) chart_version="${2:?}"; shift ;;
    --force) force=true ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) [ -z "$new_version" ] || die "unexpected argument: $1"; mode=manual; new_version="$1" ;;
  esac
  shift
done
[ -n "$mode" ] || { usage >&2; exit 1; }

# --- Resolve the target release -------------------------------------------
if [ "$mode" != manual ]; then
  args=()
  [ "$mode" = file ] && args=(--from-file "$from_file")
  meta="$("$ROOT/scripts/uos-latest.sh" ${args[@]+"${args[@]}"})"
  get() { printf '%s\n' "$meta" | sed -n "s/^$1=//p"; }
  new_version="$(get UOS_VERSION)"
  released="${released:-$(get UOS_RELEASED)}"
  url_amd64="$(get UOS_INSTALLER_URL_AMD64)"
  sha_amd64="$(get UOS_INSTALLER_SHA256_AMD64)"
  url_arm64="$(get UOS_INSTALLER_URL_ARM64)"
  sha_arm64="$(get UOS_INSTALLER_SHA256_ARM64)"
fi

current_version="$(sed -n 's/^UOS_VERSION=//p' "$VERSION_FILE")"

# --- Validate ----------------------------------------------------------------
[[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$new_version' is not X.Y.Z"
[ -n "$url_amd64" ] || die "an amd64 installer URL is required (--url-amd64)"
if [ "$force" != true ]; then
  if [ "$mode" != manual ] && [ "$new_version" = "$current_version" ]; then
    echo "Already at $current_version (latest release) — nothing to do."
    exit 0
  fi
  [ "$new_version" != "$current_version" ] || die "already at $current_version (use --force to re-apply)"
  newest="$(printf '%s\n%s\n' "$current_version" "$new_version" | sort -V | tail -n1)"
  [ "$newest" = "$new_version" ] || die "$new_version is older than current $current_version (use --force)"
fi
check_url() { # <url> <platform-token>
  local file="${1##*/}"
  [[ "$1" == https://* ]] || die "installer URL must be https: $1"
  [[ "$file" == *"-$2-$new_version-"* ]] || die "installer '$file' does not look like $2 $new_version"
}
check_sha() { [ -z "$1" ] || [[ "$1" =~ ^[0-9a-f]{64}$ ]] || die "not a sha256: $1"; }
check_url "$url_amd64" linux-x64
[ -z "$url_arm64" ] || check_url "$url_arm64" linux-arm64
check_sha "$sha_amd64"
check_sha "$sha_arm64"
[ -n "$sha_amd64" ] || echo "WARN: no amd64 sha256 — the image build will not verify the installer" >&2
[ -n "$url_arm64" ] || echo "WARN: no arm64 installer — arm64 builds will be skipped" >&2

# --- Chart version -------------------------------------------------------------
old_chart_version="$(sed -n 's/^version:[[:space:]]*//p' "$CHART_FILE" | tr -d '"')"
if [ -z "$chart_version" ]; then
  IFS=. read -r cmaj cmin cpat <<<"$old_chart_version"
  case "$chart_bump" in
    patch) chart_version="$cmaj.$cmin.$((cpat + 1))" ;;
    minor) chart_version="$cmaj.$((cmin + 1)).0" ;;
  esac
fi

# --- Write -------------------------------------------------------------------
{
  sed -n '/^#/p' "$VERSION_FILE"
  cat <<EOF
UOS_VERSION=$new_version
UOS_RELEASED=$released
UOS_INSTALLER_URL_AMD64=$url_amd64
UOS_INSTALLER_SHA256_AMD64=$sha_amd64
UOS_INSTALLER_URL_ARM64=$url_arm64
UOS_INSTALLER_SHA256_ARM64=$sha_arm64
EOF
} > "$VERSION_FILE.tmp" && mv "$VERSION_FILE.tmp" "$VERSION_FILE"

# (temp file instead of sed -i: BSD and GNU sed disagree on -i syntax)
sed -E \
  -e "s/^version:.*/version: $chart_version/" \
  -e "s/^appVersion:.*/appVersion: \"$new_version\"/" \
  "$CHART_FILE" > "$CHART_FILE.tmp" && mv "$CHART_FILE.tmp" "$CHART_FILE"

# --- Check ---------------------------------------------------------------------
grep -q "^appVersion: \"$new_version\"$" "$CHART_FILE" || die "Chart.yaml appVersion not updated"

if command -v helm >/dev/null; then
  lint_out="$(helm lint "$ROOT/charts/unifi-os" -f "$ROOT/tests/values/00-base.yaml" 2>&1)" \
    || { printf '%s\n' "$lint_out" >&2; die "helm lint failed"; }
  echo "helm lint: ok"
  if [ -d "$ROOT/charts/unifi-os/charts" ]; then
    out="$(mktemp -d)"
    "$ROOT/scripts/render-matrix.sh" "$out" && echo "render matrix: ok ($out)"
  fi
else
  echo "WARN: helm not installed — skipped helm lint" >&2
fi

stale="$(git -C "$ROOT" grep -n -F "$current_version" -- \
  ':!uos-version.env' ':!charts/unifi-os/Chart.yaml' \
  ':!scripts/testdata' ':!.claude/skills' 2>/dev/null | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
if [ -n "$stale" ] && [ "$current_version" != "$new_version" ]; then
  echo "WARN: $current_version is still referenced — check whether these should change:" >&2
  printf '%s\n' "$stale" >&2
fi

cat <<EOF

UniFi OS $current_version -> $new_version  (chart $old_chart_version -> $chart_version)
  amd64: $url_amd64
         sha256=${sha_amd64:-<none>}
  arm64: ${url_arm64:-<none>}
         sha256=${sha_arm64:-<none>}
  notes: https://community.ui.com/releases/r/uosserver/$new_version

Next: make build && make verify-image (see .claude/skills/upgrade-unifi-os/SKILL.md)
Commit message: Upgrade to unifi-os $new_version
EOF
