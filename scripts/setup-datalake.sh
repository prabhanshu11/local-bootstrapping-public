#!/bin/bash
# setup-datalake.sh - Setup Datalake API service with auto-start and self-healing

set -e

# Colors for output
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[+]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

DATALAKE_DIR="$HOME/Programs/datalake"

log "Setting up Datalake API service..."

# Check if datalake directory exists
if [ ! -d "$DATALAKE_DIR" ]; then
    warn "Datalake directory not found at $DATALAKE_DIR"
    info "Please clone or create the datalake project first"
    exit 1
fi

# Check if Docker and Docker Compose are installed
if ! command -v docker &> /dev/null; then
    warn "Docker is not installed. Installing docker..."
    sudo pacman -S --noconfirm docker docker-compose
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker "$USER"
    warn "You may need to log out and back in for docker group changes to take effect"
fi

# Ensure Docker service is running
if ! systemctl is-active --quiet docker; then
    log "Starting Docker service..."
    sudo systemctl start docker
fi

# Create systemd user service for datalake
log "Creating systemd user service for datalake..."

mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/datalake.service << 'EOF'
[Unit]
Description=Datalake API Service
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=%h/Programs/datalake
ExecStartPre=/usr/bin/docker-compose down
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

# Create a timer for health checking and auto-restart if needed
cat > ~/.config/systemd/user/datalake-healthcheck.service << 'EOF'
[Unit]
Description=Datalake Health Check and Auto-Heal
After=datalake.service

[Service]
Type=oneshot
WorkingDirectory=%h/Programs/datalake
ExecStart=/bin/bash -c 'if ! curl -f -s http://localhost:8766/health > /dev/null 2>&1; then systemctl --user restart datalake.service; fi'
EOF

cat > ~/.config/systemd/user/datalake-healthcheck.timer << 'EOF'
[Unit]
Description=Datalake Health Check Timer
After=datalake.service

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Reload systemd and enable services
log "Enabling datalake service for auto-start..."
systemctl --user daemon-reload
systemctl --user enable datalake.service
systemctl --user enable datalake-healthcheck.timer

# Start the service now
log "Starting datalake service..."
systemctl --user start datalake.service

# Wait a moment for startup
sleep 5

# Start the health check timer
systemctl --user start datalake-healthcheck.timer

# Check if service is running
if systemctl --user is-active --quiet datalake.service; then
    log "Datalake service started successfully"

    # Try to get laptop IP
    LAPTOP_IP=$(ip addr show | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | cut -d/ -f1 | head -n1)

    info "Datalake API is now running on port 8766"
    info "Local access: http://localhost:8766"
    if [ -n "$LAPTOP_IP" ]; then
        info "Network access: http://$LAPTOP_IP:8766"
    fi
    info "API docs: http://localhost:8766/docs"
else
    warn "Datalake service failed to start. Check logs with: systemctl --user status datalake.service"
    exit 1
fi

# Create symlinks for CLI scripts
log "Creating symlinks for datalake CLI scripts..."
mkdir -p "$HOME/.local/bin"
ln -sf "$DATALAKE_DIR/bin/find-conversations" "$HOME/.local/bin/"
ln -sf "$DATALAKE_DIR/bin/get-messages-from-current" "$HOME/.local/bin/"

log "Datalake setup complete!"
info "The service will auto-start on login and self-heal if it crashes"
info "Health checks run every 5 minutes"
info ""
info "CLI scripts available:"
info "  find-conversations \"query\"        # Search conversations"
info "  get-messages-from-current         # Get recent messages"
info ""
info "Useful commands:"
info "  systemctl --user status datalake.service     # Check status"
info "  systemctl --user restart datalake.service    # Restart service"
info "  systemctl --user logs -f datalake.service    # View logs"
info "  docker-compose -f $DATALAKE_DIR/docker-compose.yml logs -f  # View container logs"
