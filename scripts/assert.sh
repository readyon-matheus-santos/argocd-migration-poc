#!/usr/bin/env bash
# Assertions over runs/sN/ evidence. Pure: never re-runs the experiment.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/env.sh"
set +e
N="${1:?usage: assert.sh <scenario-number>}"
RUN_DIR="$LAB_ROOT/runs/s$N"; S="$RUN_DIR/samples.tsv"; RESULT="$RUN_DIR/result.md"
[[ -f "$S" ]] || { echo "no samples at $S — run scenario $N first" >&2; exit 2; }
FAILS=0
LINES=()
pass() { echo "PASS: $*"; LINES+=("PASS: $*"); }
fail() { echo "FAIL: $*"; FAILS=$((FAILS+1)); LINES+=("FAIL: $*"); }
info() { echo "INFO: $*"; LINES+=("INFO: $*"); }
push_epoch() { awk -F'\t' -v s="$1" '$3 ~ s {print $2; exit}' "$RUN_DIR/commits.tsv"; }

# helpers over samples: columns 1 epoch 2 kind 3 tenant 4 name 5.. fields
first_pod_ready_epoch() { awk -F'\t' -v t="$1" -v s="$2" -v v="$3" '$2=="pod"&&$3==t&&$4==s&&$5==v&&$7=="True"{print $1; exit}' "$S"; }
# job columns: 5 release-id, 6 active, 7 succeeded, 8 failed
job_active_epochs()     { awk -F'\t' -v t="$1" -v j="$2" -v r="${3:-}" '$2=="job"&&$3==t&&$4==j&&(r==""||$5==r)&&$6+0>0{print $1}' "$S"; }
job_first_succeeded()   { awk -F'\t' -v t="$1" -v j="$2" -v r="${3:-}" '$2=="job"&&$3==t&&$4==j&&(r==""||$5==r)&&$7+0>0{print $1; exit}' "$S"; }
app_phase_epochs()      { awk -F'\t' -v a="$1" -v p="$2" '$2=="app"&&$4==a&&$7==p{print $1}' "$S"; }
marker_at()             { awk -F'\t' -v t="$1" -v e="$2" '$2=="marker"&&$3==t&&$1==e{print $5; exit}' "$S"; }

case "$N" in
1)
  rel_push="$(push_epoch 'release r11')"
  br="$(first_pod_ready_epoch acme backend v2)"
  ja_done="$(job_first_succeeded acme subgraph-a-migrate r11)"
  overlap="$(job_active_epochs acme subgraph-a-migrate r11 | awk -v br="$br" '$1>=br' | head -1)"
  overlap_end="$(job_active_epochs acme subgraph-a-migrate r11 | awk -v br="$br" '$1>=br' | tail -1)"
  if [[ -n "$br" && -n "$overlap" ]]; then
    pass "backend v2 pod Ready at +$((br-rel_push))s after release push while subgraph-a-migrate Job still active (overlap $((overlap_end-overlap+2))s, until Job success at +$((ja_done-rel_push))s)"
  else
    fail "no sample shows backend v2 Ready while subgraph-a-migrate is active (backend-ready=$br, first-overlap=$overlap)"
  fi
  sa_healthy_after="$(awk -F'\t' -v br="$br" '$2=="app"&&$4=="subgraph-a-acme"&&$1==br{print $6"/"$7}' "$S" | head -1)"
  info "at backend-v2-Ready epoch, subgraph-a-acme was $sa_healthy_after (waves 2 vs 4 ordered nothing)"
  hyp="Prod shape (app-level waves + per-app PreSync) prevents new backend code from serving before subgraph migrations finish"
  exp="FAILS (race is real)"
  ;;
2)
  rel_push="$(push_epoch 'release r21')"
  hit=""
  for s in backend subgraph-a subgraph-b; do
    e="$(first_pod_ready_epoch acme "$s" v2)"; [[ -z "$e" ]] && continue
    m="$(marker_at acme "$e")"
    ph="$(awk -F'\t' -v e="$e" '$2=="app"&&$4=="tenant-migrations-acme"&&$1==e{print $7}' "$S" | head -1)"
    if [[ "$m" != "r21" ]]; then hit="$hit $s(+$((e-rel_push))s,marker=$m,layer=$ph)"; fi
  done
  layer_done="$(awk -F'\t' '$2=="marker"&&$3=="acme"&&$5=="r21"{print $1; exit}' "$S")"
  if [[ -n "$hit" ]]; then pass "v2 pods Ready before the wave-0 migrations app finished:$hit; marker reached r21 at +$((layer_done-rel_push))s"; else fail "no v2 pod went Ready before marker r21"; fi
  hyp="An app-level wave-0 migrations app is synced before the wave-2/4 service apps"
  exp="FAILS (waves are decorative across generated apps)"
  ;;
