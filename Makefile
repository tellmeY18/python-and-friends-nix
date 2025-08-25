.PHONY: help build load run clean logs stop health

# Default target
help:
	@echo "Nixify Health Check - Static Build Commands:"
	@echo ""
	@echo "  build         Build static Docker image (musl)"
	@echo "  load          Load static image into Docker"
	@echo "  run           Run static container on port 8080"
	@echo "  clean         Clean up everything"
	@echo "  logs          Show container logs"
	@echo "  stop          Stop container"
	@echo "  health        Check app health"
	@echo ""
	@echo "Architecture Detection:"
	@echo "  Current system: $$(nix eval --impure --expr 'builtins.currentSystem')"
	@echo ""

# Build the static Docker image
build:
	@echo "Building static Docker image with musl..."
	nix build --print-build-logs .#docker-image-static
	@echo "Static build complete!"

# Load static image into Docker
load: build
	@echo "Loading static image into Docker..."
	docker load < result
	@echo "Static image loaded!"

# Run the static container
run: load
	@echo "Starting static container..."
	@docker rm -f nixify-health-check 2>/dev/null || true
	docker run -d --name nixify-health-check -p 8080:80 nixify-health-check:latest
	@echo "Static container running at http://localhost:8080"

# Clean everything
clean:
	@echo "Cleaning up..."
	@docker rm -f nixify-health-check 2>/dev/null || true
	@docker rmi nixify-health-check:latest 2>/dev/null || true
	rm -f result*
	@echo "Clean complete!"

# Show logs
logs:
	@docker logs -f nixify-health-check 2>/dev/null || echo "Container not running"

# Stop container
stop:
	@docker stop nixify-health-check 2>/dev/null || true
	@docker rm nixify-health-check 2>/dev/null || true
	@echo "Container stopped!"

# Health check
health:
	@curl -s http://localhost:8080/health | python3 -m json.tool 2>/dev/null || echo "Service not available"

# Show image information
info:
	@echo "Static image information:"
	@docker images nixify-health-check:latest --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
