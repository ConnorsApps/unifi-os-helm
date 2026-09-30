#!/usr/bin/env bash
# unifi-os container: hand runtime settings to systemd-managed services, then
# run systemd as PID 1 (the bundled UniFi units start as upstream intends).
set -e
# libpq defaults for every unit.
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/10-postgres-env.conf <<CONF
[Manager]
DefaultEnvironment=PGHOST=${PGHOST} PGPORT=${PGPORT}
CONF
mkdir -p /var/log/nginx /var/lib/unifi
cat > /var/lib/unifi/env-overrides <<CONF
UNIFI_MQ_ENABLED=true
RABBITMQ_URI=${RABBITMQ_URI}
CONF
exec /sbin/init
