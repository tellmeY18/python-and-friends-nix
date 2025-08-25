{
  description = "Nixify Health Check - Docker container with Redis, PostgreSQL, and Flask app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "aarch64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      staticPkgs = pkgs.pkgsStatic;
      muslPkgs = pkgs.pkgsMusl;
    in
    {
      packages.${system} = {
        default = self.packages.${system}.docker-image-static;

        # Minimal PostgreSQL without tests and extra features
        postgres-static = muslPkgs.postgresql.overrideAttrs (oldAttrs: {
          configureFlags = oldAttrs.configureFlags or [] ++ [
            "--disable-debug"
            "--disable-profiling"
            "--disable-coverage"
            "--disable-dtrace"
            "--disable-tap-tests"
            "--without-gssapi"
            "--without-ldap"
            "--without-pam"
            "--without-python"
            "--without-perl"
            "--without-tcl"
            "--without-bonjour"
            "--without-openssl"
            "--without-libxml"
            "--without-libxslt"
            "--without-systemd"
            "--without-selinux"
            "--without-icu"
            "--without-llvm"
            "--enable-integer-datetimes"
            "--with-system-tzdata=/usr/share/zoneinfo"
          ];
          doCheck = false;
          doInstallCheck = false;
          buildInputs = [ muslPkgs.zlib muslPkgs.readline ];
          nativeBuildInputs = [ muslPkgs.pkg-config ];
        });

        # Minimal Redis without tests and extra features
        redis-static = muslPkgs.redis.overrideAttrs (oldAttrs: {
          makeFlags = oldAttrs.makeFlags or [] ++ [
            "BUILD_TLS=no"
            "USE_SYSTEMD=no"
            "USE_JEMALLOC=no"
          ];
          doCheck = false;
          doInstallCheck = false;
          # Only build redis-server, skip other tools
          buildPhase = ''
            make redis-server PREFIX=$out
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp src/redis-server $out/bin/
            strip $out/bin/redis-server
          '';
        });

        # Minimal Garage without tests and extra features
        garage-static = muslPkgs.garage_2.overrideAttrs (oldAttrs: {
          doCheck = false;
          doInstallCheck = false;
          cargoTestFlags = [];
          cargoBuildFlags = [ "--release" "--bin" "garage" ];
          # Minimal feature set
          buildFeatures = [ "default" ];
          # Skip documentation and man pages
          postInstall = ''
            mkdir -p $out/bin
            cp target/*/release/garage $out/bin/
            strip $out/bin/garage
          '';
        });

        # Minimal Python environment with only required packages
        python-env = staticPkgs.python3.withPackages (ps: with ps; [
          flask
          psycopg2
          redis
          boto3
        ]);

        # Essential runtime tools only
        runtime-tools = pkgs.buildEnv {
          name = "runtime-tools";
          paths = with staticPkgs; [
            (coreutils.override {
              singleBinary = false;  # Keep individual binaries for minimal selection
            })
            util-linux
            shadow
            bash
            gawk
            gnugrep
          ];
        };

        docker-image-static = pkgs.callPackage ./docker-redis-postgres-minimal-static.nix {
          inherit (self.packages.${system}) postgres-static redis-static garage-static python-env runtime-tools;
        };
      };
    };
}
