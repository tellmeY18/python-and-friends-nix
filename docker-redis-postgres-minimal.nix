{ pkgs }:
let
  # Create system users and groups declaratively
  users = pkgs.runCommand "users-setup" { } ''
    mkdir -p $out/etc

    # Create passwd file
    cat > $out/etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/bash
postgres:x:999:999:PostgreSQL:/var/lib/postgresql:/bin/bash
redis:x:998:998:Redis:/var/lib/redis:/bin/bash
EOF

    # Create group file
    cat > $out/etc/group << 'EOF'
root:x:0:
postgres:x:999:
redis:x:998:
EOF

    # Create shadow file (required for some operations)
    cat > $out/etc/shadow << 'EOF'
root:!:1::::::
postgres:!:1::::::
redis:!:1::::::
EOF

    chmod 640 $out/etc/shadow
  '';

  # Create base directories with proper permissions
  baseDirectories = pkgs.runCommand "base-directories" {
    nativeBuildInputs = [ pkgs.coreutils ];
  } ''
    mkdir -p $out/data/postgres $out/data/redis $out/tmp $out/var/run $out/var/log
    chmod 755 $out/data $out/tmp $out/var/run $out/var/log
    chmod 700 $out/data/postgres
    chmod 755 $out/data/redis
  '';

  # Minimal Python environment with required packages
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    flask
    psycopg2
    redis
  ]);

  # PostgreSQL configuration files
  postgresqlConf = pkgs.writeText "postgresql.conf" ''
    port = 5432
    listen_addresses = '127.0.0.1'
    max_connections = 100
    shared_buffers = 32MB
    log_destination = 'stderr'
    logging_collector = off
    log_statement = 'none'
    unix_socket_directories = '/data/postgres'
  '';

  pgHbaConf = pkgs.writeText "pg_hba.conf" ''
    local   all             all                                     trust
    host    all             all             127.0.0.1/32            trust
    host    all             all             ::1/128                 trust
  '';

  # Startup script that properly handles users
  startScript = pkgs.writeShellApplication {
    name = "start-services";
    runtimeInputs = with pkgs; [ postgresql redis coreutils shadow util-linux ];
    text = ''
      set -euo pipefail

      echo "Setting up directories and permissions..."

      # Ensure directories exist with correct permissions
      mkdir -p /data/postgres /data/redis /tmp /var/run /var/log

      # Set ownership for postgres data directory
      chown postgres:postgres /data/postgres
      chmod 700 /data/postgres

      # Set ownership for redis data directory
      chown redis:redis /data/redis
      chmod 755 /data/redis

      # Fix /tmp permissions for PostgreSQL socket
      chmod 1777 /tmp
      chown root:root /tmp

      # Initialize PostgreSQL if needed (as postgres user)
      if [ ! -f /data/postgres/PG_VERSION ]; then
        echo "Initializing PostgreSQL as postgres user..."
        setpriv --reuid=999 --regid=999 --clear-groups ${pkgs.postgresql}/bin/initdb -D /data/postgres --auth=trust

        # Copy configuration files and set ownership
        cp ${postgresqlConf} /data/postgres/postgresql.conf
        cp ${pgHbaConf} /data/postgres/pg_hba.conf
        chown postgres:postgres /data/postgres/postgresql.conf /data/postgres/pg_hba.conf
        chmod 600 /data/postgres/postgresql.conf /data/postgres/pg_hba.conf
      fi

      echo "Starting PostgreSQL as postgres user..."
      setpriv --reuid=999 --regid=999 --clear-groups ${pkgs.postgresql}/bin/postgres -D /data/postgres &

      echo "Starting Redis as redis user..."
      setpriv --reuid=998 --regid=998 --clear-groups ${pkgs.redis}/bin/redis-server --dir /data/redis --bind 127.0.0.1 --port 6379 &

      echo "Waiting for services to start..."
      sleep 5

      echo "Starting Flask application..."
      cd /app
      exec ${pythonEnv}/bin/python app.py
    '';
  };

in
pkgs.dockerTools.buildLayeredImage {
  name = "nixify-health-check";
  tag = "latest";

  # Use minimal set of standard packages
  contents = with pkgs; [
    postgresql
    redis
    pythonEnv
    coreutils
    shadow
    bash
    util-linux
    baseDirectories
  ];

  extraCommands = ''
    # Copy application
    mkdir -p app
    cp ${./app.py} app/app.py

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
    mkdir -p data/postgres data/redis tmp var/run var/log

    # Clean up unnecessary files without touching Nix store structure
    echo "Cleaning up unnecessary files..."

    # Remove documentation, development files, and cache files
    rm -rf nix/store/*/share/{man,doc,info,locale,bash-completion,zsh,fish,applications,icons,pixmaps,mime}
    rm -rf nix/store/*/lib/{systemd,udev,perl*,cmake}
    rm -rf nix/store/*/include nix/store/*/lib/pkgconfig
    rm -rf nix/store/*/share/postgresql/{extension,contrib}

    # Remove Python cache and test files
    find . -name "*.pyc" -o -name "*.pyo" -o -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
    find . -path "*/test*" -o -path "*/site-packages/pip*" -o -path "*/site-packages/wheel*" -o -path "*/site-packages/setuptools*" -exec rm -rf {} + 2>/dev/null || true

    # Remove unnecessary binaries
    find . -name "pg_*" -o -name "psql*" -o -name "redis-cli*" -o -name "redis-benchmark*" -o -name "redis-check-*" -o -name "redis-sentinel*" -exec rm -f {} + 2>/dev/null || true
    find . -name "perl*" -o -name "*.debug" -o -name "*.la" -o -name "*.a" -exec rm -f {} + 2>/dev/null || true

    # Strip binaries and remove empty directories
    find . -type f -executable -exec strip --strip-unneeded {} + 2>/dev/null || true
    find . -type d -empty -delete 2>/dev/null || true

    echo "Image optimization completed"
  '';

  config = {
    Cmd = [ "/usr/local/bin/start-services" ];
    ExposedPorts = {
      "80/tcp" = {};
    };
    Env = [
      "POSTGRES_DB=postgres"
      "POSTGRES_USER=postgres"
      "REDIS_HOST=127.0.0.1"
      "REDIS_PORT=6379"
      "PG_HOST=127.0.0.1"
      "PG_PORT=5432"
    ];
    WorkingDir = "/app";
    User = "root";  # Start as root to manage permissions, then drop to service users
  };

  # Optimize layers for better caching and smaller size
  maxLayers = 25;
}