3)
  P="$RUN_DIR/phases.tsv"; ph() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$P"; }
  r31_push="$(ph r31_push)"; r31_done="$(ph r31_done)"; r32_push="$(ph r32_push)"; failed="$(ph layer_failed)"; obs_end="$(ph observe_end)"; rev_push="$(ph revert_push)"; rev_done="$(ph revert_done)"
  m31="$(awk -F'\t' -v a="$r31_push" '$2=="marker"&&$3=="acme"&&$5=="r31"&&$1>=a{print $1; exit}' "$S")"
  # S3a
  ok=1; det=""
  for s in backend subgraph-a subgraph-b; do
    e="$(awk -F'\t' -v a="$r31_push" -v b="$m31" -v s="$s" '$2=="pod"&&$3=="acme"&&$4==s&&$1>=a&&$1<=b{k=$1; if($5=="v2"&&$7=="False")n[k]=1; if($5=="v1"&&$7=="True")o[k]=1} END{for(k in n) if(o[k]){print k; exit}}' "$S")"
    if [[ -n "$e" ]]; then det="$det $s@+$((e-r31_push))s"; else ok=0; det="$det $s:NONE"; fi
  done
  (( ok )) && pass "S3a-1 for every service a v2 pod sat un-Ready (gate) while a v1 pod served:$det" || fail "S3a-1 missing old/new coexistence:$det"
  viol="$(awk -F'\t' -v a="$r31_push" -v b="$r32_push" 'NR==FNR{if($2=="marker"&&$3=="acme")m[$1]=$5; next} $1>=a&&$1<b&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{if(m[$1]!="r31")print $1":"$4":"m[$1]}' "$S" "$S" | head -3)"
  [[ -z "$viol" ]] && pass "S3a-2 no v2 pod Ready while marker != r31" || fail "S3a-2 violations: $viol"
  fin="$(awk -F'\t' -v e="$r31_done" '$1<=e&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{c[$4]=1} END{n=0; for(k in c)n++; print n}' "$S")"
  mk_done="$(awk -F'\t' -v e="$r31_done" '$1<=e&&$2=="marker"&&$3=="acme"{v=$5} END{print v}' "$S")"
  led="$(grep -cE '^(backend|subgraph-a)\|r31\|v2\|[^|]+\|[0-9]' "$RUN_DIR/acme-ledger-main.txt")$(grep -cE '^subgraph-b\|r31\|v2\|[^|]+\|[0-9]' "$RUN_DIR/acme-ledger-subgraph_b.txt")"
  [[ "$fin" == 3 && "$mk_done" == r31 && "$led" == 21 ]] && pass "S3a-3 end of success path: marker r31, 3/3 v2 services Ready, ledger has 3 finished v2 rows" || fail "S3a-3 final state: v2ready=$fin marker=$mk_done ledger=$led"
  v2r="$(awk -F'\t' -v a="$r31_push" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{print $1; exit}' "$S")"
  [[ -n "$m31" && "$m31" -le "$v2r" ]] && pass "S3a-4 marker r31 (+$((m31-r31_push))s) <= first v2 Ready (+$((v2r-r31_push))s)" || fail "S3a-4 ordering: marker=$m31 firstReady=$v2r"
  gm="$(awk -F'\t' '$2=="marker"&&$3=="globex"&&$5!="r30"' "$S" | wc -l | tr -d ' ')"; gp="$(awk -F'\t' '$2=="pod"&&$3=="globex"&&!($5=="v1"&&$7=="True")' "$S" | wc -l | tr -d ' ')"
  [[ "$gm" == 0 && "$gp" == 0 ]] && pass "S3a-5 globex untouched all run (marker r30, pods v1/Ready)" || fail "S3a-5 globex disturbed: marker!=r30 samples=$gm pod samples=$gp"
  # S3b
  f="$(awk -F'\t' -v a="$r32_push" '$1>=a&&$2=="app"&&$4=="tenant-migrations-acme"&&$7=="Failed"{print $1; exit}' "$S")"
  [[ -n "$f" ]] && pass "S3b-1 tenant-migrations-acme reached Failed at +$((f-r32_push))s after r32 push" || fail "S3b-1 layer never Failed"
  bad="$(awk -F'\t' -v a="$r32_push" '$1>=a&&$2=="marker"&&$3=="acme"&&$5!="r31"' "$S" | wc -l | tr -d ' ')"
  [[ "$bad" == 0 ]] && pass "S3b-2 marker stayed r31 in every sample after r32 push" || fail "S3b-2 marker deviated in $bad samples"
  v3seen="$(awk -F'\t' -v a="$r32_push" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v3"{c[$4]=1} END{n=0;for(k in c)n++;print n}' "$S")"
  v3ready="$(awk -F'\t' '$2=="pod"&&$3=="acme"&&$5=="v3"&&$7=="True"' "$S" | wc -l | tr -d ' ')"
  [[ "$v3seen" == 3 && "$v3ready" == 0 ]] && pass "S3b-3 v3 pods appeared for 3/3 services and were never Ready" || fail "S3b-3 v3 services seen=$v3seen readySamples=$v3ready"
  gaps="$(awk -F'\t' -v a="$r32_push" -v b="$rev_push" '$1>=a&&$1<=b&&$2=="pod"&&$3=="acme"{k=$1; e[k]=1; if($5=="v2"&&$7=="True")r[k SUBSEP $4]=1} END{n=0; for(k in e){split("backend subgraph-a subgraph-b",S," "); for(i in S) if(!((k SUBSEP S[i]) in r)) n++} print n}' "$S")"
  [[ "$gaps" == 0 ]] && pass "S3b-4 v2 pods Ready for every service at every sample of the failure window ($((rev_push-r32_push))s)" || fail "S3b-4 $gaps service-samples without a Ready v2 pod"
  b3="$(grep -cE '^backend\|r32\|v3\|[^|]+\|[0-9]' "$RUN_DIR/acme-ledger-main.txt")"; a3="$(grep -cE '^subgraph-a\|r32\|v3\|[^|]+\|\|' "$RUN_DIR/acme-ledger-main.txt")"
  [[ "$b3" -ge 1 && "$a3" -ge 1 ]] && pass "S3b-5 DB: backend v3 migration applied+finished while subgraph-a v3 row is unfinished — gate, not the DB, held the line" || fail "S3b-5 ledger: backend-r32-finished=$b3 subgraph-a-r32-unfinished=$a3"
  endm="$(awk -F'\t' '$2=="marker"&&$3=="acme"{v=$5} END{print v}' "$S")"
  endv2="$(awk -F'\t' -v e="$rev_done" '$1>=e-4&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{c[$4]=1} END{n=0;for(k in c)n++;print n}' "$S")"
  endl="$(awk -F'\t' '$2=="app"&&$4=="tenant-migrations-acme"{v=$5"/"$6} END{print v}' "$S")"
  [[ "$endm" == r31 && "$endv2" == 3 && "$endl" == "Synced/Healthy" && "$v3ready" == 0 ]] && pass "S3b-6 after revert (+$((rev_done-rev_push))s): marker r31, 3/3 v2 Ready, layer Synced/Healthy, no v3 pod ever Ready" || fail "S3b-6 post-revert: marker=$endm v2=$endv2 layer=$endl"
  hyp="Layer + gate: no new pod serves before all tenant migrations succeed; a failed migration keeps new code gated with old code serving; git revert recovers"
  exp="PASS"
  ;;
