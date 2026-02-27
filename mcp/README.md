# Homelab MCP Server

MCP (Model Context Protocol) server providing Claude Code access to Pi-hole and UniFi for read-only monitoring and diagnostics.

Uses [bjeans/homelab-mcp](https://github.com/bjeans/homelab-mcp) Docker image.

# Setup

## 1. Fill in env vars

```bash
cp .env.example .env
```

Edit `.env` with your actual credentials

## 2. Start the container

```bash
docker compose up -d && docker compose logs -f
```

## 3. Configure Claude Code MCP

Create/edit `.mcp.json` in your project root (or `~/.claude/mcp.json` for global):

```json
{
  "mcpServers": {
    "homelab-pihole": {
      "command": "docker",
      "args": [
        "exec", "-i", "homelab-mcp",
        "python", "pihole_mcp.py"
      ]
    },
    "homelab-unifi": {
      "command": "docker",
      "args": [
        "exec", "-i", "homelab-mcp",
        "python", "unifi_mcp_optimized.py"
      ]
    }
  }
}
```

### 3. Restart Claude Code

Exit and relaunch Claude Code. Run `/mcp` to verify both servers connect.
