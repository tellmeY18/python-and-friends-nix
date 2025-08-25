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
    nativeBuildInputs = [ pkgs.coreutils ];
  } ''
    mkdir -p $out/data/postgres $out/data/redis $out/data/garage $out/tmp $out/var/run $out/var/log
    chmod 755 $out/data $out/tmp $out/var/run $out/var/log
    chmod 700 $out/data/postgres
    chmod 755 $out/data/redis
    chmod 755 $out/data/garage
  '';

  # Minimal Python environment with required packages
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    flask
    psycopg2
    redis
    boto3
    werkzeug
    jinja2
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

  # Garage configuration
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
    api_bind_addr = "0.0.0.0:3900"
    root_domain = ".s3.garage.localhost"

    [s3_web]
    bind_addr = "0.0.0.0:3902"
    root_domain = ".web.garage.localhost"
    index = "index.html"

    [admin]
    api_bind_addr = "0.0.0.0:3903"
    admin_token = "changeme"
    metrics_token = "changeme"
  '';

  # Startup script that properly handles users
  startScript = pkgs.writeShellApplication {
    name = "start-services";
    runtimeInputs = with pkgs; [ postgresql redis garage_2 coreutils shadow util-linux ];
    text = ''
      set -euo pipefail

      echo "Setting up directories and permissions..."

      # Ensure directories exist with correct permissions
      mkdir -p /data/postgres /data/redis /data/garage/meta /data/garage/data /tmp /var/run /var/log

      # Set ownership for postgres data directory
      chown postgres:postgres /data/postgres
      chmod 700 /data/postgres

      # Set ownership for redis data directory
      chown redis:redis /data/redis
      chmod 755 /data/redis

      # Set ownership for garage data directory
      chown garage:garage /data/garage
      chown garage:garage /data/garage/meta
      chown garage:garage /data/garage/data
      chmod 755 /data/garage /data/garage/meta /data/garage/data

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

      # Setup Garage configuration
      if [ ! -f /data/garage/garage.toml ]; then
        echo "Setting up Garage configuration..."
        cp ${garageConf} /data/garage/garage.toml
        chown garage:garage /data/garage/garage.toml
        chmod 600 /data/garage/garage.toml
      fi

      echo "Starting PostgreSQL as postgres user..."
      setpriv --reuid=999 --regid=999 --clear-groups ${pkgs.postgresql}/bin/postgres -D /data/postgres &

      echo "Starting Redis as redis user..."
      setpriv --reuid=998 --regid=998 --clear-groups ${pkgs.redis}/bin/redis-server --dir /data/redis --bind 127.0.0.1 --port 6379 &

      echo "Starting Garage as garage user..."
      setpriv --reuid=997 --regid=997 --clear-groups ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml server &

      echo "Waiting for services to start..."
      sleep 8

      # Initialize Garage layout and keys
      if [ ! -f /data/garage/.initialized ]; then
        echo "Initializing Garage cluster layout..."
        sleep 5

        # Wait for Garage to be ready and get node ID
        for i in {1..10}; do
          NODE_ID=$(${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml status 2>/dev/null | grep -E '^[a-f0-9]{16}' | head -1 | awk '{print $1}' || echo "")
          if [ -n "$NODE_ID" ]; then
            echo "Found Node ID: $NODE_ID"
            break
          fi
          echo "Waiting for Garage to initialize... attempt $i"
          sleep 2
        done

        if [ -n "$NODE_ID" ]; then
          echo "Setting up Garage cluster with node $NODE_ID"
          ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml layout assign "$NODE_ID" -z dc1 -c 1024 -t 1
          sleep 2
          ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml layout apply --version 1
          sleep 3

          # Generate new S3 credentials and save them
          echo "Creating S3 credentials..."
          sleep 2  # Give Garage time to fully initialize

          # Try to create key with timeout
          timeout 30 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml key create default-key > /tmp/key_output.txt 2>&1 &
          KEY_PID=$!

          if wait $KEY_PID; then
            KEY_OUTPUT=$(cat /tmp/key_output.txt)
            echo "Key creation output: $KEY_OUTPUT"

            if echo "$KEY_OUTPUT" | grep -q "Key ID:"; then
              ACCESS_KEY=$(echo "$KEY_OUTPUT" | grep "Key ID:" | awk '{print $3}')
              SECRET_KEY=$(echo "$KEY_OUTPUT" | grep "Secret key:" | awk '{print $3}')

              echo "Generated Access Key: $ACCESS_KEY"

              # Save credentials to persistent storage
              echo "AWS_ACCESS_KEY_ID=$ACCESS_KEY" > /data/garage/credentials.env
              echo "AWS_SECRET_ACCESS_KEY=$SECRET_KEY" >> /data/garage/credentials.env
              chmod 600 /data/garage/credentials.env

              # Create bucket and set permissions
              echo "Creating bucket..."
              timeout 15 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket create default-bucket || echo "Bucket may already exist"
              sleep 1
              echo "Setting bucket permissions..."
              timeout 15 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket allow default-bucket --read --write --key default-key || echo "Permission setting may have failed"

              echo "Garage setup completed successfully"
            else
              echo "Failed to create S3 key - no access key found in output"
              echo "Full output: $KEY_OUTPUT"
            fi
          else
            echo "Key creation timed out or failed"
            cat /tmp/key_output.txt 2>/dev/null || echo "No output captured"
          fi
        else
          echo "Failed to get Garage node ID"
        fi

        touch /data/garage/.initialized
      fi

      # Load credentials from persistent storage
      if [ -f /data/garage/credentials.env ]; then
        echo "Loading existing S3 credentials..."
        # shellcheck disable=SC1091
        . /data/garage/credentials.env
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
        echo "Loaded credentials for key: $AWS_ACCESS_KEY_ID"
      fi

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
    garage_2
    pythonEnv
    coreutils
    shadow
    bash
    util-linux
    gawk
    gnugrep
    procps
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
    mkdir -p data/postgres data/redis data/garage/meta data/garage/data tmp var/run var/log

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
      "GARAGE_S3_ENDPOINT=http://127.0.0.1:3900"
      "GARAGE_S3_REGION=garage"
    ];
    WorkingDir = "/app";
    User = "root";  # Start as root to manage permissions, then drop to service users
  };

  # Optimize layers for better caching and smaller size
  maxLayers = 25;
}
