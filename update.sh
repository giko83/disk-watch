#!/usr/bin/env bash
# Manually update a working Git checkout, then redeploy code only.
set -euo pipefail
[[ ${EUID} -eq 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
REPO_DIR=${DISK_WATCH_REPO:-/opt/disk-watch}
[[ -d "$REPO_DIR/.git" ]] || { echo "Not a Git checkout: $REPO_DIR" >&2; exit 1; }
cd "$REPO_DIR"
[[ -z "$(git status --porcelain)" ]] || { echo 'Checkout has local modifications; update aborted' >&2; exit 1; }
old=$(git rev-parse HEAD)
git pull --ff-only
# Refuse to deploy an incomplete or syntactically invalid checkout.
# This is a preflight, NOT an automatic rollback of the Git pull.
if ! bash ./install.sh --preflight; then
  echo "Preflight failed; installed files were not replaced. Checkout advanced from $old; investigate before retrying." >&2
  exit 1
fi
if ! bash ./install.sh; then
  echo "Install failed. Previous revision: $old. Investigate before retrying." >&2
  exit 1
fi
echo "Disk Watch updated to $(git rev-parse --short HEAD)"
