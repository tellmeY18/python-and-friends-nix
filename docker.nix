{ pkgs, careSource }:
let
  # Import all service modules
  postgres = pkgs.callPackage ./postgres.nix {};
  redis = pkgs.callPackage ./redis.nix {};
  garage = pkgs.callPackage ./garage.nix {};
  care = pkgs.callPackage ./care.nix { inherit careSource; };

  # Create system users and groups declaratively
  users = pkgs.runCommand "users-setup" { } ''
    mkdir -p $out/etc

    # Create passwd file
    cat > $out/etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/bash
postgres:x:999:999:PostgreSQL:/var/lib/postgresql:/bin/bash
redis:x:998:998:Redis:/var/lib/redis:/bin/bash
garage:x:997:997:Garage:/var/lib/garage:/bin/bash
care:x:996:996:Care Application:/app:/bin/bash
EOF

    # Create group file
    cat > $out/etc/group << 'EOF'
root:x:0:
postgres:x:999:
redis:x:998:
garage:x:997:
care:x:996:
EOF

    # Create shadow file (required for some operations)
    cat > $out/etc/shadow << 'EOF'
root:!:1::::::
postgres:!:1::::::
redis:!:1::::::
garage:!:1::::::
care:!:1::::::
EOF

    chmod 640 $out/etc/shadow
  '';

  # Create base directories with proper permissions
  baseDirectories = pkgs.runCommand "base-directories" {
    nativeBuildInputs = [ pkgs.coreutils ];
  } ''
    mkdir -p $out/data/postgres $out/data/redis $out/data/garage $out/tmp $out/var/run $out/var/log $out/app/staticfiles $out/app/media
    chmod 755 $out/data $out/tmp $out/var/run $out/var/log $out/app
    chmod 700 $out/data/postgres
    chmod 755 $out/data/redis $out/data/garage $out/app/staticfiles $out/app/media
  '';

  # Main startup script that orchestrates all services
  startScript = pkgs.writeShellApplication {
    name = "start-services";
    runtimeInputs = with pkgs; [
      coreutils shadow util-linux gnused gawk gnugrep procps
      wget gnutar xz findutils git
    ] ++ postgres.runtimeInputs ++ redis.runtimeInputs ++ garage.runtimeInputs ++ care.runtimeInputs;

    text = ''
      set -euo pipefail

      echo "🏥 Starting Care Production Environment..."

      echo "Setting up directories and permissions..."

      # Ensure directories exist with correct permissions
      mkdir -p /data/postgres /data/redis /data/garage/meta /data/garage/data /tmp /var/run /var/log /app/staticfiles /app/media

      # Fix /tmp permissions
      chmod 1777 /tmp
      chown root:root /tmp

      # Setup all services
      ${postgres.setupPostgreSQL}
      ${redis.setupRedis}
      ${garage.setupGarage}

      # Start all background services
      ${postgres.startPostgreSQL}
      ${redis.startRedis}
      ${garage.startGarage}

      echo "Waiting for services to start..."
      sleep 5

      # Load Garage credentials
      ${garage.loadGarageCredentials}

      # Setup Care application
      cd /app
      ${care.setupCare}
      ${care.setupDjango}
      ${care.startCelery}

      # Start Django application (this blocks)
      ${care.startDjango}
    '';
  };

  # Collect all packages needed
  allPackages = postgres.packages ++ redis.packages ++ garage.packages ++ care.packages ++ [
    # Core system utilities
    pkgs.coreutils
    pkgs.shadow
    pkgs.bash
    pkgs.util-linux
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.procps
    pkgs.findutils
    pkgs.gzip
    pkgs.gnutar
    pkgs.xz
    pkgs.wget
    pkgs.curl
    baseDirectories
  ];

  # Collect all environment variables
  allEnvVars = postgres.envVars ++ redis.envVars ++ garage.envVars ++ care.envVars;

in
pkgs.dockerTools.buildLayeredImage {
  name = "care-production";
  tag = "latest";

  contents = allPackages;

  extraCommands = ''
    ${care.copyCareSource}

    # Copy user/group files from our users derivation
    mkdir -p etc
    cp ${users}/etc/passwd etc/passwd
    cp ${users}/etc/group etc/group
    cp ${users}/etc/shadow etc/shadow

    # Copy startup script
    mkdir -p usr/local/bin
    cp ${startScript}/bin/start-services usr/local/bin/
    chmod +x usr/local/bin/start-services

    # Ensure proper directory structure exists
    mkdir -p data/postgres data/redis data/garage/meta data/garage/data tmp var/run var/log app/staticfiles app/media

    # Clean up unnecessary files to reduce image size
    echo "Cleaning up unnecessary files..."

    # Remove documentation, development files, and cache files
    rm -rf nix/store/*/share/{man,doc,info,locale,bash-completion,zsh,fish,applications,icons,pixmaps,mime}
    rm -rf nix/store/*/lib/{systemd,udev,cmake}
    rm -rf nix/store/*/include nix/store/*/lib/pkgconfig
    rm -rf nix/store/*/share/postgresql/{extension,contrib}

    # Remove Python cache and test files
    find . -name "*.pyc" -o -name "*.pyo" -o -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find . -path "*/test*" -o -path "*/site-packages/pip*" -o -path "*/site-packages/wheel*" -o -path "*/site-packages/setuptools*" -exec rm -rf {} + 2>/dev/null || true

    # Remove unnecessary binaries
    find . -name "pg_*" ! -name "pg_isready" ! -name "pg_dump" ! -name "pg_restore" -exec rm -f {} + 2>/dev/null || true
    find . -name "redis-cli*" -o -name "redis-benchmark*" -o -name "redis-check-*" -o -name "redis-sentinel*" -exec rm -f {} + 2>/dev/null || true
    find . -name "perl*" -o -name "*.debug" -o -name "*.la" -o -name "*.a" -exec rm -f {} + 2>/dev/null || true

    # Strip binaries and remove empty directories
    find . -type f -executable -exec strip --strip-unneeded {} + 2>/dev/null || true
    find . -type d -empty -delete 2>/dev/null || true

    echo "Care production image optimization completed"
  '';

  config = {
    Cmd = [ "/usr/local/bin/start-services" ];
    ExposedPorts = {
      "8000/tcp" = {};
    };
    Env = allEnvVars;
    WorkingDir = "/app";
    User = "root";  # Start as root to manage permissions, then drop to service users

    # Health check
    Healthcheck = {
      Test = [ "CMD-SHELL" "curl -f http://localhost:8000/api/v1/health/ || exit 1" ];
      Interval = 30000000000;  # 30s in nanoseconds
      Timeout = 10000000000;   # 10s in nanoseconds
      Retries = 3;
      StartPeriod = 120000000000;  # 120s in nanoseconds
    };
  };

  # Optimize layers for better caching
  maxLayers = 30;
}
