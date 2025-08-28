{ pkgs }:
let
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

  # Garage setup and startup functions
  setupGarage = ''
    echo "Setting up Garage..."

    # Set ownership for garage data directory
    chown garage:garage /data/garage
    chown garage:garage /data/garage/meta
    chown garage:garage /data/garage/data
    chmod 755 /data/garage /data/garage/meta /data/garage/data

    # Setup Garage configuration
    if [ ! -f /data/garage/garage.toml ]; then
      echo "Setting up Garage configuration..."
      cp ${garageConf} /data/garage/garage.toml
      chown garage:garage /data/garage/garage.toml
      chmod 600 /data/garage/garage.toml
    fi
  '';

  startGarage = ''
    echo "Starting Garage as garage user..."
    setpriv --reuid=997 --regid=997 --clear-groups ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml server &

    # Initialize Garage layout and keys
    if [ ! -f /data/garage/.initialized ]; then
      echo "Initializing Garage cluster layout..."
      sleep 8

      # Wait for Garage to be ready and get node ID
      for i in {1..20}; do
        NODE_ID=$(${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml status 2>/dev/null | grep -E '^[a-f0-9]{16}' | head -1 | awk '{print $1}' || echo "")
        if [ -n "$NODE_ID" ]; then
          echo "Found Node ID: $NODE_ID"
          break
        fi
        echo "Waiting for Garage to initialize... attempt $i"
        sleep 3
      done

      if [ -n "$NODE_ID" ]; then
        echo "Setting up Garage cluster with node $NODE_ID"
        ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml layout assign "$NODE_ID" -z dc1 -c 1024 -t 1
        sleep 2
        ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml layout apply --version 1
        sleep 5

        # Generate new S3 credentials and save them
        echo "Creating S3 credentials..."
        sleep 3

        # Try to create key with timeout
        timeout 60 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml key create care-key > /tmp/key_output.txt 2>&1 &
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
            timeout 30 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket create patient-bucket || echo "Patient bucket may already exist"
            timeout 30 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket create facility-bucket || echo "Facility bucket may already exist"
            sleep 2

            echo "Setting bucket permissions..."
            timeout 30 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket allow patient-bucket --read --write --key care-key || echo "Patient bucket permission setting may have failed"
            timeout 30 ${pkgs.garage_2}/bin/garage -c /data/garage/garage.toml bucket allow facility-bucket --read --write --key care-key || echo "Facility bucket permission setting may have failed"

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
  '';

  loadGarageCredentials = ''
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
  '';

in
{
  inherit setupGarage startGarage loadGarageCredentials;

  # Runtime dependencies
  runtimeInputs = [ pkgs.garage_2 ];

  # System packages needed
  packages = [ pkgs.garage_2 ];

  # Environment variables
  envVars = [
    "BUCKET_REGION=garage"
    "BUCKET_ENDPOINT=http://127.0.0.1:3900"
    "BUCKET_EXTERNAL_ENDPOINT=http://127.0.0.1:3900"
    "FILE_UPLOAD_BUCKET=patient-bucket"
    "FACILITY_S3_BUCKET=facility-bucket"
  ];

  # Directory setup
  directories = "mkdir -p /data/garage/meta /data/garage/data";
  directoryPermissions = "chmod 755 /data/garage /data/garage/meta /data/garage/data";
}
