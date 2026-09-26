#!/usr/bin/env bash
# Static post-build checks on a built UniFi OS image: every file the Dockerfile
# bakes in is present and the stripped components are gone. Does not boot the
# image (that needs systemd + Postgres + RabbitMQ; see the upgrade skill).
#
# Usage: scripts/verify-image.sh <image> [expected-version]
# Env:   CONTAINER_ENGINE (default podman), PLATFORM (e.g. linux/arm64)
set -euo pipefail

IMAGE="${1:?usage: verify-image.sh <image> [expected-version]}"
EXPECTED_VERSION="${2:-}"
ENGINE="${CONTAINER_ENGINE:-podman}"
platform_args=()
[ -n "${PLATFORM:-}" ] && platform_args=(--platform "$PLATFORM")

# Runs inside the image with /bin/sh; prints PASS/FAIL lines, exits 1 on any FAIL.
# shellcheck disable=SC2016
CHECKS='
fails=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fails=$((fails + 1)); }
has()  { if [ -e "$1" ]; then ok "exists: $1"; else bad "missing: $1"; fi; }
hasnt(){ if [ -e "$1" ]; then bad "should be removed: $1"; else ok "removed: $1"; fi; }
exe()  { if [ -x "$1" ]; then ok "executable: $1"; else bad "not executable: $1"; fi; }
eq()   { v="$(cat "$1" 2>/dev/null)"; if [ "$v" = "$2" ]; then ok "$1 = $2"; else bad "$1 = \"$v\" (want \"$2\")"; fi; }
grepq(){ if grep -Eq -- "$2" "$1" 2>/dev/null; then ok "$1 matches /$2/"; else bad "$1 lacks /$2/"; fi; }
nogrep(){ if grep -Eq -- "$2" "$1" 2>/dev/null; then bad "$1 still matches /$2/"; else ok "$1 has no /$2/"; fi; }

exe /entrypoint.sh
grepq /entrypoint.sh "^exec "
if [ -n "$EXPECTED_VERSION" ]; then
  eq /usr/lib/version "UOSSERVER.0000000.$EXPECTED_VERSION.0000000.000000.0000"
else
  grepq /usr/lib/version "^UOSSERVER\.0000000\.[0-9]+\.[0-9]+\.[0-9]+\."
fi
case "$(uname -m)" in
  x86_64) eq /usr/lib/platform linux-x64 ;;
  aarch64) eq /usr/lib/platform linux-arm64 ;;
  *) has /usr/lib/platform ;;
esac
eq /usr/lib/app_model UOSSERVER
eq /usr/lib/product_name "UniFi OS Server"

nogrep /etc/default/unifi-core_advanced "host\.docker\.internal"
has /etc/systemd/system/uos-discovery-client.service.d/no-restart.conf
has /etc/systemd/system/uos-agent.service.d/no-restart.conf
has /etc/systemd/system/mongodb.service.d/log-dir.conf
grepq /etc/nginx/nginx.conf "access_log /dev/stdout apm;"

exe /usr/bin/timedatectl
exe /usr/bin/timedatectl.real
grepq /usr/bin/timedatectl "timedatectl\.real"

for u in postgresql.service postgresql@14-main.service postgresql-cluster@14-main.service rabbitmq-server.service epmd.service; do
  grepq "/etc/systemd/system/$u" "^ExecStart=/bin/true"
done
has /etc/sudoers.d/60-unifi-postgres-env
for t in psql createuser createdb dropdb dropuser; do exe "/usr/local/bin/$t"; done
has /usr/lib/postgresql/14

hasnt /usr/lib/postgresql/16
hasnt /usr/lib/rabbitmq
hasnt /usr/lib/erlang
hasnt /usr/bin/mongo
has /usr/bin/mongod

echo
if [ "$fails" -eq 0 ]; then echo "All checks passed"; else echo "$fails check(s) failed"; exit 1; fi
'

"$ENGINE" run --rm ${platform_args[@]+"${platform_args[@]}"} \
  -e "EXPECTED_VERSION=$EXPECTED_VERSION" --entrypoint /bin/sh "$IMAGE" -c "$CHECKS"
