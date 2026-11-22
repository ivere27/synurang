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

### Releases & CI/CD

All build verification and GitHub Release packaging runs transparently via [`.github/workflows/build.yml`](.github/workflows/build.yml) and [`scripts/release.py`](scripts/release.py):

- **Pushes to `main`**: Update the rolling `nightly` GitHub pre-release with all verified archives and `SHA256SUMS` (no external registry pushes).
- **Pre-release tags (`vX.Y.Z-rc.N`, `-alpha.N`, `-beta.N`, `-dev.N`)**: Run all verification and artifact builds and publish only to GitHub Releases as a pre-release (external registry jobs are skipped).
- **Stable tags (`vX.Y.Z`)**: Verify version consistency and `CHANGELOG.md`, build and checksum-verify all artifacts (`protoc-gen-synurang-ffi` for Linux musl x64/arm64, Windows x64, macOS arm64/x64; Maven Android AARs & Desktop JARs; Python sdist & wheel; Flutter `pub publish --dry-run`), stage and checksum-verify a draft GitHub Release, run any enabled external publish jobs, and promote the GitHub Release to public.
  - External registry publish jobs are **opt-in** via GitHub Repository Variables (disabled by default so no signing keys or tokens need to live on GitHub when publishing Maven locally):
    - `SYNURANG_PUBLISH_MAVEN=true` (`maven-central` environment): Uses Sonatype Central Portal Publisher API (`POST /api/v1/publisher/upload` as one atomic bundle + `/status` polling). Requires `SONATYPE_USERNAME`, `SONATYPE_PASSWORD`, `MAVEN_GPG_PRIVATE_KEY` (raw ASCII-armored PGP private key text, *not* Base64-wrapped), and `MAVEN_GPG_PASSPHRASE` (optional only if the key has no passphrase).
    - `SYNURANG_PUBLISH_PYPI=true` (`pypi` environment): Uses OIDC Trusted Publishing (`id-token: write`).
    - `SYNURANG_PUBLISH_PUBDEV=true` (`pub-dev` environment): Uses OIDC Automated Publishing (`id-token: write`).

To keep your GPG private key and Sonatype credentials purely local while still letting GitHub Actions cross-compile and verify the Maven AAR/JAR artifacts, push a `vX.Y.Z` tag and then run local verification, GPG signing, and atomic Maven Central upload against the published GitHub Release:

```bash
# Dry-run download + verification first (no GPG signing or upload):
make publish_maven_release TAG=vX.Y.Z DRY_RUN=1

# Download Maven artifacts + SHA256SUMS from GitHub Release vX.Y.Z, verify digests & JNI/POMs,
# sign with your local GPG keyring (gpg-agent caching avoids repeated prompts across 16 signatures),
# and upload one atomic bundle via .maven-settings.xml (<id>central</id>)
make publish_maven_release TAG=vX.Y.Z

# Useful Make overrides:
# - REPO=owner/repo                    select a different GitHub repository when downloading a release
# - MAVEN_SERVER_ID=sonatype           select a different <server><id> in .maven-settings.xml
# - MAVEN_GPG_KEY=<key-id>             select a specific local GPG signing key (--local-user)
# - MAVEN_REPO_URL / MAVEN_STATUS_URL  override Sonatype Central Portal upload/status endpoints
# - ALLOW_DRAFT=1 / ALLOW_PRERELEASE=1 allow publishing from a draft or prerelease tag (default: disabled)

# Or publish artifacts already built locally into dist/maven:
make publish_maven
```

Prefer standard `gpg-agent` caching so pinentry prompts once across all 16 artifact signatures. When using `.maven-settings.xml`, `<password>` must be your plaintext Sonatype Central User Token (Maven-encrypted `{...}` passwords from `mvn --encrypt-password` are not supported). If `gpg-agent` caching is off (or you provide Sonatype credentials via `SONATYPE_USERNAME`/`SONATYPE_PASSWORD` instead of `.maven-settings.xml`), export secrets via environment variables rather than passing them as `make` command-line arguments (which exposes plaintext values in shell history and `ps`):

```bash
read -rsp "GPG passphrase: " MAVEN_GPG_PASSPHRASE; echo
export MAVEN_GPG_PASSPHRASE
make publish_maven_release TAG=vX.Y.Z
unset MAVEN_GPG_PASSPHRASE
```

`scripts/release.py set-version` and `check-versions` synchronize all version-locked and published artifacts (`pubspec.yaml`, Python metadata formatted as PEP 440, CocoaPods `.podspec` files, Docker/Makefile build scripts, and `README.md` install snippets). Unpublished workspace Rust crates (`crates/*`, `rust/synurang`, `cmd/protoc-gen-synurang-ffi`), `typescript/` (`"private": true`), and `csharp/Synurang` are intentionally versioned independently.

By default, `release-ci` rejects tags older than the highest published stable release to prevent accidental version downgrades. For intentional maintenance backport releases on an older series (e.g., releasing `v0.8.1` after `v0.9.0`), set the GitHub Repository Variable `SYNURANG_ALLOW_OLDER_RELEASE=1` (forwarded to `prepare-release` in `.github/workflows/build.yml`, or pass `--allow-older` / `SYNURANG_ALLOW_OLDER_RELEASE=1` when running `scripts/release.py release-ci` via CLI); `finalize-stable` will automatically publish with `--latest=false` so the newer stable series retains GitHub's `Latest` badge.

Before tagging a release, synchronize versions and add a `## X.Y.Z` section to `CHANGELOG.md` (note: PyPI-incompatible prereleases requiring `+` local versions are rejected; use `-alpha.N`, `-beta.N`, `-rc.N`, or `-dev.N`):

```bash
python3 scripts/release.py set-version X.Y.Z
make check_versions test_release

# Commit changes, then tag and push to trigger the automated release pipeline
git tag -a vX.Y.Z -m vX.Y.Z
git push origin vX.Y.Z
```

For local generator cross-compilation in `Dockerfile.codegen`:

```bash
# Build Linux x86-64/AArch64 musl and Windows x86-64 GNU bundles plus SHA256SUMS
make docker_codegen CODEGEN_VERSION=X.Y.Z

# Build and publish a tag locally (requires an authenticated GitHub CLI)
make publish_github_codegen CODEGEN_VERSION=X.Y.Z
```

Local artifacts are written to `dist/codegen`. Use `CODEGEN_TARGETS` to select a
whitespace-separated subset, `CODEGEN_DOCKER_IMAGE` to change the build image,
`CODEGEN_DIST_DIR` to change the output directory, and `CODEGEN_GITHUB_REPO`
to publish to a fork. Local publishing verifies that the local and remote tag both
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
