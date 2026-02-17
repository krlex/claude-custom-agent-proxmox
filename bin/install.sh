#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install.sh — Automated MCP server installation for Claude Code
# ============================================================================
# Supported OS: Debian/Ubuntu, RHEL/Fedora, Arch/Manjaro
# Usage:
#   bash install.sh              — install
#   bash install.sh --uninstall  — uninstall
# ============================================================================

readonly SCRIPT_VERSION="1.1.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MCP_REPO="https://github.com/gilby125/mcp-proxmox.git"
readonly MCP_SUBMODULE_DIR="$SCRIPT_DIR/mcp-servers/proxmox"
readonly MCP_FALLBACK_DIR="$HOME/mcp-servers/proxmox"
readonly SSH_KEY_PATH="$HOME/.ssh/proxmox_mcp"
readonly CLAUDE_CONFIG="$HOME/.claude.json"

# Resolved at runtime — prefers the submodule, falls back to ~/mcp-servers
MCP_DIR=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Global variables populated during installation
DISTRO=""
PKG_MANAGER=""
PROXMOX_HOST=""
PROXMOX_PORT="8006"
PROXMOX_USER="root@pam"
PROXMOX_TOKEN_NAME="claude-mcp"
PROXMOX_TOKEN_VALUE=""
SSH_USER="root"
SSH_PORT="22"

# ============================================================================
# Helper functions
# ============================================================================

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

prompt_yn() {
    local msg="$1"
    local default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${YELLOW}$msg [Y/n]:${NC} ")" yn
        yn="${yn:-y}"
    else
        read -rp "$(echo -e "${YELLOW}$msg [y/N]:${NC} ")" yn
        yn="${yn:-n}"
    fi
    [[ "${yn,,}" == "y" ]]
}

prompt_input() {
    local msg="$1"
    local default="${2:-}"
    local value
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${YELLOW}$msg${NC} [$default]: ")" value
        echo "${value:-$default}"
    else
        read -rp "$(echo -e "${YELLOW}$msg${NC}: ")" value
        echo "$value"
    fi
}

prompt_secret() {
    local msg="$1"
    local value
    read -rsp "$(echo -e "${YELLOW}$msg${NC}: ")" value
    echo
    echo "$value"
}

check_command() {
    command -v "$1" &>/dev/null
}

# ============================================================================
# 1. OS detection
# ============================================================================

detect_os() {
    header "Detecting operating system"

    if [[ ! -f /etc/os-release ]]; then
        error "Cannot find /etc/os-release"
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    local id_like="${ID_LIKE:-}"
    local id="${ID:-unknown}"

    info "Detected OS: ${PRETTY_NAME:-$id}"

    case "$id" in
        debian|ubuntu|linuxmint|pop)
            DISTRO="debian"
            PKG_MANAGER="apt"
            ;;
        fedora)
            DISTRO="fedora"
            PKG_MANAGER="dnf"
            ;;
        rhel|centos|rocky|alma)
            DISTRO="rhel"
            if check_command dnf; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro|endeavouros)
            DISTRO="arch"
            PKG_MANAGER="pacman"
            ;;
        *)
            # Fallback to ID_LIKE
            case "$id_like" in
                *debian*|*ubuntu*)
                    DISTRO="debian"
                    PKG_MANAGER="apt"
                    ;;
                *rhel*|*fedora*)
                    DISTRO="fedora"
                    if check_command dnf; then
                        PKG_MANAGER="dnf"
                    else
                        PKG_MANAGER="yum"
                    fi
                    ;;
                *arch*)
                    DISTRO="arch"
                    PKG_MANAGER="pacman"
                    ;;
                *)
                    error "Unsupported distribution: $id (ID_LIKE: $id_like)"
                    error "Supported systems: Debian/Ubuntu, RHEL/Fedora, Arch/Manjaro"
                    exit 1
                    ;;
            esac
            ;;
    esac

    success "Distribution: $DISTRO (package manager: $PKG_MANAGER)"
}

