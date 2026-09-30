package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/santhosh-tekuri/jsonschema/v6"
	swagger "github.com/swaggest/jsonschema-go"
	"k8s.io/apimachinery/pkg/api/resource"
	"sigs.k8s.io/yaml"
)

// The patterns must agree with the parsers the chart's consumers use: a false
// reject would block a valid install.
func TestDurationPattern(t *testing.T) {
	re := regexp.MustCompile(durationPattern)
	for _, s := range []string{"", "0", "+0", "30s", "1h30m", "1.5h", "500ms", "5.s", ".5s", "1µs", "1μs", "1us", "1ns", "-5s", "+5s", "5", "s", "1d", "1 s", "0s", "00", "2160h", "10m"} {
		_, err := time.ParseDuration(s)
		want := err == nil || s == ""
		if got := re.MatchString(s); got != want {
			t.Errorf("%q: pattern match = %v, ParseDuration ok = %v", s, got, want)
		}
	}
}

func TestQuantityPattern(t *testing.T) {
	re := regexp.MustCompile(quantityPattern)
	for _, s := range []string{"64Mi", "500m", "1.5", "5Gi", "1e3", "1E3", "1e-3", "0", "+1", "-1", ".5", "1k", "1K", "1Ki", "1ki", "1M", "1Mi", "big", "", "1 Gi", "1.Gi"} {
		_, err := resource.ParseQuantity(s)
		if got := re.MatchString(s); got != (err == nil) {
			t.Errorf("%q: pattern match = %v, ParseQuantity ok = %v", s, got, err == nil)
		}
	}
}

func TestCronPattern(t *testing.T) {
	var s swagger.Schema
	if err := cronSchedule("").PrepareJSONSchema(&s); err != nil {
		t.Fatal(err)
	}
	re := regexp.MustCompile(*s.Pattern)
	for s, want := range map[string]bool{
		"0 2 * * *": true, "*/5 * * * *": true, "@daily": true, "@every 1h": true,
		"CRON_TZ=UTC 0 2 * * *": true, "0 2 * *": false, "nope": false, "": false,
	} {
		if got := re.MatchString(s); got != want {
			t.Errorf("%q: got %v, want %v", s, got, want)
		}
	}
}

// compile builds the schema, skipping when the subcharts are not vendored.
func compile(t *testing.T) *jsonschema.Schema {
	t.Helper()
	raw, err := build(filepath.Join(chartDir, "charts"))
	if err != nil {
		t.Skipf("subcharts not vendored (helm dependency update charts/unifi-os): %v", err)
	}
	doc, err := jsonschema.UnmarshalJSON(bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	c := jsonschema.NewCompiler()
	if err := c.AddResource("values.schema.json", doc); err != nil {
		t.Fatal(err)
	}
	schema, err := c.Compile("values.schema.json")
	if err != nil {
		t.Fatal(err)
	}
	return schema
}

func validateYAML(schema *jsonschema.Schema, doc string) error {
	j, err := yaml.YAMLToJSON([]byte(doc))
	if err != nil {
		return err
	}
	var v any
	if err := json.Unmarshal(j, &v); err != nil {
		return err
	}
	return schema.Validate(v)
}

// The schema must reject what the templates or the subcharts would choke on,
// and accept what they tolerate.
func TestValidation(t *testing.T) {
	schema := compile(t)
	for name, tc := range map[string]struct {
		doc string
		ok  bool
	}{
		"unknown top-level key":            {"bogus: 1", false},
		"typo in nested key":               {"unifi: {gateway: {httpRoute: {hostnmae: x}}}", false},
		"port as string":                   {"unifi: {gateway: {httpRoute: {backendPort: abc}}}", false},
		"port out of range":                {"global: {postgres: {connection: {port: 70000}}}", false},
		"bad quantity":                     {"unifi: {storage: {statefulset: {sizes: {data: big}}}}", false},
		"bad service type":                 {"unifi: {service: {type: Nope}}", false},
		"bad cron":                         {"backup: {schedule: nope}", false},
		"cert-manager without issuer":      {"unifi: {tls: {certManager: {enabled: true, issuerRef: {name: ''}}}}", false},
		"cert-manager with issuer":         {"unifi: {tls: {certManager: {enabled: true, issuerRef: {name: ca}}}}", true},
		"backend TLS policy no hostname":   {"unifi: {tls: {backendTLSPolicy: {enabled: true, hostname: ''}}}", false},
		"backend TLS policy with hostname": {"unifi: {tls: {backendTLSPolicy: {enabled: true, hostname: u.example.com}}}", true},
		"rabbitmq subchart type":           {"rabbitmq: {replicaCount: abc}", false},
		"rabbitmq subchart key":            {"rabbitmq: {replicaCount: 3}", true},
		"postgres instances":               {"postgres: {cluster: {instances: 0}}", false},
		"postgres unknown cluster key":     {"postgres: {cluster: {enableSuperuserAccess: true}}", true},
		"bad role ensure":                  {"postgres: {cluster: {roles: [{name: a, ensure: maybe}]}}", false},
		"umbrella global key":              {"global: {imageRegistry: example.com}", true},
		"numeric password from --set":      {"global: {postgres: {connection: {password: 12345}}}", true},
		"null grace period":                {"unifi: {terminationGracePeriodSeconds: null}", true},
		"hull reaches the template":        {"hull: {x: 1}", true},
		"boolean container command":        {"unifi: {extraInitContainers: [{name: a, image: b, command: [true]}]}", false},
	} {
		t.Run(name, func(t *testing.T) {
			if err := validateYAML(schema, tc.doc); (err == nil) != tc.ok {
				t.Errorf("valid = %v, want %v: %v", err == nil, tc.ok, err)
			}
		})
	}
}

// Every values file in the repo must validate: the schema is closed, so a
// key missing from values.go would otherwise break installs.
func TestRepoValuesValidate(t *testing.T) {
	schema := compile(t)
	files := []string{filepath.Join(chartDir, "values.yaml"), "../../values.env.example.yaml"}
	fixtures, err := filepath.Glob("../../tests/values/*.yaml")
	if err != nil {
		t.Fatal(err)
	}
	files = append(files, fixtures...)

	for _, f := range files {
		t.Run(filepath.Base(f), func(t *testing.T) {
			y, err := os.ReadFile(f)
			if err != nil {
				t.Fatal(err)
			}
			if err := validateYAML(schema, string(y)); err != nil {
				t.Error(err)
			}
		})
	}
}
