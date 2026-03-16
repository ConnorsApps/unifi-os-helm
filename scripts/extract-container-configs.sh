#!/usr/bin/env bash
# Extract live config files from the uosserver container for comparison with the Helm chart.
# Run via: sudo -u uosserver podman exec -i uosserver bash -s < extract-container-configs.sh
# Then copy out: sudo -u uosserver podman cp uosserver:/tmp/configs.tar.gz ./configs.tar.gz
set -euo pipefail

OUT=/tmp/configs
rm -rf "$OUT" && mkdir -p "$OUT"

# 1. config.props for all identity/ULP services
for svc in ulp-go unifi-credential-server ucs-user-assets unifi-directory \
            ucs-agent unifi-identity-update uid-agent; do
  src="/usr/lib/$svc/config.props"
  [ -f "$src" ] && mkdir -p "$OUT/props/$svc" && cp "$src" "$OUT/props/$svc/"
done

# 2. Service start/pre-start scripts and envs.sh
for svc in ulp-go unifi-credential-server ucs-user-assets unifi-directory \
            ucs-agent unifi-identity-update uid-agent; do
  d="/usr/lib/$svc/scripts"
  [ -d "$d" ] && mkdir -p "$OUT/props/$svc" && cp -a "$d" "$OUT/props/$svc/"
done
# uid-agent envs.sh is referenced directly in values.yaml container command
[ -f /usr/lib/uid-agent/scripts/envs.sh ] && cp /usr/lib/uid-agent/scripts/envs.sh "$OUT/props/uid-agent/"

# 3. unifi-core: node-config files + hooks
mkdir -p "$OUT/unifi-core"
[ -d /usr/share/unifi-core/app/config ] && cp -r /usr/share/unifi-core/app/config "$OUT/unifi-core/"
[ -d /usr/share/unifi-core/app/hooks ]  && cp -r /usr/share/unifi-core/app/hooks  "$OUT/unifi-core/"

# 4. nginx full config tree
mkdir -p "$OUT/nginx"
[ -f /etc/nginx/nginx.conf ] && cp /etc/nginx/nginx.conf "$OUT/nginx/"
for d in conf.d sites-enabled sites-available snippets; do
  [ -d "/etc/nginx/$d" ] && cp -r "/etc/nginx/$d" "$OUT/nginx/"
done

# 5. Environment defaults
mkdir -p "$OUT/defaults"
for f in unifi-core unifi-core_advanced unifi ulp-go uid-agent; do
  [ -f "/etc/default/$f" ] && cp "/etc/default/$f" "$OUT/defaults/"
done

# 6. D-Bus policy (uos-agent uses zbus → needs system bus policies)
[ -d /etc/dbus-1/system.d ] && cp -r /etc/dbus-1/system.d "$OUT/dbus-system.d"

# 7. Live /data overrides (written by pre-start scripts on first boot)
for p in \
  /data/unifi-core/config/overrides \
  /data/ulp-go/ws/config.props \
  /data/unifi-credential-server/ws/config.props \
  /data/unifi-directory/ws/config.props \
  /data/ucs-agent/ws/config.props \
  /data/uid/ws/config.props \
  /data/unifi-identity-update/ws/config.props; do
  [ -e "$p" ] || continue
  rel=$(dirname "$p" | sed 's|^/data/||')
  mkdir -p "$OUT/data-overrides/$rel"
  cp -r "$p" "$OUT/data-overrides/$rel/"
done

# 8. RabbitMQ config (TLS cert paths, plugins, env)
[ -d /etc/rabbitmq ] && cp -r /etc/rabbitmq "$OUT/"

# 9. coturn (referenced by unifi-directory Before=coturn.service)
[ -d /etc/coturn ] && cp -r /etc/coturn "$OUT/"

# 10. gen-certs.sh (rabbitmq ExecStartPre; generates AMQPS certs)
[ -f /usr/share/unifi/gen-certs.sh ] && mkdir -p "$OUT/unifi" && cp /usr/share/unifi/gen-certs.sh "$OUT/unifi/"

tar -czf /tmp/configs.tar.gz -C /tmp configs
echo "Done: /tmp/configs.tar.gz"
