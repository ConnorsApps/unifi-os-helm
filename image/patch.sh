#!/bin/sh
# Adapt the unpacked upstream rootfs (/bundle/rootfs) for Kubernetes: external
# PostgreSQL/RabbitMQ, no host services, logs to the container.
#
# Static files come from image/rootfs/. Every edit to an upstream file is
# guarded by need(): when upstream moves a target the build fails rather than
# silently skipping the patch (PATCH_STRICT=false: warn only). Failure history:
# .claude/skills/upgrade-unifi-os/SKILL.md.
set -eu
R=/bundle/rootfs

need() { # <what> <command...>: fail unless the command succeeds
  what="$1"; shift
  "$@" && return 0
  echo "PATCH TARGET MISSING: $what ($*)" >&2
  echo "  Upstream changed; review this patch (see .claude/skills/upgrade-unifi-os)." >&2
  [ "${PATCH_STRICT:-true}" = false ] && { echo "  PATCH_STRICT=false: continuing" >&2; return 0; }
  exit 1
}
unit() { # <name>: unit file exists in any systemd dir
  for d in etc/systemd/system lib/systemd/system usr/lib/systemd/system; do
    [ -e "$R/$d/$1" ] && return 0
  done
  return 1
}

# Pods don't resolve host.docker.internal; unifi-core's discovery client lives in the pod.
need "unifi-core discovery host" grep -q 'host\.docker\.internal' "$R/etc/default/unifi-core_advanced"
sed -i 's|host\.docker\.internal|localhost|g' "$R/etc/default/unifi-core_advanced"

# Drop-ins in image/rootfs: uos-agent/uos-discovery-client are stub binaries
# (Restart=no stops a restart storm); mongodb's log/data dirs sit on volumes
# and need creating/chowning at every start.
need "uos-agent unit" unit uos-agent.service
need "uos-discovery-client unit" unit uos-discovery-client.service
need "mongodb unit" unit mongodb.service

# nginx global error_log to stderr. Leave nginx.conf.disabled alone: its logs
# can't point at /dev/std* under journald-backed stdio (nginx fails to start).
nginx_error='^[[:space:]]*error_log[[:space:]]+/var/log/nginx/error\.log[[:space:]]+notice;'
need "nginx global error_log" grep -Eq "$nginx_error" "$R/etc/nginx/nginx.conf"
sed -E -i "s|$nginx_error|error_log  /dev/stderr notice;|" "$R/etc/nginx/nginx.conf"

# No timesyncd in the image, and unifi-core blocks logins while
# NTPSynchronized=no; image/rootfs/usr/bin/timedatectl wraps the real one.
need "timedatectl" test -e "$R/usr/bin/timedatectl"
mv "$R/usr/bin/timedatectl" "$R/usr/bin/timedatectl.real"

# PostgreSQL and RabbitMQ run outside the pod: drop the servers, keep the PG 14
# client for the psql wrappers. MongoDB stays (UniFi Network embeds it).
need "embedded PostgreSQL 16" test -e "$R/usr/lib/postgresql/16"
need "PostgreSQL 14 client" test -e "$R/usr/lib/postgresql/14"
rm -rf \
  "$R"/usr/bin/mongo "$R"/usr/bin/rabbitmq* "$R"/usr/sbin/rabbitmq* \
  "$R"/usr/lib/rabbitmq "$R"/usr/lib/erlang "$R"/etc/rabbitmq "$R"/var/lib/rabbitmq "$R"/var/log/rabbitmq \
  "$R"/usr/lib/postgresql/16 "$R"/usr/share/postgresql/16 "$R"/etc/postgresql/16 "$R"/var/lib/postgresql/16 \
  "$R"/usr/share/doc "$R"/usr/share/man "$R"/usr/share/info

# /entrypoint.sh replays the OCI process config (env, cwd, args).
jq -r '"#!/bin/sh",
  (.process.env // [] | .[] | split("=") | "export " + .[0] + "=" + (.[1:] | join("=") | @sh)),
  ("cd " + (.process.cwd // "/" | @sh)),
  ("exec " + (.process.args | map(@sh) | join(" ")))' /bundle/config.json > "$R/entrypoint.sh"
chmod +x "$R/entrypoint.sh"
cat "$R/entrypoint.sh"

# Written by the real installer, missing from the embedded image. Without
# app_model/product_name (image/rootfs) unifi-core aborts: "Unsupported console model".
case "${TARGETARCH:-$(dpkg --print-architecture)}" in
  amd64) printf linux-x64 ;;
  arm64) printf linux-arm64 ;;
  *) printf 'linux-%s' "$(uname -m)" ;;
esac > "$R/usr/lib/platform"
version="$(sed -nE 's#.*-([0-9]+\.[0-9]+\.[0-9]+)-.*#\1#p' /tmp/installer-url)"
[ -n "$version" ] || { echo "ERROR: no X.Y.Z version in installer URL $(cat /tmp/installer-url)" >&2; exit 1; }
echo "UOSSERVER.0000000.$version.0000000.000000.0000" > "$R/usr/lib/version"

# Device files can't live in an image layer; the runtime mounts /dev.
find "$R/dev" -mindepth 1 -delete 2>/dev/null || true

cp -a "$(dirname "$0")/rootfs/." "$R/"
chmod 0755 "$R/usr/bin/timedatectl" "$R/usr/local/bin/pg-wrapper"
chmod 0440 "$R/etc/sudoers.d/60-unifi-postgres-env"