# ============================================================================
# 2. Package installation
# ============================================================================

install_packages() {
    header "Installing required packages"

    local to_install=()

    # Check what is already installed
    local checks=(
        "node:nodejs"
        "npm:npm"
        "git:git"
        "ssh-keygen:openssh"
        "jq:jq"
        "curl:curl"
    )

    for check in "${checks[@]}"; do
        local cmd="${check%%:*}"
        local name="${check##*:}"
        if check_command "$cmd"; then
            success "$name is already installed ($cmd)"
        else
            to_install+=("$name")
            warn "$name not found — will be installed"
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        success "All required packages are already installed"
        return 0
    fi

    info "Packages to install: ${to_install[*]}"

    if ! prompt_yn "Install packages?"; then
        error "Installation aborted — required packages are not installed"
        exit 1
    fi

    # Map generic names to distribution-specific package names
    local packages=()
    for pkg in "${to_install[@]}"; do
        case "$DISTRO" in
            debian)
                case "$pkg" in
                    nodejs)   packages+=("nodejs");;
                    npm)      packages+=("npm");;
                    git)      packages+=("git");;
                    openssh)  packages+=("openssh-client");;
                    jq)       packages+=("jq");;
                    curl)     packages+=("curl");;
                esac
                ;;
            fedora|rhel)
                case "$pkg" in
                    nodejs)   packages+=("nodejs");;
                    npm)      packages+=("npm");;
                    git)      packages+=("git");;
                    openssh)  packages+=("openssh-clients");;
                    jq)       packages+=("jq");;
                    curl)     packages+=("curl");;
                esac
                ;;
            arch)
                case "$pkg" in
                    nodejs)   packages+=("nodejs");;
                    npm)      packages+=("npm");;
                    git)      packages+=("git");;
                    openssh)  packages+=("openssh");;
                    jq)       packages+=("jq");;
                    curl)     packages+=("curl");;
                esac
                ;;
        esac
    done

    info "Installing: ${packages[*]}"

    case "$PKG_MANAGER" in
        apt)
            sudo apt update
            sudo apt install -y "${packages[@]}"
            ;;
        dnf)
            sudo dnf install -y "${packages[@]}"
            ;;
        yum)
            sudo yum install -y "${packages[@]}"
            ;;
        pacman)
            sudo pacman -Sy --noconfirm "${packages[@]}"
            ;;
    esac

    success "All packages installed"
}

# ============================================================================
# 3. SSH key
# ============================================================================

setup_ssh_key() {
    header "Setting up SSH key"

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [[ -f "$SSH_KEY_PATH" ]]; then
        info "SSH key already exists: $SSH_KEY_PATH"
        local fingerprint
        fingerprint=$(ssh-keygen -lf "$SSH_KEY_PATH" 2>/dev/null || echo "unknown")
        info "Fingerprint: $fingerprint"

        if prompt_yn "Use existing key?" "y"; then
            success "Using existing SSH key"
            return 0
        fi

        warn "Generating new key (old one will be saved as ${SSH_KEY_PATH}.bak)"
        cp "$SSH_KEY_PATH" "${SSH_KEY_PATH}.bak"
        [[ -f "${SSH_KEY_PATH}.pub" ]] && cp "${SSH_KEY_PATH}.pub" "${SSH_KEY_PATH}.pub.bak"
    fi

    info "Generating new Ed25519 SSH key..."
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "claude-mcp-proxmox"
    chmod 600 "$SSH_KEY_PATH"
    chmod 644 "${SSH_KEY_PATH}.pub"

    success "SSH key generated: $SSH_KEY_PATH"
}