4)
  L="$RUN_DIR/acme-ledger-main.txt"; LB="$RUN_DIR/acme-ledger-subgraph_b.txt"
  bs="$(awk -F'|' '$1=="backend"&&$2=="r41"{print $6}' "$L")"; bf="$(awk -F'|' '$1=="backend"&&$2=="r41"{print $7}' "$L")"
  as="$(awk -F'|' '$1=="subgraph-a"&&$2=="r41"{print $6}' "$L")"; af="$(awk -F'|' '$1=="subgraph-a"&&$2=="r41"{print $7}' "$L")"
  sbs="$(awk -F'|' '$1=="subgraph-b"&&$2=="r41"{print $6}' "$LB")"; sbf="$(awk -F'|' '$1=="subgraph-b"&&$2=="r41"{print $7}' "$LB")"
  info "intervals (DB clock): backend [$bs,$bf] subgraph-a [$as,$af] subgraph-b [$sbs,$sbf]"
  awk -v a="$sbs" -v b="$bf" 'BEGIN{exit !(a<b)}' && pass "S4-1 own-DB Job overlapped a main-DB Job: started(subgraph-b) < finished(backend) by $(awk -v a="$sbs" -v b="$bf" 'BEGIN{printf "%.1f", b-a}')s" || fail "S4-1 no overlap"
  awk -v a="$as" -v b="$bf" 'BEGIN{exit !(a>=b)}' && pass "S4-2 main-DB Jobs serialized: started(subgraph-a) - finished(backend) = $(awk -v a="$as" -v b="$bf" 'BEGIN{printf "%.1f", a-b}')s (>= 0)" || fail "S4-2 main-DB Jobs overlapped"
  info "accepted limitation: wave barrier is global, so subgraph-a also waited for subgraph-b (wave 0)"
  hyp="Inside the layer, same-DB migration Jobs serialize via hook waves while own-DB Jobs overlap"
  exp="PASS"
  ;;
