// Command schema-gen writes ../../charts/unifi-os/values.schema.json, which
// Helm enforces on install and lint and editors use for completion. Run it
// from this directory (or `make schema`) after `helm dependency update`: the
// subcharts' own schemas are read from the vendored archives. With -check it
// writes nothing and exits 1 when the file on disk is stale.
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"

	jsonschema "github.com/swaggest/jsonschema-go"
)

const (
	draft07    = "http://json-schema.org/draft-07/schema#" // what Helm documents
	chartDir   = "../../charts/unifi-os"
	schemaFile = chartDir + "/values.schema.json"
)

// subcharts maps a values key to the dependency archive whose values.schema.json
// is embedded under it (alias `postgres` is the `cluster` chart).
var subcharts = []struct{ key, chart string }{
	{"rabbitmq", "rabbitmq"},
	{"postgres", "cluster"},
}

// ownPkg is "main" under `go run` but the import path under `go test`.
var ownPkg = reflect.TypeFor[values]().PkgPath()

// openTypes keep unknown keys: they are shared with a subchart, whose schema
// owns the rest, or with an umbrella chart.
var openTypes = map[reflect.Type]bool{
	reflect.TypeFor[global]():          true,
	reflect.TypeFor[globalPostgres]():  true,
	reflect.TypeFor[globalRabbitMQ]():  true,
	reflect.TypeFor[backupConfig]():    true,
	reflect.TypeFor[backupUnifi]():     true,
	reflect.TypeFor[backupLogging]():   true,
	reflect.TypeFor[backupRetention](): true,
	reflect.TypeFor[rabbitmqValues]():  true,
	reflect.TypeFor[postgresValues]():  true,
	reflect.TypeFor[pgCluster]():       true,
	reflect.TypeFor[pgStorage]():       true,
	reflect.TypeFor[pgInitdb]():        true,
	reflect.TypeFor[pgRole]():          true,
	reflect.TypeFor[pgDatabase]():      true,
}

func main() {
	check := flag.Bool("check", false, "fail if "+schemaFile+" is out of date instead of writing it")
	flag.Parse()

	schema, err := build(filepath.Join(chartDir, "charts"))
	if err != nil {
		die(err)
	}
	if *check {
		if have, err := os.ReadFile(schemaFile); err != nil || !bytes.Equal(have, schema) {
			die(fmt.Errorf("%s is out of date: run `make schema`", schemaFile))
		}
		return
	}
	if err := os.WriteFile(schemaFile, schema, 0o644); err != nil {
		die(err)
	}
	fmt.Printf("Wrote %s\n", schemaFile)
}

func die(err error) {
	fmt.Fprintf(os.Stderr, "schema-gen: %v\n", err)
	os.Exit(1)
}

func build(depsDir string) ([]byte, error) {
	schema, err := reflectSchema(values{}, newK8sDocs())
	if err != nil {
		return nil, fmt.Errorf("reflect: %w", err)
	}
	schema.WithSchema(draft07).
		WithTitle("unifi-os chart values").
		WithDescription("Helm values for the unifi-os chart")

	for _, sc := range subcharts {
		if err := embedSubchart(schema, depsDir, sc.key, sc.chart); err != nil {
			return nil, err
		}
	}

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(schema); err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}
	return buf.Bytes(), nil
}

// embedSubchart adds the dependency's own values schema beside our overlay for
// its key, so neither can loosen the other.
func embedSubchart(root *jsonschema.Schema, depsDir, key, chart string) error {
	raw, err := readSubchartSchema(depsDir, chart)
	if err != nil {
		return err
	}
	var upstream jsonschema.Schema
	if err := json.Unmarshal(raw, &upstream); err != nil {
		return fmt.Errorf("%s values.schema.json: %w", chart, err)
	}
	upstream.Schema = nil // only valid at the root

	prop, ok := root.Properties[key]
	if !ok || prop.TypeObject == nil {
		return fmt.Errorf("no %q property to embed the %s schema in", key, chart)
	}
	// Draft-07 ignores siblings of $ref, so the overlay and the upstream schema
	// sit side by side under allOf.
	overlay := *prop.TypeObject
	overlay.Description = nil
	wrapped := (&jsonschema.Schema{Description: prop.TypeObject.Description}).
		WithAllOf(overlay.ToSchemaOrBool(), upstream.ToSchemaOrBool())
	root.Properties[key] = wrapped.ToSchemaOrBool()
	return nil
}