copy_ssh_key() {
    header "Copying SSH key to server"

    info "Target server: ${SSH_USER}@${PROXMOX_HOST}:${SSH_PORT}"

    if prompt_yn "Copy public key to server using ssh-copy-id?"; then
        info "Running ssh-copy-id (server password will be required)..."
        if ssh-copy-id -i "${SSH_KEY_PATH}.pub" -p "$SSH_PORT" "${SSH_USER}@${PROXMOX_HOST}"; then
            success "Key successfully copied to server"
        else
            warn "ssh-copy-id failed"
            warn "You can copy the key manually later:"
            echo "  ssh-copy-id -i ${SSH_KEY_PATH}.pub -p ${SSH_PORT} ${SSH_USER}@${PROXMOX_HOST}"
        fi
    else
        warn "Skipped key copy — make sure the key is already on the server"
    fi

    # Test connection
    info "Testing SSH connection..."
    if ssh -i "$SSH_KEY_PATH" -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes \
        "${SSH_USER}@${PROXMOX_HOST}" "echo 'SSH OK'" 2>/dev/null; then
        success "SSH connection works"
    else
        warn "SSH connection failed with key"
        warn "Make sure the key is copied to the server and try again"
    fi
}

# ============================================================================
# 4. Proxmox API token
# ============================================================================

setup_proxmox_token() {
    header "Setting up Proxmox API token"

    echo -e "Choose how to create the API token:"
    echo -e "  ${BOLD}1)${NC} Automatic — creates token via SSH on the server"
    echo -e "  ${BOLD}2)${NC} Manual entry — enter an existing token"
    echo

    local choice
    read -rp "$(echo -e "${YELLOW}Choice [1/2]:${NC} ")" choice

    case "$choice" in
        1)
            _create_token_auto
            ;;
        2)
            _create_token_manual
            ;;
        *)
            warn "Invalid choice, falling back to manual entry"
            _create_token_manual
            ;;
    esac
}

_create_token_auto() {
    info "Creating API token via SSH..."

    local ssh_cmd="ssh -i $SSH_KEY_PATH -p $SSH_PORT -o ConnectTimeout=10"

    # Check if token already exists
    local existing
    existing=$($ssh_cmd "${SSH_USER}@${PROXMOX_HOST}" \
        "pveum user token list root@pam --output-format json 2>/dev/null" 2>/dev/null || echo "[]")

    if echo "$existing" | jq -e '.[] | select(.tokenid == "claude-mcp")' &>/dev/null; then
        warn "Token 'claude-mcp' already exists on the server"
        if prompt_yn "Delete existing and create new?"; then
            $ssh_cmd "${SSH_USER}@${PROXMOX_HOST}" \
                "pveum user token remove root@pam claude-mcp" 2>/dev/null || true
            info "Old token deleted"
        else
            info "Enter the existing token value manually"
            _create_token_manual
            return
        fi
    fi

    local output
    output=$($ssh_cmd "${SSH_USER}@${PROXMOX_HOST}" \
        "pveum user token add root@pam claude-mcp --privsep 0 --output-format json" 2>/dev/null)

    if [[ -z "$output" ]]; then
        error "Could not create token via SSH"
        warn "Falling back to manual entry"
        _create_token_manual
        return
    fi

    PROXMOX_TOKEN_NAME="claude-mcp"
    PROXMOX_TOKEN_VALUE=$(echo "$output" | jq -r '.value // empty')

    if [[ -z "$PROXMOX_TOKEN_VALUE" ]]; then
        # Some formats return differently
        PROXMOX_TOKEN_VALUE=$(echo "$output" | jq -r '."full-tokenid" // empty' | cut -d'!' -f2-)
        if [[ -z "$PROXMOX_TOKEN_VALUE" ]]; then
            error "Cannot parse token from server response"
            echo "$output"
            _create_token_manual
            return
        fi
    fi

    success "Token created: root@pam!claude-mcp"
    info "Token value: ${PROXMOX_TOKEN_VALUE:0:8}..."
    warn "SAVE THIS VALUE — it cannot be displayed again!"
}

