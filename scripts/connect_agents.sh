#!/usr/bin/env bash
# Connect local agents to a self-hosted Honcho API in one step.
#
# Mint an admin JWT from Railway AUTH_JWT_SECRET, write ~/.honcho/config.json
# and ~/.honcho/agent.env, and never print the secret or the token.
#
# Usage (from the honcho repo root, or any cwd — the script finds itself):
#   ./scripts/connect_agents.sh
#   ./scripts/connect_agents.sh --install
#   ./scripts/connect_agents.sh --memstrat-dir ~/Projects/memstrat-mcp
#   ./scripts/connect_agents.sh --base-url https://api-production-….up.railway.app
#
# Prerequisites (once): railway login, and this project linked or linkable.
# Do not commit agent.env, JWTs, or AUTH_JWT_SECRET.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_BASE_URL="https://api-production-ab029ab8.up.railway.app"
BASE_URL="${HONCHO_BASE_URL:-$DEFAULT_BASE_URL}"
RAILWAY_SERVICE="${HONCHO_RAILWAY_SERVICE:-api}"
RAILWAY_PROJECT="${HONCHO_RAILWAY_PROJECT:-honcho}"
HONCHO_HOME="${HONCHO_HOME:-${HOME}/.honcho}"
CONFIG_FILE="${HONCHO_HOME}/config.json"
AGENT_ENV="${HONCHO_HOME}/agent.env"
CURSOR_SLOTS="${HONCHO_HOME}/cursor-secret-slots.env.example"
MEMSTRAT_DIR=""
RUN_INSTALL=0
DRY_RUN=0
EXPIRES=""

usage() {
  cat <<'EOF'
Connect agents to self-hosted Honcho (one command).

  ./scripts/connect_agents.sh [options]

Options:
  --base-url URL       Public API URL (default: production Railway api,
                       or HONCHO_BASE_URL if set)
  --service NAME       Railway service that holds AUTH_JWT_SECRET (default: api)
  --project NAME       Railway project name for link (default: honcho)
  --memstrat-dir PATH  Also write HONCHO_* into PATH/.env (empty slots filled)
  --install            Run `honcho install` after writing config
  --expires DURATION   JWT expiry for generate_jwt.py (default: never)
  --dry-run            Check deps and plan writes; mint nothing
  -h, --help           Show this help

Writes (chmod 600 where secrets live):
  ~/.honcho/config.json              honcho CLI + plugins (apiKey + environmentUrl)
  ~/.honcho/agent.env                HONCHO_BASE_URL + HONCHO_JWT for MemStrat/Cursor
  ~/.honcho/cursor-secret-slots.env.example
                                     empty slot names to fill once in Cursor/1Password

Never prints AUTH_JWT_SECRET or the JWT.
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="${2:?}"; shift 2 ;;
    --service) RAILWAY_SERVICE="${2:?}"; shift 2 ;;
    --project) RAILWAY_PROJECT="${2:?}"; shift 2 ;;
    --memstrat-dir) MEMSTRAT_DIR="${2:?}"; shift 2 ;;
    --install) RUN_INSTALL=1; shift ;;
    --expires) EXPIRES="${2:?}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

BASE_URL="${BASE_URL%/}"

