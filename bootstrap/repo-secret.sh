#!/usr/bin/env bash
# Idempotent ArgoCD repository Secret for the lab's private repo. The token
# flows from `gh auth token` straight through kubectl and is NEVER stored in
# a shell variable, argument, file, log, shell history, or evidence
# artifact. Secret contents are never printed by this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/lib/env.sh"

SECRET_NAME="repo-argocd-migration-poc"

gh auth token --user "$GITHUB_LOGIN" \
  | tr -d '\n' \
  | kubectl create secret generic "$SECRET_NAME" \
      -n argocd \
      --from-literal=type=git \
      --from-literal=url="$REPO_URL" \
      --from-literal=username="$GITHUB_LOGIN" \
      --from-file=password=/dev/stdin \
      --dry-run=client -o yaml \
  | kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" --dry-run=client -o yaml \
  | kubectl apply -f -

echo "Secret $SECRET_NAME applied in namespace argocd (contents not printed)."