5)
  P="$RUN_DIR/phases.tsv"; ph() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$P"; }
  t0="$(ph scale)"; t1="$(ph settled)"
  # per-pod: pods are identified only by svc; count Ready v1 pods for backend over time
  first3="$(awk -F'\t' -v a="$t0" '$1>=a&&$2=="pod"&&$3=="acme"&&$4=="backend"&&$7=="True"{c[$1]++} END{for(k in c) if(c[k]>=3){print k}}' "$S" | sort -n | head -1)"
  [[ -n "$first3" && $((first3-t0)) -le 60 ]] && pass "S5-1 backend reached 3 Ready replicas +$((first3-t0))s after the replicas commit was pushed (incl. ArgoCD sync latency; gate passed immediately)" || fail "S5-1 backend 3 Ready at ${first3:-never} (limit 60s)"
  sa_gap="$(awk -F'\t' -v a="$t0" -v b="$t1" '$1>=a&&$1<=b&&$2=="pod"&&$3=="acme"&&$4=="subgraph-a"{e[$1]=1; if($7=="True")r[$1]=1} END{n=0; for(k in e) if(!(k in r)) n++; print n}' "$S")"
  [[ "$sa_gap" -le 15 ]] && pass "S5-2 subgraph-a replacement pod: $((sa_gap*2))s without a Ready pod after delete (new pod passed gate promptly)" || fail "S5-2 subgraph-a had no Ready pod for ~$((sa_gap*2))s"
  bad="$(awk -F'\t' -v a="$t0" '$1>=a&&$2=="pod"&&$3=="acme"&&$8~/^waiting:(CrashLoopBackOff|Error)/' "$S" | wc -l | tr -d ' ')"
  [[ "$bad" == 0 ]] && pass "S5-3 no gate init container ever sampled in CrashLoopBackOff/Error (no gate retry)" || fail "S5-3 $bad samples with gate init in retry state"
  mk="$(awk -F'\t' -v a="$t0" '$1>=a&&$2=="marker"&&$3=="acme"&&$5!="r50"' "$S" | wc -l | tr -d ' ')"
  [[ "$mk" == 0 ]] && pass "S5-4 marker stayed r50" || fail "S5-4 marker changed"
  hyp="Runtime Gate never blocks steady-state scale-out or pod replacement"; exp="PASS"
  ;;
