#!/usr/bin/env bash
# catalog-agent.sh — Self-reporting agent for the Forge infrastructure catalog.
# Deploy on each node (Linux/macOS). Reads a local manifest, discovers live services,
# and POSTs a report to the Forge dashboard.
#
# Usage:
#   CATALOG_URL=https://100.106.80.3:3200 CATALOG_TOKEN=xxx ./catalog-agent.sh
#
# Or install as a cron job / systemd timer:
#   */5 * * * * CATALOG_URL=... CATALOG_TOKEN=... /usr/local/bin/catalog-agent
#
# Environment:
#   CATALOG_URL    — Base URL of Forge dashboard (required)
#   CATALOG_TOKEN  — Bearer token for auth (required)
#   MANIFEST_FILE  — Path to node-manifest.yaml (default: /etc/catalog/manifest.yaml)
#   NODE_NAME      — Override node name (default: from manifest or hostname)

set -euo pipefail

MANIFEST="${MANIFEST_FILE:-/etc/catalog/manifest.yaml}"
CATALOG_URL="${CATALOG_URL:?CATALOG_URL is required}"
CATALOG_TOKEN="${CATALOG_TOKEN:?CATALOG_TOKEN is required}"

# ─── Parse YAML manifest (lightweight, no yq dependency) ───

parse_manifest_node() {
  if [[ ! -f "$MANIFEST" ]]; then
    echo ""
    return
  fi
  grep -E '^\s+name:' "$MANIFEST" | head -1 | sed 's/.*name:[[:space:]]*//' | tr -d '"'"'" | tr -d ' '
}

parse_manifest() {
  # Outputs JSON: {"services": [...], "ignore_ports": [...]}
  if [[ ! -f "$MANIFEST" ]]; then
    echo '{"services":[],"ignore_ports":[]}'
    return
  fi

  python3 -c "
import sys, json, re

services = []
ignore_ports = []
current = None
in_services = False
in_ignore = False

for line in open('$MANIFEST'):
    stripped = line.rstrip()
    # Track which top-level block we're in
    if re.match(r'^services:', stripped):
        in_services = True
        in_ignore = False
        continue
    if re.match(r'^ignore_ports:', stripped):
        in_ignore = True
        in_services = False
        continue
    if re.match(r'^[a-z]', stripped):
        in_services = False
        in_ignore = False

    if in_ignore:
        m = re.match(r'\s+-\s+(\d+)', stripped)
        if m:
            ignore_ports.append(int(m.group(1)))

    if in_services:
        if stripped.strip().startswith('- name:'):
            if current:
                services.append(current)
            current = {'name': stripped.split('name:')[1].strip().strip('\"').strip(\"'\")}
        elif current and ':' in stripped:
            key, val = stripped.strip().split(':', 1)
            key = key.strip()
            val = val.strip().strip('\"').strip(\"'\")
            if key == 'port':
                try: val = int(val)
                except: pass
            if key in ('name','port','protocol','health','description','docs'):
                current[key] = val

if current:
    services.append(current)
print(json.dumps({'services': services, 'ignore_ports': ignore_ports}))
" 2>/dev/null || echo '{"services":[],"ignore_ports":[]}'
}

# ─── Discover live listening ports ───

discover_services() {
  # Returns JSON array of {port, protocol, pid_name}
  if command -v ss &>/dev/null; then
    ss -tlnp 2>/dev/null | awk 'NR>1 {
      split($4, a, ":");
      port = a[length(a)];
      proc = $6;
      gsub(/.*users:\(\("/, "", proc);
      gsub(/".*/, "", proc);
      if (port ~ /^[0-9]+$/) printf "{\"port\":%s,\"process\":\"%s\"},", port, proc
    }' | sed 's/,$//' | awk '{print "["$0"]"}'
  elif command -v lsof &>/dev/null; then
    # macOS fallback
    lsof -iTCP -sTCP:LISTEN -nP 2>/dev/null | awk 'NR>1 {
      split($9, a, ":");
      port = a[length(a)];
      proc = $1;
      if (port ~ /^[0-9]+$/) printf "{\"port\":%s,\"process\":\"%s\"},", port, proc
    }' | sed 's/,$//' | awk '{print "["$0"]"}'
  else
    echo "[]"
  fi
}

# ─── Collect system info ───

get_os() {
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "macOS $(sw_vers -productVersion 2>/dev/null || echo unknown)"
  else
    . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s
  fi
}

get_tailscale_ip() {
  if command -v tailscale &>/dev/null; then
    tailscale ip -4 2>/dev/null || echo ""
  else
    echo ""
  fi
}

get_public_ip() {
  curl -sf --max-time 3 https://ifconfig.me 2>/dev/null || echo ""
}

# ─── Merge manifest + live discovery ───

build_report() {
  local node_name="${NODE_NAME:-$(parse_manifest_node)}"
  node_name="${node_name:-$(hostname -s)}"

  local manifest_data
  manifest_data="$(parse_manifest)"

  local live_ports
  live_ports="$(discover_services)"

  local os_info arch_info uptime_secs ts_ip pub_ip
  os_info="$(get_os)"
  arch_info="$(uname -m)"
  uptime_secs="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || python3 -c "import subprocess,time;b=subprocess.check_output(['sysctl','-n','kern.boottime']).decode();t=int(b.split('sec = ')[1].split(',')[0]);print(int(time.time()-t))" 2>/dev/null || echo 0)"
  ts_ip="$(get_tailscale_ip)"
  pub_ip="$(get_public_ip)"

  # Merge: start with manifest services, then check which ports are live
  # Filter out ignored ports and ephemeral ports (>32767) from unknown processes
  python3 -c "
import json, sys

data = json.loads('''$manifest_data''')
manifest = data['services']
ignore_ports = set(data['ignore_ports'])
live = json.loads('''$live_ports''')
live_port_set = {s['port'] for s in live}

# Processes whose ephemeral ports should be ignored
EPHEMERAL_PROCS = {'tailscaled'}

# Mark manifest services
for svc in manifest:
    if svc.get('port') and svc['port'] in live_port_set:
        svc['status'] = 'up'
        live_port_set.discard(svc['port'])
    elif svc.get('port'):
        svc['status'] = 'down'
    else:
        svc['status'] = 'unknown'

# Add discovered services not in manifest
manifest_ports = {s.get('port') for s in manifest}
for port_info in live:
    p = port_info['port']
    proc = port_info.get('process', '')
    if p in manifest_ports:
        continue
    if p in ignore_ports:
        continue
    # Skip ephemeral ports (>32767) from known system processes
    if p > 32767 and proc in EPHEMERAL_PROCS:
        continue
    manifest.append({
        'name': proc or 'unknown',
        'port': p,
        'protocol': 'tcp',
        'status': 'up',
        'description': 'Auto-discovered (not in manifest)',
    })

report = {
    'node': '$node_name',
    'tailscaleIp': '$ts_ip' or None,
    'publicIp': '$pub_ip' or None,
    'os': '$os_info',
    'arch': '$arch_info',
    'uptime': $uptime_secs,
    'services': manifest,
    'reportedAt': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
}
# Remove None values
report = {k: v for k, v in report.items() if v is not None and v != ''}
print(json.dumps(report))
"
}

# ─── Send report ───

report_json="$(build_report)"

curl -sf --max-time 10 \
  -X POST "${CATALOG_URL}/api/catalog/report" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${CATALOG_TOKEN}" \
  -d "$report_json" \
  >/dev/null

echo "Reported to ${CATALOG_URL} as $(echo "$report_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["node"])')"
