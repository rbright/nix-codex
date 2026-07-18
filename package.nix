{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  fetchurl,
  installShellFiles,
  clang,
  cmake,
  gitMinimal,
  libclang,
  libcap,
  makeBinaryWrapper,
  openssl,
  pkg-config,
  ripgrep,
  versionCheckHook,
  installShellCompletions ? stdenv.buildPlatform.canExecute stdenv.hostPlatform,
}:
let
  rustyV8Version = "149.2.0";
  rustyV8Archive =
    if stdenv.hostPlatform.system == "x86_64-linux" then
      fetchurl {
        url = "https://github.com/denoland/rusty_v8/releases/download/v${rustyV8Version}/librusty_v8_release_x86_64-unknown-linux-gnu.a.gz";
        hash = "sha256-iu2YY323533Iv7i7R1nsW95HLQv3lD9Y4OYqNQlFxVk=";
      }
    else if stdenv.hostPlatform.system == "aarch64-linux" then
      fetchurl {
        url = "https://github.com/denoland/rusty_v8/releases/download/v${rustyV8Version}/librusty_v8_release_aarch64-unknown-linux-gnu.a.gz";
        hash = "sha256-+XdRJ8pk3MSjZi0BpSGizvuluY+DOUOog9hHc7Kv88U=";
      }
    else
      throw "Unsupported platform for codex rusty_v8 archive: ${stdenv.hostPlatform.system}";
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "codex";
  version = "0.144.6";

  src = fetchFromGitHub {
    owner = "openai";
    repo = "codex";
    tag = "rust-v${finalAttrs.version}";
    hash = "sha256-S25nhnF4lEJQdiyKDV38ORbjm+BNsswLoE5ivF0SE2U=";
  };

  sourceRoot = "${finalAttrs.src.name}/codex-rs";
  cargoLock = {
    lockFile = ./Cargo.lock;
    allowBuiltinFetchGit = true;
    extraRegistries = {
      # Avoid crates.io API downloads, which have been flaky in GitHub Actions.
      "https://github.com/rust-lang/crates.io-index" = "https://static.crates.io/crates";
    };
  };

  nativeBuildInputs = [
    clang
    cmake
    gitMinimal
    installShellFiles
    makeBinaryWrapper
    pkg-config
  ];

  buildInputs = [
    libclang
    libcap
    openssl
  ];

  preBuild = ''
    # extraRegistries is needed only while Nix fetches crates. The generated
    # Cargo config duplicates crates-io, so remove that stanza before build.
    find /build -maxdepth 4 -path '*/.cargo/config.toml' -exec \
      sed -i '/^[[:space:]]*\[source\."https:\/\/github\.com\/rust-lang\/crates\.io-index"\]$/,+2d' {} \;
  '';

  env = {
    LIBCLANG_PATH = "${lib.getLib libclang}/lib";
    NIX_CFLAGS_COMPILE = toString (
      lib.optionals stdenv.cc.isGNU [ "-Wno-error=stringop-overflow" ]
      ++ lib.optionals stdenv.cc.isClang [ "-Wno-error=character-conversion" ]
    );

    # rust-v0.118.0 pulled in rusty_v8, whose build script otherwise attempts
    # a network download that fails inside Nix sandboxed builds.
    RUSTY_V8_ARCHIVE = rustyV8Archive;

    # Upstream release profile uses fat LTO + single codegen unit, which is
    # expensive on GitHub Actions runners.
    CARGO_PROFILE_RELEASE_LTO = "off";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
  };

  cargoBuildFlags = [
    "--package"
    "codex-cli"
    "--bin"
    "codex"
  ];

  cargoInstallFlags = [
    "--package"
    "codex-cli"
    "--bin"
    "codex"
  ];

  doCheck = false;

  postInstall = lib.optionalString installShellCompletions ''
    installShellCompletion --cmd codex \
      --bash <($out/bin/codex completion bash) \
      --fish <($out/bin/codex completion fish) \
      --zsh <($out/bin/codex completion zsh)
  '';

  postFixup = ''
    wrapProgram $out/bin/codex --prefix PATH : ${lib.makeBinPath [ ripgrep ]}
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ versionCheckHook ];

  meta = {
    description = "Lightweight coding agent that runs in your terminal";
    homepage = "https://github.com/openai/codex";
    changelog = "https://raw.githubusercontent.com/openai/codex/refs/tags/rust-v${finalAttrs.version}/CHANGELOG.md";
    license = lib.licenses.asl20;
    mainProgram = "codex";
    platforms = lib.platforms.unix;
  };
})
