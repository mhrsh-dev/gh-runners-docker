#!/usr/bin/env bash
# Stop the runner set for one repository. Registration and pi credentials live
# in named volumes and survive; add -v yourself to wipe them.
set -euo pipefail
repo=${1:?usage: down.sh <repo-name> [compose args...]}
shift || true
root=$(cd "$(dirname "$0")/.." && pwd)
exec docker compose \
  --project-directory "$root" \
  --project-name "runners-$repo" \
  --env-file "$root/envs/$repo.env" \
  down "$@"
