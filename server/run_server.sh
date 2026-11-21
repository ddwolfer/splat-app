#!/usr/bin/env bash
# Start splat-server (Git Bash).
#   server/run_server.sh          -> 127.0.0.1:8000 (this PC only)
#   server/run_server.sh --lan    -> 0.0.0.0:8000   (reachable from the LAN; needs the firewall rule)
set -euo pipefail
PY="${PY:-/c/Users/$USERNAME/anaconda3/envs/sharp/python.exe}"
HOST=127.0.0.1
if [[ "${1:-}" == "--lan" ]]; then HOST=0.0.0.0; fi
# The user site-packages (%APPDATA%\Python\Python313) would shadow the conda env's packages.
export PYTHONNOUSERSITE=1
cd "$(dirname "$0")"
exec "$PY" app.py --host "$HOST" --port "${PORT:-8000}"
