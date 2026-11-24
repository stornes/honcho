#!/usr/bin/env bash
# Connect local agents to a self-hosted Honcho API in one step.
#
# Mint an admin JWT from Railway AUTH_JWT_SECRET, write ~/.honcho/config.json
# and ~/.honcho/agent.env, and never print the secret or the token.
#
# Usage (from the honcho repo root, or any cwd — the script finds itself):
#   ./scripts/connect_agents.sh --install
#   ./scripts/connect_agents.sh --base-url https://<your-api-domain>
#   ./scripts/connect_agents.sh --memstrat-dir ~/Projects/memstrat-mcp
#
# Base URL: pass --base-url / HONCHO_BASE_URL, or the script discovers the
# public domain on the linked Railway api service. No hostname is hardcoded.
#
# Prerequisites (once): railway login, and this project linked or linkable.
# Do not commit agent.env, JWTs, or AUTH_JWT_SECRET.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Empty until --base-url / HONCHO_BASE_URL / Railway domain discovery fills it.
BASE_URL="${HONCHO_BASE_URL:-}"
BASE_URL_FROM_ENV=0
[[ -n "${HONCHO_BASE_URL:-}" ]] && BASE_URL_FROM_ENV=1

RAILWAY_SERVICE="${HONCHO_RAILWAY_SERVICE:-api}"
RAILWAY_PROJECT="${HONCHO_RAILWAY_PROJECT:-honcho}"
RAILWAY_ENVIRONMENT="${HONCHO_RAILWAY_ENVIRONMENT:-production}"
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
  --base-url URL       Public API URL (or set HONCHO_BASE_URL). If omitted,
                       discover from `railway domain list` on the api service
  --service NAME       Railway service that holds AUTH_JWT_SECRET (default: api)
  --project NAME       Railway project name for link (default: honcho)
  --environment NAME   Railway environment for link (default: production)
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

Never prints AUTH_JWT_SECRET or the JWT. Never hardcodes a Railway hostname.
EOF
}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="${2:?}"; BASE_URL_FROM_ENV=0; shift 2 ;;
    --service) RAILWAY_SERVICE="${2:?}"; shift 2 ;;
    --project) RAILWAY_PROJECT="${2:?}"; shift 2 ;;
    --environment) RAILWAY_ENVIRONMENT="${2:?}"; shift 2 ;;
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
  log "railway: not linked — running: railway link --project ${RAILWAY_PROJECT} --environment ${RAILWAY_ENVIRONMENT} --service ${RAILWAY_SERVICE}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "dry-run: would run railway link with project/environment/service (no hidden prompt)"
    return
  fi
  # Pass --environment so multi-env projects do not hang on a prompt.
  # Keep stderr visible; do not discard it.
  railway link \
    --project "${RAILWAY_PROJECT}" \
    --environment "${RAILWAY_ENVIRONMENT}" \
    --service "${RAILWAY_SERVICE}" \
    || die "railway link failed. Run \`railway login\` once, then retry from ${REPO_ROOT}."
}

