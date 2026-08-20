#!/usr/bin/env bash
# Creates the second ("workload") kind cluster and registers it with the ArgoCD
# running on the control cluster — the harmony topology in miniature:
#
#   control cluster   : ArgoCD + every Application object (like harmony-platform-use2)
#   workload cluster  : tenant namespaces, postgres, service pods (like harmony-nonprod-use2)
#
# Registration is the same mechanism harmony uses: a Secret of type
# argocd.argoproj.io/secret-type=cluster holding the remote API endpoint, a
# ServiceAccount bearer token and the cluster CA. Both kind clusters sit on the
# docker "kind" network, so the control cluster reaches the workload API by its
# container IP (the host-facing 127.0.0.1 port would not resolve from a pod).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/lib/env.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"

WORKLOAD_CLUSTER="${WORKLOAD_CLUSTER_NAME:-${KIND_CLUSTER_NAME}-workload}"
WORKLOAD_KUBECONFIG="$LAB_ROOT/.cache/kubeconfig-workload"
SA_NS=kube-system
SA_NAME=argocd-manager

mkdir -p "$(dirname "$WORKLOAD_KUBECONFIG")"

CONTROL_CTX="kind-${KIND_CLUSTER_NAME}"
ck() { kubectl --context "$CONTROL_CTX" "$@"; }

if kind get clusters 2>/dev/null | grep -qx "$WORKLOAD_CLUSTER"; then
  echo "kind cluster '$WORKLOAD_CLUSTER' already exists; reusing it."
else
  rendered="$(mktemp)"
  trap 'rm -f "$rendered"' EXIT
  sed "s|__KINDEST_NODE_IMAGE__|${KINDEST_NODE_IMAGE}|" "$SCRIPT_DIR/kind-config.yaml" > "$rendered"
  # --kubeconfig keeps kind from rewriting (and re-pointing) the control kubeconfig,
  # which it would otherwise do because KUBECONFIG is exported by env.sh.
  kind create cluster --name "$WORKLOAD_CLUSTER" --config "$rendered" --kubeconfig "$WORKLOAD_KUBECONFIG"
fi
kind export kubeconfig --name "$WORKLOAD_CLUSTER" --kubeconfig "$WORKLOAD_KUBECONFIG"
echo "workload kubeconfig -> $WORKLOAD_KUBECONFIG"

wk() { kubectl --kubeconfig "$WORKLOAD_KUBECONFIG" "$@"; }

# ArgoCD needs a real identity on the remote cluster, exactly as in harmony.
wk create serviceaccount "$SA_NAME" -n "$SA_NS" --dry-run=client -o yaml | wk apply -f - >/dev/null
wk create clusterrolebinding "$SA_NAME" \
  --clusterrole=cluster-admin --serviceaccount="$SA_NS:$SA_NAME" \
  --dry-run=client -o yaml | wk apply -f - >/dev/null

TOKEN="$(wk create token "$SA_NAME" -n "$SA_NS" --duration=8760h)"
CA_DATA="$(wk config view --raw --minify --flatten \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"

# In-docker endpoint: the control cluster's pods dial the workload API server by
# container IP, not the 127.0.0.1:PORT the host kubeconfig uses.
NODE_CONTAINER="${WORKLOAD_CLUSTER}-control-plane"
NODE_IP="$(docker inspect "$NODE_CONTAINER" \
  --format '{{ (index .NetworkSettings.Networks "kind").IPAddress }}')"
SERVER="https://${NODE_IP}:6443"
echo "workload API (from inside the docker network): $SERVER"

# The cluster Secret is created on the CONTROL cluster, where ArgoCD runs.
ck create secret generic "cluster-${WORKLOAD_CLUSTER}" \
  -n argocd \
  --from-literal=name="$WORKLOAD_CLUSTER" \
  --from-literal=server="$SERVER" \
  --from-literal=config="{\"bearerToken\":\"${TOKEN}\",\"tlsClientConfig\":{\"insecure\":false,\"caData\":\"${CA_DATA}\"}}" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - "argocd.argoproj.io/secret-type=cluster" --dry-run=client -o yaml \
  | ck apply -f - >/dev/null
echo "registered '$WORKLOAD_CLUSTER' with ArgoCD on the control cluster (token not printed)."

# Prove ArgoCD can actually reach it before any Application depends on it.
ck -n argocd rollout status statefulset/argocd-application-controller --timeout=120s >/dev/null
echo "done. Children can now target: name=$WORKLOAD_CLUSTER  server=$SERVER"
