#!/usr/bin/env bash
# The UniFi OS upgrade contract: one owner for "is there an update", "do the
# upgrade" and "does it need human or agent review". Callers (the make targets,
# a workflow, an agent) read JSON instead of exit codes, because make collapses
# every failure to exit 2.
#
# Usage (via make upgrade-check | upgrade | upgrade-verify):
#   scripts/upgrade.sh check  [--from-file FW.json]
#       writes file-dumps/upgrade/check.json; exit 0 whenever it was written
#   scripts/upgrade.sh run    [--from-file FW.json]
#       bump to the latest release, diff upstream (HEAD pin vs bumped tree), verify
#   scripts/upgrade.sh verify
#       make build + test + schema-check, then rewrite the report
#
# Files in file-dumps/upgrade/ (repo-relative paths in the JSON):
#   check.json   {update, from, to, title}
#   report.json  {from, to, chart_from, chart_to, title, brief, needs_review[],
#                 verified, checks[{name, ok}], report_md, diff}
#   report.md    public facts only: posted verbatim as a PR body
#   diff/        upstream snapshots, upstream.diff; diff-summary.txt, state.json, logs/ (local)
# run and verify exit 0 iff verified (every check passed), and write the report
# either way; no report means the run itself failed. CHANGELOG.md gets a
# "## <chart version>" section from the same data.
#
# needs_review (the only place the rule lives): any upstream snapshot other
# than packages.txt CHANGED, any reference to the old version left in the tree
# (scripts/stale-refs.sh), any failed check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="file-dumps/upgrade"
DIFF_DIR=$OUT/diff
SUMMARY=$OUT/diff-summary.txt
STATE=$OUT/state.json
BRIEF=.claude/skills/upgrade-unifi-os/SKILL.md
VERSION_FILE=uos-version.env
CHART_DIR=charts/unifi-os
CHART_FILE=$CHART_DIR/Chart.yaml
CHANGELOG=CHANGELOG.md
CHECKS=(build test schema-check)
RELEASE_NOTES_BASE=https://community.ui.com/releases/r/uosserver
MAX_PKGS=40

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }
die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "==> $*"; }
kv() { sed -n "s/^$1=//p"; }  # read a key from KEY=value text on stdin
chart_version() { sed -n 's/^version:[[:space:]]*//p' | tr -d '"'; }

for tool in jq git make; do command -v "$tool" >/dev/null || die "$tool is required"; done

# --- check -------------------------------------------------------------------

cmd_check() {
  local from_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-file) from_file="${2:?--from-file needs a path}"; shift ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done
  mkdir -p "$OUT"
  rm -f "$OUT/check.json"

  local args=(--check) out rc=0
  [ -z "$from_file" ] || args+=(--from-file "$from_file")
  out="$(scripts/uos-latest.sh "${args[@]}")" || rc=$?
  # 10 = update available; anything else non-zero is a failed lookup
  [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ] || die "latest release lookup failed (exit $rc)"

  local from to update
  from="$(printf '%s\n' "$out" | kv current)"
  to="$(printf '%s\n' "$out" | kv latest)"
  update="$(printf '%s\n' "$out" | kv update_available)"
  [ -n "$from" ] && [ -n "$to" ] || die "could not read versions from: $out"
  [ "$update" = true ] || [ "$update" = false ] || die "unexpected update_available=$update"

  jq -n --argjson update "$update" --arg from "$from" --arg to "$to" \
    '{update: $update, from: $from, to: $to, title: "Upgrade to unifi-os \($to)"}' \
    > "$OUT/check.json.tmp"
  mv "$OUT/check.json.tmp" "$OUT/check.json"

  if [ "$update" = true ]; then
    echo "Update available: $from -> $to"
  else
    echo "Up to date at $from (latest release: $to)"
  fi
  echo "Wrote $OUT/check.json"
}

# --- run ---------------------------------------------------------------------

# deps_ok: every chart dependency is vendored (status "ok" in helm dependency list)
deps_ok() {
  helm dependency list "$CHART_DIR" 2>/dev/null \
    | awk -F'\t' 'NF >= 4 && NR > 1 { n++; if ($4 !~ /^ok/) bad = 1 } END { exit (bad || n == 0) ? 1 : 0 }'
}

# The chart lints against its subcharts, which are gitignored (fresh clones lack them).
ensure_deps() {
  command -v helm >/dev/null || die "helm is required"
  deps_ok && return 0
  say "helm dependency update"
  helm repo add cloudnative-pg https://cloudnative-pg.github.io/charts >/dev/null
  helm dependency update "$CHART_DIR"
}

