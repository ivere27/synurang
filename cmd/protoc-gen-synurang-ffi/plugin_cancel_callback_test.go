package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// These tests drive the *public* Synurang FFI surface only:
//   - Synurang_Stream_<Service>_Open / _Send / _Recv / _CloseSend / _Close
//   - PluginStream::on_cancel (Rust) / OnCancel (C++)
//
// They never reach into generated internals (StreamContext, register_cancel_callback,
// close_stream_context, struct field layout). The behavioural fixtures live as
// real source files under testdata/ so they get formatter, syntax highlighting,
// and reviewable diffs.
//
// Set SYNURANG_REQUIRE_NATIVE_TESTS=1 in CI to fail loudly when toolchains are
// missing. Locally the tests skip cleanly.

func TestRustPluginServerCancelCallbacks(t *testing.T) {
	requireTool(t, "protoc")
	requireTool(t, "cargo")

	packageDir, repoRoot := testDirs(t)
	tmp := t.TempDir()
	generator := buildTestGenerator(t, packageDir, tmp)
	genDir := generateExamplePluginServer(t, repoRoot, tmp, generator, "rust")

	crateDir := filepath.Join(tmp, "rust-cancel-callbacks")
	mustMkdirAll(t, filepath.Join(crateDir, "src"))

	servicePath := filepath.ToSlash(filepath.Join(repoRoot, "example", "rust", "service"))
	cargoTmpl := readFixture(t, packageDir, "rust", "Cargo.toml.in")
	writeFile(t, filepath.Join(crateDir, "Cargo.toml"),
		strings.ReplaceAll(cargoTmpl, "@SERVICE_PATH@", servicePath))

	generated, err := os.ReadFile(filepath.Join(genDir, "example_ffi_plugin.rs"))
	if err != nil {
		t.Fatal(err)
	}
	suffix := readFixture(t, packageDir, "rust", "lib_suffix.rs")
	writeFile(t, filepath.Join(crateDir, "src", "lib.rs"), string(generated)+"\n"+suffix)

	cmd := exec.Command("cargo", "test", "--", "--nocapture")
	cmd.Dir = crateDir
	cmd.Env = append(os.Environ(), "CARGO_TARGET_DIR="+sharedCargoTarget(t, tmp))
	runCmd(t, cmd)
}

func TestCppPluginServerCancelCallbacks(t *testing.T) {
	requireTool(t, "protoc")
	requireTool(t, "g++")

	packageDir, repoRoot := testDirs(t)
	tmp := t.TempDir()
	generator := buildTestGenerator(t, packageDir, tmp)
	genDir := generateExamplePluginServer(t, repoRoot, tmp, generator, "cpp")

	runCmd(t, commandIn(repoRoot, "protoc",
		"-Iexample/api",
		"-Iapi",
		"-I/usr/include",
		"--cpp_out="+genDir,
		"example.proto",
		"core.proto",
	))

	testSrc := readFixture(t, packageDir, "cpp", "cancel_callback_test.cc")
	testFile := filepath.Join(genDir, "cancel_callback_test.cc")
	writeFile(t, testFile, testSrc)

	exe := filepath.Join(tmp, "cpp-cancel-callback-test")
	runCmd(t, commandIn(repoRoot, "g++",
		"-std=c++17",
		"-O2",
		"-pthread",
		"-Wall",
		"-Wextra",
		"-Wno-unused-parameter",
		"-I"+genDir,
		"-I/usr/include",
		testFile,
		filepath.Join(genDir, "example_ffi_plugin.cc"),
		filepath.Join(genDir, "example.pb.cc"),
		filepath.Join(genDir, "core.pb.cc"),
		"-lprotobuf",
		"-o", exe,
	))
	runCmd(t, commandIn(repoRoot, exe))
}

// -----------------------------------------------------------------------------
// helpers
// -----------------------------------------------------------------------------

func requireTool(t *testing.T, name string) {
	t.Helper()
	if _, err := exec.LookPath(name); err != nil {
		if os.Getenv("SYNURANG_REQUIRE_NATIVE_TESTS") == "1" {
			t.Fatalf("required tool %q not found (SYNURANG_REQUIRE_NATIVE_TESTS=1)", name)
		}
		t.Skipf("%s not found", name)
	}
}

func testDirs(t *testing.T) (string, string) {
	t.Helper()
	packageDir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	repoRoot, err := filepath.Abs(filepath.Join(packageDir, "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return packageDir, repoRoot
}

func buildTestGenerator(t *testing.T, packageDir, tmp string) string {
	t.Helper()
	name := "protoc-gen-synurang-ffi"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	generator := filepath.Join(tmp, name)
	runCmd(t, commandIn(packageDir, "go", "build", "-o", generator, "."))
	return generator
}

func generateExamplePluginServer(t *testing.T, repoRoot, tmp, generator, lang string) string {
	t.Helper()
	outDir := filepath.Join(tmp, lang+"-generated")
	mustMkdirAll(t, outDir)
	runCmd(t, commandIn(repoRoot, "protoc",
		"-Iexample/api",
		"-Iapi",
		"-I/usr/include",
		"--plugin=protoc-gen-synurang-ffi="+generator,
		"--synurang-ffi_out="+outDir,
		"--synurang-ffi_opt=lang="+lang+",mode=plugin_server,services=GoGreeterService",
		"example.proto",
	))
	return outDir
}

func readFixture(t *testing.T, packageDir string, parts ...string) string {
	t.Helper()
	all := append([]string{packageDir, "testdata", "cancel_callback"}, parts...)
	path := filepath.Join(all...)
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture %s: %v", path, err)
	}
	return string(b)
}

// sharedCargoTarget returns a stable per-package target dir so cargo test
// across reruns / test cases reuses the prost + synurang_service build.
// Falls back to a per-test temp dir if the user cache is unavailable.
func sharedCargoTarget(t *testing.T, fallback string) string {
	t.Helper()
	if env := os.Getenv("SYNURANG_TEST_CARGO_TARGET"); env != "" {
		return env
	}
	if cache, err := os.UserCacheDir(); err == nil {
		dir := filepath.Join(cache, "synurang-tests", "cargo-target")
		if err := os.MkdirAll(dir, 0o755); err == nil {
			return dir
		}
	}
	return filepath.Join(fallback, "rust-target")
}

func commandIn(dir, name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	return cmd
}

func runCmd(t *testing.T, cmd *exec.Cmd) {
	t.Helper()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s failed: %v\n%s", cmd.String(), err, out)
	}
}

func mustMkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}
