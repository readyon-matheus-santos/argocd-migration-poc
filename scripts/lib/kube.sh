#!/usr/bin/env bash
# kubectl helpers. Every call goes through the lab kubeconfig exported by
# scripts/lib/env.sh (KUBECONFIG=.cache/kubeconfig).

k() { kubectl --request-timeout=20s "$@"; }

# Tenant objects (pods, Jobs, postgres) live on the WORKLOAD cluster when it
# exists (make workload-cluster); Applications always live on the control cluster.
WORKLOAD_KUBECONFIG="${WORKLOAD_KUBECONFIG:-$LAB_ROOT/.cache/kubeconfig-workload}"
wk() {
  if [[ -f "$WORKLOAD_KUBECONFIG" ]]; then kubectl --kubeconfig "$WORKLOAD_KUBECONFIG" --request-timeout=20s "$@"
  else k "$@"; fi
}

hard_refresh() { # hard_refresh <app>...
  local app
  for app in "$@"; do
    k annotate application.argoproj.io "$app" -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  done
}

all_apps() { k get applications.argoproj.io -n argocd -o name | sed 's#.*/##'; }
tenant_apps() { all_apps | grep -- "-$1\$" || true; }

app_state() { # prints "sync health phase"
  k get application.argoproj.io "$1" -n argocd \
    -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}' 2>/dev/null
}

wait_apps_synced_healthy() { # wait_apps_synced_healthy <timeout> <app>...
  local timeout="$1"; shift
  local elapsed=0 pending app st
  while (( elapsed < timeout )); do
    pending=()
    for app in "$@"; do
      st="$(app_state "$app")"
      [[ "$st" == Synced\ Healthy* ]] || pending+=("$app:${st:-absent}")
    done
    if (( ${#pending[@]} == 0 )); then return 0; fi
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "timeout after ${timeout}s waiting for: ${pending[*]}" >&2
  return 1
}

wait_apps_exist() { # wait_apps_exist <timeout> <app>...
  local timeout="$1"; shift
  local elapsed=0 app missing
  while (( elapsed < timeout )); do
    missing=()
    for app in "$@"; do
      k get application.argoproj.io "$app" -n argocd >/dev/null 2>&1 || missing+=("$app")
    done
    (( ${#missing[@]} == 0 )) && return 0
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "timeout after ${timeout}s; missing apps: ${missing[*]}" >&2
  return 1
}



psql_tenant() { # psql_tenant <tenant> <db> <sql>
  wk exec -n "$1" deploy/postgres -- psql -U poc -d "$2" -At -c "$3"
}

wait_apps_absent() { # wait_apps_absent <timeout> <app>...
  local timeout="$1"; shift
  local elapsed=0 app present
  while (( elapsed < timeout )); do
    present=()
    for app in "$@"; do
      k get application.argoproj.io "$app" -n argocd >/dev/null 2>&1 && present+=("$app")
    done
    (( ${#present[@]} == 0 )) && return 0
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "timeout after ${timeout}s; still present: ${present[*]}" >&2
  return 1
}

app_revision() { k get application.argoproj.io "$1" -n argocd -o jsonpath='{.status.sync.revisions[0]}' 2>/dev/null; }

wait_apps_at_revision() { # wait_apps_at_revision <timeout> <sha> <app>...
  local timeout="$1" sha="$2"; shift 2
  local elapsed=0 app pending st
  while (( elapsed < timeout )); do
    pending=()
    for app in "$@"; do
      st="$(app_state "$app")"
      [[ "$(app_revision "$app")" == "$sha" && "$st" == Synced\ Healthy* ]] || pending+=("$app:${st:-absent}")
    done
    (( ${#pending[@]} == 0 )) && return 0
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "timeout after ${timeout}s waiting for revision ${sha:0:7}: ${pending[*]}" >&2
  return 1
}

truncate_ledgers() { # both tenants, both dbs
  local t db
  for t in acme globex; do
    for db in main subgraph_b; do
      psql_tenant "$t" "$db" "DO \$\$ DECLARE r record; BEGIN FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' AND (tablename LIKE 'schema_version_%' OR tablename='migration_log') LOOP EXECUTE 'TRUNCATE ' || quote_ident(r.tablename); END LOOP; END \$\$;" >/dev/null
    done
  done
}

dump_forensics() { # dump_forensics <dir>
  local d="$1"; mkdir -p "$d"
  k get applications.argoproj.io -n argocd -o yaml > "$d/applications.yaml" 2>/dev/null
  local t
  for t in acme globex; do
    wk get pods,jobs -n "$t" -o wide > "$d/$t-objects.txt" 2>&1 || true
    wk describe jobs -n "$t" > "$d/$t-jobs-describe.txt" 2>&1 || true
    wk describe pods -n "$t" > "$d/$t-pods-describe.txt" 2>&1 || true
    psql_tenant "$t" main "SELECT svc,release_id,version,started_at,finished_at,extract(epoch from started_at) AS s,extract(epoch from finished_at) AS f FROM migration_log ORDER BY started_at" > "$d/$t-ledger-main.txt" 2>&1 || true
    psql_tenant "$t" subgraph_b "SELECT svc,release_id,version,started_at,finished_at,extract(epoch from started_at) AS s,extract(epoch from finished_at) AS f FROM migration_log ORDER BY started_at" > "$d/$t-ledger-subgraph_b.txt" 2>&1 || true
  done
}

wait_pods_ready() { # wait_pods_ready <timeout> <tenant> <releaseId>  (all backend/subgraph pods carry releaseId and are Ready; no other release pods remain)
  local timeout="$1" t="$2" rel="$3" elapsed=0 bad
  while (( elapsed < timeout )); do
    bad="$(wk get pods -n "$t" -l 'app.kubernetes.io/name in (backend,subgraph-a,subgraph-b),job-role!=migration' -o jsonpath='{range .items[*]}{.metadata.labels.release-id}{"/"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -v "^$rel/True$" | grep -v '^$' || true)"
    [[ -z "$bad" ]] && return 0
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "timeout: pods in $t not all $rel/Ready: $bad" >&2
  return 1
}


