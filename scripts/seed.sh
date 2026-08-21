#!/usr/bin/env bash
# `make seed`: default profile (the app-of-apps design) at r0/v1 for both tenants;
# commit+push only if the tree differs; wait for full convergence and both
# every Application Synced/Healthy. Doubles as the whole-stack smoke test.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/kube.sh"
source "$SCRIPT_DIR/lib/git.sh"
source "$SCRIPT_DIR/lib/release.sh"

bash "$LAB_ROOT/bootstrap/preflight.sh"
require_clean_gitops
require_not_behind

write_profile aoa
for t in acme globex; do write_tenant_values "$t" r0 v1; done

sha="$(commit_paths "" "seed: default profile (app-of-apps) at r0" gitops/root/values.yaml gitops/values)"
if [[ -n "$sha" ]]; then echo "seed: pushed $sha"; else echo "seed: gitops/ already at default profile r0 (no commit)"; fi

kubectl patch configmap argocd-cm -n argocd --type merge --patch-file "$LAB_ROOT/bootstrap/argocd-cm-patch.yaml" >/dev/null
hard_refresh root
wait_apps_synced_healthy 180 root
wait_apps_exist 300 tenant-acme tenant-globex
head="$(git -C "$LAB_ROOT" rev-parse HEAD)"
hard_refresh tenant-acme tenant-globex
wait_apps_at_revision 900 "$head" tenant-acme tenant-globex
apps=()
for t in acme globex; do for s in postgres backend subgraph-a subgraph-b tenant; do apps+=("$s-$t"); done; done
wait_apps_exist 300 "${apps[@]}"
hard_refresh "${apps[@]}"
wait_apps_synced_healthy 600 "${apps[@]}"
for t in acme globex; do wait_pods_ready 300 "$t" r0; done
echo "seed: all ${#apps[@]} apps Synced/Healthy (app-of-apps layout, release r0)"
