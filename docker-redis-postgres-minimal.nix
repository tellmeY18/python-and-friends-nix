{ pkgs, careSource }:
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

  # Python environment with basic tools for pip installation
  pythonEnv = pkgs.python313.withPackages (ps: with ps; [
    pip
    setuptools
    wheel
    virtualenv
  ]);

  # PostgreSQL configuration files
  postgresqlConf = pkgs.writeText "postgresql.conf" ''
    port = 5432
    listen_addresses = '127.0.0.1'
    max_connections = 100
    shared_buffers = 128MB
    effective_cache_size = 256MB
    maintenance_work_mem = 64MB
    checkpoint_completion_target = 0.9
    wal_buffers = 16MB
    default_statistics_target = 100
    random_page_cost = 1.1
    effective_io_concurrency = 200
    work_mem = 4MB
    min_wal_size = 1GB
    max_wal_size = 4GB
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
    runtimeInputs = with pkgs; [
      postgresql_15 redis garage_2 pythonEnv coreutils shadow util-linux
      gnused gawk gnugrep procps wget gnutar xz findutils git
    ];
    text = ''
      set -euo pipefail

      echo "🏥 Starting Care Production Environment..."

      echo "Setting up directories and permissions..."

      # Ensure directories exist with correct permissions
      mkdir -p /data/postgres /data/redis /data/garage/meta /data/garage/data /tmp /var/run /var/log /app/staticfiles /app/media

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

      # Set ownership for Care app directories
      chown -R care:care /app
      chmod 755 /app/staticfiles /app/media

      # Fix /tmp permissions for PostgreSQL socket
      chmod 1777 /tmp
      chown root:root /tmp

      # Initialize PostgreSQL if needed (as postgres user)
      if [ ! -f /data/postgres/PG_VERSION ]; then
        echo "Initializing PostgreSQL as postgres user..."
        setpriv --reuid=999 --regid=999 --clear-groups ${pkgs.postgresql_15}/bin/initdb -D /data/postgres --auth=trust

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
      setpriv --reuid=999 --regid=999 --clear-groups ${pkgs.postgresql_15}/bin/postgres -D /data/postgres &

      echo "Starting Redis as redis user..."
      setpriv --reuid=998 --regid=998 --clear-groups ${pkgs.redis}/bin/redis-server --dir /data/redis --bind 127.0.0.1 --port 6379 &

      echo "Starting Garage as garage user..."
      setpriv --reuid=997 --regid=997 --clear-groups ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml server &

      echo "Waiting for services to start..."
      sleep 8

      # Wait for PostgreSQL to be ready
      echo "Waiting for PostgreSQL to be ready..."
      for i in {1..30}; do
        if ${pkgs.postgresql_15}/bin/pg_isready -h 127.0.0.1 -p 5432 -U postgres; then
          echo "PostgreSQL is ready!"
          break
        fi
        echo "Waiting for PostgreSQL... attempt $i"
        sleep 2
      done

      # Wait for Redis to be ready
      echo "Waiting for Redis to be ready..."
      for i in {1..30}; do
        if ${pkgs.redis}/bin/redis-cli -h 127.0.0.1 -p 6379 ping | grep -q PONG; then
          echo "Redis is ready!"
          break
        fi
        echo "Waiting for Redis... attempt $i"
        sleep 2
      done

      # Create database for Care
      echo "Creating Care database..."
      ${pkgs.postgresql_15}/bin/createdb -h 127.0.0.1 -U postgres care || echo "Database 'care' may already exist"

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
          sleep 2

          # Try to create key with timeout
          timeout 30 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml key create care-key > /tmp/key_output.txt 2>&1 &
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
              chown garage:garage /data/garage/credentials.env

              # Create buckets and set permissions
              echo "Creating buckets..."
              timeout 15 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket create patient-bucket || echo "Patient bucket may already exist"
              timeout 15 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket create facility-bucket || echo "Facility bucket may already exist"
              sleep 1
              echo "Setting bucket permissions..."
              timeout 15 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket allow patient-bucket --read --write --key care-key || echo "Patient bucket permission setting may have failed"
              timeout 15 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket allow facility-bucket --read --write --key care-key || echo "Facility bucket permission setting may have failed"

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
        export BUCKET_KEY="$AWS_ACCESS_KEY_ID"
        export BUCKET_SECRET="$AWS_SECRET_ACCESS_KEY"
        echo "Loaded credentials for key: $AWS_ACCESS_KEY_ID"
      fi

      # Switch to care user for application setup
      echo "Setting up Care Django application..."
      cd /app

      # Install Python dependencies as care user
      if [ ! -f /app/.deps_installed ]; then
        echo "Installing Python dependencies from Pipfile.lock..."

        # Create home directory for care user
        mkdir -p /home/care/.local/bin
        chown -R care:care /home/care

        # Install pipenv and dependencies
        setpriv --reuid=996 --regid=996 --clear-groups python -m pip install --user pipenv

        # Install from Pipfile.lock (production dependencies only)
        export PIPENV_VENV_IN_PROJECT=1
        setpriv --reuid=996 --regid=996 --clear-groups /home/care/.local/bin/pipenv install --system --deploy --ignore-pipfile

        # Install plugins if available
        if [ -f install_plugins.py ]; then
          echo "Installing Care plugins..."
          setpriv --reuid=996 --regid=996 --clear-groups python install_plugins.py
        fi

        touch /app/.deps_installed
        chown care:care /app/.deps_installed
      fi

      # Run Django setup as care user
      echo "Running Django migrations and setup..."
      export DJANGO_SETTINGS_MODULE=config.settings.production

      setpriv --reuid=996 --regid=996 --clear-groups python manage.py migrate --noinput
      setpriv --reuid=996 --regid=996 --clear-groups python manage.py compilemessages -v 0 || echo "Message compilation may have failed"
      setpriv --reuid=996 --regid=996 --clear-groups python manage.py collectstatic --noinput

      # Sync permissions and roles if available
      setpriv --reuid=996 --regid=996 --clear-groups python manage.py sync_permissions_roles || echo "Permissions sync may have failed"
      setpriv --reuid=996 --regid=996 --clear-groups python manage.py sync_valueset || echo "Valueset sync may have failed"

      echo "Starting Celery worker and beat as care user..."
      setpriv --reuid=996 --regid=996 --clear-groups celery -A config.celery_app worker -B --loglevel=INFO --detach

      echo "🚀 Starting Care Django application as care user..."
      cd /app
      exec setpriv --reuid=996 --regid=996 --clear-groups gunicorn config.wsgi:application \
        --bind 0.0.0.0:8000 \
        --workers 4 \
        --worker-class sync \
        --worker-connections 1000 \
        --max-requests 1000 \
        --max-requests-jitter 50 \
        --preload \
        --timeout 30 \
        --keep-alive 5 \
        --log-level info \
        --access-logfile - \
        --error-logfile -
    '';
  };

