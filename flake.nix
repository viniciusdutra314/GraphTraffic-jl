{
  description = "Julia development environment for GraphTraffic-jl";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.graphtraffic-rs.url = "github:viniciusdutra314/GraphTraffic-rs";

  outputs = { nixpkgs, graphtraffic-rs, ... }:
    {
      devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ]
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            # The pinned simulator flake exposes Linux packages only. Build its
            # same source/toolchain on Darwin until it exports Darwin packages.
            simulator = graphtraffic-rs.packages.${system}.default or (
              let
                simulatorPkgs = import graphtraffic-rs.inputs.nixpkgs {
                  inherit system;
                  overlays = [ graphtraffic-rs.inputs.rust-overlay.overlays.default ];
                };
                toolchain = simulatorPkgs.rust-bin.fromRustupToolchainFile
                  "${graphtraffic-rs}/rust-toolchain.toml";
                rustPlatform = simulatorPkgs.makeRustPlatform {
                  cargo = toolchain;
                  rustc = toolchain;
                };
              in rustPlatform.buildRustPackage {
                pname = "graph-traffic";
                version = "0.1.0";
                src = graphtraffic-rs;
                cargoLock.lockFile = "${graphtraffic-rs}/Cargo.lock";
                nativeBuildInputs = with simulatorPkgs; [ cmake pkg-config ];
                buildInputs = with simulatorPkgs; [ zlib ];
                doCheck = true;
              }
            );
          in {
            default = pkgs.mkShell {
              packages = [ pkgs.julia_112-bin simulator ];
              shellHook = ''
                export JULIA_PROJECT=@.
                export GRAPHTRAFFIC_EXECUTABLE=${simulator}/bin/graph_traffic
              '';
            };
          });
    };
}
