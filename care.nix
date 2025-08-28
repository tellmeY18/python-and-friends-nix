{ pkgs, careSource }:
let
  # Python environment with basic tools for pip installation
  pythonEnv = pkgs.python313.withPackages (ps: with ps; [
    pip
    setuptools
    wheel
    virtualenv
  ]);

  # Care Django application setup and startup functions
  setupCare = ''
    echo "Setting up Care Django application..."

    # Set ownership for Care app directories
    chown -R care:care /app
    chmod 755 /app/staticfiles /app/media

    # Create home directory for care user
    mkdir -p /home/care/.local/bin /home/care/.cache
    chown -R care:care /home/care

    # Install Python dependencies as care user
    if [ ! -f /app/.deps_installed ]; then
      echo "Installing Python dependencies from Pipfile.lock..."

      # Set up environment for pip installation
      export PIP_CACHE_DIR=/home/care/.cache/pip
      export PIPENV_VENV_IN_PROJECT=1
      export HOME=/home/care

      # Create cache directory with proper ownership
      mkdir -p /home/care/.cache/pip
      chown -R care:care /home/care/.cache

      # Install pipenv and dependencies as care user (without --user flag)
      setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care PIP_CACHE_DIR=/home/care/.cache/pip python -m pip install pipenv

      # Install from Pipfile.lock (production dependencies only)
      setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care PIP_CACHE_DIR=/home/care/.cache/pip PIPENV_VENV_IN_PROJECT=1 /home/care/.local/bin/pipenv install --system --deploy --ignore-pipfile

      # Install plugins if available
      if [ -f install_plugins.py ]; then
        echo "Installing Care plugins..."
        setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care python install_plugins.py
      fi

      touch /app/.deps_installed
      chown care:care /app/.deps_installed
    fi
  '';

  setupDjango = ''
    echo "Running Django migrations and setup..."

    # Set environment variables for Django
    export DJANGO_SETTINGS_MODULE=config.settings.production
    export HOME=/home/care

    # Run Django setup as care user
    setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care DJANGO_SETTINGS_MODULE=config.settings.production python manage.py migrate --noinput
    setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care DJANGO_SETTINGS_MODULE=config.settings.production python manage.py compilemessages -v 0 || echo "Message compilation may have failed"
    setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care DJANGO_SETTINGS_MODULE=config.settings.production python manage.py collectstatic --noinput

    # Sync permissions and roles if available
    setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care DJANGO_SETTINGS_MODULE=config.settings.production python manage.py sync_permissions_roles || echo "Permissions sync may have failed"
    setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care DJANGO_SETTINGS_MODULE=config.settings.production python manage.py sync_valueset || echo "Valueset sync may have failed"
  '';

  startCelery = ''
    echo "Starting Celery worker and beat as care user..."
    setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care celery -A config.celery_app worker -B --loglevel=INFO --detach
  '';

  startDjango = ''
    echo "🚀 Starting Care Django application as care user..."
    cd /app
    exec setpriv --reuid=996 --regid=996 --init-groups env HOME=/home/care gunicorn config.wsgi:application \
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

  # Copy Care application source
  copyCareSource = ''
    # Copy Care application from flake input
    mkdir -p app

    echo "Copying Care application source from flake input..."
    cp -r ${careSource}/* app/

    # Remove git directory and other unnecessary files
    chmod -R +w app/docs app/data/sample_data 2>/dev/null || true
    rm -rf app/.git app/.github app/.vscode app/.devcontainer
    rm -rf app/docs app/data/sample_data

    # Ensure essential files are present
    chmod +x app/manage.py

    # Create home directory for care user
    mkdir -p home/care

    # Ensure proper directory structure exists
    mkdir -p app/staticfiles app/media
  '';

in
{
  inherit setupCare setupDjango startCelery startDjango copyCareSource;

  # Runtime dependencies
  runtimeInputs = [ pythonEnv pkgs.git ];

  # System packages needed
  packages = [
    pythonEnv
    pkgs.git
    pkgs.gcc
    pkgs.gnumake
    pkgs.pkg-config
    pkgs.gettext
    pkgs.zlib
    pkgs.libjpeg
    pkgs.libpq
    pkgs.gmp
    pkgs.openssl
    pkgs.libffi
    pkgs.typst
  ];

  # Environment variables
  envVars = [
    "DJANGO_SETTINGS_MODULE=config.settings.production"
    "DJANGO_DEBUG=false"
    "IS_PRODUCTION=true"
    "SECRET_KEY=care-production-secret-key-change-in-production"
    "CORS_ALLOWED_ORIGINS=[]"
    "CORS_ALLOWED_ORIGIN_REGEXES=[]"
    "DJANGO_SECURE_SSL_REDIRECT=false"
    "USE_SMS=false"
    "SEND_SMS_NOTIFICATION=false"
    "TYPST_VERSION=0.12.0"
    "PYTHONPATH=/app"
    "PYTHONUNBUFFERED=1"
    "PYTHONDONTWRITEBYTECODE=1"
    "PIPENV_VENV_IN_PROJECT=1"
    "LANG=en_US.UTF-8"
    "LC_ALL=C.UTF-8"
  ];

  # Directory setup
  directories = "mkdir -p /app/staticfiles /app/media /home/care";
  directoryPermissions = "chmod 755 /app/staticfiles /app/media";
}
