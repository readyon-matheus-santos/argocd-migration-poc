#!/usr/bin/env bash
# Scenario driver: scripts/run.sh <N>. Self-contained and re-runnable from any
# prior state: preflight → profile + baseline → truncate ledgers → sampler →
# release commit(s) → end condition → forensics into runs/sN/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/lib/kube.sh"
source "$SCRIPT_DIR/lib/git.sh"
source "$SCRIPT_DIR/lib/release.sh"
source "$SCRIPT_DIR/lib/sampler.sh"

N="${1:?usage: run.sh <scenario-number>}"
RUN_DIR="$LAB_ROOT/runs/s$N"
LEDGER="$RUN_DIR/commits.tsv"
SAMPLES="$RUN_DIR/samples.tsv"
TENANT=acme
SERVICES=(backend subgraph-a subgraph-b)

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

tenant_app_list() { local t="$1" s; for s in postgres backend subgraph-a subgraph-b; do echo "$s-$t"; done; }
hook_apps() { local t s; for t in acme globex; do for s in backend subgraph-a subgraph-b; do echo "tenant-migrations-$s-$t"; done; done; }

# converge_baseline <profile> <releaseId>
converge_baseline() {
  local profile="$1" rel="$2"
  write_profile "$profile"
  local t; for t in acme globex; do write_tenant_values "$t" "$rel" v1; done
  local sha
  sha="$(commit_paths "$LEDGER" "s$N: profile $profile + baseline $rel" gitops/root/values.yaml gitops/values)"
  [[ -n "$sha" ]] && log "baseline commit ${sha:0:7} pushed" || log "baseline already in place (no commit)"
  hard_refresh root
  wait_apps_synced_healthy 180 root
  local apps=(); for t in acme globex; do while read -r a; do apps+=("$a"); done < <(tenant_app_list "$t"); done
  if [[ "$profile" == aoa ]]; then
    # shellcheck disable=SC2046
    apps+=(tenant-acme tenant-globex $(hook_apps))
  else
    # shellcheck disable=SC2046
    wait_apps_absent 300 tenant-acme tenant-globex $(hook_apps)
  fi
  if [[ "$profile" == aoa ]]; then
    local head; head="$(git -C "$LAB_ROOT" rev-parse HEAD)"
    hard_refresh tenant-acme tenant-globex 2>/dev/null || true
    wait_apps_at_revision 900 "$head" tenant-acme tenant-globex
  fi
  wait_apps_exist 300 "${apps[@]}"
  hard_refresh "${apps[@]}"
  wait_apps_synced_healthy 900 "${apps[@]}"
  for t in acme globex; do wait_pods_ready 300 "$t" "$rel"; done
  log "baseline $rel converged (profile $profile)"
}

# release <releaseId> <version> [write_tenant_values extra args...]  -> sets RELEASE_SHA
release() {
  local rel="$1" ver="$2"; shift 2
  write_tenant_values "$TENANT" "$rel" "$ver" "$@"
  RELEASE_SHA="$(commit_paths "$LEDGER" "s$N: $TENANT release $rel ($ver)" "gitops/values/_tenants/$TENANT")"
  [[ -n "$RELEASE_SHA" ]] || { echo "release $rel produced no change" >&2; return 1; }
  log "release $rel pushed as ${RELEASE_SHA:0:7}"
  # shellcheck disable=SC2046
  hard_refresh $(tenant_apps "$TENANT")
}

wait_release_settled() { # all tenant apps Synced/Healthy at RELEASE_SHA (or Failed op), timeout
  local timeout="$1" apps=()
  while read -r a; do apps+=("$a"); done < <(tenant_apps "$TENANT")
  wait_apps_at_revision "$timeout" "$RELEASE_SHA" "${apps[@]}"
}

aoa_setup() {
  # Make sure the Application health check (bootstrap/argocd-cm-patch.yaml) is in place:
  # the parent's waves between children (2 -> 4) need it.
  k patch configmap argocd-cm -n argocd --type merge --patch-file "$LAB_ROOT/bootstrap/argocd-cm-patch.yaml" >/dev/null
}

finish() {
  stop_sampler
  # shellcheck disable=SC2046
  hard_refresh $(all_apps); sleep 5
  dump_forensics "$RUN_DIR"
  log "forensics in $RUN_DIR"
}

# ---------------------------------------------------------------------------
bash "$LAB_ROOT/bootstrap/preflight.sh" >/dev/null
require_clean_gitops
require_not_behind
mkdir -p "$RUN_DIR"; : > "$LEDGER"

case "$N" in
10a)
  # The design, success path only (watchable).
  aoa_setup
  converge_baseline aoa r120
  truncate_ledgers
  if [[ "${PREPARE_ONLY:-0}" == 1 ]]; then log "prepared: app-of-apps baseline r120 converged; run 'make scenario-10a' to fire the r121 release"; exit 0; fi
  start_sampler "$SAMPLES"; trap finish EXIT
  release r121 v2 backend=30 subgraph-a=30 subgraph-b=30; hard_refresh tenant-acme
  wait_release_settled 600; wait_pods_ready 300 acme r121
  ;;
1)
  converge_baseline appsets r10
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  release r11 v2 backend=2 subgraph-a=120 subgraph-b=2
  wait_release_settled 600 || log "WARN: release did not fully settle (see forensics)"
  ;;
10)
  # The design: parent reads the per-service tenant files (fileParameters), runs the migrations as its own PreSync, pins children inline. Gate OFF.
  aoa_setup
  PHASES="$RUN_DIR/phases.tsv"; : > "$PHASES"
  mark() { printf '%s\t%s\n' "$1" "$(date +%s)" >> "$PHASES"; log "phase: $1"; }
  converge_baseline aoa r130
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  release r131 v2 backend=30 subgraph-a=30 subgraph-b=30; hard_refresh tenant-acme; mark r131_push
  wait_release_settled 600 || log "WARN: r131 not settled"; wait_pods_ready 300 acme r131 || true; mark r131_done
  release r132 v3 backend=2 subgraph-b=2 subgraph-a=5 fail:subgraph-a; hard_refresh tenant-acme; mark r132_push
  R132_SHA="$RELEASE_SHA"
  el=0; while [[ "$(app_state tenant-acme)" != *Failed* && $el -lt 480 ]]; do sleep 3; el=$((el+3)); done
  mark parent_failed; log "parent: $(app_state tenant-acme)"
  log "observing 60s"; sleep 60; mark observe_end
  git -C "$LAB_ROOT" revert --no-edit "$R132_SHA" >/dev/null
  RELEASE_SHA="$(git -C "$LAB_ROOT" rev-parse HEAD)"; git -C "$LAB_ROOT" push -q origin "HEAD:$GIT_BRANCH"
  printf '%s\t%s\t%s\n' "$RELEASE_SHA" "$(date +%s)" "s10: revert acme r132 (${R132_SHA:0:7})" >> "$LEDGER"; mark revert_push
  # shellcheck disable=SC2046
  hard_refresh $(tenant_apps acme)
  wait_release_settled 600 || log "WARN: post-revert not settled"; wait_pods_ready 300 acme r131 || true; mark revert_done
  ;;
*) echo "scenario $N not implemented" >&2; exit 2 ;;
esac
log "scenario $N run complete"
