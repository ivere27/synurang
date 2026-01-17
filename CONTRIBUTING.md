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
4. **Ensure your code lints**:
   - Go: `go vet ./...`
   - Dart: `dart analyze`
5. **Open a Pull Request**!

## Development Setup

### Prerequisites

- Go 1.21+
- Flutter 3.10+
- Protobuf Compiler (`protoc`)
- Make

### Building

```bash
# Install dependencies
make pub_get

# Generate proto code
make proto

# Build shared library
make shared_linux
```

### Running Tests

```bash
make test
```

## Styleguides

### Go Styleguide

- Follow [Effective Go](https://golang.org/doc/effective_go.html).
- use `gofmt` to format your code.

### Dart Styleguide

- Follow the [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style).
- Use `dart format` to format your code.

## License

By contributing, you agree that your contributions will be licensed under its MIT License.
