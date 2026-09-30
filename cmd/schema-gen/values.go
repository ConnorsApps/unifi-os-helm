package main

import corev1 "k8s.io/api/core/v1"

// values mirrors charts/unifi-os/values.yaml by hand. The schema rejects
// unknown keys on the chart's own objects, so a key added to values.yaml
// without a field in these files fails `helm lint`. Types listed in openTypes
// (main.go) stay open: they are shared with a subchart or an umbrella chart.

type values struct {
	Global            global                        `json:"global" description:"Connections shared with umbrella charts"`
	Image             image                         `json:"image" description:"The UniFi OS image"`
	NameOverride      string                        `json:"nameOverride" description:"Override the chart name in resource names"`
	CommonLabels      map[string]string             `json:"commonLabels" description:"Labels on every object this chart renders (not the subcharts)"`
	CommonAnnotations map[string]string             `json:"commonAnnotations" description:"Annotations on every object this chart renders (not the subcharts)"`
	ImagePullSecrets  []corev1.LocalObjectReference `json:"imagePullSecrets" description:"Secrets used to pull every image this chart renders"`
	Backup            backupValues                  `json:"backup" description:"Scheduled backups via https://github.com/ConnorsApps/unifi-backup"`
	UnifiExporter     exporterValues                `json:"unifiExporter" description:"Prometheus metrics via https://github.com/unpoller/unpoller"`
	RabbitMQ          rabbitmqValues                `json:"rabbitmq" description:"RabbitMQ subchart (CloudPirates); everything not listed here is that chart's own values"`
	Postgres          postgresValues                `json:"postgres" description:"PostgreSQL subchart (CloudNativePG cluster); everything not listed here is that chart's own values"`
	Unifi             unifiValues                   `json:"unifi" description:"The UniFi OS StatefulSet and its Services, routes and TLS"`
	Hull              any                           `json:"hull" description:"Removed. Setting it fails the install with a migration message."`
}
