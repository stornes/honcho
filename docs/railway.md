# Deploy Honcho on Railway

This defines three services in [`.railway/railway.ts`](../.railway/railway.ts):

- **api** builds the root `Dockerfile`. It migrates, then listens on Railway's `PORT`.
- **deriver** builds the same image and runs `python -m src.deriver`.
- **Postgres** is Railway Postgres. That image includes pgvector. Migrations create the `vector` extension.

Redis is not included. Cache stays off unless you set `CACHE_ENABLED` and `CACHE_URL`.

`railway.toml` is not used. Railway no longer accepts Config as Code on new services.

## Auth

`AUTH_USE_AUTH` is `false`. That is Honcho's self-host default (`AuthSettings.USE_AUTH`).

`true` is API-key auth. Every request needs `Authorization: Bearer <jwt>`, and the process will not boot without `AUTH_JWT_SECRET`. `honcho init` calls that path "Paste an API key".

This server has no login routes. Browser login in `honcho init` appears only when the host serves `/.well-known/oauth-authorization-server` with the device grant. That is managed Honcho (`api.honcho.dev`). This repository does not implement those routes, so a Railway deploy cannot offer that login.

With auth off, no API key is required. `honcho init --base-url <api url>` can skip the key. Every caller is an admin. Do not generate a public domain until you turn auth on.

Leave `MULTI_TENANT` unset. This template is single-tenant. Multi-tenant mode refuses to boot when `AUTH_USE_AUTH` is off.

## Apply

Install the [Railway CLI](https://docs.railway.com/cli), then from the repo root:

```bash
railway init --name honcho
railway add --service api
railway config plan
railway config apply
```

`railway config apply` creates the Postgres service and the deriver. The services deploy `stornes/honcho` branch `main`.

Do not set `AUTH_JWT_SECRET`. Do not paste `LLM_OPENAI_API_KEY` to get in.

## After apply

1. Leave the api service without a public domain while `AUTH_USE_AUTH` is false.
2. The api and deriver processes can boot without an LLM key. `/health` does not call a model.
3. The deriver may exit before the first migration finishes. Redeploy it if it stops.

## LLM provider key

The API starts without a provider key. Memory, chat, summaries, dreams, and embeddings do not.

Built-in defaults use OpenAI:

- deriver, dialectic, summary, and dreamer: `gpt-5.4-mini`
- embeddings: `text-embedding-3-small`

Set `LLM_OPENAI_API_KEY` on the **api** service when you have a key. Set the same name on **deriver** to `${{api.LLM_OPENAI_API_KEY}}`.

That key is not an access credential. Do not commit it. A variable set only in the dashboard is removed on the next apply, so add both lines to `.railway/railway.ts` as `preserve()` on api and the reference on deriver before you apply again. `preserve()` stops apply when the value is missing, which is why this file does not include it yet.

`LLM_ANTHROPIC_API_KEY` or `LLM_GEMINI_API_KEY` work only if you also change the model transport. The defaults above do not read them.

## Variables

| Variable | Services | Value |
| --- | --- | --- |
| `DB_CONNECTION_URI` | api, deriver | Postgres private host, user, password, and database |
| `VECTOR_STORE_TYPE` | api, deriver | `pgvector` |
| `AUTH_USE_AUTH` | api | `false` |

`DB_CONNECTION_URI` is built from the Postgres private-network variables, with the `postgresql+psycopg://` scheme Honcho requires. If the password contains reserved URL characters, encode them.

`CORS_ORIGINS` defaults do not include a Railway domain. Add your domain before calling the API from a browser.
