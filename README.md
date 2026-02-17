# Claude Agent — Server Management via MCP

## Goal

Manage a Proxmox server (192.168.2.123) from Claude Code on a local machine, without installing anything Claude-related on the server itself.

## Architecture

```
Local machine (Manjaro)                Server (192.168.2.123)
┌──────────────────────────┐           ┌───────────────────────────┐
│  Claude Code             │           │  Proxmox VE (Debian 13)  │
│    |                     │           │    |                      │
│    ├─ Proxmox MCP Server │── API ──> │    ├─ Proxmox API (:8006)│
│    |   (local process)   │           │    ├─ LXC 400 (Keycloak) │
│    |                     │           │    ├─ WebZFS (:26619)     │
│    └─ SSH MCP Server     │── SSH ──> │    └─ systemd services   │
│       (local process)    │           │                           │
└──────────────────────────┘           └───────────────────────────┘
```

Both MCP servers run **locally** on the Manjaro machine. Neither requires installation on the server. Communication goes through existing protocols (SSH and Proxmox REST API).

## What is MCP?

MCP (Model Context Protocol) is a protocol that allows Claude Code to use additional tools. An MCP server is registered in Claude Code, and Claude automatically gains new tools it can invoke.

Example: after registering the SSH MCP server, Claude Code can execute commands on a remote server without manually writing `ssh` commands.

## Implementation (2026-02-17)

### SSH key

```
File:        ~/.ssh/proxmox_mcp (Ed25519)
Fingerprint: SHA256:OeFCK+6ZFz4BbMPweSKpUlRiGcQ+0/j0Jvgue+0j+bI
Copied to:   root@192.168.2.123
```

### Proxmox API token

```
Token ID:    root@pam!claude-mcp
Token Value: <your-token-value>
Privsep:     0 (full privileges)
```

### Installed MCP servers

#### 1. Proxmox MCP Server (mcp-proxmox)

- **Repo:** https://github.com/gilby125/mcp-proxmox
- **Language:** Node.js
- **Location:** `mcp-servers/proxmox/` (git submodule)
- **Tools:** 55+ tools for VM, LXC, storage, backup, monitoring
- **Env file:** `mcp-servers/.env`

#### 2. SSH MCP Server (ssh-mcp)

- **Repo:** https://github.com/tufantunc/ssh-mcp
- **Language:** TypeScript
- **Installation:** npx (downloaded automatically)
- **Tools:** `exec` (commands), `sudo-exec` (sudo commands)

### Configuration (`~/.claude.json`)

```json
{
  "mcpServers": {
    "proxmox": {
      "command": "node",
      "args": ["/home/krle/mcp-servers/proxmox/index.js"],
      "env": {
        "PROXMOX_HOST": "192.168.2.123",
        "PROXMOX_PORT": "8006",
        "PROXMOX_USER": "root@pam",
        "PROXMOX_TOKEN_NAME": "claude-mcp",
        "PROXMOX_TOKEN_VALUE": "<your-token-value>",
        "PROXMOX_ALLOW_ELEVATED": "true"
      }
    },
    "ssh-server": {
      "command": "npx",
      "args": ["-y", "ssh-mcp", "--", "--host=192.168.2.123", "--user=root", "--key=/home/krle/.ssh/proxmox_mcp"]
    }
  }
}
```

## Automated Installation

An installer script is provided at `bin/install.sh` that automates the entire setup process. It is the recommended way to set up the MCP servers on a fresh system.

### Requirements

- **OS:** Debian/Ubuntu, RHEL/Fedora, or Arch/Manjaro
- **Shell:** Bash
- **Access:** sudo privileges (for package installation)
- **Network:** LAN access to the Proxmox server

### Quick start

```bash
# Clone with submodules
git clone --recurse-submodules <repo-url>
cd Claude-agent-custom

# Run the installer
bash bin/install.sh

# Or, if you already cloned without --recurse-submodules:
git submodule update --init --recursive
bash bin/install.sh
```

### Usage

```bash
# Install everything interactively
bash bin/install.sh

# Remove everything
bash bin/install.sh --uninstall

# Show help
bash bin/install.sh --help
```

