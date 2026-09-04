#!/usr/bin/env bash
# Start the runner set for one repository.
#   scripts/up.sh <repo-name> [compose args...]
# Reads envs/<repo-name>.env and uses compose project runners-<repo-name>,
# so several repos' runners coexist on one machine.
set -euo pipefail

repo=${1:?usage: up.sh <repo-name> [compose args...]}
shift || true
root=$(cd "$(dirname "$0")/.." && pwd)
envfile="$root/envs/$repo.env"

[ -f "$envfile" ] || { echo "missing $envfile (copy envs/example.env)" >&2; exit 1; }

exec docker compose \
  --project-directory "$root" \
  --project-name "runners-$repo" \
  --env-file "$envfile" \
  up -d --build "$@"
