{{/*
Chart name for unifi-os.
*/}}
{{- define "unifi-os.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Shared labels for chart-managed resources.
*/}}
{{- define "unifi-os.standardLabels" -}}
app.kubernetes.io/name: {{ include "unifi-os.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Merge <service>.connection with global.<service>.connection.
Global values win over chart-local values.
Usage:
  {{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
*/}}
{{- define "unifi-os.mergedConnection" -}}
{{- $root := .root -}}
{{- $service := .service -}}
{{- $global := index $root.Values "global" | default dict -}}
{{- $globalConnection := index (index $global $service | default dict) "connection" | default dict -}}
{{- $localService := index $root.Values $service | default dict -}}
{{- $localConnection := index $localService "connection" | default dict -}}
{{- toYaml (mergeOverwrite (default dict $localConnection) $globalConnection) -}}
{{- end -}}

{{/*
PostgreSQL host — explicit connection.host when set (local or global), else derived from subchart when postgres.enabled.
*/}}
{{- define "unifi-os.postgresHost" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- if index $conn "host" -}}
{{- index $conn "host" -}}
{{- else if .Values.postgres.enabled -}}
{{- printf "%s-rw.%s.svc.cluster.local" (.Values.postgres.fullnameOverride | default "unifi-postgres") .Release.Namespace -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}

{{/*
RabbitMQ host — explicit connection.host when set (local or global), else derived from subchart when rabbitmq.enabled.
*/}}
{{- define "unifi-os.rabbitmqHost" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "rabbitmq") | fromYaml -}}
{{- if index $conn "host" -}}
{{- index $conn "host" -}}
{{- else if .Values.rabbitmq.enabled -}}
{{- printf "%s-rabbitmq.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}

{{/*
PostgreSQL connection values from merged config (global defaults; override via postgres.connection).
*/}}
{{- define "unifi-os.postgresPort" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- index $conn "port" -}}
{{- end -}}
{{- define "unifi-os.postgresDatabase" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- index $conn "database" | default "unifi-core" -}}
{{- end -}}
{{- define "unifi-os.postgresUser" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- index $conn "user" | default "unifi-core" -}}
{{- end -}}

{{/*
PostgreSQL password for creating unifi-pg-auth (plaintext mode only).
*/}}
{{- define "unifi-os.postgresPassword" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- if index $conn "useExistingSecrets" -}}
{{- "" -}}
{{- else -}}
{{- index $conn "password" | required "global.postgres.connection.password is required (or set global.postgres.connection.useExistingSecrets: true)" -}}
{{- end -}}
{{- end -}}

{{/*
Whether chart-managed credential secrets should be skipped.
True when postgres.useExistingSecrets is true or existingSecret.name is set.
Controls: unifi-pg-auth creation and init container mode.
*/}}
{{- define "unifi-os.rabbitmqUseExistingSecret" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "rabbitmq") | fromYaml -}}
{{- if index (index $conn "existingSecret" | default dict) "name" -}}
true
{{- end -}}
{{- end -}}
{{- define "unifi-os.postgresUseExistingSecret" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- if or (index $conn "useExistingSecrets") (index (index $conn "existingSecret" | default dict) "name") -}}
true
{{- end -}}
{{- end -}}

{{/*
Secret name for PostgreSQL app PGPASSWORD (secretKeyRef in the UniFi pod).
  postgres.useExistingSecrets true → pg-login-<connection.user> (e.g. pg-login-unifi-core)
  existingSecret.name set         → existingSecret.name
  otherwise                       → unifi-pg-auth (chart-managed)
*/}}
{{- define "unifi-os.postgresSecretName" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- $existing := index $conn "existingSecret" | default dict -}}
{{- if index $conn "useExistingSecrets" -}}
{{- printf "pg-login-%s" (index $conn "user" | default "unifi-core") -}}
{{- else if index $existing "name" -}}
{{- index $existing "name" -}}
{{- else -}}
{{- "unifi-pg-auth" -}}
{{- end -}}
{{- end -}}
{{- define "unifi-os.postgresSecretPasswordKey" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- $existing := index $conn "existingSecret" | default dict -}}
{{- if index $existing "name" -}}
{{- index $existing "passwordKey" | default "password" -}}
{{- else -}}
{{- "password" -}}
{{- end -}}
{{- end -}}

{{/*
Secret ref for RabbitMQ auth — name, passwordKey, erlangCookieKey for secretKeyRef.
*/}}
{{- define "unifi-os.rabbitmqSecretName" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "rabbitmq") | fromYaml -}}
{{- $existing := index $conn "existingSecret" | default dict -}}
{{- if index $existing "name" -}}
{{- index $existing "name" -}}
{{- else -}}
{{- "rabbitmq-auth" -}}
{{- end -}}
{{- end -}}
{{- define "unifi-os.rabbitmqSecretPasswordKey" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "rabbitmq") | fromYaml -}}
{{- $existing := index $conn "existingSecret" | default dict -}}
{{- if index $existing "name" -}}
{{- index $existing "passwordKey" | default "password" -}}
{{- else -}}
{{- "password" -}}
{{- end -}}
{{- end -}}

{{/*
RabbitMQ password and erlang-cookie from merged connection (for secret creation). Required when not using existingSecret.
*/}}
{{- define "unifi-os.rabbitmqPassword" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "rabbitmq") | fromYaml -}}
{{- $existing := index $conn "existingSecret" | default dict -}}
{{- if index $existing "name" -}}
{{- "" -}}
{{- else -}}
{{- index $conn "password" | required "global.rabbitmq.connection.password is required (set password or connection.existingSecret.name to use an existing secret)" -}}
{{- end -}}
{{- end -}}
{{- define "unifi-os.rabbitmqErlangCookie" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "rabbitmq") | fromYaml -}}
{{- $existing := index $conn "existingSecret" | default dict -}}
{{- if index $existing "name" -}}
{{- "" -}}
{{- else -}}
{{- index $conn "erlangCookie" | required "global.rabbitmq.connection.erlangCookie is required (set erlangCookie or connection.existingSecret.name to use an existing secret)" -}}
{{- end -}}
{{- end -}}

{{/*
TLS secret name for UniFi's nginx backend.
Returns certManager.secretName when certManager is enabled, else existingSecret, else "".
Used to conditionally enable the tls volume/mount and init container copy step.
*/}}
{{- define "unifi-os.unifiTLSSecretName" -}}
{{- if .Values.unifi.tls.certManager.enabled -}}
{{- .Values.unifi.tls.certManager.secretName | default "unifi-tls" -}}
{{- else -}}
{{- .Values.unifi.tls.existingSecret -}}
{{- end -}}
{{- end -}}

{{/*
RabbitMQ URI — uses merged connection (global overrides local). Returns URI string for RABBITMQ_URI env.
When connection.uri is set, returns it; else builds from host, port, username.
*/}}
{{- define "unifi-os.rabbitmqURI" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "rabbitmq") | fromYaml -}}
{{- if index $conn "uri" -}}
{{- index $conn "uri" -}}
{{- else -}}
{{- $host := include "unifi-os.rabbitmqHost" . -}}
{{- $port := (index $conn "port" | default 5672) -}}
{{- printf "amqp://%s:$(RABBITMQ_PASSWORD)@%s:%v/" (index $conn "username") $host $port -}}
{{- end -}}
{{- end -}}