need_cmd() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: missing \`$cmd\` — ${hint}"
    return 1
  fi
  die "missing \`$cmd\`. ${hint}"
}

check_deps() {
  # Under --dry-run, missing tools are warnings so the plan still prints.
  need_cmd railway "Install: https://docs.railway.com/guides/cli — then open a new shell so PATH updates." || true
  need_cmd uv "Install: https://docs.astral.sh/uv/ — then open a new shell so PATH updates." || true
  need_cmd python3 "Needed to merge ~/.honcho/config.json without echoing secrets." || true
}

ensure_railway_link() {
  if railway status >/dev/null 2>&1; then
    log "railway: already linked"
    return
  fi
  log "railway: not linked in this directory — running: railway link --project ${RAILWAY_PROJECT}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would run railway link --project ${RAILWAY_PROJECT}"
    return
  fi
  # Non-interactive when possible; falls back to the CLI's own prompts.
  if ! railway link --project "${RAILWAY_PROJECT}" 2>/dev/null; then
    railway link --project "${RAILWAY_PROJECT}" || die "railway link failed. Run \`railway login\` once, then retry from ${REPO_ROOT}."
  fi
}

fetch_jwt_secret() {
  # Capture only; never echo.
  local kv secret
  kv="$(railway variable list --service "${RAILWAY_SERVICE}" --kv 2>/dev/null)" \
    || die "could not list Railway variables for service ${RAILWAY_SERVICE}. Are you logged in and linked?"
  secret="$(printf '%s\n' "$kv" | sed -n 's/^AUTH_JWT_SECRET=//p' | head -n1)"
  [[ -n "$secret" ]] || die "AUTH_JWT_SECRET missing on Railway service ${RAILWAY_SERVICE}"
  printf '%s' "$secret"
}

mint_jwt() {
  local secret="$1"
  local -a args=(python scripts/generate_jwt.py --admin --print-only)
  if [[ -n "$EXPIRES" ]]; then
    args+=(--expires "$EXPIRES")
  fi
  (
    cd "$REPO_ROOT"
    AUTH_JWT_SECRET="$secret" uv run --quiet "${args[@]}"
  )
}

write_honcho_config() {
  local url="$1" token="$2"
  mkdir -p "$HONCHO_HOME"
  HONCHO_CONFIG_FILE="$CONFIG_FILE" HONCHO_URL="$url" HONCHO_TOKEN="$token" python3 - <<'PY'
import json, os
from pathlib import Path

path = Path(os.environ["HONCHO_CONFIG_FILE"])
url = os.environ["HONCHO_URL"]
token = os.environ["HONCHO_TOKEN"]
data = {}
if path.exists():
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            data = loaded
    except (json.JSONDecodeError, OSError):
        data = {}
data["environmentUrl"] = url
data["apiKey"] = token
path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
os.chmod(path, 0o600)
print(str(path), flush=True)
PY
}

write_agent_env() {
  local url="$1" token="$2"
  umask 077
  cat >"$AGENT_ENV" <<EOF
# Generated by scripts/connect_agents.sh — do not commit.
# Source this file or point MemStrat / Cursor secret slots at these names.
HONCHO_BASE_URL=${url}
HONCHO_JWT=${token}
EOF
  chmod 600 "$AGENT_ENV"
}

write_cursor_slots() {
  cat >"$CURSOR_SLOTS" <<'EOF'
# Empty Cursor / 1Password secret slot names for MemStrat MCP.
# Fill each once from ~/.honcho/agent.env (never paste into chat or git).
#
# Cursor dashboard → Cloud Agents / MCP secrets (or MCP env):
HONCHO_BASE_URL=
HONCHO_JWT=
#
# Shared peers (optional; MemStrat defaults work if unset):
HONCHO_WORKSPACE_ID=
HONCHO_PEER_ID=
HONCHO_SESSION_ID=
EOF
  chmod 644 "$CURSOR_SLOTS"
}

upsert_env_file() {
  # Fill HONCHO_BASE_URL / HONCHO_JWT in an existing .env without printing them.
  local env_file="$1" url="$2" token="$3"
  [[ -f "$env_file" ]] || die "memstrat env not found: ${env_file} (copy .env.example first)"
  HONCHO_ENV_FILE="$env_file" HONCHO_URL="$url" HONCHO_TOKEN="$token" python3 - <<'PY'
import os, re
from pathlib import Path

path = Path(os.environ["HONCHO_ENV_FILE"])
url = os.environ["HONCHO_URL"]
token = os.environ["HONCHO_TOKEN"]
text = path.read_text(encoding="utf-8")

def upsert(src: str, key: str, value: str) -> str:
    line = f"{key}={value}"
    pattern = re.compile(rf"(?m)^{re.escape(key)}=.*$")
    if pattern.search(src):
        return pattern.sub(line, src)
    if src and not src.endswith("\n"):
        src += "\n"
    return src + line + "\n"

text = upsert(text, "HONCHO_BASE_URL", url)
text = upsert(text, "HONCHO_JWT", token)
path.write_text(text, encoding="utf-8")
os.chmod(path, 0o600)
print(str(path), flush=True)
PY
}

probe_health() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 10 "${url}/health" >/dev/null 2>&1; then
      log "health: ${url}/health ok"
      return
    fi
    log "warning: ${url}/health did not respond (URL may still be fine for JWT calls)"
  fi
}

main() {
  log "honcho connect — repo ${REPO_ROOT}"
  check_deps

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would link railway project ${RAILWAY_PROJECT} (service ${RAILWAY_SERVICE})"
    log "dry-run: would mint admin JWT via scripts/generate_jwt.py --admin --print-only"
    log "dry-run: would write ${CONFIG_FILE}"
    log "dry-run: would write ${AGENT_ENV}"
    log "dry-run: would write ${CURSOR_SLOTS}"
    [[ -n "$MEMSTRAT_DIR" ]] && log "dry-run: would update ${MEMSTRAT_DIR}/.env"
    [[ "$RUN_INSTALL" -eq 1 ]] && log "dry-run: would run honcho install"
    log "dry-run: base URL ${BASE_URL}"
    exit 0
  fi

  ensure_railway_link
  probe_health "$BASE_URL"

  local secret token
  secret="$(fetch_jwt_secret)"
  token="$(mint_jwt "$secret")"
  unset secret
  [[ -n "$token" ]] || die "generate_jwt.py returned an empty token"

  write_honcho_config "$BASE_URL" "$token" >/dev/null
  write_agent_env "$BASE_URL" "$token"
  write_cursor_slots
  log "wrote ${CONFIG_FILE} (apiKey redacted; chmod 600)"
  log "wrote ${AGENT_ENV} (chmod 600; not printed)"
  log "wrote ${CURSOR_SLOTS} (empty slot names only)"

  if [[ -n "$MEMSTRAT_DIR" ]]; then
    upsert_env_file "${MEMSTRAT_DIR}/.env" "$BASE_URL" "$token" >/dev/null
    log "updated ${MEMSTRAT_DIR}/.env HONCHO_BASE_URL + HONCHO_JWT (not printed)"
  fi

  # Drop token from this shell as soon as writes finish.
  unset token

  if [[ "$RUN_INSTALL" -eq 1 ]]; then
    if command -v honcho >/dev/null 2>&1; then
      log "running: honcho install"
      honcho install
    else
      log "warning: \`honcho\` not on PATH — skip --install. Install the CLI, then run: honcho install"
    fi
  fi

  cat <<EOF >&2

Done. Next (usually once):
  1. Cursor / 1Password: fill empty slots HONCHO_BASE_URL and HONCHO_JWT
     from ${AGENT_ENV} (do not paste into chat).
  2. Optional peers: one workspace, peer "sverre" for you, one peer per tool.
  3. Wire agents: honcho install   (or re-run with --install)

Deriver stays private. No browser login on this self-hosted API.
EOF
}

main
