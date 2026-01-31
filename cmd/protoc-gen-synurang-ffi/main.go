package main

import (
	"bytes"
	"embed"
	"flag"
	"fmt"
	"path/filepath"
	"sort"
	"strings"
	"text/template"

	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/types/pluginpb"
)

//go:embed templates/*
var templateFS embed.FS

var templates *template.Template

// =============================================================================
// Data Types for Templates
// =============================================================================

type FileData struct {
	Package       string
	GoPackageName string
	Services      []ServiceData
	HasStreaming  bool
	DartPackage   string
	// For imports
	ExternalImports []string
	GoImports       []GoImport
	PbDartFile      string
	PbHeaderFile    string
	CppNamespace    string
	CppGuardName    string
	RustModPath     string
}

type GoImport struct {
	Alias string
	Path  string
}

type ServiceData struct {
	Name    string
	GoName  string
	Methods []MethodData
}

type MethodData struct {
	Name              string
	GoName            string
	FullMethodName    string
	InputType         string // Simple type name (for Dart/C++/Rust)
	OutputType        string // Simple type name (for Dart/C++/Rust)
	InputGoIdent      string // Qualified Go type (e.g., "empty.Empty" or "HelloRequest")
	OutputGoIdent     string // Qualified Go type
	IsServerStreaming bool
	IsClientStreaming bool
	IsBidiStreaming   bool
	IsUnary           bool
}

// =============================================================================
// Template Helper Functions
// =============================================================================

func toSnakeCase(s string) string {
	var result strings.Builder
	for i, r := range s {
		if i > 0 && r >= 'A' && r <= 'Z' {
			result.WriteRune('_')
		}
		result.WriteRune(r)
	}
	return strings.ToLower(result.String())
}

func callMethod(m MethodData) string {
	if !m.IsUnary {
		return m.GoName + "Internal"
	}
	return m.GoName
}

func streamType(prefix string, svc ServiceData, m MethodData) string {
	return fmt.Sprintf("%s%s%sStream", prefix, svc.GoName, m.GoName)
}

func grpcStreamType(svc ServiceData, m MethodData) string {
	return streamType("grpc", svc, m)
}

func ffiStreamType(svc ServiceData, m MethodData) string {
	return streamType("ffi", svc, m)
}

func pluginStreamType(svc ServiceData, m MethodData) string {
	return fmt.Sprintf("pluginStream%s%s", svc.GoName, m.GoName)
}

func init() {
	funcs := template.FuncMap{
		"snakeCase":        toSnakeCase,
		"callMethod":       callMethod,
		"grpcStreamType":   grpcStreamType,
		"ffiStreamType":    ffiStreamType,
		"pluginStreamType": pluginStreamType,
	}
	var err error
	templates, err = template.New("").Funcs(funcs).ParseFS(templateFS, "templates/*.tmpl")
	if err != nil {
		panic(fmt.Sprintf("failed to parse templates: %v", err))
	}
}

// =============================================================================
// Main Entry Point
// =============================================================================

func main() {
	var flags flag.FlagSet
	lang := flags.String("lang", "", "language to generate (go, dart, cpp, or rust)")
	mode := flags.String("mode", "default", "generation mode: default, plugin_server, plugin_client")
	dartPackage := flags.String("dart_package", "", "Dart package name for imports")
	services := flags.String("services", "", "comma-separated list of services to generate")

	protogen.Options{
		ParamFunc: flags.Set,
	}.Run(func(gen *protogen.Plugin) error {
		gen.SupportedFeatures = uint64(pluginpb.CodeGeneratorResponse_FEATURE_PROTO3_OPTIONAL)

		serviceList := make(map[string]bool)
		if *services != "" {
			for _, s := range strings.Split(*services, ",") {
				serviceList[strings.TrimSpace(s)] = true
			}
		}

		for _, f := range gen.Files {
			if !f.Generate {
				continue
			}
			if *lang == "go" || *lang == "" {
				generateFromTemplate(gen, f, serviceList, "go", *mode)
			}
			if *lang == "dart" || *lang == "" {
				generateFromTemplate(gen, f, serviceList, "dart", *dartPackage)
			}
			if *lang == "cpp" {
				generateFromTemplate(gen, f, serviceList, "cpp", "")
			}
			if *lang == "rust" {
				generateFromTemplate(gen, f, serviceList, "rust", "")
			}
		}
		return nil
	})
}

// =============================================================================
// Template Execution
// =============================================================================

func generateFromTemplate(gen *protogen.Plugin, file *protogen.File, serviceList map[string]bool, lang, modeOrOpt string) {
	data := buildFileData(gen, file, serviceList, lang, modeOrOpt)

	tmplName := selectTemplate(lang, modeOrOpt)
	var buf bytes.Buffer
	if err := templates.ExecuteTemplate(&buf, tmplName, data); err != nil {
		gen.Error(fmt.Errorf("template %s: %v", tmplName, err))
		return
	}

	filename := outputFilename(file, lang)
	g := gen.NewGeneratedFile(filename, file.GoImportPath)
	g.P(buf.String())
}

func selectTemplate(lang, modeOrOpt string) string {
	switch lang {
	case "go":
		switch modeOrOpt {
		case "plugin_server":
			return "go_plugin_server.go.tmpl"
		case "plugin_client":
			return "go_plugin_client.go.tmpl"
		default:
			return "go_default.go.tmpl"
		}
	case "dart":
		return "dart.dart.tmpl"
	case "cpp":
		return "cpp.h.tmpl"
	case "rust":
		return "rust.rs.tmpl"
	}
	return ""
}