discover_base_url() {
  # Prefer an explicit URL. Otherwise read the api service's public domain.
  local raw host
  if [[ -n "$BASE_URL" ]]; then
    printf '%s' "$BASE_URL"
    return
  fi
  raw="$(railway domain list \
    --project "${RAILWAY_PROJECT}" \
    --environment "${RAILWAY_ENVIRONMENT}" \
    --service "${RAILWAY_SERVICE}" \
    --json 2>/dev/null)" \
    || die "could not list Railway domains for service ${RAILWAY_SERVICE}. Pass --base-url or set HONCHO_BASE_URL."

  host="$(DOMAIN_JSON="$raw" python3 - <<'PY'
import json, os, sys

raw = os.environ.get("DOMAIN_JSON", "").strip()
if not raw:
    sys.exit(1)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(1)

rows = data if isinstance(data, list) else data.get("domains") or data.get("items") or []
if isinstance(data, dict) and not rows:
    rows = [data]

hosts: list[str] = []
for row in rows:
    if isinstance(row, str):
        hosts.append(row)
        continue
    if not isinstance(row, dict):
        continue
    for key in ("domain", "host", "hostname", "name", "url"):
        val = row.get(key)
        if isinstance(val, str) and val.strip():
            hosts.append(val.strip())
            break

# Prefer railway.app hosts; otherwise first entry.
preferred = [h for h in hosts if "railway.app" in h] or hosts
if not preferred:
    sys.exit(1)
host = preferred[0]
if host.startswith("https://") or host.startswith("http://"):
    print(host.rstrip("/"), end="")
else:
    print("https://" + host.rstrip("/"), end="")
PY
)" || die "no public domain on Railway service ${RAILWAY_SERVICE}. Generate one on api, or pass --base-url / HONCHO_BASE_URL."

  printf '%s' "$host"
}

resolve_base_url() {
  local url
  url="$(discover_base_url)"
  url="${url%/}"
  [[ -n "$url" ]] || die "empty base URL"
  case "$url" in
    https://*|http://*) ;;
    *) die "base URL must be http(s): got ${url}" ;;
  esac
  printf '%s' "$url"
}

fetch_jwt_secret() {
  # Capture only; never echo.
  local kv secret
  kv="$(railway variable list \
    --project "${RAILWAY_PROJECT}" \
    --environment "${RAILWAY_ENVIRONMENT}" \
    --service "${RAILWAY_SERVICE}" \
    --kv 2>/dev/null)" \
    || die "could not list Railway variables for service ${RAILWAY_SERVICE}. Are you logged in?"
  secret="$(printf '%s\n' "$kv" | sed -n 's/^AUTH_JWT_SECRET=//p' | head -n1)"
  [[ -n "$secret" ]] || die "AUTH_JWT_SECRET missing on Railway service ${RAILWAY_SERVICE}"
  printf '%s' "$secret"
}

mint_jwt() {
  # PYTHON_DOTENV_DISABLED skips load_dotenv(override=True) in src.config so a
  # local repo .env cannot replace the Railway AUTH_JWT_SECRET we just fetched.
  local secret="$1"
  local -a args=(python scripts/generate_jwt.py --admin --print-only)
  if [[ -n "$EXPIRES" ]]; then
    args+=(--expires "$EXPIRES")
  fi
  (
    cd "$REPO_ROOT"
    PYTHON_DOTENV_DISABLED=1 AUTH_JWT_SECRET="$secret" uv run --quiet "${args[@]}"
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
    log "dry-run: would link railway project ${RAILWAY_PROJECT} env ${RAILWAY_ENVIRONMENT} service ${RAILWAY_SERVICE}"
    if [[ -n "$BASE_URL" ]]; then
      log "dry-run: base URL ${BASE_URL}"
    else
      log "dry-run: would discover base URL via railway domain list (no hardcoded host)"
    fi
    log "dry-run: would mint admin JWT with PYTHON_DOTENV_DISABLED=1 (Railway secret wins)"
    log "dry-run: would write ${CONFIG_FILE}"
    log "dry-run: would write ${AGENT_ENV}"
    log "dry-run: would write ${CURSOR_SLOTS}"
    [[ -n "$MEMSTRAT_DIR" ]] && log "dry-run: would update ${MEMSTRAT_DIR}/.env"
    [[ "$RUN_INSTALL" -eq 1 ]] && log "dry-run: would run honcho install"
    exit 0
  fi

  ensure_railway_link
  BASE_URL="$(resolve_base_url)"
  # Show the resolved URL so the user can confirm it matches the linked project.
  if [[ "$BASE_URL_FROM_ENV" -eq 1 ]]; then
    log "using API ${BASE_URL} (from HONCHO_BASE_URL)"
  else
    log "using API ${BASE_URL}"
  fi
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