_create_token_manual() {
    info "Manual API token entry"
    info "You can create a token on the Proxmox server with:"
    echo "  pveum user token add root@pam claude-mcp --privsep 0"
    echo

    PROXMOX_TOKEN_NAME=$(prompt_input "Token name (without user@ prefix)" "claude-mcp")
    PROXMOX_TOKEN_VALUE=$(prompt_input "Token value (UUID)")

    if [[ -z "$PROXMOX_TOKEN_VALUE" ]]; then
        error "Token value cannot be empty"
        exit 1
    fi

    success "Token entered: root@pam!${PROXMOX_TOKEN_NAME}"
}

validate_token() {
    info "Validating API token..."

    local api_url="https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/version"
    local auth_header="PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_NAME}=${PROXMOX_TOKEN_VALUE}"

    local response
    response=$(curl -sk --connect-timeout 10 \
        -H "Authorization: $auth_header" \
        "$api_url" 2>/dev/null || echo "")

    if echo "$response" | jq -e '.data.version' &>/dev/null; then
        local version
        version=$(echo "$response" | jq -r '.data.version')
        success "API token works — Proxmox VE version: $version"
        return 0
    else
        warn "API validation failed (server may be using a self-signed cert)"
        warn "Response: $response"
        return 1
    fi
}

# ============================================================================
# 5. Proxmox MCP server installation
# ============================================================================

setup_mcp_server() {
    header "Installing Proxmox MCP server"

    # Prefer the git submodule if running from the repo
    if [[ -f "$MCP_SUBMODULE_DIR/.git" ]] || [[ -d "$MCP_SUBMODULE_DIR/.git" ]]; then
        MCP_DIR="$MCP_SUBMODULE_DIR"
        info "Using git submodule at $MCP_DIR"
    elif [[ -f "$SCRIPT_DIR/.gitmodules" ]] && grep -q "mcp-servers/proxmox" "$SCRIPT_DIR/.gitmodules" 2>/dev/null; then
        # Submodule is defined but not initialized
        info "Initializing git submodule..."
        git -C "$SCRIPT_DIR" submodule update --init --recursive
        if [[ -d "$MCP_SUBMODULE_DIR" ]]; then
            MCP_DIR="$MCP_SUBMODULE_DIR"
            success "Submodule initialized at $MCP_DIR"
        else
            warn "Submodule init failed, falling back to standalone clone"
            _clone_standalone
        fi
    else
        info "Not running from the git repo — using standalone clone"
        _clone_standalone
    fi

    info "Running npm install..."
    (cd "$MCP_DIR" && npm install)
    success "npm dependencies installed"

    # Verify entry point exists
    if [[ -f "$MCP_DIR/index.js" ]]; then
        success "index.js found"
    else
        local entry
        entry=$(find "$MCP_DIR" -maxdepth 2 -name "index.js" -o -name "main.js" 2>/dev/null | head -1)
        if [[ -n "$entry" ]]; then
            warn "Entry point not in root, found: $entry"
        else
            warn "Cannot find entry point — a build step may be required"
            if [[ -f "$MCP_DIR/package.json" ]]; then
                local build_script
                build_script=$(jq -r '.scripts.build // empty' "$MCP_DIR/package.json")
                if [[ -n "$build_script" ]]; then
                    info "Running npm run build..."
                    (cd "$MCP_DIR" && npm run build)
                fi
            fi
        fi
    fi
}

_clone_standalone() {
    MCP_DIR="$MCP_FALLBACK_DIR"
    mkdir -p "$(dirname "$MCP_DIR")"

    if [[ -d "$MCP_DIR/.git" ]]; then
        info "Proxmox MCP server already exists at $MCP_DIR"
        if prompt_yn "Update (git pull)?"; then
            info "Updating..."
            git -C "$MCP_DIR" pull
            success "Repo updated"
        else
            info "Skipped update"
        fi
    else
        if [[ -d "$MCP_DIR" ]]; then
            warn "$MCP_DIR exists but is not a git repo — removing and cloning fresh"
            rm -rf "$MCP_DIR"
        fi
        info "Cloning $MCP_REPO..."
        git clone "$MCP_REPO" "$MCP_DIR"
        success "Repo cloned to $MCP_DIR"
    fi
}