### What the installer does

The script runs interactively and performs the following steps in order:

1. **Prompts for server details** — IP address, API port, SSH user and port (with sensible defaults)
2. **Detects the OS** — reads `/etc/os-release` and selects the appropriate package manager (`apt`, `dnf`/`yum`, or `pacman`)
3. **Installs system packages** — `nodejs`, `npm`, `git`, `openssh`, `jq`, `curl` (skips already installed ones)
4. **Sets up SSH key** — generates an Ed25519 key at `~/.ssh/proxmox_mcp` (or reuses an existing one), then copies it to the server with `ssh-copy-id`
5. **Creates Proxmox API token** — either automatically via SSH (`pveum user token add root@pam claude-mcp --privsep 0`) or accepts manual input of an existing token
6. **Installs the Proxmox MCP server** — initializes the git submodule at `mcp-servers/proxmox/` and runs `npm install` (or falls back to cloning into `~/mcp-servers/proxmox/` if not running from the repo)
7. **Registers both MCP servers** — writes the `proxmox` and `ssh-server` entries into `~/.claude.json` using `jq`, and also calls `claude mcp add` if the CLI is available
8. **Verifies the installation** — tests the Proxmox API connection, SSH connectivity, file existence, and Claude configuration
9. **Prints a summary** with next steps

### Uninstall mode

Running with `--uninstall` reverses the installation:

- Removes `proxmox` and `ssh-server` from `~/.claude.json`
- Optionally deletes the `~/mcp-servers/proxmox/` directory (if using standalone clone)
- Optionally deletes the SSH key (`~/.ssh/proxmox_mcp`)
- Optionally revokes the API token on the Proxmox server (via SSH)

A backup of `~/.claude.json` is created before any modifications (`~/.claude.json.bak`).

### Notes

- The script is fully interactive — it never makes destructive changes without asking first
- All default values match the current setup (IP `192.168.2.123`, user `root`, port `8006`)
- If a step fails (e.g. SSH key copy), the script warns and continues rather than aborting
- The script is self-contained with no external dependencies beyond Bash

## Usage Guide

### First launch

1. **Restart Claude Code** (exit with `exit` or Ctrl+C, then run `claude` again)
2. Run `/mcp` to verify that the servers are loaded
3. If everything is OK, you will see `proxmox` and `ssh-server` in the list with status "connected"

### Usage examples

Simply write in natural language what you want. Claude Code will automatically recognize which MCP tool to use.

**Proxmox operations (via Proxmox MCP):**
```
> Show me a list of all LXC containers
> How much RAM and CPU is the server using?
> Start LXC container 400
> Stop LXC 400
> Show me the storage status
> Create a snapshot of LXC 400
```

**Shell commands on the server (via SSH MCP):**
```
> Check if the Keycloak Docker container is running in LXC 400
> Restart the WebZFS service
> Show me the WebZFS logs
> Read the current Keycloak password from LXC 400
> Run the password rotation for Keycloak
> Which processes are using the most memory?
> Show me disk usage
```

**Combined operations:**
```
> Start LXC 400 and check if the Keycloak Docker container is active
> Show me the status of all services on the server
```

### How it works in practice

1. You write a request in natural language
2. Claude Code recognizes it needs to use an MCP tool
3. Asks for your permission (first time)
4. Executes the command via the MCP server
5. Displays the result

### Example session

```
you:    Show me the list of LXC containers
claude: [uses proxmox MCP -> list_containers]
claude: There is 1 LXC container on the server:
        - LXC 400 (keycloak.local) - status: running, IP: 192.168.2.70

you:    Is Keycloak running?
claude: [uses ssh-server MCP -> exec: "pct exec 400 -- docker ps"]
claude: Yes, the Keycloak container is active:
        CONTAINER ID  IMAGE                           STATUS       PORTS
        abc123        quay.io/keycloak/keycloak:latest Up 45 min    0.0.0.0:8080->8080/tcp
```

### Usage notes

- Claude will ask for permission before executing commands (you can approve individually or for the whole session)
- MCP servers start automatically with Claude Code
- If the server is unreachable (shut down, no network), MCP tools won't work but Claude Code will continue to function normally
- You can check the status at any time with `/mcp`

