#!/usr/bin/env bash
# Generators for the committed gitops/ profile and per-tenant release values.
# Sourced by seed and the scenario driver. Pure file writers; no git here.

# write_profile <s1|s2|s3>
#   appsets: harmony today (per-service AppSets, per-app migrations)
#   aoa:     the design (parent + PreSync hook Application)
write_profile() {
  local profile="$1" migrations
  local layout=appsets
  case "$profile" in
    # baseline: harmony today — per-service AppSets, each running its own migration
    appsets) migrations=true;  layout=appsets ;;
    # the design: one parent per tenant, migrations as its PreSync hook Application
    aoa)     migrations=false; layout=appofapps ;;
    *) echo "unknown profile '$profile'" >&2; return 1 ;;
  esac
  local root_values="$LAB_ROOT/gitops/root/values.yaml"
  sed -i '' -E "s/^layout: .*$/layout: ${layout}/" "$root_values"
  local svc db
  for svc in backend subgraph-a subgraph-b; do
    case "$svc" in subgraph-b) db=subgraph_b ;; *) db=main ;; esac
    cat > "$LAB_ROOT/gitops/values/_base/$svc.yaml" <<YAML
name: $svc
db:
  name: $db
migrations:
  enabled: $migrations
YAML
  done
}

# write_tenant_values <tenant> <releaseId> <version>
# Writes ONLY the per-service tenant files. There is deliberately no
# tenant-migrations file: the migration Application is rendered by the parent
# chart, which reads the image/version out of these same per-service files. [svc=sleepSeconds ...] [fail:svc ...] [version:svc=vX ...]
#   Regenerates the four gitops/values/_tenants/<tenant>/*.yaml files.
write_tenant_values() {
  local tenant="$1" release="$2" version="$3"; shift 3
  local -A sleep=( [backend]=2 [subgraph-a]=2 [subgraph-b]=2 )
  local -A fail=( [backend]=false [subgraph-a]=false [subgraph-b]=false )
  local -A ver=( [backend]="$version" [subgraph-a]="$version" [subgraph-b]="$version" )
  local -A replicas=()
  local keep=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      fail:*) fail[${arg#fail:}]=true ;;
      version:*) local kv="${arg#version:}"; ver[${kv%%=*}]="${kv#*=}" ;;
      replicas:*) local kv="${arg#replicas:}"; replicas[${kv%%=*}]="${kv#*=}" ;;
      keep:*) keep="${arg#keep:}" ;;
      *=*) sleep[${arg%%=*}]="${arg#*=}" ;;
      *) echo "write_tenant_values: unknown arg '$arg'" >&2; return 1 ;;
    esac
  done
  local dir="$LAB_ROOT/gitops/values/_tenants/$tenant"
  mkdir -p "$dir"
  local svc
  for svc in backend subgraph-a subgraph-b; do
    {
      echo "releaseId: $release"
      echo "version: ${ver[$svc]}"
      echo "migrations:"
      echo "  sleepSeconds: ${sleep[$svc]}"
      echo "  fail: ${fail[$svc]}"
      if [[ -n "${replicas[$svc]:-}" ]]; then
        echo "replicaCount: ${replicas[$svc]}"
      fi
    } > "$dir/$svc.yaml"
  done
}