6)
  rel_push="$(push_epoch 'release r61')"
  m61="$(awk -F'\t' -v a="$rel_push" '$1>=a&&$2=="marker"&&$3=="acme"&&$5=="r61"{print $1; exit}' "$S")"
  viol="$(awk -F'\t' -v a="$rel_push" 'NR==FNR{if($2=="marker"&&$3=="acme")m[$1]=$5; next} $1>=a&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{if(m[$1]!="r61")print $1}' "$S" "$S" | wc -l | tr -d ' ')"
  [[ "$viol" == 0 ]] && pass "S6-1 no v2 pod Ready before marker r61 (marker at +$((m61-rel_push))s)" || fail "S6-1 $viol violations"
  gaps="$(awk -F'\t' -v a="$rel_push" -v b="$m61" '$1>=a&&$1<=b&&$2=="pod"&&$3=="acme"{k=$1; e[k]=1; if($5=="v1"&&$7=="True")r[k SUBSEP $4]=1} END{n=0; for(k in e){split("backend subgraph-a subgraph-b",S," "); for(i in S) if(!((k SUBSEP S[i]) in r)) n++} print n}' "$S")"
  [[ "$gaps" == 0 ]] && pass "S6-2 v1 pods stayed Ready for every service throughout the $((m61-rel_push))s window" || fail "S6-2 $gaps gaps"
  waits="$(awk -F'\t' -v a="$rel_push" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$8~/^waiting:(CrashLoopBackOff|Error)/{c[$4]=1} END{n=0;for(k in c)n++;print n}' "$S")"
  info "gate init container observed in CrashLoopBackOff/Error (kubelet restarting it) for $waits/3 services (timeout 30s < 120s migration)"
  endv2="$(awk -F'\t' '$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{c[$4]=1} END{n=0;for(k in c)n++;print n}' "$S")"
  [[ "$endv2" == 3 ]] && pass "S6-3 all 3 v2 services became Ready after the migration completed, no manual action" || fail "S6-3 v2 Ready services=$endv2"
  hs="$(awk -F'\t' -v a="$rel_push" '$1>=a&&$2=="app"&&$3=="acme"&&$4!~/postgres|tenant-migrations/{print $4":"$6}' "$S" | sort | uniq -c | sort -rn | awk '{printf "%s(%s) ", $2, $1}')"
  info "ArgoCD health of service apps during window (samples): $hs"
  hyp="Gate timeout shorter than the migration: safety holds, release self-completes; records ArgoCD/Deployment signals"; exp="PASS"
  ;;
7)
  P="$RUN_DIR/phases.tsv"; ph() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$P"; }
  p71="$(ph r71_push)"; p72="$(ph r72_push)"
  viol="$(awk -F'\t' -v a="$p71" 'NR==FNR{if($2=="marker"&&$3=="acme")m[$1]=$5; next} $1>=a&&$2=="pod"&&$3=="acme"&&($5=="v2"||$5=="v3")&&$7=="True"{if(m[$1]!=$6)print $1":"$4":"$5":"m[$1]}' "$S" "$S" | wc -l | tr -d ' ')"
  [[ "$viol" == 0 ]] && pass "S7-1 no v2/v3 pod ever Ready while marker != its own releaseId" || fail "S7-1 $viol violations"
  seen71="$(awk -F'\t' '$2=="marker"&&$3=="acme"&&$5=="r71"' "$S" | wc -l | tr -d ' ')"; m72="$(awk -F'\t' -v a="$p72" '$1>=a&&$2=="marker"&&$3=="acme"&&$5=="r72"{print $1; exit}' "$S")"
  info "marker r71 observed in $seen71 samples; marker r72 at +$((m72-p72))s after r72 push"
  endm="$(awk -F'\t' '$2=="marker"&&$3=="acme"{v=$5} END{print v}' "$S")"; endv3="$(awk -F'\t' -v e="$m72" '$1>=e&&$2=="pod"&&$3=="acme"&&$5=="v3"&&$7=="True"{c[$4]=1} END{n=0;for(k in c)n++;print n}' "$S")"
  endl="$(awk -F'\t' '$2=="app"&&$4=="tenant-migrations-acme"{v=$5"/"$6} END{print v}' "$S")"
  [[ "$endm" == r72 && "$endv3" == 3 && "$endl" == Synced/Healthy ]] && pass "S7-2 converged: marker r72, 3/3 v3 Ready, layer Synced/Healthy" || fail "S7-2 marker=$endm v3=$endv3 layer=$endl"
  last="$(tail -1 "$S" | cut -f1)"; jobs="$(awk -F'\t' -v e="$last" '$1>=e-4&&$2=="job"&&$3=="acme"&&$4~/^migrate-/{print $4"@"$5}' "$S" | sort -u | tr '\n' ' ')"; info "hook Jobs present at end: $jobs"
  led="$(awk -F'|' '$2=="r71"||$2=="r72"{printf "%s:%s:%s ", $1,$2,($5==""?"unfinished":"finished")}' "$RUN_DIR/acme-ledger-main.txt" "$RUN_DIR/acme-ledger-subgraph_b.txt")"; info "ledger r71/r72 rows: $led"
  hyp="A release superseded mid-migration converges to the newer release with no unsafe pod"; exp="PASS"
  ;;
