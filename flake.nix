{
  description = "CodeGraph — pinpoints exact code locations and relationships so AI agents spend less context window finding code and more on implementing changes";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Pin both darwin systems to a stable release branch. x86_64-darwin needs
    # it for older macOS Intel compatibility; aarch64-darwin needs it because
    # nixpkgs-unstable currently has a regression where apple_sdk_11_0 is
    # referenced but has been removed (see nixpkgs darwin-aliases.nix). The
    # -darwin branch receives security updates without the breaking churn.
    nixpkgs-darwin-legacy.url = "github:NixOS/nixpkgs/nixpkgs-24.05-darwin";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixpkgs-darwin-legacy, flake-utils, ... }@inputs:
    flake-utils.lib.eachDefaultSystem (system:
      let
        isDarwin = builtins.match ".*-darwin" system != null;
        # SurrealDB uses BSL 1.1 (unfree in nixpkgs). Allow it so
        # `nix flake check` and `nix develop` work without --impure.
        allowUnfreeSurreal = { allowUnfreePredicate = pkg: (pkg.pname or (builtins.parseDrvName pkg.name).name) == "surrealdb"; };
        pkgs =
          if isDarwin
          then import nixpkgs-darwin-legacy { inherit system; config = allowUnfreeSurreal; }
          else import nixpkgs { inherit system; config = allowUnfreeSurreal; };

        # The main `codegraph` binary lives in the `codegraph-mcp-server`
        # workspace member (crates/codegraph-mcp-server). `default` features
        # pull in the daemon; richer feature sets (ai-enhanced, embeddings,
        # server-http, all-agents, all-embeddings) are available via the
        # project's `full` feature flag — see `.#codegraph-full` below.
        codegraph = pkgs.rustPlatform.buildRustPackage {
          pname = "codegraph";
          version = "1.0.0";
          src = pkgs.lib.cleanSource ./.;
          cargoLock = {
            lockFile = ./Cargo.lock;
            # The workspace Cargo.lock contains git dependencies from the
            # liquidos-ai/AutoAgents fork (autoagents, autoagents-core,
            # autoagents-derive, autoagents-llm). `importCargoLock` needs
            # outputHashes for any git dep that doesn't carry a checksum.
            # These are only needed at evaluation time — the crates are
            # optional and not pulled in by the default-features build, but
            # the lock file still lists them so the hashes must be present.
            outputHashes = {
              "autoagents-0.3.0" = "sha256-jdOD4PVn9D8EkOAEfgt0FhBssVkpNl68bJr/gIUQjsE=";
              "autoagents-core-0.3.0" = "sha256-jdOD4PVn9D8EkOAEfgt0FhBssVkpNl68bJr/gIUQjsE=";
              "autoagents-derive-0.3.0" = "sha256-jdOD4PVn9D8EkOAEfgt0FhBssVkpNl68bJr/gIUQjsE=";
              "autoagents-llm-0.3.0" = "sha256-jdOD4PVn9D8EkOAEfgt0FhBssVkpNl68bJr/gIUQjsE=";
            };
          };

          # Build only the workspace member that produces the `codegraph`
          # binary. Building the whole workspace would also compile test
          # binaries, examples, and unrelated crates (codegraph-vector's
          # rag_demo, codegraph-graph's surreal_smoke_test, etc.).
          cargoBuildFlags = [
            "-p"
            "codegraph-mcp-server"
          ];

          # `codegraph-mcp` uses reqwest with `native-tls`, which needs
          # pkg-config to discover OpenSSL at build time.
          nativeBuildInputs = [ pkgs.pkg-config ];

          buildInputs =
            [ pkgs.openssl ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.libiconv
              pkgs.darwin.apple_sdk.frameworks.Security
              pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
            ];

          # The installer script exports MACOSX_DEPLOYMENT_TARGET=11.0 to
          # target a reasonable macOS baseline. Mirror that so the Darwin
          # build picks a compatible SDK deployment target.
          MACOSX_DEPLOYMENT_TARGET = pkgs.lib.optionalString pkgs.stdenv.isDarwin "11.0";

          # `--all-features` build is intentionally not the default here —
          # it pulls in ONNX (ort), candle, and every embedding provider,
          # which makes the build heavy and adds runtime dependencies the
          # minimal CLI doesn't need. Users who want the full feature set
          # can install `.#codegraph-full` instead.
          doCheck = false;

          meta = {
            description = "CodeGraph — pinpoints exact code locations and relationships for AI agents";
            homepage = "https://github.com/levonk/codegraph-rust";
            license = with pkgs.lib.licenses; [ mit asl20 ];
            mainProgram = "codegraph";
            maintainers = [ ];
          };
        };

        # Full-feature build matching `cargo install --path ... --all-features`
        # from install-codegraph-full-features.sh. Heavier to build; pulls in
        # ai-enhanced, server-http, all-agents, all-embeddings.
        codegraph-full = codegraph.overrideAttrs (old: {
          pname = "codegraph-full";
          cargoBuildFlags = (old.cargoBuildFlags or [ ]) ++ [
            "--features"
            "full"
          ];
        });
      in
      {
        packages = {
          # Users naturally try .#codegraph, so expose it alongside default.
          inherit codegraph;
          inherit codegraph-full;
          default = codegraph;
          source = codegraph;
        };

        apps = {
          codegraph = {
            type = "app";
            program = "${codegraph}/bin/codegraph";
          };
          codegraph-full = {
            type = "app";
            program = "${codegraph-full}/bin/codegraph";
          };
          default = {
            type = "app";
            program = "${codegraph}/bin/codegraph";
          };
        };

        checks = {
          build = codegraph;
          # `nix flake check` runs this; --help is a cheap smoke test that
          # the binary links and runs on the target system.
          smoke = pkgs.runCommand "codegraph-smoke-check"
            {
              nativeBuildInputs = [ codegraph ];
            }
            ''
              ${codegraph}/bin/codegraph --help > "$out"
            '';
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs =
            [ pkgs.openssl pkgs.rustc pkgs.cargo pkgs.cargo-watch pkgs.surrealdb ]
            ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
              pkgs.libiconv
              pkgs.darwin.apple_sdk.frameworks.Security
              pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
            ];
          MACOSX_DEPLOYMENT_TARGET = pkgs.lib.optionalString pkgs.stdenv.isDarwin "11.0";
        };
      }
    ) // {
      overlays.default = final: prev: {
        codegraph = self.packages.${final.system}.codegraph;
        codegraph-full = self.packages.${final.system}.codegraph-full;
      };
    };
}
