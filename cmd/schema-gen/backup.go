package main

// backup: scheduled backups via unifi-backup.

// backup

type backupSecret struct {
	Name          string `json:"name" description:"Secret name. Empty: the chart creates unifi-backup-secret."`
	PasswordKey   string `json:"passwordKey" description:"Key of the password"`
	StorageURLKey string `json:"storageUrlKey" description:"Key of the storage URL"`
}

type backupUnifi struct {
	URL                string   `json:"url" description:"Empty: https://unifi.<namespace>.svc.cluster.local"`
	Site               string   `json:"site" description:"UniFi site"`
	IncludeDays        int      `json:"includeDays" minimum:"0" description:"Days of history to include. 0: none."`
	InsecureSkipVerify bool     `json:"insecure_skip_verify" description:"Skip TLS verification of the controller"`
	Timeout            duration `json:"timeout" description:"Backup request timeout, e.g. 10m"`
	MaxRetries         int      `json:"max_retries" minimum:"0" description:"Retries per request"`
}

type backupLogging struct {
	Level  string `json:"level" description:"Log level"`
	Format string `json:"format" description:"Log format"`
}

type backupRetention struct {
	KeepLast int `json:"keepLast" minimum:"0" description:"Number of backups to keep"`
}

// backupConfig is rendered as unifi-backup's config.yaml; only the keys this
// chart sets are typed. The rest of its schema lives upstream:
// https://github.com/ConnorsApps/unifi-backup/blob/main/config.schema.json
type backupConfig struct {
	Unifi     backupUnifi     `json:"unifi"`
	Logging   backupLogging   `json:"logging"`
	Retention backupRetention `json:"retention"`
}

type backupValues struct {
	Enabled        bool         `json:"enabled" description:"Render the scheduled backup CronJob. Needs a local UniFi OS user with the Administrator role."`
	Schedule       cronSchedule `json:"schedule" description:"CronJob schedule"`
	Image          appImage     `json:"image"`
	Username       string       `json:"username" description:"Local UniFi OS user"`
	Password       secret       `json:"password" description:"Ignored when existingSecret.name is set"`
	StorageURL     string       `json:"storageUrl" description:"Stored in the secret: file://./backups, smb://user:pass@nas.local/share, s3://bucket?region=us-east-1, ..."`
	ExistingSecret backupSecret `json:"existingSecret"`
	Config         backupConfig `json:"config" description:"Rendered as config.yaml (unifi-backup)"`
	workload
}
