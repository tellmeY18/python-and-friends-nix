{ pkgs, postgres-static, redis-static, garage-static, python-env, runtime-tools }:
let
  # Use static packages with musl for minimal size
  staticPkgs = pkgs.pkgsStatic;
  muslPkgs = pkgs.pkgsMusl;

  # Create system users and groups declaratively
  users = pkgs.runCommand "users-setup" { } ''
    mkdir -p $out/etc

    # Create passwd file
    cat > $out/etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/bash
postgres:x:999:999:PostgreSQL:/var/lib/postgresql:/bin/bash
redis:x:998:998:Redis:/var/lib/redis:/bin/bash
garage:x:997:997:Garage:/var/lib/garage:/bin/bash
EOF

    # Create group file
    cat > $out/etc/group << 'EOF'
root:x:0:
postgres:x:999:
redis:x:998:
garage:x:997:
EOF

    # Create shadow file (required for some operations)
    cat > $out/etc/shadow << 'EOF'
root:!:1::::::
postgres:!:1::::::
redis:!:1::::::
garage:!:1::::::
EOF

    chmod 640 $out/etc/shadow
  '';

  # Create base directories with proper permissions
  baseDirectories = pkgs.runCommand "base-directories" {
    nativeBuildInputs = [ staticPkgs.coreutils ];
  } ''
    mkdir -p $out/data/postgres $out/data/redis $out/data/garage $out/tmp $out/var/run $out/var/log
    chmod 755 $out/data $out/tmp $out/var/run $out/var/log
    chmod 700 $out/data/postgres
    chmod 755 $out/data/redis
    chmod 755 $out/data/garage
  '';

  # PostgreSQL configuration files
  postgresqlConf = pkgs.writeText "postgresql.conf" ''
    port = 5432
    listen_addresses = '127.0.0.1'
    max_connections = 20
    shared_buffers = 16MB
    work_mem = 1MB
    maintenance_work_mem = 16MB
    dynamic_shared_memory_type = none
    log_destination = 'stderr'
    logging_collector = off
    log_statement = 'none'
    log_min_messages = warning
    unix_socket_directories = '/data/postgres'
    fsync = off
    synchronous_commit = off
    checkpoint_completion_target = 0.9
    wal_buffers = -1
    checkpoint_segments = 32
    checkpoint_timeout = 15min
  '';

  pgHbaConf = pkgs.writeText "pg_hba.conf" ''
    local   all             all                                     trust
    host    all             all             127.0.0.1/32            trust
    host    all             all             ::1/128                 trust
  '';

  # Garage configuration - minimal S3-compatible storage
  garageConf = pkgs.writeText "garage.toml" ''
    metadata_dir = "/data/garage/meta"
    data_dir = "/data/garage/data"

    db_engine = "sqlite"

    replication_factor = 1
    consistency_mode = "consistent"

    rpc_bind_addr = "127.0.0.1:3901"
    rpc_public_addr = "127.0.0.1:3901"
    rpc_secret = "1799bccfd7411aaaa5c8a12916cc5b1f26355a7de6b85e1a98b15a43cc5c0e64"

    [s3_api]
    s3_region = "garage"
    api_bind_addr = "127.0.0.1:3900"
    root_domain = ".s3.garage.localhost"

    [admin]
    api_bind_addr = "127.0.0.1:3903"
    admin_token = "changeme"
    metrics_token = "changeme"
  '';

  # Extract only essential binaries for minimal image size
  essentialBinaries = pkgs.runCommand "essential-binaries" {
    nativeBuildInputs = [ staticPkgs.coreutils staticPkgs.binutils ];
  } ''
    mkdir -p $out/bin

    # Copy only the essential binaries we need (already stripped in individual builds)
    cp ${postgres-static}/bin/postgres $out/bin/ || echo "postgres binary not found"
    cp ${postgres-static}/bin/initdb $out/bin/ || echo "initdb binary not found"
    cp ${redis-static}/bin/redis-server $out/bin/ || echo "redis-server binary not found"
    cp ${garage-static}/bin/garage $out/bin/ || echo "garage binary not found"

    # Copy only absolutely essential runtime tools
    cp ${runtime-tools}/bin/bash $out/bin/
    cp ${runtime-tools}/bin/su $out/bin/
    cp ${runtime-tools}/bin/chown $out/bin/
    cp ${runtime-tools}/bin/chmod $out/bin/
    cp ${runtime-tools}/bin/mkdir $out/bin/
    cp ${runtime-tools}/bin/cp $out/bin/
    cp ${runtime-tools}/bin/sleep $out/bin/
    cp ${runtime-tools}/bin/grep $out/bin/
    cp ${runtime-tools}/bin/awk $out/bin/
    cp ${runtime-tools}/bin/head $out/bin/
    cp ${runtime-tools}/bin/touch $out/bin/
    cp ${runtime-tools}/bin/echo $out/bin/

    # Final aggressive stripping for minimal size
    for binary in $out/bin/*; do
      if [ -f "$binary" ] && [ -x "$binary" ]; then
        strip --strip-all "$binary" 2>/dev/null || true
      fi
    done

    # Verify essential binaries exist
    for essential in postgres initdb redis-server garage bash su; do
      if [ ! -f "$out/bin/$essential" ]; then
        echo "ERROR: Essential binary $essential is missing!"
        exit 1
      fi
    done

    echo "Essential binaries prepared and stripped for minimal size"
  '';

  # Optimized startup script using static binaries
  startScript = pkgs.writeShellApplication {
    name = "start-services";
    runtimeInputs = [ ];
    text = ''
      set -euo pipefail

      echo "Setting up directories and permissions..."

      # Ensure directories exist with correct permissions
      /bin/mkdir -p /data/postgres /data/redis /data/garage/meta /data/garage/data /tmp /var/run /var/log

      # Set ownership for postgres data directory
      /bin/chown postgres:postgres /data/postgres 2>/dev/null || true
      /bin/chmod 700 /data/postgres

      # Set ownership for redis data directory
      /bin/chown redis:redis /data/redis 2>/dev/null || true
      /bin/chmod 755 /data/redis

      # Set ownership for garage data directory
      /bin/chown garage:garage /data/garage /data/garage/meta /data/garage/data 2>/dev/null || true
      /bin/chmod 755 /data/garage /data/garage/meta /data/garage/data

      # Fix /tmp permissions
      /bin/chmod 1777 /tmp

      # Initialize PostgreSQL if needed
      if [ ! -f /data/postgres/PG_VERSION ]; then
        echo "Initializing PostgreSQL..."
        /bin/su postgres -c "/bin/initdb -D /data/postgres --auth=trust --no-locale --encoding=UTF8"

        # Copy configuration files
        /bin/cp ${postgresqlConf} /data/postgres/postgresql.conf
        /bin/cp ${pgHbaConf} /data/postgres/pg_hba.conf
        /bin/chown postgres:postgres /data/postgres/postgresql.conf /data/postgres/pg_hba.conf 2>/dev/null || true
        /bin/chmod 600 /data/postgres/postgresql.conf /data/postgres/pg_hba.conf
      fi

      # Setup Garage configuration
      if [ ! -f /data/garage/garage.toml ]; then
        echo "Setting up Garage configuration..."
        /bin/cp ${garageConf} /data/garage/garage.toml
        /bin/chown garage:garage /data/garage/garage.toml 2>/dev/null || true
        /bin/chmod 600 /data/garage/garage.toml
      fi

      echo "Starting PostgreSQL..."
      /bin/su postgres -c "/bin/postgres -D /data/postgres" &

      echo "Starting Redis..."
      /bin/su redis -c "/bin/redis-server --dir /data/redis --bind 127.0.0.1 --port 6379 --daemonize no --save \"\"" &

      echo "Starting Garage..."
      /bin/su garage -c "/bin/garage -c /data/garage/garage.toml server" &

      echo "Waiting for services to start..."
      /bin/sleep 5

      # Initialize Garage if needed
      if [ ! -f /data/garage/.initialized ]; then
        echo "Initializing Garage cluster..."
        /bin/sleep 3

        # Get node ID and setup cluster
        for i in {1..5}; do
          NODE_ID=$(/bin/garage -c /data/garage/garage.toml status 2>/dev/null | /bin/grep -E '^[a-f0-9]{16}' | /bin/head -1 | /bin/awk '{print $1}' || echo "")
          if [ -n "$NODE_ID" ]; then
            echo "Found Node ID: $NODE_ID"
            /bin/garage -c /data/garage/garage.toml layout assign "$NODE_ID" -z dc1 -c 1024 -t 1
            /bin/sleep 1
            /bin/garage -c /data/garage/garage.toml layout apply --version 1
            /bin/sleep 2

            # Create S3 credentials
            KEY_OUTPUT=$(/bin/garage -c /data/garage/garage.toml key create default-key 2>/dev/null || echo "")
            if echo "$KEY_OUTPUT" | /bin/grep -q "Key ID:"; then
              ACCESS_KEY=$(echo "$KEY_OUTPUT" | /bin/grep "Key ID:" | /bin/awk '{print $3}')
              SECRET_KEY=$(echo "$KEY_OUTPUT" | /bin/grep "Secret key:" | /bin/awk '{print $3}')

              echo "AWS_ACCESS_KEY_ID=$ACCESS_KEY" > /data/garage/credentials.env
              echo "AWS_SECRET_ACCESS_KEY=$SECRET_KEY" >> /data/garage/credentials.env
              /bin/chmod 600 /data/garage/credentials.env

              /bin/garage -c /data/garage/garage.toml bucket create default-bucket 2>/dev/null || true
              /bin/garage -c /data/garage/garage.toml bucket allow default-bucket --read --write --key default-key 2>/dev/null || true
            fi
            break
          fi
          echo "Waiting for Garage to initialize... attempt $i"
          /bin/sleep 2
        done

        /bin/touch /data/garage/.initialized
      fi

      # Load existing credentials
      if [ -f /data/garage/credentials.env ]; then
        # shellcheck disable=SC1091
        . /data/garage/credentials.env
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
      fi

      echo "Starting Flask application..."
      cd /app
      exec ${python-env}/bin/python app.py
    '';
  };

in
pkgs.dockerTools.buildLayeredImage {
  name = "nixify-health-check";
  tag = "latest";

  # Minimal static contents for ultra-small image
  contents = [
    essentialBinaries
    python-env
    baseDirectories
  ];

  extraCommands = ''
    # Copy application
    mkdir -p app
    cp ${./app.py} app/app.py

    # Copy user/group files
    mkdir -p etc
    cp ${users}/etc/passwd etc/passwd
    cp ${users}/etc/group etc/group
    cp ${users}/etc/shadow etc/shadow

    # Copy startup script
    mkdir -p usr/local/bin
    cp ${startScript}/bin/start-services usr/local/bin/
    chmod +x usr/local/bin/start-services

    # Ensure proper directory structure
    mkdir -p data/postgres data/redis data/garage/meta data/garage/data tmp var/run var/log

    echo "Optimizing static image for ultra-minimal size..."

    # Remove all dynamic libraries and static artifacts (not needed for static builds)
    find . \( -name "*.a" -o -name "*.la" -o -name "*.so*" -o -name "*.debug" \) -delete 2>/dev/null || true

    # Aggressive cleanup of documentation and metadata
    find . -type d \( -name "share" -o -name "doc" -o -name "man" -o -name "info" -o -name "locale" \) -exec rm -rf {} + 2>/dev/null || true

    # Remove Python development artifacts
    find . \( -name "*.pyc" -o -name "*.pyo" -o -name "__pycache__" -o -name "*.egg-info" -o -name "*.dist-info" \) -exec rm -rf {} + 2>/dev/null || true
    find . -path "*/test*" -o -path "*/tests*" -o -path "*/testing*" -exec rm -rf {} + 2>/dev/null || true

    # Remove development and build artifacts
    find . -path "*/include/*" -o -path "*/lib/pkgconfig/*" -o -path "*/lib/cmake/*" -delete 2>/dev/null || true
    find . -name "*.h" -o -name "*.hpp" -o -name "*.pc" -delete 2>/dev/null || true

    # Remove locale and internationalization files
    find . -path "*/LC_*" -o -path "*/locale/*" -delete 2>/dev/null || true

    # Remove any remaining non-essential binaries in lib directories
    find . -path "*/lib/*" -type f -executable ! -name "python*" -delete 2>/dev/null || true

    # Final cleanup of empty directories
    find . -type d -empty -delete 2>/dev/null || true

    echo "Ultra-minimal static image optimization completed"
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
      "GARAGE_S3_ENDPOINT=http://127.0.0.1:3900"
      "GARAGE_S3_REGION=garage"
      "PATH=/bin:/usr/local/bin"
    ];
    WorkingDir = "/app";
    User = "root";
  };

  # Optimize for size with minimal layers for static builds
  maxLayers = 5;
}
