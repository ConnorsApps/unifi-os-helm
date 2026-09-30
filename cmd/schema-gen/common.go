package main

import (
	jsonschema "github.com/swaggest/jsonschema-go"
	corev1 "k8s.io/api/core/v1"
)

// Types and value formats shared by several sections of values.yaml.

// duration is a time.ParseDuration string; YAML lets an unquoted 0 through as
// an integer.
type duration string

const durationPattern = `^([-+]?(([0-9]+(\.[0-9]*)?|\.[0-9]+)(ns|us|µs|μs|ms|s|m|h))+|[-+]?0)?$`

func (duration) PrepareJSONSchema(s *jsonschema.Schema) error {
	s.Type = &jsonschema.Type{SliceOfSimpleTypeValues: []jsonschema.SimpleType{jsonschema.String, jsonschema.Integer}}
	s.WithPattern(durationPattern)
	return nil
}

// promDuration is a Prometheus duration (the ServiceMonitor CRD's own pattern).
type promDuration string

func (promDuration) PrepareJSONSchema(s *jsonschema.Schema) error {
	s.WithPattern(`^(([0-9]+)y)?(([0-9]+)w)?(([0-9]+)d)?(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?(([0-9]+)ms)?$`)
	return nil
}

// cronSchedule is what a Kubernetes CronJob accepts: five fields, an @macro
// or @every, each optionally prefixed with a timezone.
type cronSchedule string

func (cronSchedule) PrepareJSONSchema(s *jsonschema.Schema) error {
	s.WithPattern(`^((CRON_TZ|TZ)=\S+\s+)?(@(yearly|annually|monthly|weekly|daily|midnight|hourly)|@every\s+\S+|\S+(\s+\S+){4})$`)
	return nil
}

// secret is a string, but `--set key=12345` parses as a number and the
// templates quote it, so both must keep working.
type secret string

func (secret) PrepareJSONSchema(s *jsonschema.Schema) error {
	s.Type = &jsonschema.Type{SliceOfSimpleTypeValues: []jsonschema.SimpleType{jsonschema.String, jsonschema.Number}}
	return nil
}

type pullPolicy string

func (pullPolicy) Enum() []any {
	return []any{string(corev1.PullAlways), string(corev1.PullIfNotPresent), string(corev1.PullNever)}
}

type serviceType string

func (serviceType) Enum() []any {
	return []any{
		string(corev1.ServiceTypeClusterIP), string(corev1.ServiceTypeNodePort),
		string(corev1.ServiceTypeLoadBalancer), string(corev1.ServiceTypeExternalName),
	}
}

// trafficPolicy: "" is the chart default and leaves the field unset.
type trafficPolicy string

func (trafficPolicy) Enum() []any {
	return []any{"", string(corev1.ServiceExternalTrafficPolicyLocal), string(corev1.ServiceExternalTrafficPolicyCluster)}
}

type dnsPolicy string

func (dnsPolicy) Enum() []any {
	return []any{
		"", string(corev1.DNSClusterFirst), string(corev1.DNSClusterFirstWithHostNet),
		string(corev1.DNSDefault), string(corev1.DNSNone),
	}
}

// image has no pullPolicy: the StatefulSet leaves it to the cluster default.
type image struct {
	Repository string `json:"repository" description:"Image repository"`
	Tag        string `json:"tag" description:"Image tag. Empty: the chart's appVersion (main image)."`
}

type appImage struct {
	Repository string     `json:"repository" description:"Image repository"`
	Tag        string     `json:"tag" description:"Image tag"`
	PullPolicy pullPolicy `json:"pullPolicy" description:"Image pull policy"`
}

// workload holds the overrides unifi, unifiExporter and backup all accept
// (see the podSpec helper in templates/_helpers.tpl).
type workload struct {
	PodAnnotations                map[string]string                 `json:"podAnnotations" description:"Extra pod annotations"`
	PodLabels                     map[string]string                 `json:"podLabels" description:"Extra pod labels"`
	NodeSelector                  map[string]string                 `json:"nodeSelector" description:"Pod node selector"`
	Affinity                      corev1.Affinity                   `json:"affinity" description:"Pod affinity rules"`
	Tolerations                   []corev1.Toleration               `json:"tolerations" description:"Pod tolerations"`
	PriorityClassName             string                            `json:"priorityClassName" description:"Pod priority class"`
	TerminationGracePeriodSeconds *int64                            `json:"terminationGracePeriodSeconds" minimum:"0" description:"Null: the Kubernetes default (30s)"`
	TopologySpreadConstraints     []corev1.TopologySpreadConstraint `json:"topologySpreadConstraints" description:"Pod topology spread constraints"`
	RuntimeClassName              string                            `json:"runtimeClassName" description:"RuntimeClass for the pod"`
	HostAliases                   []corev1.HostAlias                `json:"hostAliases" description:"Extra /etc/hosts entries"`
	DNSPolicy                     dnsPolicy                         `json:"dnsPolicy" description:"Pod DNS policy. Empty: the Kubernetes default."`
	DNSConfig                     corev1.PodDNSConfig               `json:"dnsConfig" description:"Pod DNS config"`
	PodSecurityContext            corev1.PodSecurityContext         `json:"podSecurityContext" description:"Pod-level security context"`
	SecurityContext               corev1.SecurityContext            `json:"securityContext" description:"Container security context, merged over the container's required defaults"`
	ServiceAccountName            string                            `json:"serviceAccountName" description:"Pod service account. Empty: the namespace default."`
	ResourceClaims                []corev1.PodResourceClaim         `json:"resourceClaims" description:"Dynamic Resource Allocation claims; reference them from resources.claims"`
	Resources                     corev1.ResourceRequirements       `json:"resources" description:"Container resources"`
	ExtraEnv                      []corev1.EnvVar                   `json:"extraEnv" description:"Extra container env vars"`
	ExtraVolumes                  []corev1.Volume                   `json:"extraVolumes" description:"Extra pod volumes"`
	ExtraVolumeMounts             []corev1.VolumeMount              `json:"extraVolumeMounts" description:"Extra container volume mounts"`
}

type secretRef struct {
	Name string `json:"name" description:"Secret name"`
}

type service struct {
	Type                  serviceType       `json:"type" description:"Kubernetes Service type"`
	Annotations           map[string]string `json:"annotations" description:"Service annotations"`
	ExternalTrafficPolicy trafficPolicy     `json:"externalTrafficPolicy" description:"Local keeps client source IPs (LoadBalancer/NodePort). Empty: unset."`
}
