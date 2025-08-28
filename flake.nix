{
  description = "Care Production - Docker container with Redis, PostgreSQL, Garage S3, and Django Care application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      packages.${system}.default = pkgs.callPackage ./docker-redis-postgres-minimal.nix {};

      # Alias for easier access
      defaultPackage.${system} = self.packages.${system}.default;
    };
}
