{
  description = "Julia environment + GraphTraffic-rs build binary";

  inputs.self.submodules = true;
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.graphtraffic-rs.url = "path:./GraphTraffic-rs";

  outputs = { nixpkgs, graphtraffic-rs, ... }:
    {
      packages = graphtraffic-rs.packages;
      # Its buildRustPackage enables doCheck, so checking this package runs Rust tests.
      checks = graphtraffic-rs.packages;
      devShells = nixpkgs.lib.genAttrs (builtins.attrNames graphtraffic-rs.packages)
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            simulator = graphtraffic-rs.packages.${system}.default;
          in {
            default = pkgs.mkShell {
              inputsFrom = [ graphtraffic-rs.devShells.${system}.default ];
              packages = [ pkgs.julia_112-bin simulator ];
              shellHook = ''
                export JULIA_PROJECT=@.
                export GRAPHTRAFFIC_EXECUTABLE=${simulator}/bin/graph_traffic
              '';
            };
          });
    };
}
