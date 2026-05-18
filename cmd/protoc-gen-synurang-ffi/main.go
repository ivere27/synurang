package main

import (
	"bytes"
	"embed"
	"flag"
	"fmt"
	"path"
	"sort"
	"strings"
	"text/template"

	"github.com/ivere27/synurang/pkg/api"
	"google.golang.org/protobuf/compiler/protogen"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
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
	JavaPackage   string
	// For imports
	ExternalImports []string
	GoImports       []GoImport
	PbDartFile      string
	PbHeaderFile    string
	PbTsLiteFile    string   // ESM import path to the lite message module, e.g. "./volvoxgrid_lite.js"
	CppDepHeaders   []string // Additional .pb.h includes for cross-proto types
	CppNamespace    string
	CppGuardName    string
	RustModPath     string
	CSharpNamespace string
	// Message field data (for native/wasm templates)
	Messages      map[string]MessageData
	LocalMessages []MessageData
	Enums         []EnumData
	// FilePrefix is a CamelCase prefix derived from the proto filename
	// (e.g., "core.proto" → "Core", "cache.proto" → "Cache").
	// Used to disambiguate top-level Go symbols when multiple proto files
	// generate into the same package.
	FilePrefix string
	// ActiveX COM dispatch codegen
	ComPrefix     string        // "VFG"
	ComProperties []ComProperty // sorted by DispId
}

// ComProperty describes one COM DISPID entry for ActiveX codegen.
type ComProperty struct {
	DispId       int32
	Name         string // COM property name (e.g., "Rows")
	ConstName    string // DISPID_VFG_ROWS
	DispatchType string // "int_getput", "int_put", "color_getput", "indexed_int_getput", "indexed_int_put", "method", ""
	IsCustom     bool   // skip dispatch generation
	NativeSetFn  string // C function: vv_flex_grid_set_rows
	NativeGetFn  string // C function: vv_flex_grid_get_rows
}

type GoImport struct {
	Alias string
	Path  string
}

type ServiceData struct {
	Name         string
	GoName       string
	NativePrefix string // collision-safe C symbol prefix (snake_case)
	Methods      []MethodData
}

type MethodData struct {
	Name              string
	GoName            string
	FullMethodName    string
	InputType         string // Simple type name (for Dart/C++/Rust)
	OutputType        string // Simple type name (for Dart/C++/Rust)
	InputTypeKey      string // FQN key for Messages map lookup (e.g., "a.v1.Common")
	InputCppType      string // Fully-qualified C++ input type (e.g., "::google::protobuf::Empty")
	OutputCppType     string // Fully-qualified C++ output type
	InputGoIdent      string // Qualified Go type (e.g., "empty.Empty" or "HelloRequest")
	OutputGoIdent     string // Qualified Go type
	IsServerStreaming bool
	IsClientStreaming bool
	IsBidiStreaming   bool
	IsUnary           bool
	OutputIsHandle    bool   // True when the output message type is a handle
	OutputWKT         string // Well-known wrapper type name (e.g. "Empty", "BoolValue"), or "" for user-defined types
}

type MessageData struct {
	Name     string
	Fields   []FieldData
	IsHandle bool // True for messages with a single int64 "id" field (passed as scalar across C ABI)
}

type FieldData struct {
	Name           string // Proto field name (snake_case)
	GoName         string // CamelCase Go/Rust name
	Number         int32  // Field number
	ProtoKind      string // Broad type kind: "int32", "int64", "uint32", "uint64", "float", "double", "bool", "string", "bytes", "enum", "message"
	WireKind       string // Exact protobuf wire kind for TypeScript lite (e.g. "sint32", "fixed64", "sfixed32")
	TypeName       string // For enum/message: the simple type name
	IsRepeated     bool
	IsMap          bool
	IsOneof        bool
	OneofName      string // proto oneof name (snake_case)
	OneofGoName    string // PascalCase form of OneofName
	IsOptional     bool   // True for proto3 optional fields (has presence tracking)
	IsHandle       bool   // True when this message field's type is a handle
	MessageFQN     string // FQN of message type (e.g. "pkg.TreeNode"); empty for non-message fields
	NeedsBox       bool   // True for recursive message fields (prost wraps in Box)
	MessageIsLocal bool   // True when this message field's type is declared in the same proto file
	// Map-entry sub-fields. Populated only when IsMap is true. Proto3 keys
	// are limited to integral / bool / string kinds; values can be any
	// non-map, non-repeated scalar / enum / message.
	MapKeyKind      string // Broad ProtoKind for the key (e.g. "string", "int32")
	MapKeyWireKind  string // Exact WireKind for the key (e.g. "sint32", "fixed64")
	MapValueKind    string // Broad ProtoKind for the value
	MapValueWireKind string // Exact WireKind for the value
	MapValueTypeName string // For enum/message values, the simple type name
}

type EnumData struct {
	Name   string
	Values []EnumValueData
}

