package main

// postgres: overlay on the CloudNativePG `cluster` subchart schema (see main.go).

type roleEnsure string

func (roleEnsure) Enum() []any { return []any{"present", "absent"} }

type pgRole struct {
	Name           string     `json:"name" required:"true" description:"Role name"`
	Ensure         roleEnsure `json:"ensure" description:"present or absent"`
	Login          bool       `json:"login" description:"Role can log in"`
	CreateDB       bool       `json:"createdb" description:"Role can create databases"`
	PasswordSecret secretRef  `json:"passwordSecret" description:"Secret holding the role's password (fixed names: pg-login-<role>)"`
}

type pgDatabase struct {
	Name  string `json:"name" required:"true" description:"Database name"`
	Owner string `json:"owner" description:"Owning role"`
}

type pgInitdb struct {
	Database string    `json:"database" description:"Database created at bootstrap"`
	Owner    string    `json:"owner" description:"Database owner created at bootstrap"`
	Secret   secretRef `json:"secret" description:"Secret holding the owner's credentials"`
}

type pgStorage struct {
	Size         quantity `json:"size" description:"Volume size, e.g. 10Gi"`
	StorageClass string   `json:"storageClass" description:"StorageClass name. Empty: the cluster default."`
}

type pgCluster struct {
	Instances int       `json:"instances" minimum:"1" description:"Number of Postgres instances"`
	ImageName string    `json:"imageName" description:"PostgreSQL 14 is a ceiling: ulp-go's SQL is rejected by 15+, which breaks login. See DATABASE.md."`
	Storage   pgStorage `json:"storage"`
	Initdb    pgInitdb  `json:"initdb"`
	Roles     []pgRole  `json:"roles" description:"Each role reads its password from pg-login-<name> (fixed names)"`
}

type postgresValues struct {
	Enabled          bool         `json:"enabled" description:"Deploy the CloudNativePG cluster subchart (needs the CNPG operator). False: use global.postgres.connection."`
	Connection       pgConnection `json:"connection" description:"Same as global.postgres.connection; global wins"`
	FullnameOverride string       `json:"fullnameOverride" description:"Name of the Cluster; the chart derives the host from it"`
	Cluster          pgCluster    `json:"cluster"`
	Databases        []pgDatabase `json:"databases" description:"Databases created declaratively"`
}
