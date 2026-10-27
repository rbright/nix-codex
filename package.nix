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
  rustyV8Version = "152.2.0";
  rustyV8Archive =
    if stdenv.hostPlatform.system == "x86_64-linux" then
      fetchurl {
        url = "https://github.com/denoland/rusty_v8/releases/download/v${rustyV8Version}/librusty_v8_release_x86_64-unknown-linux-gnu.a.gz";
        hash = "sha256-tmg+mvy3f72MssOs9F001SApqyFrMyUiyVF5wS8P7Tw=";
      }
    else if stdenv.hostPlatform.system == "aarch64-linux" then
      fetchurl {
        url = "https://github.com/denoland/rusty_v8/releases/download/v${rustyV8Version}/librusty_v8_release_aarch64-unknown-linux-gnu.a.gz";
        hash = "sha256-xAGWu/GCUy5YP2W32vAZb9uzNU5vrFmzHQU5wg+THz0=";
      }
    else
      throw "Unsupported platform for codex rusty_v8 archive: ${stdenv.hostPlatform.system}";
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "codex";
  version = "0.165.0";

  src = fetchFromGitHub {
    owner = "openai";
    repo = "codex";
    tag = "rust-v${finalAttrs.version}";
    hash = "sha256-b9PpwNQeZsJIN4wbGA3FLfWAKd2EDMN5E/zj/Y62/vk=";
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

  # Build with the repository Cargo.lock, which may carry security bumps
  # before an upstream release does (for example rustls-webpki and
  # webpki-roots for the eMudhra intermediate CA compromise).
  postPatch = ''
    cp ${./Cargo.lock} Cargo.lock
  '';

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

    # mxc-sdk's build script compares its Windows binding provenance with the
    # first `windows` entry in ../Cargo.lock. In the Nix vendor dir that file
    # is codex's lockfile (windows 0.58), so the check fails. The bindings are
    # Windows-only; removing the provenance file makes the script skip it.
    rm -f "$NIX_BUILD_TOP"/cargo-vendor-dir/mxc-sdk-*/build/isolation_session_bindings/GENERATION_INFO.toml
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