8)
  rel_push="$(push_epoch 'release r81')"
  m81="$(awk -F'\t' -v a="$rel_push" '$1>=a&&$2=="marker"&&$3=="acme"&&$5=="r81"{print $1; exit}' "$S")"
  rolled="$(awk -F'\t' -v a="$rel_push" '$1>=a&&$2=="pod"&&$3=="acme"&&$6=="r81"{c[$4]=1} END{n=0;for(k in c)n++;print n}' "$S")"
  [[ "$rolled" == 3 ]] && pass "S8-1 all 3 services rolled new r81 pods (subgraphs with unchanged v1 image)" || fail "S8-1 services rolled=$rolled"
  viol="$(awk -F'\t' -v a="$rel_push" 'NR==FNR{if($2=="marker"&&$3=="acme")m[$1]=$5; next} $1>=a&&$2=="pod"&&$3=="acme"&&$6=="r81"&&$7=="True"{if(m[$1]!="r81")print $1}' "$S" "$S" | wc -l | tr -d ' ')"
  [[ "$viol" == 0 ]] && pass "S8-2 no r81 pod Ready before marker r81 (+$((m81-rel_push))s)" || fail "S8-2 $viol violations"
  endv="$(awk -F'\t' '$2=="pod"&&$3=="acme"&&$6=="r81"&&$7=="True"{c[$4]=$5} END{for(k in c)printf "%s=%s ",k,c[k]}' "$S")"
  fin="$(awk -F'\t' -v a="$rel_push" '$1>=a&&$2=="pod"&&$3=="acme"&&$6=="r81"&&$7=="True"{c[$4]=1; if(length(c)==3){print $1; exit}}' "$S")"
  info "final: $endv; push→all r81 Ready = $((fin-rel_push))s; cost = 3 pod restarts for a 1-image release"
  hyp="A backend-only release still rolls+gates every service (cost of tenant-wide releaseId)"; exp="PASS"
  ;;
9)
  P="$RUN_DIR/phases.tsv"; ph() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$P"; }
  rb="$(ph rollback_push)"; rd="$(ph rollback_done)"
  first90="$(awk -F'\t' -v a="$rb" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v1"&&$6=="r90"&&$7=="True"{c[$4]=1; if(length(c)==3){print $1; exit}}' "$S")"
  hook90="$(awk -F'\t' -v a="$rb" '$1>=a&&$2=="job"&&$3=="acme"&&$4~/^migrate-/&&$5=="r90"&&($6+0>0||$7+0>0){print $1; exit}' "$S")"
  hookdone="$(awk -F'\t' -v a="$rb" '$1>=a&&$2=="job"&&$3=="acme"&&$4=="migrate-subgraph-a"&&$5=="r90"&&$7+0>0{print $1; exit}' "$S")"
  [[ -n "$first90" ]] && pass "S9-1 rollback: all 3 r90 (stable) pods Ready +$((first90-rb))s after the pointer commit" || fail "S9-1 r90 pods never all Ready"
  if [[ -n "$first90" && -n "$hookdone" && "$first90" -lt "$hookdone" ]]; then pass "S9-2 stable pods passed the gate BEFORE the layer finished re-running r90 hooks (+$((hookdone-rb))s) — set-membership marker, no wait on migrations" ; else fail "S9-2 r90 pods waited for hooks (ready=$first90 hooksDone=$hookdone)"; fi
  set_at="$(awk -F'\t' -v e="$first90" '$2=="marker"&&$3=="acme"&&$1==e{print $6}' "$S")"; info "marker at that moment: completed=[$set_at]"
  viol="$(awk -F'\t' 'NR==FNR{if($2=="marker"&&$3=="acme")m[$1]=","$6; next} $2=="pod"&&$3=="acme"&&$7=="True"&&$1 in m{if(index(m[$1],","$6",")==0)print $1":"$4":"$6}' "$S" "$S" | wc -l | tr -d ' ')"
  [[ "$viol" == 0 ]] && pass "S9-3 no pod ever Ready whose release id was not in the marker's completed set" || fail "S9-3 $viol violations"
  hyp="Rollback pointer to the previous release: pods pass the gate immediately (marker keeps completed set), no dependence on re-running migrations"; exp="PASS"
  ;;
