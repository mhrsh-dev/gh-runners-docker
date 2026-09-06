#!/usr/bin/env bash
# Show pi's auth state inside the shared credentials volume.
set -euo pipefail
docker run --rm \
  -e PI_CODING_AGENT_DIR=/pi-home/agent \
  -v pi-agent-home:/pi-home \
  --entrypoint pi \
  gh-runners/pi:latest auth check --provider anthropic --json