in
pkgs.dockerTools.buildLayeredImage {
  name = "care-production";
  tag = "latest";

  # Use required system packages for build and runtime
  contents = with pkgs; [
    # Core system utilities
    coreutils
    shadow
    bash
    util-linux
    gawk
    gnugrep
    gnused
    procps
    findutils
    gzip
    gnutar
    xz

    # Network utilities
    wget
    curl

    # Build dependencies (equivalent to build-essential)
    gcc
    gnumake
    pkg-config
    git

    # Runtime dependencies
    gettext

    # Database and services
    postgresql_15
    redis
    garage_2

    # Python environment
    pythonEnv

    # System libraries for pip packages (runtime deps)
    zlib
    libjpeg          # For Pillow
    libpq            # For psycopg
    gmp              # For some cryptography packages
    openssl          # For SSL/TLS
    libffi           # For cffi-based packages

    # Typst for document generation
    typst

    # Directory structure
    baseDirectories
  ];

  extraCommands = ''
    # Copy Care application from flake input
    mkdir -p app

    echo "Copying Care application source from flake input..."
    cp -r ${careSource}/* app/

    # Remove git directory and other unnecessary files
    rm -rf app/.git app/.github app/.vscode app/.devcontainer
    chmod -R +w app/docs app/data/sample_data 2>/dev/null || true
    rm -rf app/docs app/data/sample_data

    # Ensure essential files are present
    chmod +x app/manage.py

    # Copy user/group files from our users derivation
    mkdir -p etc
    cp ${users}/etc/passwd etc/passwd
    cp ${users}/etc/group etc/group
    cp ${users}/etc/shadow etc/shadow

    # Copy startup script
    mkdir -p usr/local/bin
    cp ${startScript}/bin/start-services usr/local/bin/
    chmod +x usr/local/bin/start-services

    # Create home directory for care user
    mkdir -p home/care

    # Ensure proper directory structure exists
    mkdir -p data/postgres data/redis data/garage/meta data/garage/data tmp var/run var/log app/staticfiles app/media

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
    Env = [
      # Django settings
      "DJANGO_SETTINGS_MODULE=config.settings.production"
      "DJANGO_DEBUG=false"
      "IS_PRODUCTION=true"

      # Database
      "DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/care"
      "POSTGRES_HOST=127.0.0.1"
      "POSTGRES_PORT=5432"
      "POSTGRES_USER=postgres"
      "POSTGRES_PASSWORD=postgres"
      "POSTGRES_DB=care"

      # Redis/Celery
      "REDIS_URL=redis://127.0.0.1:6379/0"
      "CELERY_BROKER_URL=redis://127.0.0.1:6379/0"

      # S3/Storage (will be overridden by Garage credentials)
      "BUCKET_REGION=garage"
      "BUCKET_ENDPOINT=http://127.0.0.1:3900"
      "BUCKET_EXTERNAL_ENDPOINT=http://127.0.0.1:3900"
      "FILE_UPLOAD_BUCKET=patient-bucket"
      "FACILITY_S3_BUCKET=facility-bucket"

      # Security
      "SECRET_KEY=care-production-secret-key-change-in-production"
      "CORS_ALLOWED_ORIGINS=[]"
      "CORS_ALLOWED_ORIGIN_REGEXES=[]"
      "DJANGO_SECURE_SSL_REDIRECT=false"

      # Other Care-specific settings
      "USE_SMS=false"
      "SEND_SMS_NOTIFICATION=false"
      "TYPST_VERSION=0.12.0"

      # Python settings
      "PYTHONPATH=/app"
      "PYTHONUNBUFFERED=1"
      "PYTHONDONTWRITEBYTECODE=1"

      # Pipenv settings
      "PIPENV_VENV_IN_PROJECT=1"

      # Locale
      "LANG=en_US.UTF-8"
      "LC_ALL=C.UTF-8"
    ];
    WorkingDir = "/app";
    User = "root";  # Start as root to manage permissions, then drop to service users
  };

  # Optimize layers for better caching and smaller size
  maxLayers = 25;
}
