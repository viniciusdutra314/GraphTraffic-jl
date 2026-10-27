{
  description = "Julia development environment for GraphTraffic-jl";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  inputs.graphtraffic-rs.url = "github:viniciusdutra314/GraphTraffic-rs";

  outputs = { nixpkgs, graphtraffic-rs, ... }:
    {
      devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ]
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            simulator = graphtraffic-rs.packages.${system}.default;
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
