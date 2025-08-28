{
  description = "Care Production - Docker container with Redis, PostgreSQL, Garage S3, and Django Care application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    care.url = "github:ohcnetwork/care";
  };

  outputs = { self, nixpkgs, care }:
    let
      supportedSystems = [ "aarch64-linux" "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.callPackage ./docker.nix {
            careSource = care;
          };
        }
      );
    };
}
