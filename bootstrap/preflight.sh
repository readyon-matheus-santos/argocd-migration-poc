#!/usr/bin/env bash
# Preflight for this lab. Runs at the top of `make bootstrap`, `make seed`,
# and every `make scenario-N`. Never mutates anything; every failure prints
# one actionable message and preflight keeps checking the rest before exiting
# non-zero, so one run surfaces every problem instead of one at a time.
#
# Usage: preflight.sh [--skip-colima]
#   --skip-colima  skip the Docker-engine checks (targets that don't touch the
#                  cluster).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../scripts/lib/env.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/versions.env"

# env.sh sets -e for scripts that should abort on the first error; this
# script's whole point is to keep checking after a failure, so relax that
# back to just -u/pipefail now that sourcing is done.
set +e

SKIP_COLIMA=0
[[ "${1:-}" == "--skip-colima" ]] && SKIP_COLIMA=1

FAILED=0
fail() {
  echo "PREFLIGHT FAIL: $1" >&2
  FAILED=1
}
ok() {
  echo "PREFLIGHT OK:   $1"
}

# ---- bash ----
if [[ -z "${BASH_VERSION:-}" ]]; then
  fail "not running under bash. Re-run via: bash bootstrap/preflight.sh"
else
  ok "bash $BASH_VERSION"
fi

# ---- required tools present + versions ----
require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    fail "'$tool' is not on PATH. Install it before continuing."
    return 1
  fi
  return 0
}

for t in kind kubectl helm git gh bash; do
  require_tool "$t" || true
done

if command -v kind >/dev/null 2>&1; then ok "kind: $(kind version 2>/dev/null | head -1)"; fi
if command -v kubectl >/dev/null 2>&1; then ok "kubectl: $(kubectl version --client 2>/dev/null | head -1)"; fi
if command -v helm >/dev/null 2>&1; then ok "helm: $(helm version --short 2>/dev/null)"; fi
if command -v git >/dev/null 2>&1; then ok "git: $(git --version)"; fi

# ---- gh >= 2.40 (needed for `gh auth token --user`) ----
if command -v gh >/dev/null 2>&1; then
  gh_version="$(gh --version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  ok "gh: $gh_version"
  ver_ge() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
  }
  if ! ver_ge "$gh_version" "$GH_MIN_VERSION"; then
    fail "gh $gh_version is older than the required $GH_MIN_VERSION (needed for 'gh auth token --user'). Upgrade gh."
  fi
fi

# ---- Docker engine (any: Docker Desktop, OrbStack, Rancher Desktop, colima, ...) ----
if [[ "$SKIP_COLIMA" -eq 0 ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    fail "'docker' is not on PATH. kind needs a Docker-compatible engine (Docker Desktop, OrbStack, Rancher Desktop, colima ...)."
  elif ! docker info >/dev/null 2>&1; then
    fail "'docker info' failed. Start your Docker engine (e.g. Docker Desktop, or 'colima start --cpu 4 --memory 8')."
  else
    ok "docker engine reachable (context: $(docker context show 2>/dev/null || echo default))"
    mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    if [[ "${mem_bytes:-0}" -gt 0 && "${mem_bytes}" -lt $((6*1024*1024*1024)) ]]; then
      echo "PREFLIGHT WARN: docker engine has $((mem_bytes/1024/1024/1024)) GiB; 8 GiB recommended (ArgoCD + 2x postgres + ~15 pods)."
    fi
  fi
fi

# ---- GitHub identity and remote (never mutates anything) ----
normalize_owner_repo() {
  # Accepts an https or ssh git remote URL, prints "owner/repo" (no .git suffix).
  local url="$1"
  local stripped="${url%.git}"
  if [[ "$stripped" =~ ^https://[^/]+/([^/]+)/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$stripped" =~ ^git@[^:]+:([^/]+)/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  elif [[ "$stripped" =~ ^ssh://git@[^/]+/([^/]+)/([^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    echo ""
  fi
}

configured_owner_repo="$(normalize_owner_repo "$REPO_URL")"
if [[ -z "$configured_owner_repo" ]]; then
  fail "REPO_URL '$REPO_URL' does not look like an https or ssh GitHub remote."
else
  ok "REPO_URL resolves to $configured_owner_repo"
fi

if command -v gh >/dev/null 2>&1; then
  active_login="$(gh api user --jq .login 2>/dev/null || true)"
  if [[ -z "$active_login" ]]; then
    fail "'gh api user' failed. Run: gh auth login"
  elif [[ "$active_login" != "$GITHUB_LOGIN" ]]; then
    fail "active gh identity is '$active_login', expected '$GITHUB_LOGIN'. Run: gh auth switch --user $GITHUB_LOGIN"
  else
    ok "active gh identity is $active_login"
  fi

  if [[ -n "$configured_owner_repo" ]]; then
    is_private="$(gh repo view "$configured_owner_repo" --json isPrivate --jq .isPrivate 2>/dev/null || true)"
    if [[ -z "$is_private" ]]; then
      fail "'gh repo view $configured_owner_repo' failed. Does the repo exist and is it reachable by '$GITHUB_LOGIN'?"
    else
      ok "repo $configured_owner_repo is reachable (private=$is_private)"
    fi
  fi
fi

if command -v git >/dev/null 2>&1; then
  origin_url="$(git -C "$LAB_ROOT" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$origin_url" ]]; then
    fail "git remote 'origin' is not configured in $LAB_ROOT. This is a manual, one-time user step (see README)."
  else
    origin_owner_repo="$(normalize_owner_repo "$origin_url")"
    if [[ -z "$configured_owner_repo" ]]; then
      : # already reported above
    elif [[ "$origin_owner_repo" != "$configured_owner_repo" ]]; then
      fail "origin ('$origin_owner_repo') does not match REPO_URL ('$configured_owner_repo'). Fix REPO_URL/GIT_BRANCH env or 'git remote set-url origin'."
    else
      ok "origin matches REPO_URL ($origin_owner_repo)"
    fi
  fi

  current_branch="$(git -C "$LAB_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
    fail "checkout is not on a branch (detached HEAD?). Check out $GIT_BRANCH."
  elif [[ "$current_branch" != "$GIT_BRANCH" ]]; then
    fail "checked-out branch is '$current_branch', expected GIT_BRANCH '$GIT_BRANCH'. Run: git checkout $GIT_BRANCH"
  else
    ok "checked out on $GIT_BRANCH"
  fi

  if ! git -C "$LAB_ROOT" ls-remote --exit-code origin "refs/heads/$GIT_BRANCH" >/dev/null 2>&1; then
    fail "'git ls-remote origin refs/heads/$GIT_BRANCH' failed with ambient git auth. If 'gh' works, try: gh auth setup-git"
  else
    ok "origin/$GIT_BRANCH is reachable over ambient git auth"
  fi
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "Preflight failed. Fix the FAIL lines above and re-run." >&2
  exit 1
fi

echo "Preflight passed."
