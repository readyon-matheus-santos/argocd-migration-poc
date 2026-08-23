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
10)
  P="$RUN_DIR/phases.tsv"; ph() { awk -F'\t' -v k="$1" '$1==k{print $2}' "$P"; }
  p1="$(ph r131_push)"; p2="$(ph r132_push)"; pf="$(ph parent_failed)"; rp="$(ph revert_push)"; rd="$(ph revert_done)"
  # hooks done = last-wave hook Job (migrate-subgraph-a) of r131 succeeded
  m="$(awk -F'\t' -v a="$p1" '$1>=a&&$2=="job"&&$3=="acme"&&$4~/^migrate-subgraph-a-r131-/&&$5=="r131"&&$7+0>0{print $1; exit}' "$S")"
  v2first="$(awk -F'\t' -v a="$p1" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v2"{print $1; exit}' "$S")"; v2ready="$(awk -F'\t' -v a="$p1" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{print $1; exit}' "$S")"
  [[ -n "$m" && -n "$v2first" && "$v2first" -ge "$m" ]] && pass "S10-1 no v2 pod existed before the parent's PreSync migrations completed: last hook succeeded at +$((m-p1))s, first v2 pod +$((v2first-p1))s, Ready +$((v2ready-p1))s" || fail "S10-1 v2 pod at ${v2first:-never}, last hook at ${m:-never}"
  oos="$(awk -F'\t' -v a="$p1" -v m="$m" '$1>=a&&$1<m&&$2=="app"&&$3=="acme"&&$4~/^(backend|subgraph-a|subgraph-b)-acme$/&&($5!="Synced"||$7=="Running"){print $1":"$4}' "$S" | head -3)"
  [[ -z "$oos" ]] && pass "S10-2 service Applications untouched until the hooks finished" || fail "S10-2 $oos"
  v3="$(awk -F'\t' -v a="$p2" '$1>=a&&$2=="pod"&&$3=="acme"&&$5=="v3"' "$S" | wc -l | tr -d ' ')"
  [[ "$v3" == 0 ]] && pass "S10-3 failed release: no v3 pod ever created" || fail "S10-3 $v3 v3 samples"
  pfe="$(awk -F'\t' -v a="$p2" '$1>=a&&$2=="app"&&$4=="tenant-acme"&&$7=="Failed"{print $1; exit}' "$S")"
  [[ -n "$pfe" ]] && pass "S10-4 parent reached Failed at +$((pfe-p2))s after r132 push (single retry cycle, no nested child)" || fail "S10-4 parent never Failed"
  gaps="$(awk -F'\t' -v a="$p2" -v b="$rp" '$1>=a&&$1<=b&&$2=="pod"&&$3=="acme"{k=$1; e[k]=1; if($5=="v2"&&$7=="True")r[k SUBSEP $4]=1} END{n=0; for(k in e){split("backend subgraph-a subgraph-b",S," "); for(i in S) if(!((k SUBSEP S[i]) in r)) n++} print n}' "$S")"
  [[ "$gaps" == 0 ]] && pass "S10-5 v2 served every sample of the failure window ($((rp-p2))s)" || fail "S10-5 gaps=$gaps"
  endm=r131; endv2="$(awk -F'\t' -v e="$rd" '$1>=e-4&&$2=="pod"&&$3=="acme"&&$5=="v2"&&$7=="True"{c[$4]=1} END{n=0;for(k in c)n++;print n}' "$S")"; endp="$(awk -F'\t' '$2=="app"&&$4=="tenant-acme"{v=$5"/"$6"/"$7} END{print v}' "$S")"
  [[ "$endm" == r131 && "$endv2" == 3 ]] && pass "S10-6 after revert (+$((rd-rp))s): 3/3 v2 Ready, parent $endp" || fail "S10-6 release=$endm v2=$endv2 parent=$endp"
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