# tee_status <file> <cmd...>: tee the command's stdout to the file, return its status
tee_status() {
  local file="$1" rc; shift
  set +e
  "$@" | tee "$file"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# write_state: from/to = committed pin (HEAD) vs working tree
write_state() {
  local head_env from to released chart_from chart_to
  head_env="$(git show "HEAD:$VERSION_FILE" 2>/dev/null)" || die "no committed $VERSION_FILE at HEAD"
  from="$(printf '%s\n' "$head_env" | kv UOS_VERSION)"
  to="$(kv UOS_VERSION < "$VERSION_FILE")"
  released="$(kv UOS_RELEASED < "$VERSION_FILE")"
  chart_from="$(git show "HEAD:$CHART_FILE" | chart_version)"
  chart_to="$(chart_version < "$CHART_FILE")"
  [ -n "$from" ] && [ -n "$to" ] || die "no UOS_VERSION in $VERSION_FILE"
  [ "$from" != "$to" ] || die "already at $to: nothing to upgrade (make upgrade-check says whether a newer release exists)"
  mkdir -p "$OUT"
  jq -n --arg from "$from" --arg to "$to" --arg released "$released" \
    --arg chart_from "$chart_from" --arg chart_to "$chart_to" \
    '{from: $from, to: $to, released: $released, chart_from: $chart_from, chart_to: $chart_to}' \
    > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

cmd_run() {
  local from_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --from-file) from_file="${2:?--from-file needs a path}"; shift ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done
  # A missing report must never be a leftover of an earlier run.
  rm -rf "$OUT/report.json" "$OUT/report.md" "$STATE" "$SUMMARY" "$DIFF_DIR" "$OUT/logs"
  mkdir -p "$OUT/logs"

  ensure_deps

  say "bump uos-version.env + Chart.yaml"
  local bump_args=(--latest)
  [ -z "$from_file" ] || bump_args=(--from-file "$from_file")
  tee_status "$OUT/logs/bump.log" scripts/bump-uos-version.sh "${bump_args[@]}" \
    || die "bump-uos-version.sh failed"
  write_state

  say "diff upstream: committed pin (HEAD) vs bumped tree"
  # The summary is stdout only; podman/docker progress goes to stderr.
  if ! OUT_DIR="$ROOT/$DIFF_DIR" tee_status "$SUMMARY" scripts/diff-uos-images.sh; then
    echo "WARN: upstream snapshot diff failed; the report will say so" >&2
    rm -f "$SUMMARY"
  fi

  cmd_verify
}

# --- verify ------------------------------------------------------------------

# snapshot_rows <summary>: "name<TAB>unchanged|CHANGED<TAB>added<TAB>removed" per snapshot
snapshot_rows() {
  local line re='^[[:space:]]+([A-Za-z0-9_.-]+)[[:space:]]+(unchanged|CHANGED)([[:space:]]+\(\+([0-9]+)/-([0-9]+)[[:space:]]+lines\))?[[:space:]]*$'
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then
      printf '%s\t%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[4]:-}" "${BASH_REMATCH[5]:-}"
    fi
  done < "$1"
}

# package_changes <summary>: "pkg: old → new" per changed package, sorted
package_changes() {
  awk '
    /^Package version changes:/ { on = 1; next }
    on && $1 == "<" { old[$2] = $3; seen[$2] = 1 }
    on && $1 == ">" { new[$2] = $3; seen[$2] = 1 }
    END {
      for (p in seen) {
        if ((p in old) && (p in new)) printf "%s: %s → %s\n", p, old[p], new[p]
        else if (p in old) printf "%s: removed (%s)\n", p, old[p]
        else printf "%s: added (%s)\n", p, new[p]
      }
    }' "$1" | LC_ALL=C sort
}

# run_check <name>: make <name>, quiet; the log keeps the output
run_check() {
  local name="$1" log="$OUT/logs/$1.log" rc=0
  say "make $name (log: $log)"
  # PATCH_STRICT on the command line beats an exported PATCH_STRICT=false
  make -C "$ROOT" --no-print-directory PATCH_STRICT=true "$name" > "$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "    FAILED (exit $rc); last lines:" >&2
    tail -n 20 "$log" | sed 's/^/    | /' >&2
  fi
  return "$rc"
}

# join_by <sep> <items...>
join_by() { local sep="$1" out="" i; shift; for i in "$@"; do out="${out:+$out$sep}$i"; done; printf '%s' "$out"; }

cmd_verify() {
  mkdir -p "$OUT/logs"
  rm -f "$OUT/report.json" "$OUT/report.md"

  local tree_to from to released chart_from chart_to
  tree_to="$(kv UOS_VERSION < "$VERSION_FILE")"
  if [ ! -f "$STATE" ] || [ "$(jq -r .to "$STATE")" != "$tree_to" ]; then
    write_state
  fi
  from="$(jq -r .from "$STATE")"; to="$(jq -r .to "$STATE")"; released="$(jq -r .released "$STATE")"
  chart_from="$(jq -r .chart_from "$STATE")"; chart_to="$(jq -r .chart_to "$STATE")"
  local title="Upgrade to unifi-os $to"

  # Upstream snapshot summary saved by `run`; valid only for this from -> to.
  local have_summary=false snaps=() changed=() other_changed=()
  if [ -f "$SUMMARY" ] && grep -q "^UniFi OS upstream diff: $from -> $to\$" "$SUMMARY"; then
    have_summary=true
    local name status add del
    while IFS=$'\t' read -r name status add del; do
      snaps+=("$name"$'\t'"$status"$'\t'"$add"$'\t'"$del")
      if [ "$status" = CHANGED ]; then
        changed+=("$name")
        [ "$name" = packages.txt ] || other_changed+=("$name (+$add/-$del lines)")
      fi
    done < <(snapshot_rows "$SUMMARY")
    [ "${#snaps[@]}" -gt 0 ] || have_summary=false
  fi

  # Checks
  local checks=() check_names_ok=() failed=() name ok
  for name in "${CHECKS[@]}"; do
    if run_check "$name"; then ok=true; check_names_ok+=("$name"); else ok=false; failed+=("$name"); fi
    checks+=("$(jq -nc --arg name "$name" --argjson ok "$ok" '{name: $name, ok: $ok}')")
  done
  local verified=false
  [ "${#failed[@]}" -gt 0 ] || verified=true

  # needs_review
  local review=() stale_files
  if [ "$have_summary" = false ]; then
    review+=("upstream snapshot comparison is missing: run make upgrade")
  fi
  local c
  for c in ${other_changed[@]+"${other_changed[@]}"}; do
    review+=("upstream snapshot $c changed")
  done
  stale_files="$(scripts/stale-refs.sh "$from" | cut -d: -f1 | LC_ALL=C sort -u | paste -sd' ' -)"
  if [ -n "$stale_files" ]; then
    review+=("old version $from is still referenced in: ${stale_files// /, }")
  fi
  for c in ${failed[@]+"${failed[@]}"}; do
    review+=("check failed: $c")
  done

  # Package changes (compact lines)
  local pkgs=() npkgs=0
  if [ "$have_summary" = true ]; then
    while IFS= read -r line; do pkgs+=("$line"); done < <(package_changes "$SUMMARY")
    npkgs=${#pkgs[@]}
  fi

  local diff_path=""
  [ ! -f "$DIFF_DIR/upstream.diff" ] || diff_path="$DIFF_DIR/upstream.diff"

  # report.json
  local review_json checks_json
  review_json="$(jq -nc '$ARGS.positional' --args ${review[@]+"${review[@]}"})"
  checks_json="$(printf '%s\n' "${checks[@]}" | jq -sc .)"
  jq -n --arg from "$from" --arg to "$to" --arg chart_from "$chart_from" --arg chart_to "$chart_to" \
    --arg title "$title" --arg brief "$BRIEF" --argjson needs_review "$review_json" \
    --argjson verified "$verified" --argjson checks "$checks_json" \
    --arg report_md "$OUT/report.md" --arg diff "$diff_path" \
    '{from: $from, to: $to, chart_from: $chart_from, chart_to: $chart_to, title: $title, brief: $brief,
      needs_review: $needs_review, verified: $verified, checks: $checks, report_md: $report_md, diff: $diff}' \
    > "$OUT/report.json.tmp"

  # report.md: posted verbatim as a public PR body. Public facts only.
  {
    echo "UniFi OS Server $from → $to${released:+ (released $released)}. Chart $chart_from → $chart_to."
    echo
    echo "Release notes: $RELEASE_NOTES_BASE/$to (unread; the page is JavaScript-rendered)."
    echo
    echo "## Upstream rootfs changes"
    echo
    if [ "$have_summary" = true ]; then
      echo "| Snapshot | Result |"
      echo "|---|---|"
      local row
      for row in "${snaps[@]}"; do
        IFS=$'\t' read -r name status add del <<<"$row"
        if [ "$status" = CHANGED ]; then echo "| $name | CHANGED (+$add/-$del lines) |"; else echo "| $name | unchanged |"; fi
      done
      echo
      echo "Package version changes: $npkgs"
      if [ "$npkgs" -gt 0 ]; then
        echo
        local i
        for ((i = 0; i < npkgs && i < MAX_PKGS; i++)); do echo "- ${pkgs[$i]}"; done
        [ "$npkgs" -le "$MAX_PKGS" ] || echo "- and $((npkgs - MAX_PKGS)) more"
      fi
    else
      echo "Not compared (no upstream snapshot summary)."
    fi
    echo
    echo "## Checks"
    echo
    echo "| Check | ok |"
    echo "|---|---|"
    local cj
    for cj in "${checks[@]}"; do
      jq -r '"| make \(.name) | \(if .ok then "yes" else "no" end) |"' <<<"$cj"
    done
    echo
    echo "## Needs review"
    echo
    if [ "${#review[@]}" -eq 0 ]; then
      echo "None."
    else
      for c in "${review[@]}"; do echo "- $c"; done
    fi
    echo
    echo "Not verified: runtime boot"
  } > "$OUT/report.md.tmp"

  mv "$OUT/report.md.tmp" "$OUT/report.md"
  mv "$OUT/report.json.tmp" "$OUT/report.json"

  # CHANGELOG.md: compact public summary under "## <chart version>"
  local snap_line pkg_line verified_line
  if [ "$have_summary" = false ]; then
    snap_line="not compared"
  elif [ "${#changed[@]}" -eq 0 ]; then
    snap_line="no changes"
  elif [ "${#other_changed[@]}" -eq 0 ]; then
    snap_line="only packages.txt changed"
  else
    snap_line="changed: $(join_by ', ' "${changed[@]}")"
  fi
  if [ "$npkgs" -eq 0 ]; then
    pkg_line="none"
  else
    pkg_line="$(join_by '; ' "${pkgs[@]:0:8}")"
    [ "$npkgs" -le 8 ] || pkg_line="$pkg_line; and $((npkgs - 8)) more"
  fi
  if [ "$verified" = true ]; then
    verified_line="yes ($(join_by ', ' "${check_names_ok[@]}")); runtime boot not verified"
  else
    verified_line="no (failed: $(join_by ', ' "${failed[@]}"))"
  fi
  update_changelog "$chart_to" "## $chart_to

UniFi OS $from → $to${released:+ (released $released)}.

- Upstream snapshots: $snap_line.
- Package changes: $pkg_line.
- Verified: $verified_line."

  # Human summary
  echo
  echo "UniFi OS $from -> $to  (chart $chart_from -> $chart_to)"
  local cj
  for cj in "${checks[@]}"; do jq -r '"  check \(.name): \(if .ok then "ok" else "FAILED" end)"' <<<"$cj"; done
  if [ "${#review[@]}" -eq 0 ]; then
    echo "  needs_review: none"
  else
    echo "  needs_review:"
    for c in "${review[@]}"; do echo "    - $c"; done
  fi
  echo "  verified: $verified"
  echo "  report: $OUT/report.json, $OUT/report.md; changelog: $CHANGELOG"

  [ "$verified" = true ]
}

# update_changelog <chart version> <section text>: write or replace the section
# for that version, newest first, below the intro.
update_changelog() {
  local version="$1" section="$2" tmp
  if [ ! -f "$CHANGELOG" ]; then
    cat > "$CHANGELOG" <<'EOF'
# Changelog

Chart releases, newest first. Each section names the UniFi OS Server release
it packages (the image tag is the chart's `appVersion`). `make upgrade` and
`make upgrade-verify` maintain the entries for upstream upgrades.

EOF
  fi
  tmp="$(mktemp)"
  printf '%s\n\n' "$section" > "$tmp.section"
  awk -v heading="## $version" -v sectionfile="$tmp.section" '
    function emit(   line) { while ((getline line < sectionfile) > 0) print line; done = 1 }
    /^## / {
      if (!done) emit()
      skip = ($0 == heading)
    }
    skip { next }
    { print }
    END { if (!done) emit() }
  ' "$CHANGELOG" > "$tmp"
  mv "$tmp" "$CHANGELOG"
  rm -f "$tmp.section"
}

# --- main --------------------------------------------------------------------

[ $# -gt 0 ] || { usage >&2; exit 1; }
cmd="$1"; shift
case "$cmd" in
  check) cmd_check "$@" ;;
  run) cmd_run "$@" ;;
  verify) cmd_verify "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac
