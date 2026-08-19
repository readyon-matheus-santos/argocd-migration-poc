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
layer_apps() { echo "tenant-migrations-acme tenant-migrations-globex"; }

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
  if [[ "$profile" == s1 || "$profile" == aoa ]]; then
    # shellcheck disable=SC2046
    wait_apps_absent 300 $(layer_apps)
  else
    # shellcheck disable=SC2046
    apps+=($(layer_apps))
  fi
  if [[ "$profile" == aoa ]]; then apps+=(tenant-acme tenant-globex); else wait_apps_absent 300 tenant-acme tenant-globex; fi
  if [[ "$profile" == aoa ]]; then
    local head; head="$(git -C "$LAB_ROOT" rev-parse HEAD)"
    hard_refresh tenant-acme tenant-globex 2>/dev/null || true
    wait_apps_at_revision 900 "$head" tenant-acme tenant-globex
  fi
  wait_apps_exist 300 "${apps[@]}"
  hard_refresh "${apps[@]}"
  wait_apps_synced_healthy 900 "${apps[@]}"
  if [[ "$profile" != s1 && "$profile" != aoa ]]; then for t in acme globex; do wait_marker 120 "$t" "$rel"; done; fi
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
3a)
  # Success path only (S3a) — the watchable "all migrations pass, then deploy" simulation.
  converge_baseline s3 r30
  truncate_ledgers
  if [[ "${PREPARE_ONLY:-0}" == 1 ]]; then log "prepared: baseline r30 converged; run 'make scenario-3a' to fire the r31 release"; exit 0; fi
  start_sampler "$SAMPLES"; trap finish EXIT
  release r31 v2 backend=30 subgraph-a=30 subgraph-b=30 keep:r30
  wait_release_settled 600; wait_marker 60 acme r31; wait_pods_ready 300 acme r31
  ;;
1)
  converge_baseline s1 r10
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  release r11 v2 backend=2 subgraph-a=120 subgraph-b=2
  wait_release_settled 600 || log "WARN: release did not fully settle (see forensics)"
  ;;
2)
  converge_baseline s2 r20
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  release r21 v2 backend=60 subgraph-a=60 subgraph-b=60 keep:r20
  wait_release_settled 600 || log "WARN: release did not fully settle"
  ;;
3)
  PHASES="$RUN_DIR/phases.tsv"; : > "$PHASES"
  mark() { printf '%s\t%s\n' "$1" "$(date +%s)" >> "$PHASES"; log "phase: $1"; }
  converge_baseline s3 r30
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  # --- S3a: success path ---
  release r31 v2 backend=30 subgraph-a=30 subgraph-b=30 keep:r30; mark r31_push
  wait_release_settled 600; wait_marker 60 acme r31; wait_pods_ready 300 acme r31; mark r31_done
  R31_SHA="$RELEASE_SHA"
  # --- S3b: failure + revert ---
  release r32 v3 backend=2 subgraph-b=2 subgraph-a=5 fail:subgraph-a keep:r31,r30; mark r32_push
  R32_SHA="$RELEASE_SHA"
  el=0; while [[ "$(app_state tenant-migrations-acme)" != *Failed* && $el -lt 300 ]]; do sleep 3; el=$((el+3)); done
  [[ "$(app_state tenant-migrations-acme)" == *Failed* ]] || log "WARN: tenant-migrations-acme never reached Failed"
  mark layer_failed
  log "observing failure window for 60s (no commits)"; sleep 60; mark observe_end
  git -C "$LAB_ROOT" revert --no-edit "$R32_SHA" >/dev/null
  RELEASE_SHA="$(git -C "$LAB_ROOT" rev-parse HEAD)"
  git -C "$LAB_ROOT" push -q origin "HEAD:$GIT_BRANCH"
  printf '%s\t%s\t%s\n' "$RELEASE_SHA" "$(date +%s)" "s3: revert acme r32 (${R32_SHA:0:7})" >> "$LEDGER"; mark revert_push
  # shellcheck disable=SC2046
  hard_refresh $(tenant_apps acme)
  wait_release_settled 600 || log "WARN: post-revert not fully settled"
  wait_marker 60 acme r31 || true; wait_pods_ready 300 acme r31 || true; mark revert_done
  ;;
4)
  converge_baseline s3 r40
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  release r41 v2 backend=20 subgraph-a=20 subgraph-b=20 keep:r40
  wait_release_settled 600; wait_marker 60 acme r41; wait_pods_ready 300 acme r41
  ;;
5)
  converge_baseline s3 r50
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  PHASES="$RUN_DIR/phases.tsv"; : > "$PHASES"
  write_tenant_values acme r50 v1 replicas:backend=3
  sha="$(commit_paths "$LEDGER" "s5: acme backend replicas 3 (no release)" gitops/values/_tenants/acme)"
  printf 'scale\t%s\n' "$(date +%s)" >> "$PHASES"; log "scale commit ${sha:0:7}"
  hard_refresh backend-acme
  k delete pod -n acme -l app.kubernetes.io/name=subgraph-a,job-role!=migration --wait=false >/dev/null
  printf 'delete\t%s\n' "$(date +%s)" >> "$PHASES"
  el=0; while (( el < 180 )); do
    n="$(k get pods -n acme -l 'app.kubernetes.io/name in (backend,subgraph-a),job-role!=migration' -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{" "}{end}' | tr ' ' '\n' | grep -c True)"
    [[ "$n" == 4 ]] && break; sleep 3; el=$((el+3)); done
  sleep 10; printf 'settled\t%s\n' "$(date +%s)" >> "$PHASES"
  write_tenant_values acme r50 v1
  commit_paths "$LEDGER" "s5: acme backend replicas back to 1" gitops/values/_tenants/acme >/dev/null; hard_refresh backend-acme
  ;;
6)
  converge_baseline s3 r60
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  release r61 v2 backend=120 subgraph-a=2 subgraph-b=2 gateTimeout:30 progressDeadline:60 keep:r60
  wait_release_settled 900 || log "WARN: not settled"; wait_marker 60 acme r61 || true; wait_pods_ready 600 acme r61 || true
  ;;
7)
  converge_baseline s3 r70
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  PHASES="$RUN_DIR/phases.tsv"; : > "$PHASES"
  release r71 v2 backend=90 subgraph-a=90 subgraph-b=90 keep:r70; printf 'r71_push\t%s\n' "$(date +%s)" >> "$PHASES"
  sleep 20
  release r72 v3 backend=5 subgraph-a=5 subgraph-b=5 keep:r71,r70; printf 'r72_push\t%s\n' "$(date +%s)" >> "$PHASES"
  wait_release_settled 900 || log "WARN: not settled"; wait_marker 120 acme r72 || true; wait_pods_ready 600 acme r72 || true
  ;;
8)
  converge_baseline s3 r80
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  release r81 v2 backend=20 subgraph-a=20 subgraph-b=20 version:subgraph-a=v1 version:subgraph-b=v1 keep:r80
  wait_release_settled 600 || log "WARN: not settled"; wait_marker 60 acme r81 || true; wait_pods_ready 300 acme r81 || true
  ;;
9)
  # Coexistence / rollback pointer: after r91 is live, point acme back to r90
  # (stable) while the marker still lists both. r90 pods must pass the gate
  # immediately — before the layer re-runs r90's hooks.
  converge_baseline s3 r90
  truncate_ledgers
  start_sampler "$SAMPLES"; trap finish EXIT
  PHASES="$RUN_DIR/phases.tsv"; : > "$PHASES"
  release r91 v2 backend=30 subgraph-a=30 subgraph-b=30 keep:r90; printf 'r91_push\t%s\n' "$(date +%s)" >> "$PHASES"
  wait_release_settled 600; wait_marker 60 acme r91; wait_pods_ready 300 acme r91; printf 'r91_done\t%s\n' "$(date +%s)" >> "$PHASES"
  write_tenant_values acme r90 v1 backend=10 subgraph-a=10 subgraph-b=10 keep:r91
  RELEASE_SHA="$(commit_paths "$LEDGER" "s9: acme rollback pointer to r90 (stable)" gitops/values/_tenants/acme)"
  printf 'rollback_push\t%s\n' "$(date +%s)" >> "$PHASES"; log "rollback pushed ${RELEASE_SHA:0:7}"
  # shellcheck disable=SC2046
  hard_refresh $(tenant_apps acme)
  wait_release_settled 600 || log "WARN: not settled"; wait_pods_ready 300 acme r90 || true; printf 'rollback_done\t%s\n' "$(date +%s)" >> "$PHASES"
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
