#!/usr/bin/env bash
# Installs ArgoCD v3.4.5 (pinned, official manifest) into namespace argocd,
# sets timeout.reconciliation=15s, and restarts the application controller
# so the setting is certainly in effect.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/lib/env.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# --server-side: the applicationsets CRD exceeds the 256KiB last-applied
# annotation limit under client-side apply. --force-conflicts keeps re-runs
# idempotent (this script is the only manager of these objects).
kubectl apply --server-side --force-conflicts -n argocd -f "$ARGOCD_INSTALL_MANIFEST"

kubectl wait --for=condition=Available --timeout=300s deployment --all -n argocd

kubectl patch configmap argocd-cm -n argocd --type merge --patch-file "$SCRIPT_DIR/argocd-cm-patch.yaml"
kubectl rollout restart statefulset/argocd-application-controller -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=180s

kubectl wait --for=condition=Available --timeout=300s deployment --all -n argocd
echo "ArgoCD $ARGOCD_VERSION installed and healthy in namespace argocd."
