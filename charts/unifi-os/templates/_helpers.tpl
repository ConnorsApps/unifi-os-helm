{{/*
Chart name for unifi-os.
*/}}
{{- define "unifi-os.name" -}}
{{- default .Chart.Name .Chart.NameOverride | trunc 63 | trimSuffix "-" -}}
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
{{- printf "%s-rw.%s.svc.cluster.local" .Values.postgres.clusterName .Release.Namespace -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}

{{/*
MongoDB host — explicit connection.host when set (local or global), else derived from subchart when mongodb.enabled.
*/}}
{{- define "unifi-os.mongodbHost" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "mongodb") | fromYaml -}}
{{- if index $conn "host" -}}
{{- index $conn "host" -}}
{{- else if .Values.mongodb.enabled -}}
{{- printf "%s-unifi-mongodb-svc.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
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
{{- index $conn "user" -}}
{{- end -}}

{{/*
Effective PostgreSQL password — required unless connection.existingSecret.name is set (merged config).
*/}}
{{- define "unifi-os.postgresPassword" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- index $conn "password" | required "global.postgres.connection.password is required (set password or connection.existingSecret.name to use an existing secret)" -}}
{{- end -}}

{{/*
Whether to use existing secret (skip creating our own). Returns "true" when existingSecret.name is set.
*/}}
{{- define "unifi-os.mongodbUseExistingSecret" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "mongodb") | fromYaml -}}
{{- if index (index $conn "existingSecret" | default dict) "name" -}}
true
{{- end -}}
{{- end -}}
{{- define "unifi-os.rabbitmqUseExistingSecret" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "rabbitmq") | fromYaml -}}
{{- if index (index $conn "existingSecret" | default dict) "name" -}}
true
{{- end -}}
{{- end -}}
{{- define "unifi-os.postgresUseExistingSecret" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- if index (index $conn "existingSecret" | default dict) "name" -}}
true
{{- end -}}
{{- end -}}

{{/*
Secret ref for MongoDB password — name and key for secretKeyRef.
When connection.existingSecret.name is set, use that; else use our mongodb-password secret.
*/}}
{{- define "unifi-os.mongodbSecretName" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "mongodb") | fromYaml -}}
{{- $existing := index $conn "existingSecret" | default dict -}}
{{- if index $existing "name" -}}
{{- index $existing "name" -}}
{{- else -}}
{{- "mongodb-password" -}}
{{- end -}}
{{- end -}}
{{- define "unifi-os.mongodbSecretPasswordKey" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "mongodb") | fromYaml -}}
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
Secret ref for PostgreSQL auth — name and key for secretKeyRef.
*/}}
{{- define "unifi-os.postgresSecretName" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "postgres") | fromYaml -}}
{{- $existing := index $conn "existingSecret" | default dict -}}
{{- if index $existing "name" -}}
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
MongoDB password from merged connection (for secret creation). Required when not using existingSecret.
*/}}
{{- define "unifi-os.mongodbPassword" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "mongodb") | fromYaml -}}
{{- $existing := index $conn "existingSecret" | default dict -}}
{{- if index $existing "name" -}}
{{- "" -}}
{{- else -}}
{{- index $conn "password" | required "global.mongodb.connection.password is required (set password or connection.existingSecret.name to use an existing secret)" -}}
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
MongoDB URI — uses merged connection (global overrides local). Returns URI string for MONGO_URI env.
When connection.uri is set, returns it; else builds from host, port, username, database, replicaSetName.
replicaSetName is omitted from the URI when empty — set global.mongodb.connection.replicaSetName: ""
to use a standalone MongoDB instance (e.g. mongodb.replicaSet.enabled: false in the subchart).
*/}}
{{- define "unifi-os.mongoURI" -}}
{{- $conn := include "unifi-os.mergedConnection" (dict "root" . "service" "mongodb") | fromYaml -}}
{{- if index $conn "uri" -}}
{{- index $conn "uri" -}}
{{- else -}}
{{- $host := include "unifi-os.mongodbHost" . -}}
{{- $port := (index $conn "port" | default 27017) -}}
{{- $rsName := index $conn "replicaSetName" | default "" -}}
{{- if $rsName -}}
{{- printf "mongodb://%s:$(MONGO_PASSWORD)@%s:%v/%s?replicaSet=%s" (index $conn "username") $host $port (index $conn "database") $rsName -}}
{{- else -}}
{{- printf "mongodb://%s:$(MONGO_PASSWORD)@%s:%v/%s" (index $conn "username") $host $port (index $conn "database") -}}
{{- end -}}
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
