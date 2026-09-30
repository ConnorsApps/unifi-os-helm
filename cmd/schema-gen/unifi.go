package main

import corev1 "k8s.io/api/core/v1"

// unifi: the StatefulSet, its Services, Gateway API routes and TLS.

// caBundle is the only value the Gateway API defines for wellKnownCACertificates.
type caBundle string

func (caBundle) Enum() []any { return []any{"", "System"} }

type issuerRef struct {
	Name  string `json:"name" description:"Issuer name. Required when certManager.enabled."`
	Kind  string `json:"kind" description:"Issuer kind"`
	Group string `json:"group" description:"Issuer API group"`
}

type certManager struct {
	Enabled     bool      `json:"enabled" description:"Issue the certificate with cert-manager. Overrides existingSecret."`
	SecretName  string    `json:"secretName" description:"Secret cert-manager writes the certificate to"`
	IssuerRef   issuerRef `json:"issuerRef"`
	DNSNames    []string  `json:"dnsNames" description:"Default: [gateway.httpRoute.hostname]"`
	Duration    duration  `json:"duration" description:"Certificate lifetime, e.g. 2160h"`
	RenewBefore duration  `json:"renewBefore" description:"Renew this long before expiry, e.g. 360h"`
}

type caCertificateRef struct {
	Name string `json:"name" description:"ConfigMap holding the CA"`
	Key  string `json:"key" description:"Key in the ConfigMap"`
}

type backendTLSPolicy struct {
	Enabled                 bool             `json:"enabled" description:"Gateway API BackendTLSPolicy: re-encrypt gateway to nginx"`
	WellKnownCACertificates caBundle         `json:"wellKnownCACertificates" description:"\"System\" for public CAs; else caCertificateRef"`
	CACertificateRef        caCertificateRef `json:"caCertificateRef"`
	Hostname                string           `json:"hostname" description:"SNI name on the certificate. Required when enabled."`
}

type tls struct {
	ExistingSecret   string           `json:"existingSecret" description:"kubernetes.io/tls secret for UniFi's nginx (tls.crt, tls.key, optional ca.crt). Empty: self-signed."`
	CertManager      certManager      `json:"certManager"`
	BackendTLSPolicy backendTLSPolicy `json:"backendTLSPolicy"`
}

type statefulsetSizes struct {
	Persistent quantity `json:"persistent" description:"persistent volume size"`
	Data       quantity `json:"data" description:"data volume size"`
	Srv        quantity `json:"srv" description:"srv volume size"`
	Unifi      quantity `json:"unifi" description:"unifi volume size"`
	Log        quantity `json:"log" description:"log volume size"`
	Mongodb    quantity `json:"mongodb" description:"mongodb volume size"`
}

type statefulsetStorage struct {
	StorageClassName string           `json:"storageClassName" description:"StorageClass name. Empty: the cluster default."`
	Sizes            statefulsetSizes `json:"sizes"`
}

type storageValues struct {
	Statefulset statefulsetStorage `json:"statefulset" description:"PVCs. Fixed at install: a StatefulSet's volumeClaimTemplates cannot change."`
}

type parentRef struct {
	Name      string `json:"name" description:"Gateway name"`
	Namespace string `json:"namespace" description:"Gateway namespace. Empty: the release namespace."`
}

type l4Route struct {
	Enabled     bool   `json:"enabled" description:"Render this route"`
	SectionName string `json:"sectionName" description:"Listener name on parentRef"`
	BackendPort int    `json:"backendPort" minimum:"1" maximum:"65535" description:"Service port the route targets"`
}

type httpRoute struct {
	l4Route
	Hostname string `json:"hostname" description:"Hostname the route answers for"`
}

type udpRoutes struct {
	Discovery l4Route `json:"discovery" description:"Device discovery (10003)"`
	Stun      l4Route `json:"stun" description:"STUN (3478)"`
	Syslog    l4Route `json:"syslog" description:"Syslog (5514)"`
}

type gateway struct {
	ParentRef       parentRef `json:"parentRef"`
	HTTPRouteInform httpRoute `json:"httpRouteInform" description:"HTTPRoute for the inform port"`
	HTTPRoute       httpRoute `json:"httpRoute" description:"HTTPRoute for the web UI"`
	TCPRoute        l4Route   `json:"tcpRoute" description:"TCPRoute for the inform port"`
	UDPRoutes       udpRoutes `json:"udpRoutes"`
}

type journalctl struct {
	Resources corev1.ResourceRequirements `json:"resources" description:"journalctl sidecar resources"`
}

type discoveryShim struct {
	Image     image                       `json:"image"`
	Resources corev1.ResourceRequirements `json:"resources" description:"Discovery shim resources"`
}

type unifiValues struct {
	UosSystemIP         string             `json:"uosSystemIP" description:"Hostname or IP devices use to reach the controller (set-inform URL)"`
	TLS                 tls                `json:"tls"`
	Storage             storageValues      `json:"storage"`
	Gateway             gateway            `json:"gateway" description:"Gateway API routes; each needs a matching listener (sectionName) on parentRef"`
	Service             service            `json:"service" description:"The unifi Service (HTTPS + TCP)"`
	HotspotService      service            `json:"hotspotService" description:"The hotspot Service (portal redirects)"`
	UDPService          service            `json:"udpService" description:"The udp Service (STUN, syslog, discovery)"`
	ExtraInitContainers []corev1.Container `json:"extraInitContainers" description:"Run after the built-in init container"`
	Journalctl          journalctl         `json:"journalctl"`
	DiscoveryShim       discoveryShim      `json:"discoveryShim"`
	workload
}
