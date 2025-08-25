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

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nix
          git
          docker
          (python3.withPackages (ps: with ps; [
            flask
            psycopg2
            redis
          ]))
          postgresql
          redis
        ];

        shellHook = ''
          echo "Nixify Health Check Development Environment (aarch64-linux)"
          echo ""
          echo "Available commands:"
          echo "  nix build                   - Build Docker image"
          echo "  make build                  - Build and run container"
          echo "  python app.py               - Run app locally"
          echo ""
        '';
      };

      checks.${system}.docker-image = self.packages.${system}.docker-image;
    };
}