# ============================================================================
# 6. Register MCP servers in Claude Code
# ============================================================================

register_mcp_servers() {
    header "Registering MCP servers in Claude Code"

    local entry_point="$MCP_DIR/index.js"
    if [[ ! -f "$entry_point" ]]; then
        # Look for alternative entry points
        for candidate in "$MCP_DIR/dist/index.js" "$MCP_DIR/build/index.js" "$MCP_DIR/src/index.js"; do
            if [[ -f "$candidate" ]]; then
                entry_point="$candidate"
                break
            fi
        done
    fi

    info "Proxmox MCP entry point: $entry_point"

    # Method: directly edit ~/.claude.json with jq
    # This is more reliable than 'claude mcp add' since it doesn't depend on claude being in PATH

    if [[ -f "$CLAUDE_CONFIG" ]]; then
        # Backup
        cp "$CLAUDE_CONFIG" "${CLAUDE_CONFIG}.bak"
        info "Configuration backup: ${CLAUDE_CONFIG}.bak"
    else
        echo '{}' > "$CLAUDE_CONFIG"
    fi

    # Add proxmox MCP server
    local tmp_config
    tmp_config=$(mktemp)

    jq --arg entry "$entry_point" \
       --arg host "$PROXMOX_HOST" \
       --arg port "$PROXMOX_PORT" \
       --arg user "$PROXMOX_USER" \
       --arg token_name "$PROXMOX_TOKEN_NAME" \
       --arg token_value "$PROXMOX_TOKEN_VALUE" \
       '.mcpServers.proxmox = {
            "command": "node",
            "args": [$entry],
            "env": {
                "PROXMOX_HOST": $host,
                "PROXMOX_PORT": $port,
                "PROXMOX_USER": $user,
                "PROXMOX_TOKEN_NAME": $token_name,
                "PROXMOX_TOKEN_VALUE": $token_value,
                "PROXMOX_ALLOW_ELEVATED": "true"
            }
        }' "$CLAUDE_CONFIG" > "$tmp_config"

    # Add ssh-server MCP
    jq --arg host "$PROXMOX_HOST" \
       --arg user "$SSH_USER" \
       --arg key "$SSH_KEY_PATH" \
       '.mcpServers."ssh-server" = {
            "command": "npx",
            "args": ["-y", "ssh-mcp", "--", ("--host=" + $host), ("--user=" + $user), ("--key=" + $key)]
        }' "$tmp_config" > "${tmp_config}.2"

    mv "${tmp_config}.2" "$CLAUDE_CONFIG"
    rm -f "$tmp_config"

    success "Proxmox MCP server registered"
    success "SSH MCP server registered"

    # Also try 'claude mcp add' if available
    if check_command claude; then
        info "Claude CLI found — additional registration via CLI"
        claude mcp add proxmox \
            -e "PROXMOX_HOST=$PROXMOX_HOST" \
            -e "PROXMOX_PORT=$PROXMOX_PORT" \
            -e "PROXMOX_USER=$PROXMOX_USER" \
            -e "PROXMOX_TOKEN_NAME=$PROXMOX_TOKEN_NAME" \
            -e "PROXMOX_TOKEN_VALUE=$PROXMOX_TOKEN_VALUE" \
            -e "PROXMOX_ALLOW_ELEVATED=true" \
            -- node "$entry_point" 2>/dev/null || true

        claude mcp add ssh-server \
            -- npx -y ssh-mcp -- \
            "--host=${PROXMOX_HOST}" "--user=${SSH_USER}" "--key=${SSH_KEY_PATH}" \
            2>/dev/null || true
    fi

    info "Configuration saved to $CLAUDE_CONFIG"
}

