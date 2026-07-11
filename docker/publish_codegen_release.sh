#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_TARGETS=(
  x86_64-unknown-linux-musl
  aarch64-unknown-linux-musl
  x86_64-pc-windows-gnu
)

die() {
  echo "Error: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
version="${CODEGEN_VERSION:-}"
version="${version#v}"
[[ -n "${version}" ]] || die "CODEGEN_VERSION is required"
[[ "${version}" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || \
  die "CODEGEN_VERSION contains unsafe characters: '${version}'"

tag="v${version}"
github_repo="${CODEGEN_GITHUB_REPO:-ivere27/synurang}"
[[ "${github_repo}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
  die "CODEGEN_GITHUB_REPO must be OWNER/REPO, got '${github_repo}'"

dist_dir="${CODEGEN_DIST_DIR:-${repo_root}/dist/codegen}"
if [[ "${dist_dir}" != /* ]]; then
  dist_dir="${repo_root}/${dist_dir}"
fi

command -v git >/dev/null 2>&1 || die "git is not installed or not in PATH"
command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is not installed or not in PATH"

assert_release_source() {
  local status head local_tag remote_tag
  status="$(git -C "${repo_root}" status --porcelain --untracked-files=normal)"
  [[ -z "${status}" ]] || \
    die "refusing to publish from a dirty checkout; commit or remove all changes first"

  head="$(git -C "${repo_root}" rev-parse HEAD)"
  local_tag="$(git -C "${repo_root}" rev-parse -q --verify "refs/tags/${tag}^{commit}" 2>/dev/null)" || \
    die "local tag ${tag} does not exist; create it at the release commit and push it first"
  [[ "${local_tag}" == "${head}" ]] || \
    die "local tag ${tag} points to ${local_tag}, but HEAD is ${head}"

  remote_tag="$(gh api "repos/${github_repo}/commits/${tag}" --jq .sha 2>/dev/null)" || \
    die "remote tag ${tag} was not found in ${github_repo}; push it first"
  [[ "${remote_tag}" == "${head}" ]] || \
    die "remote tag ${tag} points to ${remote_tag}, but the checkout is ${head}"
}

assert_release_source
if gh release view "${tag}" --repo "${github_repo}" >/dev/null 2>&1; then
  die "release ${tag} already exists in ${github_repo}; release assets are immutable in this workflow"
fi

targets=()
if [[ -n "${CODEGEN_TARGETS:-}" ]]; then
  read -r -a targets <<< "${CODEGEN_TARGETS}"
else
  targets=("${DEFAULT_TARGETS[@]}")
fi
[[ "${#targets[@]}" -gt 0 ]] || die "CODEGEN_TARGETS did not contain any targets"

CODEGEN_VERSION="${version}" \
CODEGEN_DIST_DIR="${dist_dir}" \
  bash "${script_dir}/build_codegen_release.sh" "${targets[@]}"

# Check again after the potentially long build so the published bytes are tied
# to the same clean, pushed commit that passed the initial preflight.
assert_release_source
if gh release view "${tag}" --repo "${github_repo}" >/dev/null 2>&1; then
  die "release ${tag} was created while the build was running; refusing to modify it"
fi

checksum_file="${dist_dir}/SHA256SUMS"
[[ -f "${checksum_file}" ]] || die "missing checksum manifest: ${checksum_file}"
(
  cd "${dist_dir}"
  sha256sum --check --strict SHA256SUMS
)

assets=()
for target in "${targets[@]}"; do
  case "${target}" in
    x86_64-unknown-linux-musl|aarch64-unknown-linux-musl)
      extension="tar.gz"
      ;;
    x86_64-pc-windows-gnu)
      extension="zip"
      ;;
    *)
      die "unknown codegen target '${target}'"
      ;;
  esac
  asset="${dist_dir}/protoc-gen-synurang-ffi-${version}-${target}.${extension}"
  [[ -f "${asset}" ]] || die "missing release asset: ${asset}"
  assets+=("${asset}")
done

# Read the annotated tag's message for the release notes instead of gh's
# --notes-from-tag, which older gh versions (< 2.31) do not support. The remote
# tag is already verified against HEAD by assert_release_source, so --verify-tag
# is redundant and likewise omitted for compatibility with older gh.
tag_notes="$(git -C "${repo_root}" tag -l --format='%(contents)' "${tag}")"
[[ -n "${tag_notes}" ]] || tag_notes="${tag}"

release_flags=(
  --repo "${github_repo}"
  --title "${tag}"
  --notes-file -
)
if [[ "${version}" == *-* ]]; then
  release_flags+=(--prerelease)
fi

# gh creates a draft internally while it uploads positional assets, and only
# publishes after every upload succeeds. A failed upload therefore cannot
# leave a partially populated public release.
printf '%s\n' "${tag_notes}" | gh release create "${tag}" \
  "${release_flags[@]}" \
  "${assets[@]}" "${checksum_file}"

echo "Published ${tag} to ${github_repo}"
