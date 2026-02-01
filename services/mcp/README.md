# Homelab MCP Server

MCP (Model Context Protocol) server providing Claude Code access to Pi-hole and UniFi for read-only monitoring and diagnostics.

Uses [bjeans/homelab-mcp](https://github.com/bjeans/homelab-mcp) Docker image.

## Setup on Raspberry Pi

### 1. Create directory and files

```bash
mkdir -p ~/homelab-mcp && cd ~/homelab-mcp
```

Copy `docker-compose.yaml` and `.env.example` from this directory to the Pi.

Edit `.env` with your actual credentials:

### 3. Start the container

```bash
docker-compose up -d
```

## Setup on Client (Linux PC)

### 1. Ensure passwordless SSH to the Pi

```bash
# Assuming "pi.hole" is a hostname that resolves to the Pi-hole IP address
ssh-copy-id me@pi.hole
ssh me@pi.hole "echo connected"  # Should work without password prompt
```

### 2. Configure Claude Code MCP

Create/edit `.mcp.json` in your project root (or `~/.claude/mcp.json` for global):

```json
{
  "mcpServers": {
    "homelab-pihole": {
      "command": "ssh",
      "args": [
        "me@pi.hole",
        "docker", "exec", "-i", "homelab-mcp",
        "python", "pihole_mcp.py"
      ]
    },
    "homelab-unifi": {
      "command": "ssh",
      "args": [
        "me@pi.hole",
        "docker", "exec", "-i", "homelab-mcp",
        "python", "unifi_mcp_optimized.py"
      ]
    }
  }
}
```

### 3. Restart Claude Code

Exit and relaunch Claude Code. Run `/mcp` to verify both servers connect.