# ============================================================================
# 7. Verification
# ============================================================================

verify_installation() {
    header "Verifying installation"

    local all_ok=true

    # Test 1: Proxmox API
    info "Test 1: Proxmox API connection..."
    local api_url="https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json/nodes"
    local auth_header="PVEAPIToken=${PROXMOX_USER}!${PROXMOX_TOKEN_NAME}=${PROXMOX_TOKEN_VALUE}"
    local response
    response=$(curl -sk --connect-timeout 10 \
        -H "Authorization: $auth_header" \
        "$api_url" 2>/dev/null || echo "")

    if echo "$response" | jq -e '.data' &>/dev/null; then
        local nodes
        nodes=$(echo "$response" | jq -r '.data[].node' | tr '\n' ', ' | sed 's/,$//')
        success "Proxmox API works — Nodes: $nodes"
    else
        warn "Proxmox API test failed"
        all_ok=false
    fi

    # Test 2: SSH connection
    info "Test 2: SSH connection..."
    if ssh -i "$SSH_KEY_PATH" -p "$SSH_PORT" -o ConnectTimeout=10 -o BatchMode=yes \
        "${SSH_USER}@${PROXMOX_HOST}" "hostname" 2>/dev/null; then
        success "SSH connection works"
    else
        warn "SSH connection failed"
        all_ok=false
    fi

    # Test 3: MCP server files
    info "Test 3: MCP server files..."
    if [[ -f "$MCP_DIR/index.js" ]] || [[ -f "$MCP_DIR/dist/index.js" ]]; then
        success "MCP server files exist"
    else
        warn "MCP server entry point not found"
        all_ok=false
    fi

    # Test 4: Claude configuration
    info "Test 4: Claude configuration..."
    if [[ -f "$CLAUDE_CONFIG" ]] && jq -e '.mcpServers.proxmox' "$CLAUDE_CONFIG" &>/dev/null; then
        success "Proxmox MCP registered in claude.json"
    else
        warn "Proxmox MCP not in claude.json"
        all_ok=false
    fi

    if [[ -f "$CLAUDE_CONFIG" ]] && jq -e '.mcpServers."ssh-server"' "$CLAUDE_CONFIG" &>/dev/null; then
        success "SSH MCP registered in claude.json"
    else
        warn "SSH MCP not in claude.json"
        all_ok=false
    fi

    echo
    if $all_ok; then
        success "All tests passed!"
    else
        warn "Some tests failed — check the warnings above"
    fi
}

# ============================================================================
# 8. Summary
# ============================================================================

print_summary() {
    header "Installation summary"

    echo -e "${BOLD}Proxmox MCP Server${NC}"
    echo "  Host:       $PROXMOX_HOST:$PROXMOX_PORT"
    echo "  User:       $PROXMOX_USER"
    echo "  Token:      ${PROXMOX_USER}!${PROXMOX_TOKEN_NAME}"
    echo "  Location:   $MCP_DIR"
    echo

    echo -e "${BOLD}SSH MCP Server${NC}"
    echo "  Host:       ${SSH_USER}@${PROXMOX_HOST}:${SSH_PORT}"
    echo "  SSH key:    $SSH_KEY_PATH"
    echo

    echo -e "${BOLD}Configuration${NC}"
    echo "  Claude:     $CLAUDE_CONFIG"
    echo

    echo -e "${BOLD}Next steps:${NC}"
    echo "  1. Restart Claude Code to load the new MCP servers"
    echo "  2. Use /mcp to check server status"
    echo "  3. Try: 'Show me the list of VMs on the Proxmox server'"
    echo
}

# ============================================================================
# 9. Uninstall
# ============================================================================

