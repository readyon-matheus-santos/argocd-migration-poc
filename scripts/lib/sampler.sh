#!/usr/bin/env bash
# 2-second sampler. One line per tick per observed object into samples.tsv:
#   epoch<TAB>kind<TAB>tenant<TAB>name<TAB>f1<TAB>f2<TAB>f3<TAB>f4
# kinds:
#   pod   tenant svc      version release-id ready(True/False) init-state
#   job   tenant jobname  release-id active succeeded failed
#   app   tenant appname  sync health phase
sample_once() {
  local out="$1" epoch tenant
  epoch="$(date +%s)"
  for tenant in acme globex; do
    kubectl get pods -n "$tenant" -l 'job-role!=migration' -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/name}{"\t"}{.metadata.labels.version}{"\t"}{.metadata.labels.release-id}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\t"}{.status.initContainerStatuses[0].state}{"\n"}{end}' 2>/dev/null \
      | awk -v e="$epoch" -v t="$tenant" -F'\t' 'NF>=4 && $1!="postgres" && $1!="tenant-migrations" {st="-"; if (match($5,/"(waiting|running|terminated)"/)) st=substr($5,RSTART+1,RLENGTH-2); if (st=="waiting" && match($5,/"reason":"[A-Za-z]+"/)) st=st ":" substr($5,RSTART+10,RLENGTH-11); printf "%s\tpod\t%s\t%s\t%s\t%s\t%s\t%s\n", e, t, $1, $2, $3, $4, st}' >> "$out"
    kubectl get jobs -n "$tenant" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.release-id}{"\t"}{.status.active}{"\t"}{.status.succeeded}{"\t"}{.status.failed}{"\n"}{end}' 2>/dev/null \
      | awk -v e="$epoch" -v t="$tenant" -F'\t' 'NF>=1 && $1!="" {printf "%s\tjob\t%s\t%s\t%s\t%s\t%s\t%s\n", e, t, $1, $2, ($3==""?0:$3), ($4==""?0:$4), ($5==""?0:$5)}' >> "$out"
  done
  kubectl get applications.argoproj.io -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\t"}{.status.operationState.phase}{"\n"}{end}' 2>/dev/null \
    | awk -v e="$epoch" -F'\t' '$1!="root" {n=$1; t=n; sub(/.*-/,"",t); printf "%s\tapp\t%s\t%s\t%s\t%s\t%s\n", e, t, n, $2, $3, ($4==""?"-":$4)}' >> "$out"
}

start_sampler() { # start_sampler <samples.tsv>  -> sets SAMPLER_PID
  : > "$1"
  ( while true; do sample_once "$1"; sleep 2; done ) &
  SAMPLER_PID=$!
}
stop_sampler() { [[ -n "${SAMPLER_PID:-}" ]] && kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null || true; }