## MCP Server Coverage

### Proxmox MCP Server

| Operation | Example |
|-----------|---------|
| List LXC containers | `pct list` |
| Start/stop LXC | `pct start 400`, `pct stop 400` |
| LXC status | `pct status 400` |
| Create new LXC | `pct create ...` |
| Resources (CPU, RAM, disk) | Proxmox API monitoring |
| Storage info | `zpool status`, ZFS datasets |
| Backup/restore | Proxmox backup API |

### SSH MCP Server

| Operation | Example |
|-----------|---------|
| Docker management in LXC | `pct exec 400 -- docker ps` |
| Keycloak start/stop | `pct exec 400 -- docker start/stop keycloak` |
| systemd services | `systemctl status webzfs` |
| Reading logs | `journalctl -u webzfs`, `docker logs keycloak` |
| Reading files | `cat /root/keycloak-demo-password.txt` |
| Running scripts | `/opt/keycloak-rotate-password.sh` |
| Any shell command | Arbitrary command on the server |

## Security

| Aspect | Implementation |
|--------|----------------|
| Claude credentials on server | None — MCP servers run locally |
| SSH authentication | Ed25519 key (`~/.ssh/proxmox_mcp`) |
| Proxmox API access | Token `root@pam!claude-mcp` (privsep=0) |
| Network access | LAN only (192.168.2.0/24) |
| New ports on server | None — uses existing ones (SSH:22, API:8006) |
| Sensitive data | Token and SSH key stored locally only |

### Optional: restricting the Proxmox API token

A dedicated user with limited privileges can be created:

```bash
# On the server
pveum user add claude@pve
pveum aclmod / -user claude@pve -role PVEAuditor  # read-only
pveum user token add claude@pve mcp-token
```

Available roles:
- `PVEAuditor` — read-only (safest)
- `PVEVMAdmin` — VM/LXC management
- `PVEAdmin` — full access

## Files

| Location | Description |
|----------|-------------|
| `bin/install.sh` | Automated installer for MCP servers |
| `mcp-servers/proxmox/` | Proxmox MCP server (git submodule) |
| `mcp-servers/.env` | Environment variables for Proxmox MCP (not tracked) |
| `.gitmodules` | Git submodule definitions |
| `~/.claude.json` | Claude Code configuration with MCP servers |
| `~/.ssh/proxmox_mcp` | SSH private key for MCP access |
| `~/.ssh/proxmox_mcp.pub` | SSH public key (copied to server) |

## Management

### Checking MCP server status

Run the `/mcp` command in Claude Code.

### Removing MCP servers

The recommended way to remove everything is the installer's uninstall mode:

```bash
bash bin/install.sh --uninstall
```

This handles MCP server removal, directory cleanup, SSH key deletion, and API token revocation interactively.

Alternatively, you can remove components manually:

```bash
claude mcp remove proxmox
claude mcp remove ssh-server
```

### Deleting the API token

```bash
ssh -i ~/.ssh/proxmox_mcp root@192.168.2.123 "pveum user token remove root@pam claude-mcp"
```

### Removing the SSH key from the server

```bash
ssh -i ~/.ssh/proxmox_mcp root@192.168.2.123 "sed -i '/claude-mcp-proxmox/d' ~/.ssh/authorized_keys"
```

## Rejected Alternatives

| Approach | Reason |
|----------|--------|
| Custom REST API (FastAPI) on server | Proxmox already has an API; requires custom code and maintenance |
| WebSocket server on server | Over-engineering; SSH does the same thing and better |
| Claude login on server | Security risk — credentials on the server |
| Claude Agent SDK on server | Requires API key on the server |
| Ansible | Good for playbooks but too much ceremony for ad-hoc commands |

## Notes

- MCP servers start automatically when Claude Code is launched
- If an MCP server is not working, Claude Code still functions (just without those tools)
- Status can be checked with the `/mcp` command in Claude Code
- **Claude Code must be restarted** for new MCP servers to be recognized
- Installed: 2026-02-17
