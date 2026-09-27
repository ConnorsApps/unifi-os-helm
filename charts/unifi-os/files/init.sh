#!/usr/bin/env bash
# Init container: wait for PostgreSQL, then write the config UniFi's services
# expect under /data (TLS, DB credentials, log settings). Services chown these
# files in their pre-start hooks, so they are copied, not mounted.
#   /run/secrets/overrides  config-overrides ConfigMap + <role>/db.{username,password}
#                           from the pg-login-<role> secrets (when present)
#   /run/secrets/tls        TLS secret (optional; else a self-signed cert)
set -e
export USER=unifi-core GROUP=unifi-core
O=/run/secrets/overrides
cfg=/data/unifi-core/config
own() { chown "$USER:$GROUP" "$@" 2>/dev/null || true; }

echo "Waiting for PostgreSQL at $PGHOST:$PGPORT"
# shellcheck disable=SC2016 # expanded by the inner bash
until timeout 2 bash -c ': > "/dev/tcp/$PGHOST/$PGPORT"' 2>/dev/null; do sleep 2; done

/usr/share/unifi-core/app/hooks/pre-start 2>/dev/null || true
mkdir -p "$cfg/http" "$cfg/overrides" /data/unifi-core/logs /srv/unifi-core /persistent

crt="$cfg/unifi-core.crt" key="$cfg/unifi-core.key" ca="$cfg/unifi-core-ca.crt"
if [ -f /run/secrets/tls/tls.crt ] && [ -f /run/secrets/tls/tls.key ]; then
  cp /run/secrets/tls/tls.crt "$crt"
  cp /run/secrets/tls/tls.key "$key"
  if [ -f /run/secrets/tls/ca.crt ]; then cp /run/secrets/tls/ca.crt "$ca"; else cp "$crt" "$ca"; fi
fi
if [ ! -s "$crt" ] || [ ! -s "$key" ]; then
  rm -f "$crt" "$key"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key" -out "$crt" -days 3650 \
    -subj "/CN=unifi.local" >/dev/null 2>&1 || true
  if [ -s "$crt" ] && [ ! -s "$ca" ]; then cp "$crt" "$ca"; fi
fi
own "$crt" "$key" "$ca"
chmod 600 "$key" 2>/dev/null || true

if [ -n "$PGHOST" ] && [ -n "$PGPASSWORD" ]; then
  printf 'postgres:\n  host: %s\n  port: %s\n  database: %s\n  user: %s\n  password: "%s"\n' \
    "$PGHOST" "${PGPORT:-5432}" "${PGDATABASE:-unifi-core}" "${PGUSER:-unifi-core}" "$PGPASSWORD" \
    > "$cfg/overrides/local.yaml"
  own "$cfg/overrides/local.yaml"
fi
cp "$O/production.yaml" "$cfg/overrides/production.yaml"
own "$cfg/overrides/production.yaml"

# <service> <postgres role>: database = service. Credentials come from the
# role's pg-login secret, else the unifi-core PGPASSWORD. <service>.config.props
# from the ConfigMap is appended.
while read -r svc role; do
  dst="/data/$svc/ws/config.props"
  mkdir -p "/data/$svc/ws"
  if [ -f "$O/$role/db.username" ] && [ -f "$O/$role/db.password" ]; then
    user="$(cat "$O/$role/db.username")" pass="$(cat "$O/$role/db.password")"
  elif [ -n "$PGHOST" ] && [ -n "$PGPASSWORD" ]; then
    user="$role" pass="$PGPASSWORD"
  else
    continue
  fi
  printf 'db.name = %s\ndb.host = %s\ndb.port = %s\ndb.encrypted = false\ndb.username = %s\ndb.password = %s\n' \
    "$svc" "$PGHOST" "${PGPORT:-5432}" "$user" "$pass" > "$dst"
  if [ -f "$O/$svc.config.props" ]; then printf '\n' >> "$dst"; cat "$O/$svc.config.props" >> "$dst"; fi
  own "$dst"
done <<'SERVICES'
ulp-go ulp-go
unifi-credential-server unifi-credential-server
ucs-user-assets unifi-credential-server
unifi-directory unifi-directory
ucs-agent ucs-agent
unifi-identity-update unifi-identity-update
uid uid
SERVICES

[ -f /data/uos_uuid ] || echo "$UOS_UUID" > /data/uos_uuid
cp /usr/share/unifi-core/http/ssl-nist.conf "$cfg/http/ssl-dynamic.conf" || true
