{
  description = "Nixify Health Check - Docker container with Redis, PostgreSQL, and Flask app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system} = {
        default = self.packages.${system}.docker-image;
        docker-image = pkgs.callPackage ./docker-redis-postgres-minimal.nix {};
      };


    };
}
