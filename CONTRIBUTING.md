# Contributing to Synurang

First off, thanks for taking the time to contribute! 🎉

The following is a set of guidelines for contributing to Synurang. These are mostly guidelines, not rules. Use your best judgment, and feel free to propose changes to this document in a pull request.

## How to Contribute

### Reporting Bugs

This section guides you through submitting a bug report for Synurang. Following these guidelines helps maintainers and the community understand your report, reproduce the behavior, and find related reports.

- **Use a clear and descriptive title** for the issue to identify the problem.
- **Describe the exact steps to reproduce the problem** in as much detail as possible.
- **Provide specific examples** to demonstrate the steps.
- **Describe the behavior you observed after following the steps** and point out what exactly is the problem with that behavior.
- **Explain which behavior you expected to see instead and why.**

### Pull Requests

1. **Fork the repo** and create your branch from `main`.
2. **Run tests** to ensure your changes don't break existing functionality:
   ```bash
   make test
   ```
3. **Format your code**:
   - Go: `gofmt -w .`
   - Dart: `dart format .`
   - Rust generator: `cargo fmt --manifest-path cmd/protoc-gen-synurang-ffi/Cargo.toml`
4. **Ensure your code lints**:
   - Go: `go vet ./...`
   - Dart: `dart analyze`
   - Rust generator: `cargo clippy --locked --manifest-path cmd/protoc-gen-synurang-ffi/Cargo.toml --all-targets`
5. **Open a Pull Request**!

## Development Setup

### Prerequisites

- Go 1.22+
- Flutter 3.19+
- Rust 1.80+ and Cargo
- Python 3.10+ for Python host/codegen work
- Protobuf Compiler (`protoc`)
- Make
- Docker for cross-platform generator release bundles

### Building

```bash
# Install dependencies
make pub_get

# Generate proto code
make proto

# Build the canonical Rust code generator
make build_plugin

# Build shared library
make shared_linux
```

### Running Tests

```bash
make test

# Focused Rust generator regression suite
make test_codegen

# Python runtime, codegen, and host checks
make test_python

# Optional real remote-gRPC integration (requires ./python[grpc])
make test_python_grpc
```

The generator implementation is Rust even when it emits `lang=go`; do not add
a second language-specific generator binary. The installed executable must
remain `protoc-gen-synurang-ffi` so `protoc --synurang-ffi_out` can discover it.

### Generator Releases

Generator release binaries are built in `Dockerfile.codegen`, not with the
host toolchain. `CODEGEN_VERSION` is mandatory; a leading `v` is accepted.

```bash
# Build Linux x86-64/AArch64 and Windows x86-64 bundles plus SHA256SUMS
make docker_codegen CODEGEN_VERSION=0.6.3

# From a clean checkout, tag the release commit and push the tag first
git tag -a v0.6.3 -m v0.6.3
git push origin v0.6.3

# Build and publish v0.6.3 (requires an authenticated GitHub CLI)
make publish_github_codegen CODEGEN_VERSION=0.6.3
```

Artifacts are written to `dist/codegen`. Use `CODEGEN_TARGETS` to select a
whitespace-separated subset, `CODEGEN_DOCKER_IMAGE` to change the build image,
`CODEGEN_DIST_DIR` to change the output directory, and `CODEGEN_GITHUB_REPO`
to publish to a fork. Publishing verifies that the local and remote tag both
point at the clean checkout and will not mutate an existing release.
`make publish_github` is an alias for the generator publishing target.

## Styleguides

### Go Styleguide

- Follow [Effective Go](https://golang.org/doc/effective_go.html).
- use `gofmt` to format your code.

### Dart Styleguide

- Follow the [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style).
- Use `dart format` to format your code.

### Rust Styleguide

- Run `cargo fmt` and keep the generator warning-free under `cargo clippy`.

### Python Styleguide

- Support Python 3.10 and newer; Python 2 compatibility is not a goal.
- Keep the core FFI host free of mandatory third-party dependencies.

## License

By contributing, you agree that your contributions will be licensed under its MIT License.
