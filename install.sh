#!/usr/bin/env bash
# install.sh — Install the catalog agent on a node.
#
# Run locally on the target node:
#   curl -sf <url>/install.sh | bash -s -- --url http://100.106.80.3:3200 --token <key> --name my-node
#
# Or copy and run manually:
#   ./install.sh --url http://100.106.80.3:3200 --token <CATALOG_API_KEY> --name my-node

set -euo pipefail

CATALOG_URL=""
CATALOG_TOKEN=""
NODE_NAME=""
MANIFEST_DIR="/etc/catalog"
INSTALL_DIR="/usr/local/bin"
AGENT_SCRIPT="catalog-agent"

usage() {
  echo "Usage: $0 --url <CATALOG_URL> --token <CATALOG_API_KEY> [--name <NODE_NAME>]"
  echo ""
  echo "Options:"
  echo "  --url    Forge dashboard URL (e.g. http://100.106.80.3:3200)"
  echo "  --token  Catalog API key (Bearer token for reporting)"
  echo "  --name   Node name (default: hostname)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)   CATALOG_URL="$2"; shift 2 ;;
    --token) CATALOG_TOKEN="$2"; shift 2 ;;
    --name)  NODE_NAME="$2"; shift 2 ;;
    *)       usage ;;
  esac
done

[[ -z "$CATALOG_URL" ]] && echo "Error: --url required" && usage
[[ -z "$CATALOG_TOKEN" ]] && echo "Error: --token required" && usage
NODE_NAME="${NODE_NAME:-$(hostname -s)}"

# Check dependencies
for cmd in python3 curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd is required but not found"
    exit 1
  fi
done

echo "Installing catalog-agent for node: $NODE_NAME"

# 1. Install the agent script
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/catalog-agent.sh" ]]; then
  cp "$SCRIPT_DIR/catalog-agent.sh" "$INSTALL_DIR/$AGENT_SCRIPT"
else
  echo "Error: catalog-agent.sh not found in $SCRIPT_DIR"
  exit 1
fi
chmod +x "$INSTALL_DIR/$AGENT_SCRIPT"
echo "  Installed $INSTALL_DIR/$AGENT_SCRIPT"

# 2. Create manifest if it doesn't exist
mkdir -p "$MANIFEST_DIR"
if [[ ! -f "$MANIFEST_DIR/manifest.yaml" ]]; then
  cat > "$MANIFEST_DIR/manifest.yaml" <<YAML
# Node manifest for $NODE_NAME
# Edit this file to describe your services.
# The agent will auto-discover additional listening ports.

node:
  name: $NODE_NAME

# Ports to exclude from auto-discovery
ignore_ports:
  - 53     # DNS resolver
  - 22     # SSH

services: []
  # Example:
  # - name: my-service
  #   port: 8080
  #   protocol: http
  #   health: /health
  #   description: "My awesome service"
YAML
  echo "  Created $MANIFEST_DIR/manifest.yaml (edit to add your services)"
else
  echo "  Manifest already exists at $MANIFEST_DIR/manifest.yaml (skipped)"
fi

# 3. Set up cron job
CRON_LINE="*/5 * * * * CATALOG_URL=\"$CATALOG_URL\" CATALOG_TOKEN=\"$CATALOG_TOKEN\" $INSTALL_DIR/$AGENT_SCRIPT >> /tmp/catalog-agent.log 2>&1"

if crontab -l 2>/dev/null | grep -qF "$AGENT_SCRIPT"; then
  echo "  Cron job already exists (skipped)"
else
  (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
  echo "  Added cron job (every 5 min)"
fi

# 4. Test report
echo "  Testing first report..."
if CATALOG_URL="$CATALOG_URL" CATALOG_TOKEN="$CATALOG_TOKEN" "$INSTALL_DIR/$AGENT_SCRIPT" 2>&1; then
  echo ""
  echo "Done! Node '$NODE_NAME' is now reporting to $CATALOG_URL"
  echo "Edit $MANIFEST_DIR/manifest.yaml to describe your services."
else
  echo ""
  echo "Warning: Test report failed. Check CATALOG_URL and CATALOG_TOKEN."
  echo "The cron job is installed and will retry every 5 minutes."
fi
