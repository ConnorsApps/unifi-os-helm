package main

// rabbitmq: overlay on the CloudPirates subchart schema (see main.go).

// subcharts (overlays on the vendored schemas; see main.go)

type rabbitmqValues struct {
	Enabled    bool         `json:"enabled" description:"Deploy the CloudPirates RabbitMQ subchart. False: use global.rabbitmq.connection."`
	Connection mqConnection `json:"connection" description:"Same as global.rabbitmq.connection; global wins"`
}
