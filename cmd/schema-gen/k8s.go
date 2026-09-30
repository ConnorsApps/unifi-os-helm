package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"

	jsonschema "github.com/swaggest/jsonschema-go"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

// Kubernetes types are reflected as-is; this file restores what their Go shape
// lacks: descriptions, required fields, enums and Quantity.

// quantityPattern is the resource.Quantity grammar (64Mi, 500m, 1.5, 1e3).
const quantityPattern = `^(\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\+|-)?(([0-9]+(\.[0-9]*)?)|(\.[0-9]+))))?$`

// quantity is a string-only Quantity, for sizes the templates splice in verbatim.
type quantity string

func (quantity) PrepareJSONSchema(s *jsonschema.Schema) error {
	s.WithPattern(quantityPattern)
	return nil
}

// k8sEnums are closed string sets; "" is listed where the API accepts it.
var k8sEnums = map[reflect.Type][]any{
	reflect.TypeFor[corev1.TolerationOperator](): {"", string(corev1.TolerationOpExists), string(corev1.TolerationOpEqual), string(corev1.TolerationOpLt), string(corev1.TolerationOpGt)},
	reflect.TypeFor[corev1.TaintEffect]():        {"", string(corev1.TaintEffectNoSchedule), string(corev1.TaintEffectPreferNoSchedule), string(corev1.TaintEffectNoExecute)},
	reflect.TypeFor[corev1.NodeSelectorOperator](): {
		string(corev1.NodeSelectorOpIn), string(corev1.NodeSelectorOpNotIn), string(corev1.NodeSelectorOpExists),
		string(corev1.NodeSelectorOpDoesNotExist), string(corev1.NodeSelectorOpGt), string(corev1.NodeSelectorOpLt),
	},
	reflect.TypeFor[corev1.SeccompProfileType]():       {string(corev1.SeccompProfileTypeUnconfined), string(corev1.SeccompProfileTypeRuntimeDefault), string(corev1.SeccompProfileTypeLocalhost)},
	reflect.TypeFor[corev1.AppArmorProfileType]():      {string(corev1.AppArmorProfileTypeUnconfined), string(corev1.AppArmorProfileTypeRuntimeDefault), string(corev1.AppArmorProfileTypeLocalhost)},
	reflect.TypeFor[corev1.PodFSGroupChangePolicy]():   {string(corev1.FSGroupChangeOnRootMismatch), string(corev1.FSGroupChangeAlways)},
	reflect.TypeFor[corev1.PodSELinuxChangePolicy]():   {string(corev1.SELinuxChangePolicyRecursive), string(corev1.SELinuxChangePolicyMountOption)},
	reflect.TypeFor[corev1.SupplementalGroupsPolicy](): {string(corev1.SupplementalGroupsPolicyMerge), string(corev1.SupplementalGroupsPolicyStrict)},
	reflect.TypeFor[corev1.ProcMountType]():            {string(corev1.DefaultProcMount), string(corev1.UnmaskedProcMount)},
}

// k8sQuantity maps resource.Quantity: a string or number, but an opaque struct
// to reflection.
func k8sQuantity(v reflect.Value, s *jsonschema.Schema) (bool, error) {
	if v.Type() != reflect.TypeFor[resource.Quantity]() {
		return false, nil
	}
	str := (&jsonschema.Schema{}).WithType(jsonschema.String.Type()).WithPattern(quantityPattern)
	num := (&jsonschema.Schema{}).WithType(jsonschema.Number.Type())
	s.WithOneOf(str.ToSchemaOrBool(), num.ToSchemaOrBool())
	return true, nil
}

// k8sDocs caches doc comments per package, parsed from the pinned module source.
type k8sDocs struct {
	pkgs map[string]map[string]string // import path -> "Type" / "Type.jsonField" -> text
}

func newK8sDocs() *k8sDocs { return &k8sDocs{pkgs: map[string]map[string]string{}} }

