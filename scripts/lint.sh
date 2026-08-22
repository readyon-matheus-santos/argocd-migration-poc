#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env.sh"
cd "$LAB_ROOT"
helm lint gitops/root --set repoURL=https://example.invalid/x.git --set targetRevision=main
helm lint gitops/charts/postgres
helm lint gitops/charts/fake-service --set name=backend
helm lint gitops/charts/fake-service --set name=backend --set migrationsOnly=true
helm dependency build gitops/charts/tenant-migrations >/dev/null
helm lint gitops/charts/tenant-migrations --set backend.enabled=true --set backend.name=backend --set backend.db.name=main
helm lint gitops/charts/tenant-parent --set repoURL=https://example.invalid/x.git --set targetRevision=main --set tenant=acme --set namespace=acme
helm lint gitops/charts/tenant-parent-harmony --set mode=parent
helm lint gitops/charts/tenant-parent-harmony --set mode=migrations --set migrations.job.image=v1 --set migrations.job.repository=ecr/x
helm template t gitops/charts/tenant-parent-harmony -f gitops/charts/tenant-parent-harmony/ci/armk-prod-use2-values.yaml >/dev/null
if grep -rqE "\b(9511139|9757074|1161535)[0-9]{5}\b" gitops/ ; then echo "AWS account id in a public repo" >&2; exit 1; fi

for f in bootstrap/*.sh scripts/*.sh scripts/lib/*.sh; do bash -n "$f"; done
if command -v shellcheck >/dev/null; then shellcheck -x bootstrap/*.sh scripts/*.sh scripts/lib/*.sh || true; fi
if git grep -nE 'gh[opusr]_[A-Za-z0-9]{20,}' -- . ; then echo "token-shaped content found" >&2; exit 1; fi
if git grep -n -E 'github.com/[A-Za-z0-9_-]+/argocd-migration-poc' -- gitops ; then echo "concrete repo URL inside gitops/" >&2; exit 1; fi
echo "lint OK"
