#!/usr/bin/env bash
# Shared configuration contract for this lab. Source this from any script
# invoked outside `make` so it agrees with the Makefile's defaults/overrides.
#
# Precedence: already-exported environment > .env at the lab root > these defaults.
set -euo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export LAB_ROOT

if [[ -f "$LAB_ROOT/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$LAB_ROOT/.env"
  set +a
fi

: "${REPO_URL:=https://github.com/readyon-matheus-santos/argocd-migration-poc.git}"
: "${GITHUB_LOGIN:=$(gh api user --jq .login 2>/dev/null)}"
: "${GIT_BRANCH:=main}"
: "${KIND_CLUSTER_NAME:=argocd-migration-poc}"
: "${KUBECONFIG_PATH:=$LAB_ROOT/.cache/kubeconfig}"

export REPO_URL GITHUB_LOGIN GIT_BRANCH KIND_CLUSTER_NAME KUBECONFIG_PATH
export KUBECONFIG="$KUBECONFIG_PATH"
