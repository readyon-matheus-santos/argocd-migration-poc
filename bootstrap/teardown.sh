#!/usr/bin/env bash
# Deletes ONLY the named kind cluster. The Docker engine itself is left running.
# Cannot select another cluster: --name is always this lab's fixed name.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/lib/env.sh"

kind delete cluster --name "$KIND_CLUSTER_NAME"
echo "kind cluster '$KIND_CLUSTER_NAME' deleted."
