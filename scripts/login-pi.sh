#!/usr/bin/env bash
# One-time per machine: log pi in to a Claude Pro/Max subscription.
# Credentials land in the shared `pi-agent-home` Docker volume and auto-refresh;
# the host ~/.pi/agent is never mounted.
#
# In the pi TUI: /login -> Claude Pro/Max -> follow the URL -> paste the code,
# then /exit.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

docker image inspect gh-runners/pi:latest >/dev/null 2>&1 || {
  docker build -t gh-runners/base:latest -f "$root/Dockerfile.base" "$root"
  docker build -t gh-runners/pi:latest -f "$root/Dockerfile.pi" "$root"
}

docker run --rm -it \
  -e PI_CODING_AGENT_DIR=/pi-home/agent \
  -e TERM="${TERM:-xterm-256color}" \
  -v pi-agent-home:/pi-home \
  gh-runners/pi:latest pi
