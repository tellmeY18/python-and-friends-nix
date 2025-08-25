# Nixify Health Check

A minimal, reproducible containerized health monitoring application built with Nix for `aarch64-linux`.

## Overview

This project demonstrates a clean, simple approach to building Docker containers with Nix. It packages:

- **Flask Health Check API**: Simple health monitoring endpoints
- **Redis**: In-memory data store 
- **PostgreSQL**: Relational database
- **Nix Flakes**: Reproducible builds targeting `aarch64-linux`

## Quick Start

### Prerequisites

- Nix with flakes enabled
- `aarch64-linux` build capability (native or remote builder)
- Docker for running containers

### Build and Run

```bash
# Build the Docker image (uses remote builder if needed)
make build

# Run the container on port 8080
make run

# Check health
make health

# View logs
make logs

# Clean up
make clean
```

## API Endpoints

- `GET /` - Service information and status
- `GET /health` - Overall health check (200/503)
- `GET /health/redis` - Redis-specific health check
- `GET /health/postgres` - PostgreSQL-specific health check

## Project Structure

```
mono/
├── app.py                           # Flask application with health checks
├── docker-redis-postgres-minimal.nix # Docker image definition
├── flake.nix                        # Simple Nix flake for aarch64-linux
├── Makefile                         # Basic build/run commands
└── README.md                        # This file
```

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `REDIS_HOST` | `127.0.0.1` | Redis hostname |
| `REDIS_PORT` | `6379` | Redis port |
| `PG_HOST` | `127.0.0.1` | PostgreSQL hostname |
| `PG_PORT` | `5432` | PostgreSQL port |
| `POSTGRES_USER` | `postgres` | PostgreSQL username |
| `POSTGRES_DB` | `postgres` | PostgreSQL database |
| `APP_PORT` | `80` | Flask application port |

## Architecture

The container runs three services:

1. **PostgreSQL** - Initialized on first run, data persisted in `/data/postgres`
2. **Redis** - Simple in-memory cache, data in `/data/redis`  
3. **Flask App** - Health monitoring API on port 80

All services run as root for simplicity in this POC. Services are bound to localhost only for security.

## Build Details

- **Target Platform**: `aarch64-linux` only
- **Base**: Minimal Nix packages (no bloated base images)
- **Size Optimized**: Uses `buildLayeredImage` for efficient Docker layers
- **Reproducible**: Same build every time via Nix

## Development

```bash
# Enter development shell (aarch64-linux)
nix develop --system aarch64-linux

# Run locally (requires Redis + PostgreSQL)
python app.py
```

## Why Nix?

1. **Reproducible**: Identical containers across environments
2. **Minimal**: Only necessary dependencies included
3. **No Dockerfile**: Infrastructure as code
4. **Cached**: Efficient builds with Nix store
5. **Declarative**: Clear dependency management

## Commands

```bash
make build    # Build Docker image
make run      # Start container on port 8080  
make logs     # Show container logs
make stop     # Stop and remove container
make health   # Check application health
make clean    # Clean up everything
```

## Troubleshooting

**Build fails**: Ensure you have `aarch64-linux` build capability configured.

**Container won't start**: Check if ports 8080, 5432, or 6379 are already in use.

**Health check fails**: Services need a few seconds to initialize. Check logs with `make logs`.

## License

MIT License