type EnumValueData struct {
	Name   string
	Number int32
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

// cppQualifiedType returns the fully-qualified C++ type for a protobuf message.
// e.g., "google.protobuf.Empty" -> "::google::protobuf::Empty"
func cppQualifiedType(msg *protogen.Message) string {
	if msg == nil {
		return ""
	}
	return "::" + strings.ReplaceAll(string(msg.Desc.FullName()), ".", "::")
}

func serviceHasStreaming(svc ServiceData) bool {
	for _, m := range svc.Methods {
		if !m.IsUnary {
			return true
		}
	}
	return false
}

// nativePrefix returns the C function prefix for a service.
// e.g., "VVFlexGridService" → "vv_flex_grid"
func nativePrefix(svc ServiceData) string {
	name := strings.TrimSuffix(svc.GoName, "Service")
	return acronymAwareSnakeCase(name)
}

// acronymAwareSnakeCase converts CamelCase to snake_case, keeping
// consecutive uppercase runs together (e.g., "VVFlexGrid" → "vv_flex_grid").
func acronymAwareSnakeCase(s string) string {
	var result strings.Builder
	runes := []rune(s)
	for i, r := range runes {
		if i > 0 && r >= 'A' && r <= 'Z' {
			prev := runes[i-1]
			if prev >= 'a' && prev <= 'z' {
				result.WriteRune('_')
			} else if i+1 < len(runes) && runes[i+1] >= 'a' && runes[i+1] <= 'z' {
				result.WriteRune('_')
			}
		}
		result.WriteRune(r)
	}
	return strings.ToLower(result.String())
}

// lowerFirst returns s with the first character lowercased.
func lowerFirst(s string) string {
	if s == "" {
		return s
	}
	return strings.ToLower(s[:1]) + s[1:]
}

// toScreamingSnake converts CamelCase to SCREAMING_SNAKE_CASE.
// e.g., "BackColorFixed" → "BACK_COLOR_FIXED", "TopRow" → "TOP_ROW".
func toScreamingSnake(s string) string {
	var result strings.Builder
	runes := []rune(s)
	for i, r := range runes {
		if i > 0 && r >= 'A' && r <= 'Z' {
			prev := runes[i-1]
			if prev >= 'a' && prev <= 'z' {
				result.WriteRune('_')
			} else if i+1 < len(runes) && runes[i+1] >= 'a' && runes[i+1] <= 'z' {
				result.WriteRune('_')
			}
		}
		result.WriteRune(r)
	}
	return strings.ToUpper(result.String())
}

// inferDispatchType determines the COM dispatch macro type for an ActiveX property.
func inferDispatchType(prop *api.ActiveXProperty, setMethod, getMethod *MethodData, msgs map[string]MessageData) string {
	if setMethod == nil && getMethod == nil {
		return ""
	}

	hasGet := getMethod != nil
	hasPut := setMethod != nil

	// Color properties
	if prop.Olecolor {
		if hasGet && hasPut {
			return "color_getput"
		}
		return ""
	}

	// Count fields in setter input to distinguish simple vs indexed.
	// The first field is typically grid_id (raw int64 handle), so:
	//   2 total fields → simple (grid_id + value)
	//   3+ total fields → indexed (grid_id + index + value)
	isIndexed := false
	if hasPut {
		inMsg, ok := msgs[setMethod.InputTypeKey]
		if ok && len(inMsg.Fields) >= 3 {
			isIndexed = true
		}
	}

	if isIndexed {
		if hasGet && hasPut {
			return "indexed_int_getput"
		}
		if hasPut {
			return "indexed_int_put"
		}
	}

	if hasGet && hasPut {
		return "int_getput"
	}
	if hasPut {
		return "int_put"
	}

	return ""
}

// computeFilePrefix derives a CamelCase prefix from a proto file path.
// e.g., "core.proto" → "Core", "cache.proto" → "Cache".
func computeFilePrefix(file *protogen.File) string {
	p := file.Desc.Path()
	base := strings.TrimSuffix(path.Base(p), path.Ext(p))
	if base == "" {
		return ""
	}
	return strings.ToUpper(base[:1]) + base[1:]
}

// isHandleMessage returns true if the message is a handle type:
// exactly one non-repeated int64 field named "id".
func isHandleMessage(msg *protogen.Message) bool {
	if len(msg.Fields) != 1 {
		return false
	}
	f := msg.Fields[0]
	return string(f.Desc.Name()) == "id" &&
		f.Desc.Kind() == protoreflect.Int64Kind &&
		!f.Desc.IsList() && !f.Desc.IsMap()
}

// wellKnownOutputTypes maps protobuf FQNs to short names used for return-type classification.
var wellKnownOutputTypes = map[string]string{
	"google.protobuf.Empty":       "Empty",
	"google.protobuf.Int32Value":  "Int32Value",
	"google.protobuf.BoolValue":   "BoolValue",
	"google.protobuf.DoubleValue": "DoubleValue",
	"google.protobuf.StringValue": "StringValue",
}

// rustCType maps a FieldData to its Rust extern "C" compatible type.
func rustCType(f FieldData) string {
	if f.IsHandle {
		return "i64"
	}
	switch f.ProtoKind {
	case "int32":
		return "i32"
	case "int64":
		return "i64"
	case "uint32":
		return "u32"
	case "uint64":
		return "u64"
	case "float":
		return "f32"
	case "double":
		return "f64"
	case "bool":
		return "i32"
	case "string", "bytes":
		return "*const u8"
	case "enum":
		return "i32"
	case "message":
		return "*const u8"
	default:
		return "i32"
	}
}

// cHeaderType maps a FieldData to its C header type.
func cHeaderType(f FieldData) string {
	if f.IsHandle {
		return "int64_t"
	}
	switch f.ProtoKind {
	case "int32":
		return "int32_t"
	case "int64":
		return "int64_t"
	case "uint32":
		return "uint32_t"
	case "uint64":
		return "uint64_t"
	case "float":
		return "float"
	case "double":
		return "double"
	case "bool":
		return "int32_t"
	case "string", "bytes":
		return "const uint8_t*"
	case "enum":
		return "int32_t"
	case "message":
		return "const uint8_t*"
	default:
		return "int32_t"
	}
}

// needsLen returns true if the field type needs a separate length parameter.
func needsLen(f FieldData) bool {
	if f.IsHandle {
		return false
	}
	return f.ProtoKind == "string" || f.ProtoKind == "bytes" || f.IsRepeated ||
		f.ProtoKind == "message"
}

// needsOutLen returns true if the return type needs an out_len parameter.
func needsOutLen(m MethodData) bool {
	if m.OutputIsHandle {
		return false
	}
	switch m.OutputWKT {
	case "Empty", "Int32Value", "BoolValue", "DoubleValue":
		return false
	default:
		return true
	}
}

// rustReturnType returns the Rust return type for a native function.
func rustReturnType(m MethodData) string {
	if m.OutputIsHandle {
		return "i64"
	}
	switch m.OutputWKT {
	case "Empty":
		return "i32"
	case "Int32Value":
		return "i32"
	case "BoolValue":
		return "i32"
	case "DoubleValue":
		return "f64"
	default:
		return "*mut u8"
	}
}

// cReturnType returns the C header return type.
func cReturnType(m MethodData) string {
	if m.OutputIsHandle {
		return "int64_t"
	}
	switch m.OutputWKT {
	case "Empty":
		return "int32_t"
	case "Int32Value":
		return "int32_t"
	case "BoolValue":
		return "int32_t"
	case "DoubleValue":
		return "double"
	case "StringValue":
		return "uint8_t*"
	default:
		return "uint8_t*"
	}
}

// hasRepeated returns true if any field in the slice is a repeated field.
func hasRepeated(fields []FieldData) bool {
	for _, f := range fields {
		if f.IsRepeated {
			return true
		}
	}
	return false
}

func hasOneof(fields []FieldData) bool {
	for _, f := range fields {
		if f.IsOneof {
			return true
		}
	}
	return false
}

func hasMap(fields []FieldData) bool {
	for _, f := range fields {
		if f.IsMap {
			return true
		}
	}
	return false
}

// needsPbFallback returns true if the message cannot be flattened into
// individual C parameters (has repeated, oneof, or map fields).
func needsPbFallback(fields []FieldData) bool {
	return hasRepeated(fields) || hasOneof(fields) || hasMap(fields)
}

// nonOneofFields returns fields that are not part of a oneof.
func nonOneofFields(fields []FieldData) []FieldData {
	var out []FieldData
	for _, f := range fields {
		if !f.IsOneof {
			out = append(out, f)
		}
	}
	return out
}

// nativeErrReturn returns the Rust error-sentinel return statement for a native C API function.
// The template is responsible for binding the error variable `e` before invoking this.
func nativeErrReturn(m MethodData) string {
	switch {
	case m.OutputWKT == "Empty":
		return "return -1;"
	case m.OutputIsHandle:
		return "return -1;"
	case m.OutputWKT == "Int32Value":
		return "return i32::MIN;"
	case m.OutputWKT == "BoolValue":
		return "return -1;"
	case m.OutputWKT == "DoubleValue":
		return "return f64::NAN;"
	default:
		return "if !out_len.is_null() { *out_len = 0; } return std::ptr::null_mut();"
	}
}

// wasmErrReturn returns the Rust error-sentinel return statement for a WASM export function.
func wasmErrReturn(m MethodData) string {
	switch {
	case m.OutputWKT == "Empty":
		return "return;"
	case m.OutputIsHandle:
		return "return -1;"
	case m.OutputWKT == "Int32Value":
		return "return i32::MIN;"
	case m.OutputWKT == "BoolValue":
		return "return false;"
	case m.OutputWKT == "DoubleValue":
		return "return f64::NAN;"
	case m.OutputWKT == "StringValue":
		return "return String::new();"
	default:
		return "return Vec::new();"
	}
}

// =============================================================================
// C# Lite Template Helpers
// =============================================================================

// csharpType maps a proto field kind to a C# type name.
func csharpType(f FieldData) string {
	// Note: do not use IsHandle here — lite mode generates the actual GridHandle
	// message class, so handle fields must be treated as regular message fields.
	switch f.ProtoKind {
	case "int32":
		return "int"
	case "int64":
		return "long"
	case "uint32":
		return "uint"
	case "uint64":
		return "ulong"
	case "float":
		return "float"
	case "double":
		return "double"
	case "bool":
		return "bool"
	case "string":
		return "string"
	case "bytes":
		return "byte[]"
	case "enum":
		return f.TypeName
	case "message":
		return f.TypeName
	default:
		return "int"
	}
}

// csharpIsValueType returns true if the C# type is a value type (needs ? for nullable).
func csharpIsValueType(f FieldData) bool {
	switch f.ProtoKind {
	case "int32", "int64", "uint32", "uint64", "float", "double", "bool", "enum":
		return true
	default:
		return false
	}
}

// OneofGroup describes a real (non-synthetic) proto oneof for C# codegen.
type OneofGroup struct {
	Name   string      // proto oneof name (snake_case), e.g., "value"
	GoName string      // PascalCase, e.g., "Value"
	Fields []FieldData // fields in this oneof
}

// pascalFromSnake converts a snake_case identifier to PascalCase.
func pascalFromSnake(s string) string {
	out := ""
	for _, part := range strings.Split(s, "_") {
		if part == "" {
			continue
		}
		out += strings.ToUpper(part[:1]) + part[1:]
	}
	return out
}

// oneofGroups returns the distinct real oneof groups for a message's fields.
func oneofGroups(fields []FieldData) []OneofGroup {
	seen := make(map[string]*OneofGroup)
	var order []string
	for _, f := range fields {
		if !f.IsOneof || f.IsOptional {
			continue
		}
		g, ok := seen[f.OneofName]
		if !ok {
			g = &OneofGroup{Name: f.OneofName, GoName: pascalFromSnake(f.OneofName)}
			seen[f.OneofName] = g
			order = append(order, f.OneofName)
		}
		g.Fields = append(g.Fields, f)
	}
	var result []OneofGroup
	for _, name := range order {
		result = append(result, *seen[name])
	}
	return result
}

// =============================================================================
// TypeScript Lite Template Helpers
// =============================================================================

func lowerCamelFromSnake(s string) string {
	if s == "" {
		return s
	}
	parts := strings.Split(s, "_")
	var out strings.Builder
	out.WriteString(parts[0])
	for _, p := range parts[1:] {
		if p == "" {
			continue
		}
		out.WriteString(strings.ToUpper(p[:1]))
		out.WriteString(p[1:])
	}
	return out.String()
}

func tsPropName(f FieldData) string {
	return lowerFirst(f.GoName)
}

func tsJsonName(f FieldData) string {
	return lowerCamelFromSnake(f.Name)
}

func tsType(f FieldData) string {
	switch f.ProtoKind {
	case "int32", "uint32", "float", "double":
		return "number"
	case "int64", "uint64":
		return "bigint"
	case "bool":
		return "boolean"
	case "string":
		return "string"
	case "bytes":
		return "Uint8Array"
	case "enum":
		return f.TypeName
	case "message":
		if f.MessageIsLocal {
			return f.TypeName
		}
		return "unknown"
	default:
		return "unknown"
	}
}

func tsDefaultValue(f FieldData) string {
	switch f.ProtoKind {
	case "int32", "uint32", "float", "double", "enum":
		return "0"
	case "int64", "uint64":
		return "0n"
	case "bool":
		return "false"
	case "string":
		return `""`
	default:
		return ""
	}
}

func tsOneofCaseEnumName(messageName, groupName string) string {
	return messageName + groupName + "OneofCase"
}

func tsOneofCaseProperty(f FieldData) string {
	if !f.IsOneof || f.IsOptional {
		return ""
	}
	return lowerFirst(f.OneofGoName) + "Case"
}

func tsOneofCaseValue(messageName string, f FieldData) string {
	if !f.IsOneof || f.IsOptional {
		return ""
	}
	return tsOneofCaseEnumName(messageName, f.OneofGoName) + "." + f.GoName
}

// =============================================================================
// Swift Lite Template Helpers
// =============================================================================

// swiftKeywords are Swift identifiers that must be backtick-escaped when used
// as a property name, enum case, or method name.
var swiftKeywords = map[string]bool{
	"associatedtype": true, "class": true, "deinit": true, "enum": true,
	"extension": true, "fileprivate": true, "func": true, "import": true,
	"init": true, "inout": true, "internal": true, "let": true, "open": true,
	"operator": true, "private": true, "protocol": true, "public": true,
	"static": true, "struct": true, "subscript": true, "typealias": true,
	"var": true, "break": true, "case": true, "continue": true, "default": true,
	"defer": true, "do": true, "else": true, "fallthrough": true, "for": true,
	"guard": true, "if": true, "in": true, "repeat": true, "return": true,
	"switch": true, "where": true, "while": true, "as": true, "Any": true,
	"catch": true, "false": true, "is": true, "nil": true, "rethrows": true,
	"super": true, "self": true, "Self": true, "throw": true, "throws": true,
	"true": true, "try": true,
}

func swiftEscape(name string) string {
	if swiftKeywords[name] {
		return "`" + name + "`"
	}
	return name
}

// swiftType returns the Swift type for a scalar / enum / message field.
// Repeated arrays and optional ? are applied by the template, not here.
func swiftType(f FieldData) string {
	switch f.ProtoKind {
	case "int32":
		return "Int32"
	case "int64":
		return "Int64"
	case "uint32":
		return "UInt32"
	case "uint64":
		return "UInt64"
	case "float":
		return "Float"
	case "double":
		return "Double"
	case "bool":
		return "Bool"
	case "string":
		return "String"
	case "bytes":
		return "Data"
	case "enum", "message":
		return f.TypeName
	default:
		return "Int32"
	}
}

// swiftDefault returns the trailing " = <value>" for a non-optional, non-repeated,
// non-message field. Returns empty string when no default initializer applies
// (caller must handle).
func swiftDefault(f FieldData) string {
	switch f.ProtoKind {
	case "int32", "int64", "uint32", "uint64", "float", "double":
		return " = 0"
	case "bool":
		return " = false"
	case "string":
		return ` = ""`
	case "bytes":
		return " = Data()"
	case "enum":
		zero := swiftEnumZeroCase(f.TypeName)
		if zero == "" {
			return ""
		}
		return " = ." + zero
	default:
		return ""
	}
}

// swiftFieldName returns the lowerCamelCase Swift property name from a proto
// snake_case field name, with Swift keyword escaping.
func swiftFieldName(f FieldData) string {
	return swiftEscape(lowerCamelFromSnake(f.Name))
}

// swiftMethodName returns the lowerCamelCase Swift method name from the proto
// PascalCase RPC name.
func swiftMethodName(name string) string {
	return swiftEscape(lowerFirst(name))
}

// enumStripPrefix caches the decision (per enum) of whether to strip the
// SCREAMING_SNAKE enum-name prefix from each value when forming Swift cases.
// We strip only if every value yields a valid Swift identifier after
// stripping; otherwise no value is stripped, keeping the enum self-consistent.
// Populated in collectEnumData.
var enumStripPrefix = map[string]bool{}

func toLowerCamelFromUnderscored(s string) string {
	parts := strings.Split(strings.ToLower(s), "_")
	var b strings.Builder
	wroteFirst := false
	for _, p := range parts {
		if p == "" {
			continue
		}
		if !wroteFirst {
			b.WriteString(p)
			wroteFirst = true
		} else {
			b.WriteString(strings.ToUpper(p[:1]))
			b.WriteString(p[1:])
		}
	}
	return b.String()
}

// swiftEnumCase returns the Swift enum case name for a proto enum value.
// Proto convention: enum values are prefixed with the SCREAMING_SNAKE form of
// the enum name (e.g. CellKind.CELL_KIND_UNSPECIFIED). We strip that prefix if
// — for this enum — every value yields a valid Swift identifier after
// stripping. Otherwise the full value name is used for every case in the enum.
// Matches SwiftProtobuf's behavior.
func swiftEnumCase(enumName, valueName string) string {
	prefix := toScreamingSnake(enumName) + "_"
	v := valueName
	if enumStripPrefix[enumName] && strings.HasPrefix(v, prefix) {
		v = v[len(prefix):]
	}
	out := toLowerCamelFromUnderscored(v)
	if out == "" {
		out = strings.ToLower(valueName)
	}
	return swiftEscape(out)
}

// enumZeroCases caches the Swift case name for the zero-value of each enum,
// populated in collectEnumData. Keyed by EnumData.Name (Go-side identifier).
var enumZeroCases = map[string]string{}

// swiftEnumZeroCase returns the Swift case name of the zero-numbered value of
// the named enum, used as a fallback when reading an unknown raw value.
func swiftEnumZeroCase(enumTypeName string) string {
	return enumZeroCases[enumTypeName]
}

// swiftOneofCase returns the Swift case identifier inside a oneof's nested
// enum, derived from the field's Go (CamelCase) name.
func swiftOneofCase(goName string) string {
	return swiftEscape(lowerFirst(goName))
}

// swiftWriteCall returns the ProtoWriter method name for a scalar/enum
// wire kind. Branches on the exact WireKind (sint32, sfixed64, ...) so
// the generated encoder uses the correct zigzag / fixed-width path.
// Returns "" for messages — those go through `encode(into:)` instead.
func swiftWriteCall(wireKind string) string {
	switch wireKind {
	case "int32":
		return "writeInt32"
	case "sint32":
		return "writeSInt32"
	case "sfixed32":
		return "writeSFixed32"
	case "int64":
		return "writeInt64"
	case "sint64":
		return "writeSInt64"
	case "sfixed64":
		return "writeSFixed64"
	case "uint32":
		return "writeUInt32"
	case "fixed32":
		return "writeFixed32"
	case "uint64":
		return "writeUInt64"
	case "fixed64":
		return "writeFixed64"
	case "float":
		return "writeFloat"
	case "double":
		return "writeDouble"
	case "bool":
		return "writeBool"
	case "string":
		return "writeString"
	case "bytes":
		return "writeBytes"
	case "enum":
		return "writeInt32"
	default:
		return ""
	}
}

// swiftReadCall mirrors swiftWriteCall but returns the ProtoReader method
// (e.g. "readSInt32"). Returns "" for messages.
func swiftReadCall(wireKind string) string {
	switch wireKind {
	case "int32":
		return "readInt32"
	case "sint32":
		return "readSInt32"
	case "sfixed32":
		return "readSFixed32"
	case "int64":
		return "readInt64"
	case "sint64":
		return "readSInt64"
	case "sfixed64":
		return "readSFixed64"
	case "uint32":
		return "readUInt32"
	case "fixed32":
		return "readFixed32"
	case "uint64":
		return "readUInt64"
	case "fixed64":
		return "readFixed64"
	case "float":
		return "readFloat"
	case "double":
		return "readDouble"
	case "bool":
		return "readBool"
	case "string":
		return "readString"
	case "bytes":
		return "readBytes"
	case "enum":
		return "readInt32"
	default:
		return ""
	}
}

// swiftScalarWire returns the WireType enum case for the non-packed wire
// of a scalar/enum kind. Used by packed-repeated dispatch to detect "this
// is one element, read scalar" vs ".lengthDelimited, read packed body".
func swiftScalarWire(wireKind string) string {
	switch wireKind {
	case "fixed32", "sfixed32", "float":
		return ".fixed32"
	case "fixed64", "sfixed64", "double":
		return ".fixed64"
	case "string", "bytes", "message":
		return ".lengthDelimited"
	default:
		return ".varint"
	}
}

// swiftMapKeyType returns the Swift dictionary key type for a map field.
// Proto3 keys are restricted to integral / bool / string kinds.
func swiftMapKeyType(f FieldData) string {
	switch f.MapKeyKind {
	case "int32":
		return "Int32"
	case "int64":
		return "Int64"
	case "uint32":
		return "UInt32"
	case "uint64":
		return "UInt64"
	case "bool":
		return "Bool"
	case "string":
		return "String"
	default:
		return "String"
	}
}

// swiftMapValueType returns the Swift dictionary value type for a map
// field. Message and enum values use their simple type name; scalars map
// to Swift's native numeric types.
func swiftMapValueType(f FieldData) string {
	switch f.MapValueKind {
	case "int32":
		return "Int32"
	case "int64":
		return "Int64"
	case "uint32":
		return "UInt32"
	case "uint64":
		return "UInt64"
	case "float":
		return "Float"
	case "double":
		return "Double"
	case "bool":
		return "Bool"
	case "string":
		return "String"
	case "bytes":
		return "Data"
	case "enum", "message":
		return f.MapValueTypeName
	default:
		return "Int32"
	}
}

// swiftMapKeyDefault / swiftMapValueDefault return a Swift expression for
// the proto3 default value of a map key/value. Used to initialise the
// loop-local accumulators when decoding a map entry.
func swiftMapKeyDefault(f FieldData) string {
	return swiftKindDefault(f.MapKeyKind, "")
}

func swiftMapValueDefault(f FieldData) string {
	return swiftKindDefault(f.MapValueKind, f.MapValueTypeName)
}

func swiftKindDefault(kind, typeName string) string {
	switch kind {
	case "int32", "int64", "uint32", "uint64", "float", "double":
		return "0"
	case "bool":
		return "false"
	case "string":
		return `""`
	case "bytes":
		return "Data()"
	case "enum":
		zero := swiftEnumZeroCase(typeName)
		if zero == "" {
			return typeName + "(rawValue: 0)!"
		}
		return "." + zero
	case "message":
		return typeName + "()"
	default:
		return "0"
	}
}

// swiftNotDefault returns the Swift expression that's true when `expr` is
// not at its proto3 default. Used to gate "skip default when serializing".
func swiftNotDefault(kind, expr string) string {
	switch kind {
	case "bool":
		return expr
	case "string", "bytes":
		return "!" + expr + ".isEmpty"
	case "enum":
		return expr + ".rawValue != 0"
	default:
		return expr + " != 0"
	}
}

func init() {
	funcs := template.FuncMap{
		"snakeCase":        toSnakeCase,
		"callMethod":       callMethod,
		"grpcStreamType":   grpcStreamType,
		"ffiStreamType":    ffiStreamType,
		"pluginStreamType": pluginStreamType,
		"replace":          strings.ReplaceAll,
		"upper":            strings.ToUpper,
		// Native/WASM template functions
		"rustCType":           rustCType,
		"cHeaderType":         cHeaderType,
		"needsLen":            needsLen,
		"needsOutLen":         needsOutLen,
		"rustReturnType":      rustReturnType,
		"cReturnType":         cReturnType,
		"hasRepeated":         hasRepeated,
		"hasOneof":            hasOneof,
		"hasMap":              hasMap,
		"needsPbFallback":     needsPbFallback,
		"nonOneofFields":      nonOneofFields,
		"nativeErrReturn":     nativeErrReturn,
		"wasmErrReturn":       wasmErrReturn,
		"lowerFirst":          lowerFirst,
		"serviceHasStreaming": serviceHasStreaming,
		"lower":               strings.ToLower,
		"screaming":           toScreamingSnake,
		// C# lite template functions
		"csharpType":        csharpType,
		"csharpIsValueType": csharpIsValueType,
		"oneofGroups":       oneofGroups,
		// TypeScript lite template functions
		"tsType":              tsType,
		"tsDefaultValue":      tsDefaultValue,
		"tsPropName":          tsPropName,
		"tsJsonName":          tsJsonName,
		"tsOneofCaseEnumName": tsOneofCaseEnumName,
		"tsOneofCaseProperty": tsOneofCaseProperty,
		"tsOneofCaseValue":    tsOneofCaseValue,
		// Swift lite template functions
		"swiftType":            swiftType,
		"swiftEscape":          swiftEscape,
		"swiftDefault":         swiftDefault,
		"swiftFieldName":       swiftFieldName,
		"swiftMethodName":      swiftMethodName,
		"swiftEnumCase":        swiftEnumCase,
		"swiftEnumZeroCase":    swiftEnumZeroCase,
		"swiftOneofCase":       swiftOneofCase,
		"swiftWriteCall":       swiftWriteCall,
		"swiftReadCall":        swiftReadCall,
		"swiftScalarWire":      swiftScalarWire,
		"swiftMapKeyType":      swiftMapKeyType,
		"swiftMapValueType":    swiftMapValueType,
		"swiftMapKeyDefault":   swiftMapKeyDefault,
		"swiftMapValueDefault": swiftMapValueDefault,
		"swiftNotDefault":      swiftNotDefault,
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
	lang := flags.String("lang", "", "language to generate (go, dart, cpp, c, rust, java, csharp, typescript, or swift)")
	mode := flags.String("mode", "default", "generation mode: default, plugin_server, plugin_client, native, wasm, lite")
	dartPackage := flags.String("dart_package", "", "Dart package name for imports")
	javaPackage := flags.String("java_package", "", "Java package name for generated classes")
	csharpNamespace := flags.String("csharp_namespace", "", "C# namespace for generated classes")
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
				generateFromTemplate(gen, f, serviceList, "cpp", *mode)
			}
			if *lang == "rust" {
				generateFromTemplate(gen, f, serviceList, "rust", *mode)
			}
			if *lang == "java" {
				generateFromTemplate(gen, f, serviceList, "java", *javaPackage)
			}
			if *lang == "csharp" {
				if *mode == "lite" {
					generateFromTemplate(gen, f, serviceList, "csharp", "lite")
				} else {
					generateFromTemplate(gen, f, serviceList, "csharp", *csharpNamespace)
				}
			}
			if *lang == "typescript" || *lang == "ts" {
				if (*mode == "" || *mode == "default") && hasGeneratedServices(f, serviceList) {
					generateFromTemplate(gen, f, serviceList, "typescript", "lite")
				}
				generateFromTemplate(gen, f, serviceList, "typescript", *mode)
			}
			if *lang == "c" {
				generateFromTemplate(gen, f, serviceList, "c", *mode)
			}
			if *lang == "swift" {
				if *mode == "lite" {
					generateFromTemplate(gen, f, serviceList, "swift", "lite")
				} else {
					generateFromTemplate(gen, f, serviceList, "swift", *mode)
				}
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

	// For C++ plugin_server mode, generate both header and implementation
	if lang == "cpp" && modeOrOpt == "plugin_server" {
		// Generate header
		var headerBuf bytes.Buffer
		if err := templates.ExecuteTemplate(&headerBuf, "cpp_plugin_server.h.tmpl", data); err != nil {
			gen.Error(fmt.Errorf("template cpp_plugin_server.h.tmpl: %v", err))
			return
		}
		headerFilename := outputFilenameWithMode(file, lang, modeOrOpt, ".h")
		hg := gen.NewGeneratedFile(headerFilename, file.GoImportPath)
		hg.P(headerBuf.String())

		// Generate implementation
		var implBuf bytes.Buffer
		if err := templates.ExecuteTemplate(&implBuf, "cpp_plugin_server.cc.tmpl", data); err != nil {
			gen.Error(fmt.Errorf("template cpp_plugin_server.cc.tmpl: %v", err))
			return
		}
		implFilename := outputFilenameWithMode(file, lang, modeOrOpt, ".cc")
		ig := gen.NewGeneratedFile(implFilename, file.GoImportPath)
		ig.P(implBuf.String())
		return
	}

	tmplName := selectTemplate(lang, modeOrOpt)
	var buf bytes.Buffer
	if err := templates.ExecuteTemplate(&buf, tmplName, data); err != nil {
		gen.Error(fmt.Errorf("template %s: %v", tmplName, err))
		return
	}

	filename := outputFilenameWithMode(file, lang, modeOrOpt, "")
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
		switch modeOrOpt {
		case "plugin_server":
			return "cpp_plugin_server.cc.tmpl"
		default:
			return "cpp.h.tmpl"
		}
	case "rust":
		switch modeOrOpt {
		case "plugin_server":
			return "rust_plugin_server.rs.tmpl"
		case "native":
			return "rust_native.rs.tmpl"
		case "wasm":
			return "rust_wasm.rs.tmpl"
		default:
			return "rust.rs.tmpl"
		}
	case "c":
		switch modeOrOpt {
		case "activex":
			return "c_activex.h.tmpl"
		default:
			return "c_native.h.tmpl"
		}
	case "java":
		return "java.java.tmpl"
	case "csharp":
		if modeOrOpt == "lite" {
			return "csharp_lite.cs.tmpl"
		}
		return "csharp.cs.tmpl"
	case "typescript", "ts":
		if modeOrOpt == "lite" {
			return "typescript_lite.ts.tmpl"
		}
		return "typescript.ts.tmpl"
	case "swift":
		return "swift_lite.swift.tmpl"
	}
	return ""
}

func outputFilenameWithMode(file *protogen.File, lang, mode, ext string) string {
	base := strings.TrimSuffix(file.Desc.Path(), ".proto")
	if idx := strings.LastIndex(base, "/"); idx >= 0 {
		base = base[idx+1:]
	}

	if mode == "plugin_server" {
		switch lang {
		case "go":
			return base + "_ffi_plugin.pb.go"
		case "cpp":
			if ext != "" {
				return base + "_ffi_plugin" + ext
			}
			return base + "_ffi_plugin.cc"
		case "rust":
			return base + "_ffi_plugin.rs"
		}
	}

	if mode == "activex" && lang == "c" {
		return base + "_activex.h"
	}

	if mode == "native" {
		switch lang {
		case "rust":
			return base + "_ffi_native.rs"
		case "c":
			return base + "_ffi_native.h"
		}
	}

	if mode == "wasm" {
		switch lang {
		case "rust":
			return base + "_wasm.rs"
		}
	}

	if mode == "lite" {
		switch lang {
		case "csharp":
			return base + "_lite.cs"
		case "typescript", "ts":
			return base + "_lite.ts"
		case "swift":
			return base + "_lite.swift"
		}
	}

	switch lang {
	case "go":
		return base + "_ffi.pb.go"
	case "dart":
		return base + "_ffi.pb.dart"
	case "cpp":
		return base + "_ffi.h"
	case "c":
		return base + "_ffi_native.h"
	case "rust":
		return base + "_ffi.rs"
	case "java":
		return base + "_ffi.java"
	case "csharp":
		return base + "_ffi.cs"
	case "typescript", "ts":
		return base + "_ffi.ts"
	case "swift":
		return base + "_ffi.swift"
	}
	return base + "_ffi"
}

// Kept for backward compatibility
func outputFilename(file *protogen.File, lang string) string {
	return outputFilenameWithMode(file, lang, "", "")
}

// =============================================================================
// Build Template Data
// =============================================================================

// messageDataFromProtogen converts a *protogen.Message into MessageData.
func messageDataFromProtogen(msg *protogen.Message) MessageData {
	md := MessageData{Name: msg.GoIdent.GoName, IsHandle: isHandleMessage(msg)}
	for _, field := range msg.Fields {
		fd := FieldData{
			Name:       string(field.Desc.Name()),
			GoName:     field.GoName,
			Number:     int32(field.Desc.Number()),
			IsRepeated: field.Desc.IsList(),
			IsMap:      field.Desc.IsMap(),
		}
		switch field.Desc.Kind() {
		case protoreflect.BoolKind:
			fd.ProtoKind = "bool"
			fd.WireKind = "bool"
		case protoreflect.Int32Kind:
			fd.ProtoKind = "int32"
			fd.WireKind = "int32"
		case protoreflect.Sint32Kind:
			fd.ProtoKind = "int32"
			fd.WireKind = "sint32"
		case protoreflect.Sfixed32Kind:
			fd.ProtoKind = "int32"
			fd.WireKind = "sfixed32"
		case protoreflect.Int64Kind:
			fd.ProtoKind = "int64"
			fd.WireKind = "int64"
		case protoreflect.Sint64Kind:
			fd.ProtoKind = "int64"
			fd.WireKind = "sint64"
		case protoreflect.Sfixed64Kind:
			fd.ProtoKind = "int64"
			fd.WireKind = "sfixed64"
		case protoreflect.Uint32Kind:
			fd.ProtoKind = "uint32"
			fd.WireKind = "uint32"
		case protoreflect.Fixed32Kind:
			fd.ProtoKind = "uint32"
			fd.WireKind = "fixed32"
		case protoreflect.Uint64Kind:
			fd.ProtoKind = "uint64"
			fd.WireKind = "uint64"
		case protoreflect.Fixed64Kind:
			fd.ProtoKind = "uint64"
			fd.WireKind = "fixed64"
		case protoreflect.FloatKind:
			fd.ProtoKind = "float"
			fd.WireKind = "float"
		case protoreflect.DoubleKind:
			fd.ProtoKind = "double"
			fd.WireKind = "double"
		case protoreflect.StringKind:
			fd.ProtoKind = "string"
			fd.WireKind = "string"
		case protoreflect.BytesKind:
			fd.ProtoKind = "bytes"
			fd.WireKind = "bytes"
		case protoreflect.EnumKind:
			fd.ProtoKind = "enum"
			fd.WireKind = "enum"
			if field.Enum != nil {
				fd.TypeName = field.Enum.GoIdent.GoName
			}
		case protoreflect.MessageKind, protoreflect.GroupKind:
			fd.ProtoKind = "message"
			fd.WireKind = "message"
			if field.Message != nil {
				fd.TypeName = field.Message.GoIdent.GoName
				fd.IsHandle = isHandleMessage(field.Message)
				fd.MessageFQN = string(field.Message.Desc.FullName())
				fd.MessageIsLocal = field.Message.Desc.ParentFile().Path() == msg.Desc.ParentFile().Path() &&
					!field.Message.Desc.IsMapEntry()
			}
		default:
			fd.ProtoKind = "unknown"
			fd.WireKind = "unknown"
		}
		if field.Desc.ContainingOneof() != nil {
			fd.IsOneof = true
			fd.OneofName = string(field.Desc.ContainingOneof().Name())
			fd.OneofGoName = pascalFromSnake(fd.OneofName)
		}
		if field.Desc.HasOptionalKeyword() {
			fd.IsOptional = true
		}
		if fd.IsMap && field.Message != nil {
			// Map fields synthesize a hidden MapEntry message with `key` at
			// tag 1 and `value` at tag 2. Surface those into FieldData so
			// templates can emit native dictionary types without re-deriving
			// from the entry message. ProtoKind / WireKind / IsRepeated are
			// left as protobuf-go set them (kind=message, repeated=false)
			// so existing templates branch consistently.
			for _, sub := range field.Message.Fields {
				kind, wire, typeName := classifyField(sub)
				switch sub.Desc.Number() {
				case 1:
					fd.MapKeyKind = kind
					fd.MapKeyWireKind = wire
				case 2:
					fd.MapValueKind = kind
					fd.MapValueWireKind = wire
					fd.MapValueTypeName = typeName
				}
			}
		}
		md.Fields = append(md.Fields, fd)
	}
	return md
}

// classifyField returns the ProtoKind / WireKind / TypeName triple for a
// single protogen field. Extracted from messageDataFromProtogen so map
// sub-fields can be classified without a recursive FieldData build.
func classifyField(field *protogen.Field) (kind string, wire string, typeName string) {
	switch field.Desc.Kind() {
	case protoreflect.BoolKind:
		return "bool", "bool", ""
	case protoreflect.Int32Kind:
		return "int32", "int32", ""
	case protoreflect.Sint32Kind:
		return "int32", "sint32", ""
	case protoreflect.Sfixed32Kind:
		return "int32", "sfixed32", ""
	case protoreflect.Int64Kind:
		return "int64", "int64", ""
	case protoreflect.Sint64Kind:
		return "int64", "sint64", ""
	case protoreflect.Sfixed64Kind:
		return "int64", "sfixed64", ""
	case protoreflect.Uint32Kind:
		return "uint32", "uint32", ""
	case protoreflect.Fixed32Kind:
		return "uint32", "fixed32", ""
	case protoreflect.Uint64Kind:
		return "uint64", "uint64", ""
	case protoreflect.Fixed64Kind:
		return "uint64", "fixed64", ""
	case protoreflect.FloatKind:
		return "float", "float", ""
	case protoreflect.DoubleKind:
		return "double", "double", ""
	case protoreflect.StringKind:
		return "string", "string", ""
	case protoreflect.BytesKind:
		return "bytes", "bytes", ""
	case protoreflect.EnumKind:
		name := ""
		if field.Enum != nil {
			name = field.Enum.GoIdent.GoName
		}
		return "enum", "enum", name
	case protoreflect.MessageKind, protoreflect.GroupKind:
		name := ""
		if field.Message != nil {
			name = field.Message.GoIdent.GoName
		}
		return "message", "message", name
	default:
		return "unknown", "unknown", ""
	}
}

// collectMessage converts a *protogen.Message into MessageData and adds it to
// the map. It recurses into message-typed fields so nested/imported messages
// referenced by fields are also available for template lookup.
func collectMessage(msgs map[string]MessageData, msg *protogen.Message, visited map[string]bool) {
	key := string(msg.Desc.FullName())
	if visited[key] {
		return // already collected or in progress
	}
	visited[key] = true
	msgs[key] = messageDataFromProtogen(msg)
	for _, field := range msg.Fields {
		if field.Message != nil {
			collectMessage(msgs, field.Message, visited)
		}
	}
}

func collectLocalMessages(out *[]MessageData, msg *protogen.Message, visited map[string]bool) {
	if msg.Desc.IsMapEntry() {
		return
	}
	key := string(msg.Desc.FullName())
	if visited[key] {
		return
	}
	visited[key] = true
	*out = append(*out, messageDataFromProtogen(msg))
	for _, nested := range msg.Messages {
		collectLocalMessages(out, nested, visited)
	}
}

func collectEnumData(out *[]EnumData, enum *protogen.Enum, visited map[string]bool) {
	key := string(enum.Desc.FullName())
	if visited[key] {
		return
	}
	visited[key] = true
	data := EnumData{Name: enum.GoIdent.GoName}
	for _, value := range enum.Values {
		data.Values = append(data.Values, EnumValueData{
			Name:   string(value.Desc.Name()),
			Number: int32(value.Desc.Number()),
		})
	}
	// Decide once whether to strip the enum's SCREAMING_SNAKE prefix when
	// forming Swift case names: strip only if every value yields a valid
	// Swift identifier (non-empty, non-digit-leading) after stripping.
	if _, cached := enumStripPrefix[data.Name]; !cached {
		prefix := toScreamingSnake(data.Name) + "_"
		strip := true
		for _, v := range data.Values {
			rest := v.Name
			if strings.HasPrefix(rest, prefix) {
				rest = rest[len(prefix):]
			} else {
				strip = false
				break
			}
			if rest == "" || (rest[0] >= '0' && rest[0] <= '9') {
				strip = false
				break
			}
		}
		enumStripPrefix[data.Name] = strip
	}
	// Cache the Swift case name of the zero-numbered value for the Swift
	// lite template's `swiftEnumZeroCase` helper. Must run after the
	// strip decision above so swiftEnumCase sees it.
	if _, cached := enumZeroCases[data.Name]; !cached {
		for _, v := range data.Values {
			if v.Number == 0 {
				enumZeroCases[data.Name] = swiftEnumCase(data.Name, v.Name)
				break
			}
		}
	}
	*out = append(*out, data)
}

func collectLocalMessageEnums(out *[]EnumData, msg *protogen.Message, visited map[string]bool) {
	if msg.Desc.IsMapEntry() {
		return
	}
	for _, enum := range msg.Enums {
		collectEnumData(out, enum, visited)
	}
	for _, nested := range msg.Messages {
		collectLocalMessageEnums(out, nested, visited)
	}
}

// collectMessageFiles recursively collects the parent proto file paths of
// a message and all message types reachable through its fields.
func collectMessageFiles(msg *protogen.Message, files map[string]bool, visited map[string]bool) {
	key := string(msg.Desc.FullName())
	if visited[key] {
		return
	}
	visited[key] = true
	files[msg.Desc.ParentFile().Path()] = true
	for _, field := range msg.Fields {
		if field.Message != nil {
			collectMessageFiles(field.Message, files, visited)
		}
	}
}

// markBoxFields detects cycles in the message type graph and sets NeedsBox
// on fields that prost would wrap in Box<T>. A field needs boxing when its
// message type can reach back to the parent through singular (non-repeated,
// non-map) message fields, forming a cycle that would be infinitely sized.
func markBoxFields(msgs map[string]MessageData) {
	for key, md := range msgs {
		for i, f := range md.Fields {
			if f.ProtoKind != "message" || f.IsRepeated || f.IsMap || f.MessageFQN == "" {
				continue
			}
			if canReach(msgs, f.MessageFQN, key, nil) {
				md.Fields[i].NeedsBox = true
			}
		}
		msgs[key] = md
	}
}

// canReach returns true if 'from' can reach 'target' by following singular
// message fields (edges that don't go through Vec/Map indirection).
func canReach(msgs map[string]MessageData, from, target string, visited map[string]bool) bool {
	if from == target {
		return true
	}
	if visited == nil {
		visited = make(map[string]bool)
	}
	if visited[from] {
		return false
	}
	visited[from] = true
	md, ok := msgs[from]
	if !ok {
		return false
	}
	for _, f := range md.Fields {
		if f.ProtoKind != "message" || f.IsRepeated || f.IsMap || f.MessageFQN == "" {
			continue
		}
		if canReach(msgs, f.MessageFQN, target, visited) {
			return true
		}
	}
	return false
}

func buildFileData(gen *protogen.Plugin, file *protogen.File, serviceList map[string]bool, lang, modeOrOpt string) FileData {
	data := FileData{
		Package:       string(file.Desc.Package()),
		GoPackageName: string(file.GoPackageName),
		FilePrefix:    computeFilePrefix(file),
	}

	// Language-specific fields
	baseProto := path.Base(file.Desc.Path())
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
	case "java":
		if modeOrOpt != "" {
			data.JavaPackage = modeOrOpt
		} else {
			// Derive from proto package, converting to Java convention
			data.JavaPackage = strings.ReplaceAll(data.Package, "-", "_")
		}
	case "csharp":
		if modeOrOpt != "" && modeOrOpt != "lite" {
			data.CSharpNamespace = modeOrOpt
		} else {
			// Derive from proto package: example.v1 -> Example.V1
			parts := strings.Split(data.Package, ".")
			for i, part := range parts {
				if len(part) > 0 {
					parts[i] = strings.ToUpper(part[:1]) + part[1:]
				}
			}
			data.CSharpNamespace = strings.Join(parts, ".")
		}
	case "typescript", "ts":
		// Default-mode TS imports message classes from the sibling lite module.
		// Both files are emitted into the same output directory.
		data.PbTsLiteFile = "./" + strings.TrimSuffix(baseProto, ".proto") + "_lite.js"
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
				InputTypeKey:      string(method.Input.Desc.FullName()),
				InputCppType:      cppQualifiedType(method.Input),
				OutputCppType:     cppQualifiedType(method.Output),
				OutputIsHandle:    isHandleMessage(method.Output),
				OutputWKT:         wellKnownOutputTypes[string(method.Output.Desc.FullName())],
				InputGoIdent:      qualifyGoType(method.Input.GoIdent, true),         // Input always used
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

	// Compute collision-safe native prefixes.
	// nativePrefix strips "Service" suffix, so "Alpha" and "AlphaService"
	// would both map to "alpha". Detect collisions and use full name instead.
	prefixCount := make(map[string]int)
	for i := range data.Services {
		p := nativePrefix(data.Services[i])
		prefixCount[p]++
	}
	for i := range data.Services {
		p := nativePrefix(data.Services[i])
		if prefixCount[p] > 1 {
			// Collision: use the full GoName without stripping "Service"
			data.Services[i].NativePrefix = acronymAwareSnakeCase(data.Services[i].GoName)
		} else {
			data.Services[i].NativePrefix = p
		}
	}

	// Convert Go imports map to slice (sorted for deterministic output)
	for path, alias := range goImports {
		data.GoImports = append(data.GoImports, GoImport{Alias: alias, Path: path})
	}
	sort.Slice(data.GoImports, func(i, j int) bool {
		return data.GoImports[i].Path < data.GoImports[j].Path
	})

	// Build messages map (for native/wasm templates)
	// Collect from method input/output types so imported and nested messages are included.
	data.Messages = make(map[string]MessageData)
	visited := make(map[string]bool)
	for _, service := range file.Services {
		if !shouldGenerateService(service.GoName, serviceList) {
			continue
		}
		for _, method := range service.Methods {
			collectMessage(data.Messages, method.Input, visited)
			collectMessage(data.Messages, method.Output, visited)
		}
	}
	markBoxFields(data.Messages)

	needsLocalTypes := lang == "typescript" || (lang == "csharp" && modeOrOpt == "lite") || (lang == "swift" && modeOrOpt == "lite")
	if needsLocalTypes {
		localMsgVisited := make(map[string]bool)
		for _, msg := range file.Messages {
			collectLocalMessages(&data.LocalMessages, msg, localMsgVisited)
		}
		sort.Slice(data.LocalMessages, func(i, j int) bool {
			return data.LocalMessages[i].Name < data.LocalMessages[j].Name
		})

		localEnumVisited := make(map[string]bool)
		for _, enum := range file.Enums {
			collectEnumData(&data.Enums, enum, localEnumVisited)
		}
		for _, msg := range file.Messages {
			collectLocalMessageEnums(&data.Enums, msg, localEnumVisited)
		}
		sort.Slice(data.Enums, func(i, j int) bool {
			return data.Enums[i].Name < data.Enums[j].Name
		})
	}

	// Build ActiveX COM properties (for c activex mode).
	// Must come after messages map is built so inferDispatchType can inspect field counts.
	if lang == "c" && modeOrOpt == "activex" {
		for _, service := range file.Services {
			if !shouldGenerateService(service.GoName, serviceList) {
				continue
			}
			opts := service.Desc.Options()
			if opts == nil {
				continue
			}
			axSvc, ok := proto.GetExtension(opts, api.E_ActivexService).(*api.ActiveXServiceOption)
			if !ok || axSvc == nil {
				continue
			}

			data.ComPrefix = axSvc.Prefix

			// Find matching ServiceData for NativePrefix lookup
			var svcNativePrefix string
			for _, sd := range data.Services {
				if sd.GoName == service.GoName {
					svcNativePrefix = sd.NativePrefix
					break
				}
			}

			// Build method lookup map (name -> MethodData)
			methodMap := make(map[string]*MethodData)
			for i := range data.Services {
				if data.Services[i].GoName == service.GoName {
					for j := range data.Services[i].Methods {
						methodMap[data.Services[i].Methods[j].Name] = &data.Services[i].Methods[j]
					}
					break
				}
			}

			for _, prop := range axSvc.Properties {
				cp := ComProperty{
					DispId:   prop.Dispid,
					Name:     prop.Name,
					IsCustom: prop.Custom,
				}

				// Compute constant name: DISPID_VFG_ROWS
				// Use plain uppercase (no underscore insertion) to match legacy COM convention.
				cp.ConstName = "DISPID_" + axSvc.Prefix + "_" + strings.ToUpper(prop.Name)

				// Determine setter/getter RPC names
				setMethodName := "Set" + prop.Name
				getMethodName := "Get" + prop.Name
				if prop.SetMethod != "" {
					setMethodName = prop.SetMethod
				}
				if prop.GetMethod != "" {
					getMethodName = prop.GetMethod
				}

				setMethod := methodMap[setMethodName]
				getMethod := methodMap[getMethodName]

				// Compute native function names
				if setMethod != nil {
					cp.NativeSetFn = svcNativePrefix + "_" + toSnakeCase(setMethod.Name)
				}
				if getMethod != nil {
					cp.NativeGetFn = svcNativePrefix + "_" + toSnakeCase(getMethod.Name)
				}

				// Infer dispatch type
				if !prop.Custom {
					cp.DispatchType = inferDispatchType(prop, setMethod, getMethod, data.Messages)
				}

				data.ComProperties = append(data.ComProperties, cp)
			}
		}

		// Sort by DispId
		sort.Slice(data.ComProperties, func(i, j int) bool {
			return data.ComProperties[i].DispId < data.ComProperties[j].DispId
		})
	}

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

	// Build dependency headers for C++
	if lang == "cpp" {
		depFiles := make(map[string]bool)
		fileVisited := make(map[string]bool)
		ownPath := file.Desc.Path()
		for _, service := range file.Services {
			if !shouldGenerateService(service.GoName, serviceList) {
				continue
			}
			for _, method := range service.Methods {
				collectMessageFiles(method.Input, depFiles, fileVisited)
				collectMessageFiles(method.Output, depFiles, fileVisited)
			}
		}
		delete(depFiles, ownPath)
		for depPath := range depFiles {
			data.CppDepHeaders = append(data.CppDepHeaders, strings.TrimSuffix(depPath, ".proto")+".pb.h")
		}
		sort.Strings(data.CppDepHeaders)
	}

	return data
}

func shouldGenerateService(serviceName string, serviceList map[string]bool) bool {
	if len(serviceList) == 0 {
		return true
	}
	return serviceList[serviceName]
}

func hasGeneratedServices(file *protogen.File, serviceList map[string]bool) bool {
	for _, service := range file.Services {
		if shouldGenerateService(service.GoName, serviceList) {
			return true
		}
	}
	return false
}

func addDartImport(imports map[string]bool, file *protogen.File, protoPath, dartPackage string) {
	if protoPath == file.Desc.Path() {
		return
	}
	target := strings.TrimSuffix(protoPath, ".proto") + ".pb.dart"
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