func (d *k8sDocs) lookup(pkgPath, key string) (string, error) {
	docs, ok := d.pkgs[pkgPath]
	if !ok {
		var err error
		if docs, err = parseDocs(pkgPath); err != nil {
			return "", fmt.Errorf("docs for %s: %w", pkgPath, err)
		}
		d.pkgs[pkgPath] = docs
	}
	return docs[key], nil
}

func parseDocs(pkgPath string) (map[string]string, error) {
	out, err := exec.Command("go", "list", "-f", "{{.Dir}}", pkgPath).Output()
	if err != nil {
		return nil, fmt.Errorf("go list: %w", err)
	}
	dir := strings.TrimSpace(string(out))
	files, err := filepath.Glob(filepath.Join(dir, "*.go"))
	if err != nil {
		return nil, err
	}

	docs := map[string]string{}
	fset := token.NewFileSet()
	for _, path := range files {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, path, nil, parser.ParseComments)
		if err != nil {
			return nil, err
		}
		for _, decl := range f.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.TYPE {
				continue
			}
			for _, spec := range gd.Specs {
				ts := spec.(*ast.TypeSpec)
				doc := ts.Doc
				if doc == nil {
					doc = gd.Doc
				}
				docs[ts.Name.Name] = cleanDoc(doc)
				st, ok := ts.Type.(*ast.StructType)
				if !ok {
					continue
				}
				for _, field := range st.Fields.List {
					if name := jsonName(field.Tag); name != "" {
						docs[ts.Name.Name+"."+name] = cleanDoc(field.Doc)
					}
				}
			}
		}
	}
	return docs, nil
}

func jsonName(tag *ast.BasicLit) string {
	if tag == nil {
		return ""
	}
	name, _, _ := strings.Cut(reflect.StructTag(strings.Trim(tag.Value, "`")).Get("json"), ",")
	if name == "-" {
		return ""
	}
	return name
}

// cleanDoc joins a comment into one line, dropping "+optional"-style markers.
func cleanDoc(cg *ast.CommentGroup) string {
	if cg == nil {
		return ""
	}
	var kept []string
	for _, line := range strings.Split(cg.Text(), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "+") {
			continue
		}
		kept = append(kept, line)
	}
	return strings.Join(kept, " ")
}

func isK8sType(t reflect.Type) bool {
	return strings.HasPrefix(t.PkgPath(), "k8s.io/")
}

// enrich adds to a reflected Kubernetes type what its Go shape lacks.
func (d *k8sDocs) enrich(t reflect.Type, s *jsonschema.Schema) error {
	if enum, ok := k8sEnums[t]; ok {
		s.WithEnum(enum...)
		if s.Type != nil && slices.Contains(s.Type.SliceOfSimpleTypeValues, jsonschema.Null) {
			s.Enum = append(s.Enum, nil) // optional pointer fields
		}
	}
	if t.Kind() != reflect.Struct {
		return nil
	}

	doc, err := d.lookup(t.PkgPath(), t.Name())
	if err != nil {
		return err
	}
	if doc != "" && s.Description == nil {
		s.WithDescription(doc)
	}

	for i := 0; i < t.NumField(); i++ {
		name, opts, _ := strings.Cut(t.Field(i).Tag.Get("json"), ",")
		if name == "" || name == "-" {
			continue // inline embeds are flattened by the reflector
		}
		if prop, ok := s.Properties[name]; ok && prop.TypeObject != nil {
			doc, err := d.lookup(t.PkgPath(), t.Name()+"."+name)
			if err != nil {
				return err
			}
			if doc != "" {
				prop.TypeObject.WithDescription(doc)
			}
		}
		// Optional fields are tagged omitempty; the rest are required.
		if !strings.Contains(","+opts+",", ",omitempty,") && !slices.Contains(s.Required, name) {
			s.Required = append(s.Required, name)
		}
	}
	return nil
}
