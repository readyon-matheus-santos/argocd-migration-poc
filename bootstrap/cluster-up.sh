#!/usr/bin/env bash
# Creates the lab's kind cluster and exports ONLY its kubeconfig to
# .cache/kubeconfig. The user's default kubeconfig is never read or written.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/lib/env.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"

mkdir -p "$(dirname "$KUBECONFIG_PATH")"

if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
  echo "kind cluster '$KIND_CLUSTER_NAME' already exists; reusing it."
else
  rendered_config="$(mktemp)"
  trap 'rm -f "$rendered_config"' EXIT
  sed "s|__KINDEST_NODE_IMAGE__|${KINDEST_NODE_IMAGE}|" "$SCRIPT_DIR/kind-config.yaml" > "$rendered_config"
  kind create cluster --name "$KIND_CLUSTER_NAME" --config "$rendered_config"
fi

kind export kubeconfig --name "$KIND_CLUSTER_NAME" --kubeconfig "$KUBECONFIG_PATH"
echo "Cluster '$KIND_CLUSTER_NAME' kubeconfig exported to $KUBECONFIG_PATH"
