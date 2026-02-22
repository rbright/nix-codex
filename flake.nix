{
  description = "Nix package for Codex CLI";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    flake-utils.lib.eachSystem supportedSystems (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        codex = pkgs.callPackage ./package.nix { };
      in
      {
        packages = {
          inherit codex;
          default = codex;
        };

        apps = {
          codex = {
            type = "app";
            program = "${codex}/bin/codex";
            meta = {
              description = "Run codex";
            };
          };
          default = {
            type = "app";
            program = "${codex}/bin/codex";
            meta = {
              description = "Run codex";
            };
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.bash
            pkgs.deadnix
            pkgs.git
            pkgs.jq
            pkgs.just
            pkgs.nix
            pkgs.nixfmt
            pkgs.perl
            pkgs.prek
            pkgs.ripgrep
            pkgs.shellcheck
            pkgs.statix
          ];
        };

        formatter = pkgs.nixfmt;
      }
    );
}