func outputFilename(file *protogen.File, lang string) string {
	base := strings.TrimSuffix(file.Desc.Path(), ".proto")
	if idx := strings.LastIndex(base, "/"); idx >= 0 {
		base = base[idx+1:]
	}
	switch lang {
	case "go":
		return base + "_ffi.pb.go"
	case "dart":
		return base + "_ffi.pb.dart"
	case "cpp":
		return base + "_ffi.h"
	case "rust":
		return base + "_ffi.rs"
	}
	return base + "_ffi"
}

// =============================================================================
// Build Template Data
// =============================================================================

func buildFileData(gen *protogen.Plugin, file *protogen.File, serviceList map[string]bool, lang, modeOrOpt string) FileData {
	data := FileData{
		Package:       string(file.Desc.Package()),
		GoPackageName: string(file.GoPackageName),
	}

	// Language-specific fields
	baseProto := filepath.Base(file.Desc.Path())
	switch lang {
	case "dart":
		data.DartPackage = modeOrOpt
		data.PbDartFile = strings.TrimSuffix(baseProto, ".proto") + ".pb.dart"
	case "cpp":
		data.PbHeaderFile = strings.TrimSuffix(baseProto, ".proto") + ".pb.h"
		data.CppNamespace = strings.ReplaceAll(data.Package, ".", "::")
		guardBase := strings.TrimSuffix(outputFilename(file, "cpp"), ".h")
		data.CppGuardName = strings.ToUpper(strings.ReplaceAll(guardBase, ".", "_")) + "_H_"
	case "rust":
		data.RustModPath = strings.ReplaceAll(data.Package, ".", "_")
	}

	// Track Go imports for external packages
	goImports := make(map[string]string) // import path -> alias

	// Helper to get qualified Go type name (optionally adds import)
	qualifyGoType := func(ident protogen.GoIdent, addImport bool) string {
		if ident.GoImportPath == file.GoImportPath {
			return ident.GoName
		}
		// External package - need qualified name
		alias := goPackageAlias(string(ident.GoImportPath))
		if addImport {
			goImports[string(ident.GoImportPath)] = alias
		}
		return alias + "." + ident.GoName
	}

	// Build services and methods
	for _, service := range file.Services {
		if !shouldGenerateService(service.GoName, serviceList) {
			continue
		}

		svcData := ServiceData{
			Name:   string(service.Desc.Name()),
			GoName: service.GoName,
		}

		for _, method := range service.Methods {
			isServerStream := method.Desc.IsStreamingServer()
			isClientStream := method.Desc.IsStreamingClient()
			isStreaming := isServerStream || isClientStream

			m := MethodData{
				Name:              string(method.Desc.Name()),
				GoName:            method.GoName,
				FullMethodName:    fmt.Sprintf("/%s.%s/%s", data.Package, service.Desc.Name(), method.Desc.Name()),
				InputType:         method.Input.GoIdent.GoName,
				OutputType:        method.Output.GoIdent.GoName,
				InputGoIdent:      qualifyGoType(method.Input.GoIdent, true),        // Input always used
				OutputGoIdent:     qualifyGoType(method.Output.GoIdent, isStreaming), // Output only for streaming
				IsServerStreaming: isServerStream && !isClientStream,
				IsClientStreaming: isClientStream && !isServerStream,
				IsBidiStreaming:   isServerStream && isClientStream,
				IsUnary:           !isServerStream && !isClientStream,
			}

			if isStreaming {
				data.HasStreaming = true
			}

			svcData.Methods = append(svcData.Methods, m)
		}

		data.Services = append(data.Services, svcData)
	}

	// Convert Go imports map to slice (sorted for deterministic output)
	for path, alias := range goImports {
		data.GoImports = append(data.GoImports, GoImport{Alias: alias, Path: path})
	}
	sort.Slice(data.GoImports, func(i, j int) bool {
		return data.GoImports[i].Path < data.GoImports[j].Path
	})

	// Build external imports for Dart
	if lang == "dart" {
		imports := make(map[string]bool)
		for _, service := range file.Services {
			if !shouldGenerateService(service.GoName, serviceList) {
				continue
			}
			for _, method := range service.Methods {
				addDartImport(imports, file, method.Input.Desc.ParentFile().Path(), modeOrOpt)
				addDartImport(imports, file, method.Output.Desc.ParentFile().Path(), modeOrOpt)
			}
		}
		for imp := range imports {
			data.ExternalImports = append(data.ExternalImports, imp)
		}
		sort.Strings(data.ExternalImports)
	}

	return data
}

func shouldGenerateService(serviceName string, serviceList map[string]bool) bool {
	if len(serviceList) == 0 {
		return true
	}
	return serviceList[serviceName]
}

func addDartImport(imports map[string]bool, file *protogen.File, path, dartPackage string) {
	if path == file.Desc.Path() {
		return
	}
	target := strings.TrimSuffix(path, ".proto") + ".pb.dart"
	var imp string
	if strings.HasPrefix(target, "google/protobuf/") {
		imp = "package:protobuf/well_known_types/" + target
	} else if dartPackage != "" {
		imp = "package:" + dartPackage + "/" + target
	} else {
		imp = target
	}
	imports[imp] = true
}

// goPackageAlias extracts the package alias from an import path
// e.g., "google.golang.org/protobuf/types/known/emptypb" -> "emptypb"
func goPackageAlias(importPath string) string {
	// Get the last part of the import path
	if idx := strings.LastIndex(importPath, "/"); idx >= 0 {
		return importPath[idx+1:]
	}
	return importPath
}
