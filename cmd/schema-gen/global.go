package main

// global.* and the postgres/rabbitmq connection blocks.

// global / connections

type pgSecretRef struct {
	Name        string `json:"name" description:"Secret holding the app's password"`
	PasswordKey string `json:"passwordKey" description:"Key in the secret"`
}

type pgConnection struct {
	Host               string      `json:"host" description:"External PostgreSQL host. Derived from the subchart when postgres.enabled."`
	Port               int         `json:"port" minimum:"1" maximum:"65535" description:"PostgreSQL port"`
	Database           string      `json:"database" description:"Database name"`
	User               string      `json:"user" description:"Database user"`
	Password           secret      `json:"password" description:"The chart creates unifi-pg-auth (+ pg-login-<role> when postgres.enabled)"`
	UseExistingSecrets bool        `json:"useExistingSecrets" description:"postgres.enabled only: you create every pg-login-<role> secret"`
	ExistingSecret     pgSecretRef `json:"existingSecret" description:"External only: secret holding the app's password"`
}

type mqSecretRef struct {
	Name            string `json:"name" description:"Secret holding the credentials"`
	PasswordKey     string `json:"passwordKey" description:"Key of the password"`
	ErlangCookieKey string `json:"erlangCookieKey" description:"Key of the Erlang cookie"`
}

type mqConnection struct {
	Host           string      `json:"host" description:"External RabbitMQ host. Derived from the subchart when rabbitmq.enabled."`
	Port           int         `json:"port" minimum:"1" maximum:"65535" description:"AMQP port"`
	Username       string      `json:"username" description:"RabbitMQ user"`
	Password       secret      `json:"password" description:"Required unless existingSecret.name is set"`
	ErlangCookie   secret      `json:"erlangCookie" description:"Required unless existingSecret.name is set"`
	ExistingSecret mqSecretRef `json:"existingSecret" description:"Secret holding the password and Erlang cookie"`
	URI            string      `json:"uri" description:"Overrides the amqp:// URI built from the fields above"`
}

type globalPostgres struct {
	Connection pgConnection `json:"connection"`
}

type globalRabbitMQ struct {
	Connection mqConnection `json:"connection"`
}

// global is shared with umbrella charts, so it stays open.
type global struct {
	Postgres globalPostgres `json:"postgres" description:"External PostgreSQL connection. Wins over postgres.connection."`
	RabbitMQ globalRabbitMQ `json:"rabbitmq" description:"External RabbitMQ connection. Wins over rabbitmq.connection."`
}
