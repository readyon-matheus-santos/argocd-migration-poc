#!/usr/bin/env bash
# Renders bootstrap/root-app.yaml.tmpl and applies it. This is the only
# script that materializes REPO_URL/GIT_BRANCH into a live cluster object.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/lib/env.sh"

sed \
  -e "s|__REPO_URL__|${REPO_URL}|g" \
  -e "s|__GIT_BRANCH__|${GIT_BRANCH}|g" \
  "$SCRIPT_DIR/root-app.yaml.tmpl" \
  | kubectl apply -f -

echo "root Application applied (repoURL=$REPO_URL targetRevision=$GIT_BRANCH)."
