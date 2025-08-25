.PHONY: help build load run clean logs stop health

# Default target
help:
	@echo "Nixify Health Check - Simple POC Commands:"
	@echo ""
	@echo "  build     Build Docker image (aarch64-linux)"
	@echo "  load      Load image into Docker"
	@echo "  run       Run container on port 8080"
	@echo "  clean     Clean up everything"
	@echo "  logs      Show container logs"
	@echo "  stop      Stop container"
	@echo "  health    Check app health"
	@echo ""

# Build the Docker image
build:
	@echo "Building Docker image for aarch64-linux..."
	nix build --system aarch64-linux
	@echo "Build complete!"

# Load image into Docker
load: build
	@echo "Loading image into Docker..."
	docker load < result
	@echo "Image loaded!"

# Run the container
run: load
	@echo "Starting container..."
	@docker rm -f nixify-health-check 2>/dev/null || true
	docker run -d --name nixify-health-check -p 8080:80 nixify-health-check:latest
	@echo "Container running at http://localhost:8080"

# Clean everything
clean:
	@echo "Cleaning up..."
	@docker rm -f nixify-health-check 2>/dev/null || true
	@docker rmi nixify-health-check:latest 2>/dev/null || true
	rm -f result*
	@echo "Clean complete!"

# Show logs
logs:
	docker logs -f nixify-health-check

# Stop container
stop:
	@docker stop nixify-health-check 2>/dev/null || true
	@docker rm nixify-health-check 2>/dev/null || true
	@echo "Container stopped!"

# Health check
health:
	@curl -s http://localhost:8080/health | python3 -m json.tool || echo "Service not available"
