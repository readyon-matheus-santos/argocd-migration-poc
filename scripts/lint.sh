#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env.sh"
cd "$LAB_ROOT"
helm lint gitops/root --set repoURL=https://example.invalid/x.git --set targetRevision=main
helm lint gitops/charts/postgres
helm lint gitops/charts/fake-service --set name=backend
helm lint gitops/charts/tenant-parent --set repoURL=https://example.invalid/x.git --set targetRevision=main --set tenant=acme --set namespace=acme
helm lint gitops/charts/tenant-parent --set mode=migrations --set releaseId=r0 --set "services[0].name=backend" --set "services[0].db=main" --set "services[0].version=v1"
for f in bootstrap/*.sh scripts/*.sh scripts/lib/*.sh; do bash -n "$f"; done
if command -v shellcheck >/dev/null; then shellcheck -x bootstrap/*.sh scripts/*.sh scripts/lib/*.sh || true; fi
if git grep -nE 'gh[opusr]_[A-Za-z0-9]{20,}' -- . ; then echo "token-shaped content found" >&2; exit 1; fi
if git grep -n -E 'github.com/[A-Za-z0-9_-]+/argocd-migration-poc' -- gitops ; then echo "concrete repo URL inside gitops/" >&2; exit 1; fi
echo "lint OK"
