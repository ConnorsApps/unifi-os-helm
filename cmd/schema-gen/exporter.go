package main

// unifiExporter: Prometheus metrics via unpoller.

// unifiExporter

type exporterConfig struct {
	URL           string `json:"url" description:"Empty: https://unifi.<namespace>.svc.cluster.local"`
	Username      string `json:"username" description:"Local Viewer user (password auth)"`
	Password      secret `json:"password" description:"Password for username"`
	APIKey        secret `json:"apiKey" description:"UniFi OS 4+: Settings > Admins & Users > <user> > API Key. Wins over username/password."`
	VerifyTLS     bool   `json:"verifyTLS" description:"Verify the controller's TLS certificate"`
	SaveSites     bool   `json:"saveSites" description:"Export site metrics"`
	SaveDpi       bool   `json:"saveDpi" description:"Export DPI metrics"`
	SaveEvents    bool   `json:"saveEvents" description:"Client connect/disconnect and network events"`
	SaveAlarms    bool   `json:"saveAlarms" description:"Export alarms"`
	SaveAnomalies bool   `json:"saveAnomalies" description:"Export anomalies"`
	SaveIds       bool   `json:"saveIds" description:"Device ID-to-name label mappings"`
	HashPii       bool   `json:"hashPii" description:"Hash MACs and client names"`
	ReportErrors  bool   `json:"reportErrors" description:"Report errors to unpoller"`
}

type exporterSecret struct {
	Name        string `json:"name" description:"Secret name. Empty: the chart creates unifi-exporter-secret."`
	PasswordKey string `json:"passwordKey" description:"Key of the password"`
	APIKeyKey   string `json:"apiKeyKey" description:"Key of the API key"`
}

type serviceMonitor struct {
	Enabled       bool         `json:"enabled" description:"Render a ServiceMonitor (needs the Prometheus Operator CRDs)"`
	Interval      promDuration `json:"interval" description:"Scrape interval"`
	ScrapeTimeout promDuration `json:"scrapeTimeout" description:"Scrape timeout"`
}

type exporterService struct {
	Type        serviceType       `json:"type" description:"Kubernetes Service type"`
	Annotations map[string]string `json:"annotations" description:"Service annotations"`
}

type exporterValues struct {
	Enabled        bool            `json:"enabled" description:"Deploy unpoller for Prometheus metrics"`
	Image          appImage        `json:"image"`
	Config         exporterConfig  `json:"config" description:"Auth, first match wins: config.apiKey, config.username + config.password, existingSecret"`
	ExistingSecret exporterSecret  `json:"existingSecret"`
	ServiceMonitor serviceMonitor  `json:"serviceMonitor"`
	Service        exporterService `json:"service"`
	workload
}
