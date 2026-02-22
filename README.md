# nix-codex

[![CI](https://github.com/rbright/nix-codex/actions/workflows/ci.yml/badge.svg)](https://github.com/rbright/nix-codex/actions/workflows/ci.yml)

Nix package for Codex CLI.

Source: [`openai/codex`](https://github.com/openai/codex).

## What this repo provides

- Nix package: `codex` (binary: `codex`)
- Nix app output: `.#codex`
- Scripted updater for version/source hash pin refresh
- Scheduled GitHub Actions updater that opens auto-mergeable PRs
- Automated GitHub release creation on `codex` version bumps
- Local quality gate (`just`) and GitHub Actions CI

## Quickstart

```sh
# list commands
just --list

# full local validation gate
just check

# run the packaged binary
just run --help
```

## Build and run

```sh
nix build -L 'path:.#codex'
nix run 'path:.#codex' -- --help
```

Success criteria:

- `nix build` exits `0`
- `nix run` prints `codex` CLI usage output

## Update workflow

```sh
# latest stable rust-vX.Y.Z tag from openai/codex
just update

# explicit version forms are accepted
just update 0.104.0
just update v0.104.0
just update rust-v0.104.0
```

`./scripts/update-package.sh` updates:

- `version`
- `src.hash`
- `Cargo.lock` (from upstream `codex-rs`)

Only full release versions are accepted (`X.Y.Z`). Pre-release tags (for example
`rust-v0.105.0-alpha.1`) are ignored/rejected.

### Updater prerequisites

- `curl`
- `git`
- `jq`
- `nix`
- `perl`
- `tar`

Check script usage:

```sh
./scripts/update-package.sh --help
```

## Automated GitHub updates

Workflow: `.github/workflows/update-codex.yml`

- Runs every 6 hours and on manual dispatch.
- Detects the latest stable upstream `rust-vX.Y.Z` tag from `openai/codex`.
- Ignores pre-release tags (alpha/beta/rc) and rejects non-`X.Y.Z` manual overrides.
- If newer than `package.nix`, runs `scripts/update-package.sh` and opens/updates a PR.
- Enables auto-merge (`squash`) for that PR.

### One-time repository setup

1. Add repo secret `CODEX_UPDATER_TOKEN` (fine-grained PAT scoped to this repo):
   - **Contents**: Read and write
   - **Pull requests**: Read and write
2. In repository settings → **Actions → General**:
   - Set workflow permissions to **Read and write permissions**.
   - Enable **Allow GitHub Actions to create and approve pull requests**.
3. Ensure branch protection/required checks allow auto-merge after CI passes.

Manual trigger:

- Actions → **Update codex package** → **Run workflow**
- Optional input: `version` (accepts `0.x.y`, `v0.x.y`, or `rust-v0.x.y`)

## Automated GitHub releases

Workflow: `.github/workflows/release-codex.yml`

- Runs on pushes to `main` when `package.nix` changes.
- Compares previous and current `package.nix` `version` values.
- Creates a GitHub release + tag named `v<version>` only when the packaged version changes.
- Skips docs-only merges and other changes that do not modify `package.nix` version.

No extra secret is required; it uses the workflow `GITHUB_TOKEN` with `contents: write`.

## Linting and checks

```sh
just fmt
just fmt-check
just lint
just check
```

`just lint` runs:

- `statix`
- `deadnix`
- `nixfmt --check`
- `shellcheck`

## Use from another flake

```nix
{
  inputs.nixCodex.url = "github:rbright/nix-codex";

  outputs = { self, nixpkgs, nixCodex, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ({ pkgs, ... }: {
          environment.systemPackages = [
            nixCodex.packages.${pkgs.system}.codex
          ];
        })
      ];
    };
  };
}
```