func readSubchartSchema(depsDir, chart string) ([]byte, error) {
	matches, err := filepath.Glob(filepath.Join(depsDir, chart+"-*.tgz"))
	if err != nil {
		return nil, err
	}
	if len(matches) != 1 {
		return nil, fmt.Errorf("want one %s-*.tgz in %s, found %d: run `helm dependency update charts/unifi-os` first", chart, depsDir, len(matches))
	}
	f, err := os.Open(matches[0])
	if err != nil {
		return nil, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", matches[0], err)
	}
	tr := tar.NewReader(gz)
	want := chart + "/values.schema.json"
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil, fmt.Errorf("%s has no %s", matches[0], want)
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", matches[0], err)
		}
		if h.Name == want {
			return io.ReadAll(tr)
		}
	}
}

func reflectSchema(v any, docs *k8sDocs) (*jsonschema.Schema, error) {
	r := jsonschema.Reflector{}
	schema, err := r.Reflect(v,
		jsonschema.InterceptSchema(func(p jsonschema.InterceptSchemaParams) (bool, error) {
			if !p.Value.IsValid() {
				return false, nil
			}
			if !p.Processed {
				return k8sQuantity(p.Value, p.Schema)
			}
			t := p.Value.Type()
			for t.Kind() == reflect.Pointer {
				t = t.Elem()
			}
			switch {
			case isK8sType(t):
				return false, docs.enrich(t, p.Schema)
			case t.Kind() == reflect.Struct && t.PkgPath() == ownPkg:
				ownStruct(t, p.Schema)
			}
			return false, nil
		}),
	)
	return &schema, err
}

// ownStruct rejects unknown keys on our own structs, so a typo fails `helm
// lint`. Kubernetes types stay open: a newer cluster's valid field must not be
// rejected.
func ownStruct(t reflect.Type, s *jsonschema.Schema) {
	if !openTypes[t] {
		closed := false
		s.AdditionalProperties = &jsonschema.SchemaOrBool{TypeBoolean: &closed}
	}

	switch t {
	case reflect.TypeFor[certManager]():
		s.AllOf = append(s.AllOf, whenEnabled(requireNested("issuerRef", "name")))
	case reflect.TypeFor[backendTLSPolicy]():
		s.AllOf = append(s.AllOf, whenEnabled(requireNonEmpty("hostname")))
	}
}

// whenEnabled returns `if enabled: true then <then>`, mirroring a template
// fail() so the error shows up at lint time.
func whenEnabled(then *jsonschema.Schema) jsonschema.SchemaOrBool {
	isEnabled := (&jsonschema.Schema{}).
		WithRequired("enabled").
		WithPropertiesItem("enabled", (&jsonschema.Schema{}).WithConst(true).ToSchemaOrBool())
	return (&jsonschema.Schema{}).
		WithIf(isEnabled.ToSchemaOrBool()).
		WithThen(then.ToSchemaOrBool()).
		ToSchemaOrBool()
}

func requireNonEmpty(field string) *jsonschema.Schema {
	return (&jsonschema.Schema{}).
		WithRequired(field).
		WithPropertiesItem(field, (&jsonschema.Schema{MinLength: 1}).ToSchemaOrBool())
}

func requireNested(obj, field string) *jsonschema.Schema {
	return (&jsonschema.Schema{}).
		WithRequired(obj).
		WithPropertiesItem(obj, requireNonEmpty(field).ToSchemaOrBool())
}
