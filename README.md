# Nixify Health Check

A minimal, reproducible containerized health monitoring application built with Nix using static (musl) builds for optimal size and portability.

## Overview

This project demonstrates building optimized Docker containers with Nix using static musl-based binaries for minimal container size and maximum portability across different Linux distributions.

### Services Included

- **Flask Health Check API**: Simple health monitoring endpoints  
- **Redis**: In-memory data store
- **PostgreSQL**: Relational database
- **Garage S3**: Lightweight S3-compatible object storage
- **Nix Flakes**: Reproducible, multi-architecture builds

## Quick Start

### Prerequisites

- Nix with flakes enabled
- Docker for running containers
- GitHub Actions for automated building (recommended)

### Local Development

```bash
# Build static Docker image
make build

# Run static container on port 8080
make run

# Check health status
make health

# View logs
make logs

# Clean up
make clean

# Show image information
make info
```

### GitHub Actions (Recommended)

The project includes automated GitHub Actions workflows that:

- Build for both x86_64 and aarch64 architectures
- Create static musl-based images only
- Push to GitHub Container Registry (ghcr.io)
- Generate multi-architecture manifests

**Available workflow:**
- `.github/workflows/build-docker.yml` - Multi-arch static build

## API Endpoints

- `GET /` - Service information and status
- `GET /health` - Overall health check (200/503)
- `GET /health/redis` - Redis-specific health check
- `GET /health/postgres` - PostgreSQL-specific health check

## Project Structure

```
mono/
├── app.py                                    # Flask application with health checks
├── docker-redis-postgres-minimal-static.nix # Static Docker image (musl)
├── flake.nix                                 # Nix flake 
├── Makefile                                  # Build/run commands
├── .github/workflows/                        # GitHub Actions workflows
│   └── build-docker.yml                     # Multi-arch static build
└── README.md                                 # This file
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

The container runs four services:

1. **PostgreSQL** - Initialized on first run, data persisted in `/data/postgres`
2. **Redis** - Simple in-memory cache, data in `/data/redis`
3. **Garage S3** - Lightweight object storage, data in `/data/garage` 
4. **Flask App** - Health monitoring API on port 80

All services run as dedicated users for security, but startup happens as root for proper initialization.

## Build Details

### Static Build (`docker-redis-postgres-minimal-static.nix`)
- **libc**: musl (minimal libc)
- **Linking**: Static binaries with minimal dependencies
- **Compatibility**: Excellent portability across Linux distributions
- **Size**: Optimized (~100-200MB depending on architecture)
- **Performance**: Low memory usage and fast startup

## Multi-Architecture Support

- **x86_64-linux** (AMD64): Native builds on GitHub Actions
- **aarch64-linux** (ARM64): Native builds on ARM64 runners or cross-compilation
- **Cross-compilation**: Automatic fallback when native runners unavailable
- **Multi-arch manifests**: Single image tag works on both architectures

## GitHub Actions Setup

### Automatic Building

The workflows automatically build and push images when you:

1. Push to `main`/`master` branch
2. Create pull requests  
3. Manually trigger via workflow dispatch

### Container Registry

Images are pushed to GitHub Container Registry:

```bash
# Pull the latest multi-arch static image
docker pull ghcr.io/your-org/your-repo/nixify-health-check:latest

# Pull specific architecture
docker pull ghcr.io/your-org/your-repo/nixify-health-check:latest-x86_64-linux-static
docker pull ghcr.io/your-org/your-repo/nixify-health-check:latest-aarch64-linux-static
```

### Available Image Tags

- `latest` - Multi-arch static build
- `latest-x86_64-linux-static` - x86_64 specific static build
- `latest-aarch64-linux-static` - aarch64 specific static build  
- `{branch}-{sha}-{arch}-static` - Commit-specific builds

## Development

```bash
# Enter development shell
nix develop

# Run locally (requires services)
python app.py

# Build static image locally
nix build .#docker-image-static

# Cross-compile for different architecture
nix build --system aarch64-linux .#docker-image-static
```

## Why Nix?

1. **Reproducible**: Bit-for-bit identical builds across environments
2. **Multi-arch**: Native cross-compilation support
3. **Size Optimized**: Static linking and dependency elimination
4. **No Dockerfile**: Pure, declarative infrastructure as code
5. **Cached**: Shared build artifacts via binary caches
6. **Hermetic**: Isolated, dependency-tracked builds

## Available Commands

```bash
make build    # Build static Docker image  
make run      # Run static container (port 8080)
make logs     # Show container logs
make stop     # Stop container
make health   # Check application health
make info     # Show image information
make clean    # Clean up everything
```

## Troubleshooting

### Local Development

**Build fails**: Ensure Nix flakes are enabled: `nix-env --version` should show flake support.

**Container won't start**: Check if ports 8080/8081 are already in use: `lsof -i :8080`

**Health check fails**: Services need 15-30 seconds to initialize. Check logs: `make logs`

**Cross-compilation slow**: Use GitHub Actions for faster multi-arch builds.

### GitHub Actions

**Builds timeout**: Large builds may hit 6-hour limit.

**Architecture mismatch**: Ensure your workflow targets the correct system architectures.

**Registry permission denied**: Verify `packages: write` permission is set in workflow.

**Image not found**: Check if workflow completed successfully and image was pushed.

## Performance Characteristics

| Metric | Static Build |
|--------|-------------|
| Build Time | ~10-15 min |
| Image Size | 100-200MB |
| Memory Usage | ~100MB |
| Startup Time | ~12s |

*Times vary based on cache hits and architecture*

## License

MIT License