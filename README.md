# catalog-agent

A lightweight, self-reporting infrastructure catalog agent. Runs on each node (Linux or macOS), discovers listening services, and reports to a [Forge dashboard](https://github.com/rhclaw/forge-dashboard).

## Quick Start

### Install on a node

```bash
# Download
curl -sfL https://raw.githubusercontent.com/rhclaw/catalog-agent/main/install.sh -o /tmp/install.sh
curl -sfL https://raw.githubusercontent.com/rhclaw/catalog-agent/main/catalog-agent.sh -o /tmp/catalog-agent.sh

# Install (requires root)
sudo bash /tmp/install.sh --url <CATALOG_URL> --token <CATALOG_API_KEY> --name my-node
```

This will:
1. Install `/usr/local/bin/catalog-agent`
2. Create `/etc/catalog/manifest.yaml` (if it doesn't exist)
3. Add a cron job to report every 5 minutes
4. Run a test report

### Manual install

```bash
# Copy the agent script
sudo cp catalog-agent.sh /usr/local/bin/catalog-agent
sudo chmod +x /usr/local/bin/catalog-agent

# Create a manifest
sudo mkdir -p /etc/catalog
sudo cp examples/linux-vps.yaml /etc/catalog/manifest.yaml
# Edit to match your services

# Add cron
(crontab -l 2>/dev/null; echo '*/5 * * * * CATALOG_URL="<URL>" CATALOG_TOKEN="<TOKEN>" /usr/local/bin/catalog-agent >> /tmp/catalog-agent.log 2>&1') | crontab -
```

## How It Works

```
Node (cron every 5m)                    Forge Dashboard
┌─────────────────────┐                ┌──────────────────┐
│ /etc/catalog/        │  POST /api/   │ catalog.json      │
│   manifest.yaml     │──catalog/──→  │                   │
│ + ss/lsof live scan  │   report      │ "Infra" tab       │
└─────────────────────┘  (Bearer key) └──────────────────┘
```

1. Reads the manifest for known services and ignore list
2. Scans live TCP ports (`ss -tlnp` on Linux, `lsof` on macOS)
3. Matches live ports to manifest entries → marks up/down
4. Auto-discovers unlisted ports (skips ignored ports and ephemeral tailscaled ports)
5. Collects system info (OS, arch, uptime, Tailscale IP)
6. POSTs merged report to the Forge dashboard

## Manifest Format

`/etc/catalog/manifest.yaml`:

```yaml
node:
  name: my-node          # Node name shown in dashboard

ignore_ports:
  - 53                   # systemd-resolved
  - 22                   # SSH

services:
  - name: my-app
    port: 3000
    protocol: http       # http, https, tcp, etc.
    health: /health      # Optional health endpoint
    description: "My application"

  - name: database
    port: 5432
    protocol: tcp
    description: "PostgreSQL"
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Service name |
| `port` | no | TCP port (omit for portless services like background agents) |
| `protocol` | no | Protocol hint (`http`, `https`, `tcp`, `bolt`, `wss`) |
| `health` | no | Health check path (currently informational) |
| `description` | no | Human-readable description |
| `docs` | no | Link or reference to documentation |

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `CATALOG_URL` | yes | Base URL of Forge dashboard |
| `CATALOG_TOKEN` | yes | Bearer token for `/api/catalog/report` |
| `MANIFEST_FILE` | no | Path to manifest (default: `/etc/catalog/manifest.yaml`) |
| `NODE_NAME` | no | Override node name from manifest |

## Requirements

- `bash`, `python3`, `curl`
- `ss` (Linux) or `lsof` (macOS) for port discovery
- Network access to the Forge dashboard

## Examples

See [`examples/`](examples/) for manifest templates:
- [`linux-vps.yaml`](examples/linux-vps.yaml) — Generic Linux VPS
- [`macos.yaml`](examples/macos.yaml) — macOS with Ollama/MLX

## License

MIT