uninstall() {
    header "Removing MCP servers"

    warn "This will remove MCP servers from Claude Code"
    if ! prompt_yn "Continue with removal?"; then
        info "Aborted"
        exit 0
    fi

    # Remove from Claude configuration
    if [[ -f "$CLAUDE_CONFIG" ]]; then
        info "Removing MCP servers from $CLAUDE_CONFIG..."
        cp "$CLAUDE_CONFIG" "${CLAUDE_CONFIG}.bak"

        local tmp_config
        tmp_config=$(mktemp)
        jq 'del(.mcpServers.proxmox) | del(.mcpServers."ssh-server")' \
            "$CLAUDE_CONFIG" > "$tmp_config"
        mv "$tmp_config" "$CLAUDE_CONFIG"
        success "MCP servers removed from configuration"
    fi

    # Also try claude CLI
    if check_command claude; then
        claude mcp remove proxmox 2>/dev/null || true
        claude mcp remove ssh-server 2>/dev/null || true
    fi

    # Delete standalone MCP server directory (not the submodule)
    if [[ -d "$MCP_FALLBACK_DIR" ]]; then
        if prompt_yn "Delete $MCP_FALLBACK_DIR?"; then
            rm -rf "$MCP_FALLBACK_DIR"
            success "MCP server directory deleted"

            # Remove empty parent dir
            local parent_dir
            parent_dir="$(dirname "$MCP_FALLBACK_DIR")"
            if [[ -d "$parent_dir" ]] && [[ -z "$(ls -A "$parent_dir" 2>/dev/null)" ]]; then
                rmdir "$parent_dir" 2>/dev/null || true
            fi
        fi
    fi

    # SSH key
    if [[ -f "$SSH_KEY_PATH" ]]; then
        if prompt_yn "Delete SSH key ($SSH_KEY_PATH)?"; then
            rm -f "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub"
            success "SSH key deleted"
        fi
    fi

    # API token on server
    if prompt_yn "Delete API token from Proxmox server?" "n"; then
        local host
        host=$(prompt_input "Proxmox server IP" "192.168.2.123")
        local ssh_key="${SSH_KEY_PATH}"
        if [[ ! -f "$ssh_key" ]]; then
            ssh_key=$(prompt_input "Path to SSH key for server access")
        fi
        if [[ -f "$ssh_key" ]]; then
            info "Deleting API token from server..."
            ssh -i "$ssh_key" -o ConnectTimeout=10 "root@${host}" \
                "pveum user token remove root@pam claude-mcp" 2>/dev/null && \
                success "API token deleted from server" || \
                warn "Token deletion failed"
        fi
    fi

    echo
    success "Removal complete"
    info "Restart Claude Code to apply changes"
}

# ============================================================================
# Main flow
# ============================================================================

main_install() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║  MCP Server Installer for Claude Code  v$SCRIPT_VERSION     ║"
    echo "║  Proxmox MCP + SSH MCP                            ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Gather server information
    header "Server configuration"
    PROXMOX_HOST=$(prompt_input "Proxmox server IP address" "192.168.2.123")
    PROXMOX_PORT=$(prompt_input "Proxmox API port" "8006")
    SSH_USER=$(prompt_input "SSH user" "root")
    SSH_PORT=$(prompt_input "SSH port" "22")

    # Installation steps
    detect_os
    install_packages
    setup_ssh_key
    copy_ssh_key
    setup_proxmox_token
    validate_token || true
    setup_mcp_server
    register_mcp_servers
    verify_installation
    print_summary
}

main() {
    # Parse arguments
    case "${1:-}" in
        --uninstall|-u)
            uninstall
            ;;
        --help|-h)
            echo "Usage: $0 [option]"
            echo
            echo "Options:"
            echo "  (none)          Run installation"
            echo "  --uninstall     Remove MCP servers"
            echo "  --help          Show help"
            echo "  --version       Show version"
            exit 0
            ;;
        --version|-v)
            echo "install.sh v$SCRIPT_VERSION"
            exit 0
            ;;
        "")
            main_install
            ;;
        *)
            error "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
}

main "$@"
