#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage:
  ${0} [--version <version>] [--file <path>]

Examples:
  ${0}
  ${0} --version 0.104.0
  ${0} --version v0.104.0
  ${0} --version rust-v0.104.0
  ${0} --file ${script_dir}/../package.nix

Environment overrides:
  CODEX_REPO_OWNER  GitHub owner (default: openai)
  CODEX_REPO_NAME   GitHub repo (default: codex)
  CODEX_TAG_PREFIX  Git tag prefix (default: rust-v)
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

normalize_version() {
  local raw="$1"
  raw="${raw#rust-v}"
  raw="${raw#v}"
  printf '%s' "$raw"
}

is_full_release_version() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

version=""
target_file="${script_dir}/../package.nix"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --file)
      target_file="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

repo_owner="${CODEX_REPO_OWNER:-openai}"
repo_name="${CODEX_REPO_NAME:-codex}"
tag_prefix="${CODEX_TAG_PREFIX:-rust-v}"

require_cmd curl
require_cmd git
require_cmd jq
require_cmd nix
require_cmd perl
require_cmd tar

if [[ ! -f "$target_file" ]]; then
  echo "Target file not found: $target_file" >&2
  exit 1
fi

target_dir="$(cd -- "$(dirname -- "$target_file")" && pwd)"
lock_file="${target_dir}/Cargo.lock"

if [[ -z "$version" ]]; then
  latest_tag="$(
    git ls-remote --tags --refs "https://github.com/${repo_owner}/${repo_name}.git" "${tag_prefix}*" \
      | awk '{ print $2 }' \
      | sed 's@refs/tags/@@' \
      | grep -E "^${tag_prefix}[0-9]+\.[0-9]+\.[0-9]+$" \
      | sort -V \
      | tail -n1
  )"

  if [[ -z "$latest_tag" ]]; then
    echo "Failed to resolve latest stable tag from ${repo_owner}/${repo_name}" >&2
    exit 1
  fi

  version="$(normalize_version "$latest_tag")"
else
  version="$(normalize_version "$version")"
fi

if [[ -z "$version" ]]; then
  echo "Resolved version is empty" >&2
  exit 1
fi

if ! is_full_release_version "$version"; then
  echo "Only full release versions are supported (X.Y.Z). Received: $version" >&2
  exit 1
fi

tag="${tag_prefix}${version}"
source_url="https://github.com/${repo_owner}/${repo_name}/archive/${tag}.tar.gz"

echo "Updating codex package definition"
echo "  repo:    ${repo_owner}/${repo_name}"
echo "  version: ${version}"
echo "  tag:     ${tag}"

source_hash="$(
  nix store prefetch-file --json --unpack "$source_url" \
    | jq -r '.hash'
)"

if [[ ! "$source_hash" =~ ^sha256- ]]; then
  echo "Failed to resolve source hash from: $source_url" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

curl -fsSL "$source_url" -o "$tmpdir/source.tar.gz"
tar -xzf "$tmpdir/source.tar.gz" -C "$tmpdir"

source_lockfile="$(find "$tmpdir" -maxdepth 3 -type f -path '*/codex-rs/Cargo.lock' | head -n1)"
if [[ -z "$source_lockfile" ]]; then
  echo "Could not find codex-rs/Cargo.lock in fetched source archive" >&2
  exit 1
fi

cp "$source_lockfile" "$lock_file"

VERSION="$version" perl -0pi -e 's/(\n\s*version = )"[^"]+";/$1 . "\"" . $ENV{VERSION} . "\";"/e' "$target_file"
SOURCE_HASH="$source_hash" perl -0pi -e 's/(src = fetchFromGitHub \{.*?\n\s*hash = )"sha256-[^"]+";/$1 . "\"" . $ENV{SOURCE_HASH} . "\";"/se' "$target_file"

echo "Updated: $target_file"
echo "  version:   $version"
echo "  src.hash:  $source_hash"
echo "  lock file: $lock_file"
