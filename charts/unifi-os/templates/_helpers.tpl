{{- define "unifi-os.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fail fast if deprecated hull.* values are still set. This chart was migrated
off HULL (vidispine/hull) to plain Helm templates — a leftover `hull:` block
in a values file is silently ignored otherwise, which is worse than an error.
*/}}
{{- define "unifi-os.rejectHullValues" -}}
{{- if .Values.hull }}
{{- fail "values.hull.* is set but this chart no longer uses HULL (vidispine/hull) — it was migrated to plain Helm templates and the `hull:` key has no effect. Remove it from your values file. See values.env.example.yaml for the equivalent curated override values (nodeSelector, affinity, tolerations, extraEnv, extraVolumes, securityContext, resourceClaims, service.type/annotations, etc.)." -}}
{{- end -}}
{{- end -}}

{{- define "unifi-os.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Selector labels. Params: root, component (optional). Immutable on existing workloads. */}}
{{- define "unifi-os.selectorLabels" -}}
{{- $root := .root -}}
{{- $component := .component | default "" -}}
app.kubernetes.io/name: {{ include "unifi-os.name" $root }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
{{- if $component }}
app.kubernetes.io/component: {{ $component }}
{{- end }}
{{- end -}}

{{/* Standard labels + commonLabels. Params: root, component (optional). */}}
{{- define "unifi-os.labels" -}}
{{- $root := .root -}}
helm.sh/chart: {{ include "unifi-os.chart" $root }}
{{ include "unifi-os.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
app.kubernetes.io/version: {{ $root.Chart.AppVersion | quote }}
{{- with $root.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Object or pod-template metadata. Params: root, name (omit for pod templates),
component, labels (extra), annotations (extra; win over commonAnnotations).
*/}}
{{- define "unifi-os.metadata" -}}
{{- if .name }}
name: {{ .name }}
namespace: {{ .root.Release.Namespace }}
{{- end }}
labels:
  {{- include "unifi-os.labels" . | nindent 2 }}
  {{- with .labels }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- with merge (deepCopy (.annotations | default dict)) (.root.Values.commonAnnotations | default dict) }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Pod spec overrides shared by every workload. Params: root, values (.Values.unifi,
.Values.unifiExporter or .Values.backup).
*/}}
{{- define "unifi-os.podSpec" -}}
{{- $v := .values -}}
{{- $spec := dict -}}
{{- with .root.Values.imagePullSecrets }}{{ $_ := set $spec "imagePullSecrets" . }}{{ end -}}
{{- with $v.podSecurityContext }}{{ $_ := set $spec "securityContext" . }}{{ end -}}
{{- range $k := list "serviceAccountName" "nodeSelector" "affinity" "tolerations" "priorityClassName" "terminationGracePeriodSeconds" "topologySpreadConstraints" "runtimeClassName" "hostAliases" "dnsPolicy" "dnsConfig" "resourceClaims" -}}
{{- with index $v $k }}{{ $_ := set $spec $k . }}{{ end -}}
{{- end -}}
{{- with $spec }}{{ toYaml . }}{{ end -}}
{{- end -}}

{{/*
Resolved PostgreSQL connection, as YAML: include "unifi-os.postgres" . | fromYaml
global.postgres.connection wins over postgres.connection (umbrella charts).
The app's PGPASSWORD comes from:
  useExistingSecrets   → pg-login-<user> (bundled CNPG, secrets created by you)
  existingSecret.name  → that secret (external PostgreSQL)
  otherwise (managed)  → unifi-pg-auth, created from connection.password
*/}}
{{- define "unifi-os.postgres" -}}
{{- $c := mergeOverwrite (deepCopy (.Values.postgres.connection | default dict)) (deepCopy (dig "postgres" "connection" dict (.Values.global | default dict))) -}}
{{- $existing := $c.existingSecret | default dict -}}
{{- $managed := not (or $c.useExistingSecrets $existing.name) -}}
{{- $host := $c.host -}}
{{- if and (not $host) .Values.postgres.enabled -}}
{{- $host = printf "%s-rw.%s.svc.cluster.local" (.Values.postgres.fullnameOverride | default "unifi-postgres") .Release.Namespace -}}
{{- end -}}
host: {{ $host | default "" | quote }}
port: {{ $c.port | quote }}
database: {{ $c.database | default "unifi-core" | quote }}
user: {{ $c.user | default "unifi-core" | quote }}
useExistingSecrets: {{ $c.useExistingSecrets | default false }}
managed: {{ $managed }}
{{- if $c.useExistingSecrets }}
secretName: {{ printf "pg-login-%s" ($c.user | default "unifi-core") | quote }}
passwordKey: password
{{- else if $existing.name }}
secretName: {{ $existing.name | quote }}
passwordKey: {{ $existing.passwordKey | default "password" | quote }}
{{- else }}
secretName: unifi-pg-auth
passwordKey: password
{{- end }}
{{- if $managed }}
password: {{ $c.password | required "global.postgres.connection.password is required (or set global.postgres.connection.useExistingSecrets: true)" | quote }}
{{- else }}
password: {{ $c.password | default "" | quote }}
{{- end }}
{{- end -}}

{{/*
Resolved RabbitMQ connection, as YAML: include "unifi-os.rabbitmq" . | fromYaml
global.rabbitmq.connection wins over rabbitmq.connection. The chart creates
rabbitmq-auth (managed) unless connection.existingSecret.name is set.
*/}}
{{- define "unifi-os.rabbitmq" -}}
{{- $c := mergeOverwrite (deepCopy (.Values.rabbitmq.connection | default dict)) (deepCopy (dig "rabbitmq" "connection" dict (.Values.global | default dict))) -}}
{{- $existing := $c.existingSecret | default dict -}}
{{- $host := $c.host -}}
{{- if and (not $host) .Values.rabbitmq.enabled -}}
{{- $host = printf "%s-rabbitmq.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}
host: {{ $host | default "" | quote }}
{{- /* $(RABBITMQ_PASSWORD) is expanded by Kubernetes from the container env. */}}
uri: {{ $c.uri | default (printf "amqp://%s:$(RABBITMQ_PASSWORD)@%s:%v/" $c.username $host ($c.port | default 5672)) | quote }}
managed: {{ not $existing.name }}
{{- if $existing.name }}
secretName: {{ $existing.name | quote }}
passwordKey: {{ $existing.passwordKey | default "password" | quote }}
{{- else }}
secretName: rabbitmq-auth
passwordKey: password
password: {{ $c.password | required "global.rabbitmq.connection.password is required (set password or connection.existingSecret.name to use an existing secret)" | quote }}
erlangCookie: {{ $c.erlangCookie | required "global.rabbitmq.connection.erlangCookie is required (set erlangCookie or connection.existingSecret.name to use an existing secret)" | quote }}
{{- end }}
{{- end -}}

{{/* unifi-os container ports, keyed by the Service that exposes them. */}}
{{- define "unifi-os.ports" -}}
unifi:
  - {name: https, port: 443, protocol: TCP}             # UniFi OS UI/API (nginx)
  - {name: inform, port: 8080, protocol: TCP}           # device inform
  - {name: network-app, port: 8443, protocol: TCP}      # Network application UI/API
  - {name: id-hub, port: 9543, protocol: TCP}           # Identity Hub
  - {name: site-supervisor, port: 11084, protocol: TCP}
  - {name: speedtest, port: 6789, protocol: TCP}        # mobile speed test
  - {name: hotspot-secure, port: 8444, protocol: TCP}   # secure hotspot portal
  - {name: rtp, port: 5005, protocol: TCP}
hotspot:
  - {name: redirect-0, port: 8880, protocol: TCP}       # hotspot portal redirects
  - {name: redirect-1, port: 8881, protocol: TCP}
  - {name: redirect-2, port: 8882, protocol: TCP}
udp:
  - {name: stun, port: 3478, protocol: UDP}             # adoption, remote management
  - {name: syslog, port: 5514, protocol: UDP}           # remote syslog
  - {name: discovery, port: 10003, protocol: UDP}       # device discovery
{{- end -}}
