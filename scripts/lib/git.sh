#!/usr/bin/env bash
# git helpers for the lab repo: exact-path staging, fast-forward-only pushes,
# and a commits ledger. Never -a/-A, never --force.

require_clean_gitops() {
  if [[ -n "$(git -C "$LAB_ROOT" status --porcelain -- gitops/)" ]]; then
    echo "gitops/ has uncommitted changes; commit or stash them first (they would be swept into a release commit)." >&2
    return 1
  fi
}

require_not_behind() {
  git -C "$LAB_ROOT" fetch -q origin "$GIT_BRANCH"
  local behind
  behind="$(git -C "$LAB_ROOT" rev-list --count "HEAD..origin/$GIT_BRANCH")"
  if [[ "$behind" != "0" ]]; then
    echo "local $GIT_BRANCH is $behind commit(s) behind origin/$GIT_BRANCH; run: git pull --ff-only" >&2
    return 1
  fi
}

# commit_paths <ledger-file-or-empty> <subject> <path>...  -> prints SHA (or nothing if no change)
commit_paths() {
  local ledger="$1" subject="$2"; shift 2
  git -C "$LAB_ROOT" add -- "$@"
  if git -C "$LAB_ROOT" diff --cached --quiet -- "$@"; then
    return 0
  fi
  git -C "$LAB_ROOT" commit -q -m "$subject" -- "$@"
  local sha epoch
  sha="$(git -C "$LAB_ROOT" rev-parse HEAD)"
  git -C "$LAB_ROOT" push -q origin "HEAD:$GIT_BRANCH"
  epoch="$(date +%s)"
  [[ -n "$ledger" ]] && printf '%s\t%s\t%s\n' "$sha" "$epoch" "$subject" >> "$ledger"
  echo "$sha"
}
