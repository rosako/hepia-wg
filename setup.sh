#!/bin/bash

# WireGuard Config Fetcher & Installer
# Interactive script to download WireGuard configs via SCP and set them up

set -e

# Colors for better UX
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default remote path
REMOTE_CONFIG_PATH="/root/hepia"

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════╗"
    echo "║     WireGuard Config Fetcher & Setup      ║"
    echo "╚═══════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_step() {
    echo -e "${BLUE}[*]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (for WireGuard installation)"
        echo -e "    Run with: ${YELLOW}sudo $0${NC}"
        exit 1
    fi
}

# Get server address from user
get_server_address() {
    echo ""
    print_step "Enter the server address (IP or hostname):"
    read -p "    Server: " SERVER_ADDRESS
    
    if [[ -z "$SERVER_ADDRESS" ]]; then
        print_error "Server address cannot be empty"
        exit 1
    fi
    
    # Optional: custom port
    read -p "    SSH Port [22]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-22}
    
    # Optional: custom remote path
    read -p "    Remote config path [${REMOTE_CONFIG_PATH}]: " CUSTOM_PATH
    REMOTE_CONFIG_PATH=${CUSTOM_PATH:-$REMOTE_CONFIG_PATH}
}

# List available config files on remote server
list_remote_configs() {
    print_step "Fetching available config files from ${SERVER_ADDRESS}..."
    echo ""
    
    # Get list of .conf files from remote server
    CONFIG_LIST=$(ssh -p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "root@${SERVER_ADDRESS}" \
        "ls -1 ${REMOTE_CONFIG_PATH}/*.conf 2>/dev/null" 2>&1) || {
        print_error "Failed to connect or no config files found"
        echo -e "    ${YELLOW}Error: ${CONFIG_LIST}${NC}"
        exit 1
    }
    
    if [[ -z "$CONFIG_LIST" ]]; then
        print_error "No .conf files found in ${REMOTE_CONFIG_PATH}"
        exit 1
    fi
    
    # Convert to array
    mapfile -t CONFIGS <<< "$CONFIG_LIST"
    
    echo -e "${GREEN}Available WireGuard configurations:${NC}"
    echo ""
    
    local i=1
    for config in "${CONFIGS[@]}"; do
        local filename=$(basename "$config")
        echo -e "    ${CYAN}[$i]${NC} $filename"
        ((i++))
    done
    echo ""
}

# Let user select a config
select_config() {
    local max=${#CONFIGS[@]}
    
    while true; do
        read -p "    Select config [1-${max}]: " SELECTION
        
        if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 1 ] && [ "$SELECTION" -le "$max" ]; then
            SELECTED_CONFIG="${CONFIGS[$((SELECTION-1))]}"
            SELECTED_FILENAME=$(basename "$SELECTED_CONFIG")
            print_success "Selected: ${SELECTED_FILENAME}"
            break
        else
            print_error "Invalid selection. Please enter a number between 1 and ${max}"
        fi
    done
}

# Download the selected config
download_config() {
    echo ""
    print_step "Downloading ${SELECTED_FILENAME}..."
    
    # Create temp directory
    TEMP_DIR=$(mktemp -d)
    LOCAL_CONFIG="${TEMP_DIR}/${SELECTED_FILENAME}"
    
    scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new \
        "root@${SERVER_ADDRESS}:${SELECTED_CONFIG}" \
        "$LOCAL_CONFIG" || {
        print_error "Failed to download config file"
        rm -rf "$TEMP_DIR"
        exit 1
    }
    
    print_success "Downloaded to ${LOCAL_CONFIG}"
}