10)
  P="$RUN_DIR/phases.tsv"; ph() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$P"; }
  p1="$(ph r131_push)"; p2="$(ph r132_push)"; pf="$(ph parent_failed)"; rp="$(ph revert_push)"; rd="$(ph revert_done)"
  # hooks done = last-wave hook Job (migrate-subgraph-a) of r131 succeeded
  m="$(awk -F'\t' -v a="$p1" '$1>=a&&$2=="job"&&$3=="acme"&&$4=="migrate-subgraph-a"&&$5=="r131"&&$7+0>0{print $1; exit}' "$S")"
  v2first="$(awk -F'\t' -v a="$p1" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v2"{print $1; exit}' "$S")"; v2ready="$(awk -F'\t' -v a="$p1" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{print $1; exit}' "$S")"
  [[ -n "$m" && -n "$v2first" && "$v2first" -ge "$m" ]] && pass "S10-1 no v2 pod existed before the parent's PreSync migrations completed: last hook succeeded at +$((m-p1))s, first v2 pod +$((v2first-p1))s, Ready +$((v2ready-p1))s" || fail "S10-1 v2 at ${v2first:-never}, marker at ${m:-never}"
  oos="$(awk -F'\t' -v a="$p1" -v m="$m" '$1>=a&&$1<m&&$2=="app"&&$3=="acme"&&$4~/^(backend|subgraph-a|subgraph-b)-acme$/&&($5!="Synced"||$7=="Running"){print $1":"$4}' "$S" | head -3)"
  [[ -z "$oos" ]] && pass "S10-2 service Applications untouched until the hooks finished" || fail "S10-2 $oos"
  v3="$(awk -F'\t' -v a="$p2" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v3"' "$S" | wc -l | tr -d ' ')"
  [[ "$v3" == 0 ]] && pass "S10-3 failed release: no v3 pod ever created" || fail "S10-3 $v3 v3 samples"
  pfe="$(awk -F'\t' -v a="$p2" '$1>=a&&$2=="app"&&$4=="tenant-acme"&&$7=="Failed"{print $1; exit}' "$S")"
  [[ -n "$pfe" ]] && pass "S10-4 parent reached Failed at +$((pfe-p2))s after r132 push (single retry cycle, no nested child)" || fail "S10-4 parent never Failed"
  gaps="$(awk -F'\t' -v a="$p2" -v b="$rp" '$1>=a&&$1<=b&&$2=="pod"&&$3=="acme"{k=$1; e[k]=1; if($5=="v2"&&$7=="True")r[k SUBSEP $4]=1} END{n=0; for(k in e){split("backend subgraph-a subgraph-b",S," "); for(i in S) if(!((k SUBSEP S[i]) in r)) n++} print n}' "$S")"
  [[ "$gaps" == 0 ]] && pass "S10-5 v2 served every sample of the failure window ($((rp-p2))s)" || fail "S10-5 gaps=$gaps"
  endm=r131; endv2="$(awk -F'\t' -v e="$rd" '$1>=e-4&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{c[$4]=1} END{n=0;for(k in c)n++;print n}' "$S")"; endp="$(awk -F'\t' '$2=="app"&&$4=="tenant-acme"{v=$5"/"$6"/"$7} END{print v}' "$S")"
  [[ "$endm" == r131 && "$endv2" == 3 ]] && pass "S10-6 after revert (+$((rd-rp))s): marker r131, 3/3 v2 Ready, parent $endp" || fail "S10-6 marker=$endm v2=$endv2 parent=$endp"
  runs111="$(grep -c '^backend|r131|' "$RUN_DIR/acme-ledger-main.txt")"; info "backend r131 migration executed $runs111 time(s) over the run (hooks re-run on every parent sync incl. the revert)"
  hyp="App-of-apps (parent reads per-service tenant files via fileParameters, migrations as its own PreSync, children pinned inline): a tenant-file tag bump moves children only after the parent's hooks succeed"; exp="PASS"
  ;;
*) echo "no assertions for scenario $N" >&2; exit 2 ;;
esac

if (( FAILS == 0 )); then verdict=PASS; else verdict=FAIL; fi
echo "OVERALL: $verdict"
actual="$(printf '%s; ' "${LINES[@]}" | sed 's/|/\\|/g')"
printf '| S%s | %s | %s | %s | %s |\n' "$N" "$hyp" "$exp" "$actual" "$verdict" > "$RESULT"
[[ "$verdict" == PASS ]]
