# Deploy Honcho on Railway

This defines three services in [`.railway/railway.ts`](../.railway/railway.ts):

- **api** builds the root `Dockerfile`. It migrates, then listens on Railway's `PORT`.
- **deriver** builds the same image and runs `python -m src.deriver`.
- **Postgres** is Railway Postgres. That image includes pgvector. Migrations create the `vector` extension.

Redis is not included. Cache stays off unless you set `CACHE_ENABLED` and `CACHE_URL`.

`railway.toml` is not used. Railway no longer accepts Config as Code on new services.

## Auth

`AUTH_USE_AUTH` is `true` on api. Every request except `/health` needs a Bearer JWT. The process will not boot without `AUTH_JWT_SECRET`. `preserve()` keeps that secret across applies.

This server has no browser login. Device login in `honcho init` is only for managed Honcho (`api.honcho.dev`). Agents authenticate with a JWT signed by `AUTH_JWT_SECRET`.

### Connect agents in one step

From the repo root (after `railway login` once):

```bash
./scripts/connect_agents.sh
# or: ./scripts/connect_agents.sh --install
# or: ./scripts/connect_agents.sh --memstrat-dir /path/to/memstrat-mcp
```

The script checks `railway` and `uv`, links the Railway project if needed, mints an admin JWT from `AUTH_JWT_SECRET`, and writes local config **without printing the secret or the token**:

- `~/.honcho/config.json` — honcho CLI + plugins (`apiKey` + `environmentUrl`)
- `~/.honcho/agent.env` — `HONCHO_BASE_URL` + `HONCHO_JWT` for MemStrat / Cursor (chmod 600)
- `~/.honcho/cursor-secret-slots.env.example` — empty slot names to fill once in Cursor or 1Password

Fill Cursor dashboard secret slots `HONCHO_BASE_URL` and `HONCHO_JWT` once from `agent.env`. Do not paste them into chat or commit them.

Manual mint (debug only):

```bash
railway link --project honcho
export AUTH_JWT_SECRET="$(railway variable list --service api --kv | sed -n 's/^AUTH_JWT_SECRET=//p')"
uv run python scripts/generate_jwt.py --admin
```

Send it as `Authorization: Bearer <jwt>`. `generate_jwt.py --admin` has no expiry. Add `--expires 24h` for a shorter token. Do not commit the secret or the token.

The deriver has no public domain.

Leave `MULTI_TENANT` unset. This template is single-tenant.

## Apply

Install the [Railway CLI](https://docs.railway.com/cli), then from the repo root:

```bash
railway init --name honcho
railway add --service api
railway config plan
railway config apply
```

`railway config apply` creates the Postgres service and the deriver. The services deploy `stornes/honcho` branch `main`.

Set `AUTH_JWT_SECRET` on api before the first apply. `preserve()` stops apply when it is missing. Generate it with `uv run python scripts/generate_jwt_secret.py` and pass it to `railway variable set AUTH_JWT_SECRET --stdin --service api --skip-deploys`. Do not commit it.

## After apply

1. On api, generate a public domain. Leave the target port on Railway's `PORT`.
2. Open `https://<your-domain>/health`. It returns `{"status":"ok"}` without a JWT.
3. The deriver may exit before the first migration finishes. Redeploy it if it stops. Leave it without a public domain.

## LLM provider key

The API starts without a provider key. Memory, chat, summaries, dreams, and embeddings do not.

Built-in defaults use OpenAI:

- deriver, dialectic, summary, and dreamer: `gpt-5.4-mini`
- embeddings: `text-embedding-3-small`

`LLM_OPENAI_API_KEY` is `preserve()` on api. deriver references `${{api.LLM_OPENAI_API_KEY}}`. Apply does not replace a value already set in Railway, and it stops if the api value is missing. Do not commit the key.

`LLM_ANTHROPIC_API_KEY` or `LLM_GEMINI_API_KEY` work only if you also change the model transport. The defaults above do not read them.

## Variables

| Variable | Services | Value |
| --- | --- | --- |
| `DB_CONNECTION_URI` | api, deriver | Postgres private host, user, password, and database |
| `VECTOR_STORE_TYPE` | api, deriver | `pgvector` |
| `AUTH_USE_AUTH` | api | `true` |
| `AUTH_JWT_SECRET` | api | `preserve()` |
| `LLM_OPENAI_API_KEY` | api; deriver references api | `preserve()` on api |

`DB_CONNECTION_URI` is built from the Postgres private-network variables, with the `postgresql+psycopg://` scheme Honcho requires. If the password contains reserved URL characters, encode them.

`CORS_ORIGINS` defaults do not include a Railway domain. Add your domain before calling the API from a browser.
