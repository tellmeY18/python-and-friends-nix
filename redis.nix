{ pkgs }:
let
  # Redis setup and startup functions
  setupRedis = ''
    echo "Setting up Redis..."

    # Set ownership for redis data directory
    chown redis:redis /data/redis
    chmod 755 /data/redis
  '';

  startRedis = ''
    echo "Starting Redis as redis user..."
    setpriv --reuid=998 --regid=998 --clear-groups ${pkgs.redis}/bin/redis-server --dir /data/redis --bind 127.0.0.1 --port 6379 &

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
  '';

in
{
  inherit setupRedis startRedis;

  # Runtime dependencies
  runtimeInputs = [ pkgs.redis ];

  # System packages needed
  packages = [ pkgs.redis ];

  # Environment variables
  envVars = [
    "REDIS_URL=redis://127.0.0.1:6379/0"
    "CELERY_BROKER_URL=redis://127.0.0.1:6379/0"
  ];

  # Directory setup
  directories = "mkdir -p /data/redis";
  directoryPermissions = "chmod 755 /data/redis";
}
