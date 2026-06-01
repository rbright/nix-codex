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

require_option_value() {
  local option="$1"
  local value="${2:-}"

  if [[ -z "$value" ]]; then
    echo "Missing value for $option" >&2
    usage >&2
    exit 1
  fi
}

version=""
target_file="${script_dir}/../package.nix"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      require_option_value "$1" "${2:-}"
      version="$2"
      shift 2
      ;;
    --file)
      require_option_value "$1" "${2:-}"
      target_file="$2"
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

require_cmd awk
require_cmd git
require_cmd jq
require_cmd nix
require_cmd perl

if [[ ! -f "$target_file" ]]; then
  echo "Target file not found: $target_file" >&2
  exit 1
fi

target_dir="$(cd -- "$(dirname -- "$target_file")" && pwd)"
lock_file="${target_dir}/Cargo.lock"

if [[ -z "$version" ]]; then
  latest_tag="$(
    git ls-remote --tags --refs "https://github.com/${repo_owner}/${repo_name}.git" "${tag_prefix}*" \
      | awk -v prefix="$tag_prefix" '
        {
          tag = $2
          sub(/^refs\/tags\//, "", tag)
          if (index(tag, prefix) != 1) {
            next
          }

          version = substr(tag, length(prefix) + 1)
          if (version ~ /^[0-9]+\.[0-9]+\.[0-9]+$/) {
            print tag
          }
        }
      ' \
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

source_prefetch_json="$(nix store prefetch-file --json --unpack "$source_url")"
source_hash="$(jq -r '.hash' <<<"$source_prefetch_json")"
source_store_path="$(jq -r '.storePath // .path // empty' <<<"$source_prefetch_json")"

if [[ ! "$source_hash" =~ ^sha256- ]]; then
  echo "Failed to resolve source hash from: $source_url" >&2
  exit 1
fi

if [[ -z "$source_store_path" || ! -d "$source_store_path" ]]; then
  echo "Failed to resolve prefetched source store path from: $source_url" >&2
  exit 1
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

source_lockfile="$(find "$source_store_path" -maxdepth 3 -type f -path '*/codex-rs/Cargo.lock' | head -n1)"
if [[ -z "$source_lockfile" ]]; then
  echo "Could not find codex-rs/Cargo.lock in prefetched source archive" >&2
  exit 1
fi

cp "$source_lockfile" "$lock_file"

rusty_v8_version="$(
  awk '
    /^\[\[package\]\]$/ {
      if (pkg_name == "v8" && pkg_version != "") {
        print pkg_version
        found = 1
        exit
      }
      pkg_name = ""
      pkg_version = ""
      next
    }
    /^name = / {
      value = $0
      sub(/^name = "/, "", value)
      sub(/"$/, "", value)
      pkg_name = value
      next
    }
    /^version = / {
      value = $0
      sub(/^version = "/, "", value)
      sub(/"$/, "", value)
      pkg_version = value
      next
    }
    END {
      if (!found && pkg_name == "v8" && pkg_version != "") {
        print pkg_version
        found = 1
      }
      if (!found) {
        exit 1
      }
    }
  ' "$lock_file"
)"

if [[ -z "$rusty_v8_version" ]]; then
  echo "Could not find v8 crate version in $lock_file" >&2
  exit 1
fi

prefetch_rusty_v8_hash() {
  local arch="$1"
  local url="https://github.com/denoland/rusty_v8/releases/download/v${rusty_v8_version}/librusty_v8_release_${arch}-unknown-linux-gnu.a.gz"
  local hash
  hash="$(nix store prefetch-file --json "$url" | jq -r '.hash')"

  if [[ ! "$hash" =~ ^sha256- ]]; then
    echo "Failed to resolve rusty_v8 hash from: $url" >&2
    exit 1
  fi

  printf '%s' "$hash"
}

refresh_cargo_hash_if_present() {
  if ! grep -Eq '^[[:space:]]*(cargoHash|vendorHash) = ' "$target_file"; then
    return 0
  fi

  if [[ ! -f "${target_dir}/flake.nix" ]]; then
    echo "Cannot refresh cargoHash/vendorHash without a flake at: ${target_dir}/flake.nix" >&2
    exit 1
  fi

  echo "Detected cargoHash/vendorHash; refreshing via nix build hash mismatch"
  perl -0pi -e 's/(\n\s*(?:cargoHash|vendorHash) = )(?:lib\.fakeHash|"sha256-[^"]+");/$1 . "lib.fakeHash;"/e' "$target_file"

  local log_file="${tmpdir}/cargo-hash.log"
  local status
  set +e
  nix build --no-link "${target_dir}#codex" >"$log_file" 2>&1
  status=$?
  set -e

  local cargo_hash
  cargo_hash="$(perl -ne 'print "$1\n" if /got:\s*(sha256-[A-Za-z0-9+\/=]+)/' "$log_file" | tail -n1)"

  if [[ -z "$cargo_hash" ]]; then
    echo "Failed to refresh cargoHash/vendorHash. nix build exited with status $status" >&2
    tail -n 20 "$log_file" >&2
    exit 1
  fi

  CARGO_HASH="$cargo_hash" perl -0pi -e 's/(\n\s*(?:cargoHash|vendorHash) = )(?:lib\.fakeHash|"sha256-[^"]+");/$1 . "\"" . $ENV{CARGO_HASH} . "\";"/e' "$target_file"
}

echo "Prefetching rusty_v8 archives for v${rusty_v8_version}"
rusty_v8_x86_64_hash="$(prefetch_rusty_v8_hash x86_64)"
rusty_v8_aarch64_hash="$(prefetch_rusty_v8_hash aarch64)"

VERSION="$version" perl -0pi -e 's/(\n\s*version = )"[^"]+";/$1 . "\"" . $ENV{VERSION} . "\";"/e' "$target_file"
SOURCE_HASH="$source_hash" perl -0pi -e 's/(src = fetchFromGitHub \{.*?\n\s*hash = )"sha256-[^"]+";/$1 . "\"" . $ENV{SOURCE_HASH} . "\";"/se' "$target_file"
RUSTY_V8_VERSION="$rusty_v8_version" perl -0pi -e 's/(\n\s*rustyV8Version = )"[^"]+";/$1 . "\"" . $ENV{RUSTY_V8_VERSION} . "\";"/e' "$target_file"
RUSTY_V8_X86_64_HASH="$rusty_v8_x86_64_hash" perl -0pi -e 's/(librusty_v8_release_x86_64-unknown-linux-gnu\.a\.gz";\n\s*hash = )"sha256-[^"]+";/$1 . "\"" . $ENV{RUSTY_V8_X86_64_HASH} . "\";"/e' "$target_file"
RUSTY_V8_AARCH64_HASH="$rusty_v8_aarch64_hash" perl -0pi -e 's/(librusty_v8_release_aarch64-unknown-linux-gnu\.a\.gz";\n\s*hash = )"sha256-[^"]+";/$1 . "\"" . $ENV{RUSTY_V8_AARCH64_HASH} . "\";"/e' "$target_file"
refresh_cargo_hash_if_present

echo "Updated: $target_file"
echo "  version:              $version"
echo "  src.hash:             $source_hash"
echo "  lock file:            $lock_file"
echo "  rusty_v8 version:     $rusty_v8_version"
echo "  rusty_v8 x86_64 hash: $rusty_v8_x86_64_hash"
echo "  rusty_v8 aarch64 hash: $rusty_v8_aarch64_hash"
