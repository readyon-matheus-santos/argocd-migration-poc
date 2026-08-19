#!/usr/bin/env bash
# `make status`: uses ONLY the dedicated kubeconfig. Fails clearly, before
# doing anything, if bootstrap has not run yet — it never falls back to
# another kubeconfig or context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/lib/env.sh"

if [[ ! -f "$KUBECONFIG_PATH" ]]; then
  echo "No kubeconfig at $KUBECONFIG_PATH — run 'make bootstrap' first." >&2
  exit 1
fi

if ! kubectl --request-timeout=5s cluster-info >/dev/null 2>&1; then
  echo "Cluster at $KUBECONFIG_PATH is not reachable — run 'make bootstrap' first." >&2
  exit 1
fi

echo "== remote revision =="
git -C "$LAB_ROOT" ls-remote origin "refs/heads/$GIT_BRANCH" | awk '{print $1}'

echo
echo "== Applications (argocd namespace) =="
kubectl get applications.argoproj.io -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision,REVISIONS:.status.sync.revisions[0]'

for ns in acme globex; do
  echo
  echo "== tenant $ns: marker releaseId=$(kubectl get configmap migrations-complete -n "$ns" -o jsonpath='{.data.releaseId}' 2>/dev/null || echo '<none>') completed=[$(kubectl get configmap migrations-complete -n "$ns" -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | sed -n 's/^completed\.//p' | sort | tr '\n' ',')] =="
  kubectl get pods -n "$ns" -L version,release-id --no-headers 2>/dev/null \
    -o custom-columns='POD:.metadata.name,VERSION:.metadata.labels.version,RELEASE:.metadata.labels.release-id,READY:.status.conditions[?(@.type=="Ready")].status,PHASE:.status.phase' || true
done
