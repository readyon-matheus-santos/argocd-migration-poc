#!/usr/bin/env bash
# Generators for the committed gitops/ profile and per-tenant release values.
# Sourced by seed and the scenario driver. Pure file writers; no git here.

# write_profile <s1|s2|s3>
#   s1: per-app migrations on, layer off, gate off  (prod baseline shape)
#   s2: layer on, per-app migrations off, gate off  (waves-only)
#   s3: layer on, per-app migrations off, gate on   (layer + gate comparison)
#   aoa: app-of-apps with the migrations as the parent's own PreSync (the design)
write_profile() {
  local profile="$1" layer migrations gate
  local layout=appsets
  case "$profile" in
    s1) layer=false; migrations=true;  gate=false ;;
    s2) layer=true;  migrations=false; gate=false ;;
    s3) layer=true;  migrations=false; gate=true ;;
    aoa) layer=false; migrations=false; gate=false; layout=appofapps ;;
    *) echo "unknown profile '$profile'" >&2; return 1 ;;
  esac
  local root_values="$LAB_ROOT/gitops/root/values.yaml"
  sed -i '' -E "s/^(  enabled: )(true|false)$/\1${layer}/" "$root_values"
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
gate:
  enabled: $gate
YAML
  done
}

# write_tenant_values <tenant> <releaseId> <version> [svc=sleepSeconds ...] [fail:svc ...] [gateTimeout:N] [progressDeadline:N] [version:svc=vX ...]
#   Regenerates the four gitops/values/_tenants/<tenant>/*.yaml files.
write_tenant_values() {
  local tenant="$1" release="$2" version="$3"; shift 3
  local -A sleep=( [backend]=2 [subgraph-a]=2 [subgraph-b]=2 )
  local -A fail=( [backend]=false [subgraph-a]=false [subgraph-b]=false )
  local -A ver=( [backend]="$version" [subgraph-a]="$version" [subgraph-b]="$version" )
  local gate_timeout="" progress_deadline=""
  local -A replicas=()
  local keep=""
  local arg
  for arg in "$@"; do
    case "$arg" in
      fail:*) fail[${arg#fail:}]=true ;;
      gateTimeout:*) gate_timeout="${arg#gateTimeout:}" ;;
      progressDeadline:*) progress_deadline="${arg#progressDeadline:}" ;;
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
      if [[ -n "$gate_timeout" ]]; then
        echo "gate:"
        echo "  timeoutSeconds: $gate_timeout"
      fi
      if [[ -n "$progress_deadline" ]]; then
        echo "progressDeadlineSeconds: $progress_deadline"
      fi
    } > "$dir/$svc.yaml"
  done
  {
    echo "releaseId: $release"
    if [[ -n "$keep" ]]; then
      echo "previousReleaseIds: [${keep}]"
    else
      echo "previousReleaseIds: []"
    fi
    echo "services:"
    for svc in backend subgraph-a subgraph-b; do
      case "$svc" in subgraph-b) db=subgraph_b ;; *) db=main ;; esac
      echo "  - name: $svc"
      echo "    db: $db"
      echo "    version: ${ver[$svc]}"
      echo "    sleepSeconds: ${sleep[$svc]}"
      echo "    fail: ${fail[$svc]}"
    done
  } > "$dir/tenant-migrations.yaml"
}