# Install WireGuard if not present
install_wireguard() {
    echo ""
    print_step "Checking WireGuard installation..."
    
    if command -v wg &> /dev/null; then
        print_success "WireGuard is already installed"
        return
    fi
    
    print_warning "WireGuard not found. Installing..."
    
    # Detect package manager and install
    if command -v apt-get &> /dev/null; then
        apt-get update -qq
        apt-get install -y wireguard wireguard-tools
    elif command -v dnf &> /dev/null; then
        dnf install -y wireguard-tools
    elif command -v yum &> /dev/null; then
        yum install -y epel-release
        yum install -y wireguard-tools
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm wireguard-tools
    elif command -v zypper &> /dev/null; then
        zypper install -y wireguard-tools
    elif command -v apk &> /dev/null; then
        apk add wireguard-tools
    else
        print_error "Could not detect package manager. Please install WireGuard manually."
        exit 1
    fi
    
    print_success "WireGuard installed successfully"
}

# Import the WireGuard profile
import_profile() {
    echo ""
    print_step "Importing WireGuard profile..."
    
    # Extract interface name from filename (remove .conf)
    INTERFACE_NAME="${SELECTED_FILENAME%.conf}"
    
    # Copy config to WireGuard directory
    WG_CONFIG_DIR="/etc/wireguard"
    mkdir -p "$WG_CONFIG_DIR"
    
    # Check if config already exists
    if [[ -f "${WG_CONFIG_DIR}/${SELECTED_FILENAME}" ]]; then
        print_warning "Config ${SELECTED_FILENAME} already exists"
        read -p "    Overwrite? [y/N]: " OVERWRITE
        if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
            print_warning "Skipping import"
            rm -rf "$TEMP_DIR"
            return
        fi
    fi
    
    cp "$LOCAL_CONFIG" "${WG_CONFIG_DIR}/${SELECTED_FILENAME}"
    chmod 600 "${WG_CONFIG_DIR}/${SELECTED_FILENAME}"
    
    print_success "Config imported to ${WG_CONFIG_DIR}/${SELECTED_FILENAME}"
    
    # Cleanup temp
    rm -rf "$TEMP_DIR"
}

# Offer to activate the connection
activate_connection() {
    echo ""
    read -p "    Activate WireGuard connection now? [Y/n]: " ACTIVATE
    
    if [[ ! "$ACTIVATE" =~ ^[Nn]$ ]]; then
        print_step "Activating ${INTERFACE_NAME}..."
        
        # Check if already active
        if wg show "$INTERFACE_NAME" &> /dev/null; then
            print_warning "Interface ${INTERFACE_NAME} is already active"
            read -p "    Restart it? [y/N]: " RESTART
            if [[ "$RESTART" =~ ^[Yy]$ ]]; then
                wg-quick down "$INTERFACE_NAME" 2>/dev/null || true
                wg-quick up "$INTERFACE_NAME"
                print_success "Interface ${INTERFACE_NAME} restarted"
            fi
        else
            wg-quick up "$INTERFACE_NAME"
            print_success "Interface ${INTERFACE_NAME} activated"
        fi
        
        # Show connection status
        echo ""
        print_step "Connection status:"
        echo ""
        wg show "$INTERFACE_NAME"
    fi
}

# Offer to enable on boot
enable_on_boot() {
    echo ""
    read -p "    Enable ${INTERFACE_NAME} on system boot? [y/N]: " ENABLE_BOOT
    
    if [[ "$ENABLE_BOOT" =~ ^[Yy]$ ]]; then
        systemctl enable "wg-quick@${INTERFACE_NAME}" 2>/dev/null || {
            print_warning "Could not enable systemd service (systemd may not be available)"
            return
        }
        print_success "Enabled ${INTERFACE_NAME} to start on boot"
    fi
}

# Main execution
main() {
    print_banner
    check_root
    get_server_address
    list_remote_configs
    select_config
    download_config
    install_wireguard
    import_profile
    activate_connection
    enable_on_boot
    
    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║            Setup Complete!                ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "Useful commands:"
    echo -e "    ${CYAN}wg show${NC}                        - Show active connections"
    echo -e "    ${CYAN}wg-quick up ${INTERFACE_NAME}${NC}   - Activate connection"
    echo -e "    ${CYAN}wg-quick down ${INTERFACE_NAME}${NC} - Deactivate connection"
    echo ""
}

main "$@"
