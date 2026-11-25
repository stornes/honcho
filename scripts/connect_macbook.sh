#!/usr/bin/env bash
# Register this MacBook with an existing Railway Honcho install.
#
# Wraps scripts/connect_agents.sh (Honcho agent connect — NOT Cursor cloud
# private workers). Clones or updates the local repo, then runs connect with
# --install. Does not deploy to Railway and never prints a JWT.
#
# Default repo path: /Users/stornes/Projects/honcho
# Override: HONCHO_REPO=/path/to/honcho bash scripts/connect_macbook.sh
#
# How to run:
#   bash /Users/stornes/Projects/honcho/scripts/connect_macbook.sh

set -euo pipefail

REPO_DEFAULT="/Users/stornes/Projects/honcho"
REPO="${HONCHO_REPO:-$REPO_DEFAULT}"
CLONE_URL="https://github.com/stornes/honcho.git"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }
ok() { log "ok: $*"; }

detect_host() {
  local host os_name os_detail
  host="$(hostname 2>/dev/null || printf 'unknown')"
  os_name="$(uname -s 2>/dev/null || printf 'unknown')"
  os_detail="$os_name"
  if [[ "$os_name" == "Darwin" ]] && command -v sw_vers >/dev/null 2>&1; then
    os_detail="$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) ($(uname -m))"
  fi
  log "host: ${host}"
  log "os:   ${os_detail}"
}

need_cmd() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "found \`${cmd}\` ($(command -v "$cmd"))"
    return 0
  fi
  die "missing \`${cmd}\`. ${hint}"
}

check_tools() {
  log "checking required tools (node, npm, git)…"
  need_cmd node "Install Node.js from https://nodejs.org/ then open a new shell."
  need_cmd npm "Install Node.js (includes npm) from https://nodejs.org/ then open a new shell."
  need_cmd git "Install Xcode CLT: xcode-select --install"
  log "note: railway and uv are checked by scripts/connect_agents.sh"
}

ensure_repo() {
  local parent
  if [[ -d "$REPO/.git" ]]; then
    ok "repo present at ${REPO}"
    log "updating: fetch + checkout main + pull (ff-only)"
    (
      cd "$REPO"
      git fetch origin
      git checkout main
      git pull --ff-only origin main
    ) || die "git update failed in ${REPO}"
    ok "repo on main and up to date"
    return
  fi

  if [[ -e "$REPO" ]]; then
    die "${REPO} exists but is not a git repo. Set HONCHO_REPO or remove/rename it."
  fi

  parent="$(dirname "$REPO")"
  mkdir -p "$parent"
  log "cloning ${CLONE_URL} → ${REPO}"
  git clone "$CLONE_URL" "$REPO" || die "git clone failed"
  ok "cloned into ${REPO}"
}

run_connect() {
  local connect="${REPO}/scripts/connect_agents.sh"
  [[ -x "$connect" || -f "$connect" ]] || die "missing ${connect} — is this the stornes/honcho repo?"
  chmod +x "$connect" 2>/dev/null || true
  log "running: ${connect} --install"
  (
    cd "$REPO"
    ./scripts/connect_agents.sh --install
  ) || die "connect_agents.sh --install failed (see messages above)"
}

main() {
  log "honcho MacBook connect — wrapping scripts/connect_agents.sh"
  log "repo: ${REPO} (override with HONCHO_REPO)"
  detect_host
  check_tools
  ensure_repo
  run_connect
  cat <<EOF >&2

success: MacBook registered with Railway Honcho via connect_agents.sh --install.
Next (usually once): fill Cursor/1Password slots HONCHO_BASE_URL and HONCHO_JWT
from ~/.honcho/agent.env (never paste into chat).

How to run: bash /Users/stornes/Projects/honcho/scripts/connect_macbook.sh
EOF
}

main "$@"
