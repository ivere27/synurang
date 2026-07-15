#!/usr/bin/env bash
set -euo pipefail

readonly CANONICAL_BINARY="protoc-gen-synurang-ffi"
readonly DEFAULT_TARGETS=(
  x86_64-unknown-linux-musl
  aarch64-unknown-linux-musl
  x86_64-pc-windows-gnu
)

die() {
  echo "Error: $*" >&2
  exit 1
}

validate_target() {
  case "$1" in
    x86_64-unknown-linux-musl|aarch64-unknown-linux-musl|x86_64-pc-windows-gnu) ;;
    *)
      die "unknown codegen target '$1' (expected: ${DEFAULT_TARGETS[*]})"
      ;;
  esac
}

validate_build_jobs() {
  if [[ -n "${CARGO_BUILD_JOBS:-}" ]] && \
      ! [[ "${CARGO_BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    die "CARGO_BUILD_JOBS must be a positive integer, got '${CARGO_BUILD_JOBS}'"
  fi
}

# The same file is the host-side Docker wrapper and the image entrypoint. This
# keeps the release flow in one command while ensuring all compilation happens
# in the pinned image.
if [[ "${SYNURANG_CODEGEN_IN_DOCKER:-0}" != "1" ]]; then
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(cd "${script_dir}/.." && pwd)"
  image_tag="${CODEGEN_DOCKER_IMAGE:-synurang-codegen-release:latest}"
  docker_platform="${CODEGEN_DOCKER_PLATFORM:-linux/amd64}"
  dist_dir="${CODEGEN_DIST_DIR:-${repo_root}/dist/codegen}"
  requested_targets=("$@")

  if [[ "${dist_dir}" != /* ]]; then
    dist_dir="${repo_root}/${dist_dir}"
  fi
  mkdir -p "${dist_dir}"
  dist_dir="$(cd "${dist_dir}" && pwd)"

  command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
  [[ -f "${repo_root}/Dockerfile.codegen" ]] || \
    die "Dockerfile.codegen not found at ${repo_root}/Dockerfile.codegen"
  [[ -n "${CODEGEN_VERSION:-}" ]] || \
    die "CODEGEN_VERSION is required (for example: CODEGEN_VERSION=0.7.2 $0)"
  validate_build_jobs

  if [[ "${#requested_targets[@]}" -eq 0 && -n "${CODEGEN_TARGETS:-}" ]]; then
    # CODEGEN_TARGETS is a whitespace-separated list for Make/CI callers.
    read -r -a requested_targets <<< "${CODEGEN_TARGETS}"
  fi
  if [[ "${#requested_targets[@]}" -eq 0 ]]; then
    requested_targets=("${DEFAULT_TARGETS[@]}")
  fi
  for target in "${requested_targets[@]}"; do
    validate_target "${target}"
  done

  source_date_epoch="${SOURCE_DATE_EPOCH:-}"
  if [[ -z "${source_date_epoch}" ]]; then
    source_date_epoch="$(git -C "${repo_root}" log -1 --format=%ct 2>/dev/null || true)"
  fi
  source_date_epoch="${source_date_epoch:-315532800}"

  echo "Building Docker image: ${image_tag} (${docker_platform})"
  docker build \
    --platform "${docker_platform}" \
    --tag "${image_tag}" \
    --file "${repo_root}/Dockerfile.codegen" \
    "${repo_root}"

  run_args=(
    --rm
    --platform "${docker_platform}"
    --user "$(id -u):$(id -g)"
    --env SYNURANG_CODEGEN_IN_DOCKER=1
    --env REPO_ROOT=/workspace/synurang
    --env HOME=/tmp
    --env "SOURCE_DATE_EPOCH=${source_date_epoch}"
    --volume "${repo_root}:/workspace/synurang"
    --volume "${dist_dir}:/workspace/codegen-dist"
    --env DIST_DIR=/workspace/codegen-dist
    --workdir /workspace/synurang
  )
  for variable in CODEGEN_VERSION CARGO_BUILD_JOBS; do
    if [[ -n "${!variable:-}" ]]; then
      run_args+=(--env "${variable}=${!variable}")
    fi
  done

  echo "Building release bundles: ${requested_targets[*]}"
  docker run "${run_args[@]}" "${image_tag}" "${requested_targets[@]}"
  echo "Artifacts: ${dist_dir}"
  exit 0
fi

repo_root="${REPO_ROOT:-$(pwd)}"
crate_dir="${repo_root}/cmd/protoc-gen-synurang-ffi"
manifest="${crate_dir}/Cargo.toml"
lockfile="${crate_dir}/Cargo.lock"
dist_dir="${DIST_DIR:-${repo_root}/dist/codegen}"
target_dir="${CARGO_TARGET_DIR:-${repo_root}/target/codegen-release}"
requested_targets=("$@")

[[ -f "${manifest}" ]] || die "Rust generator manifest not found: ${manifest}"
[[ -f "${lockfile}" ]] || die "Rust generator lockfile not found: ${lockfile}"
[[ -f "${repo_root}/LICENSE" ]] || die "license file not found: ${repo_root}/LICENSE"

if [[ "${#requested_targets[@]}" -eq 0 ]]; then
  requested_targets=("${DEFAULT_TARGETS[@]}")
fi
for target in "${requested_targets[@]}"; do
  validate_target "${target}"
done

version="${CODEGEN_VERSION:-}"
[[ -n "${version}" ]] || \
  die "CODEGEN_VERSION is required (it is the GitHub release version, not the Cargo package version)"
version="${version#v}"
[[ "${version}" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || \
  die "CODEGEN_VERSION contains unsafe archive-name characters: '${version}'"

source_date_epoch="${SOURCE_DATE_EPOCH:-315532800}"
[[ "${source_date_epoch}" =~ ^[0-9]+$ ]] || \
  die "SOURCE_DATE_EPOCH must be an integer, got '${source_date_epoch}'"
# ZIP's timestamp format starts in 1980.
[[ "${source_date_epoch}" -ge 315532800 ]] || \
  die "SOURCE_DATE_EPOCH must be 315532800 (1980-01-01) or later"
validate_build_jobs

cargo_binary="$(awk '
  /^\[package\]$/ { in_package = 1; next }
  /^\[/ { in_package = 0 }
  in_package && $1 == "name" {
    value = $3
    gsub(/"/, "", value)
    print value
    exit
  }
' "${manifest}")"
[[ -n "${cargo_binary}" ]] || die "could not determine the Cargo binary name from ${manifest}"

export CARGO_TARGET_DIR="${target_dir}"
export CARGO_INCREMENTAL=0
export TZ=UTC
export LC_ALL=C
export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc
export RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }--remap-path-prefix=${repo_root}=."

mkdir -p "${dist_dir}"
find "${dist_dir}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
work_dir="$(mktemp -d /tmp/synurang-codegen-release-XXXXXX)"
cleanup() {
  rm -rf "${work_dir}"
}
trap cleanup EXIT

smoke_test_native_generator() {
  local binary="$1"
  local smoke_root="${work_dir}/smoke"
  local go_out="${smoke_root}/go-out"
  local python_out="${smoke_root}/python-out"
  mkdir -p "${go_out}" "${python_out}"

  cat > "${smoke_root}/smoke.proto" <<'PROTO'
syntax = "proto3";
package synurang.release.smoke;
option go_package = "example.com/synurang/release/smoke";

message PingRequest {}
message PingResponse {}

service SmokeService {
  rpc Ping(PingRequest) returns (PingResponse);
}
PROTO

  protoc \
    --proto_path="${smoke_root}" \
    --plugin="protoc-gen-synurang-ffi=${binary}" \
    --synurang-ffi_out="${go_out}" \
    --synurang-ffi_opt=lang=go \
    smoke.proto

  local generated="${go_out}/smoke_ffi.pb.go"
  [[ -s "${generated}" ]] || \
    die "protoc smoke test did not produce the expected non-empty file: ${generated}"
  grep -q 'SmokeService' "${generated}" || \
    die "protoc smoke-test output does not contain SmokeService: ${generated}"

  protoc \
    --proto_path="${smoke_root}" \
    --plugin="protoc-gen-synurang-ffi=${binary}" \
    --synurang-ffi_out="${python_out}" \
    --synurang-ffi_opt=lang=python \
    smoke.proto

  [[ -s "${python_out}/smoke_lite.py" ]] || \
    die "Python smoke test did not produce smoke_lite.py"
  [[ -s "${python_out}/smoke_ffi.py" ]] || \
    die "Python smoke test did not produce smoke_ffi.py"
  python3 -m py_compile "${python_out}/smoke_lite.py" "${python_out}/smoke_ffi.py"
  grep -q 'class SmokeServiceClient' "${python_out}/smoke_ffi.py" || \
    die "Python smoke test did not produce the neutral service client"
  grep -q 'class SmokeServiceFfi' "${python_out}/smoke_ffi.py" || \
    die "Python smoke test did not preserve the FFI compatibility client"
  echo "Passed protoc smoke tests for Go and Python"
}

package_target() {
  local triple="$1"
  local source_name="${cargo_binary}"
  local installed_name="${CANONICAL_BINARY}"
  local archive_ext="tar.gz"

  if [[ "${triple}" == *-windows-* ]]; then
    source_name+=".exe"
    installed_name+=".exe"
    archive_ext="zip"
  fi

  local built_binary="${target_dir}/${triple}/release/${source_name}"
  [[ -f "${built_binary}" ]] || \
    die "Cargo succeeded but expected binary is missing: ${built_binary}"

  if [[ "${triple}" == *-linux-musl ]]; then
    if readelf -l "${built_binary}" | grep -q 'INTERP'; then
      die "Linux release binary is dynamically linked (PT_INTERP present): ${built_binary}"
    fi
    if readelf -d "${built_binary}" 2>/dev/null | grep -q 'NEEDED'; then
      die "Linux release binary has dynamic dependencies: ${built_binary}"
    fi
  fi

  local bundle_name="${CANONICAL_BINARY}-${version}-${triple}"
  local bundle_root="${work_dir}/${bundle_name}"
  local archive="${dist_dir}/${bundle_name}.${archive_ext}"
  mkdir -p "${bundle_root}"
  install -m 0755 "${built_binary}" "${bundle_root}/${installed_name}"
  install -m 0644 "${repo_root}/LICENSE" "${bundle_root}/LICENSE"
  find "${bundle_root}" -exec touch -h -d "@${source_date_epoch}" {} +

  if [[ "${archive_ext}" == "zip" ]]; then
    (
      cd "${work_dir}"
      find "${bundle_name}" -print | sort | zip -X -q "${archive}" -@
    )
    unzip -tq "${archive}" >/dev/null || die "archive verification failed: ${archive}"
  else
    tar \
      --sort=name \
      --format=ustar \
      --mtime="@${source_date_epoch}" \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      -C "${work_dir}" \
      -cf - "${bundle_name}" | gzip -n > "${archive}"
    tar -tzf "${archive}" >/dev/null || die "archive verification failed: ${archive}"
  fi

  echo "Built: ${archive}"
}

echo "Generator version: ${version}"
echo "SOURCE_DATE_EPOCH: ${source_date_epoch}"
cargo_args=(
  --release
  --locked
  --manifest-path "${manifest}"
)
if [[ -n "${CARGO_BUILD_JOBS:-}" ]]; then
  cargo_args+=(--jobs "${CARGO_BUILD_JOBS}")
fi
for triple in "${requested_targets[@]}"; do
  echo "Building ${triple}..."
  if [[ "${triple}" == *-linux-musl ]]; then
    cargo zigbuild "${cargo_args[@]}" --target "${triple}"
  else
    cargo build "${cargo_args[@]}" --target "${triple}"
  fi
  if [[ "${triple}" == x86_64-unknown-linux-musl ]]; then
    smoke_test_native_generator \
      "${target_dir}/${triple}/release/${cargo_binary}"
  fi
  package_target "${triple}"
done

mapfile -d '' archives < <(
  find "${dist_dir}" -maxdepth 1 -type f \
    \( -name '*.tar.gz' -o -name '*.zip' \) \
    -printf '%f\0' | sort -z
)
[[ "${#archives[@]}" -gt 0 ]] || die "no release archives were produced"
(
  cd "${dist_dir}"
  sha256sum "${archives[@]}" > SHA256SUMS
  sha256sum --check --strict SHA256SUMS >/dev/null
)

echo "Built checksum manifest: ${dist_dir}/SHA256SUMS"
find "${dist_dir}" -maxdepth 1 -type f -printf '%f\t%s bytes\n' | sort
