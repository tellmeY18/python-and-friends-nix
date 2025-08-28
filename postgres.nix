{ pkgs }:
let
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
    unix_socket_directories = '/tmp'
    log_timezone = 'UTC'
    timezone = 'UTC'
    lc_messages = 'en_US.utf8'
    lc_monetary = 'en_US.utf8'
    lc_numeric = 'en_US.utf8'
    lc_time = 'en_US.utf8'
    default_text_search_config = 'pg_catalog.english'
  '';

  pgHbaConf = pkgs.writeText "pg_hba.conf" ''
    local   all             all                                     trust
    host    all             all             127.0.0.1/32            trust
    host    all             all             ::1/128                 trust
  '';

  # PostgreSQL initialization and startup functions
  setupPostgreSQL = ''
    echo "Setting up PostgreSQL..."

    # Set ownership for postgres data directory
    chown postgres:postgres /data/postgres
    chmod 700 /data/postgres

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
  '';

  startPostgreSQL = ''
    echo "Starting PostgreSQL as postgres user..."
    setpriv --reuid=999 --regid=999 --clear-groups ${pkgs.postgresql_15}/bin/postgres -D /data/postgres &

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

    # Create database for Care
    echo "Creating Care database..."
    ${pkgs.postgresql_15}/bin/createdb -h 127.0.0.1 -U postgres care || echo "Database 'care' may already exist"
  '';

in
{
  inherit setupPostgreSQL startPostgreSQL;

  # Runtime dependencies
  runtimeInputs = [ pkgs.postgresql_15 ];

  # System packages needed
  packages = [ pkgs.postgresql_15 pkgs.libpq ];

  # Environment variables
  envVars = [
    "DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/care"
    "POSTGRES_HOST=127.0.0.1"
    "POSTGRES_PORT=5432"
    "POSTGRES_USER=postgres"
    "POSTGRES_PASSWORD=postgres"
    "POSTGRES_DB=care"
  ];

  # Directory setup
  directories = "mkdir -p /data/postgres";
  directoryPermissions = "chmod 700 /data/postgres";
}
