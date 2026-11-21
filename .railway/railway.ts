// Railway project for Honcho. Config as Code (railway.toml / railway.json)
// is deprecated: new services cannot use it. This file is the project
// definition. Railway does not read it on deploy. Apply it with the CLI:
//
//   railway config plan
//   railway config apply
//
// "${{Service.VAR}}" strings are Railway reference variables. They are
// resolved by Railway at deploy time. No secret values live in this file.
// preserve() keeps a value you set with `railway variable set`. A variable
// that exists in Railway but is absent here is deleted on the next apply.

import {
  defineRailway,
  github,
  postgres,
  preserve,
  project,
  service,
} from "railway/iac";

// Private-network host:port/database. Honcho's SQLAlchemy URL must use the
// psycopg driver prefix. Railway's DATABASE_URL uses postgresql://.
const pgEndpoint =
  "${{Postgres.PGHOST}}:${{Postgres.PGPORT}}/${{Postgres.PGDATABASE}}";
const dbConnectionUri =
  "postgresql+psycopg://${{Postgres.PGUSER}}:${{Postgres.PGPASSWORD}}@" +
  pgEndpoint;

// This template lives on stornes/honcho. Apply deploys that fork's main.
const source = github("stornes/honcho", { branch: "main" });

const imageBuild = {
  builder: "DOCKERFILE" as const,
  dockerfilePath: "Dockerfile",
};

// Railway healthchecks the injected PORT. docker/entrypoint.sh listens on
// 8000 and never reads PORT. Run the same migration, then bind PORT.
const apiStart =
  'sh -c \'/app/.venv/bin/python scripts/provision_db.py && exec /app/.venv/bin/fastapi run --host 0.0.0.0 --port "${PORT:-8000}" --workers "${API_WORKERS:-1}" src/main.py\'';

export default defineRailway(() => {
  // Railway Postgres 18. The image ships pgvector. Migrations create the
  // vector extension. pg_trgm and btree_gin are optional.
  const db = postgres("Postgres");

  const api = service("api", {
    source,
    build: imageBuild,
    start: apiStart,
    healthcheck: "/health",
    healthcheckTimeout: 300,
    deploy: {
      restartPolicyType: "ON_FAILURE",
      restartPolicyMaxRetries: 10,
      sleepApplication: false,
    },
    env: {
      DB_CONNECTION_URI: dbConnectionUri,
      VECTOR_STORE_TYPE: "pgvector",
      // Public URL. Turn this off only for a private network with no domain.
      AUTH_USE_AUTH: "true",
      // Set both before the first apply. preserve() keeps them across applies.
      AUTH_JWT_SECRET: preserve(),
      LLM_OPENAI_API_KEY: preserve(),
    },
  });

  // Same image as the API. fly.toml and docker-compose run this process
  // beside the API. It does not serve HTTP.
  const deriver = service("deriver", {
    source,
    build: imageBuild,
    start: "python -m src.deriver",
    deploy: {
      restartPolicyType: "ON_FAILURE",
      restartPolicyMaxRetries: 10,
      sleepApplication: false,
    },
    env: {
      DB_CONNECTION_URI: dbConnectionUri,
      VECTOR_STORE_TYPE: "pgvector",
      LLM_OPENAI_API_KEY: "${{api.LLM_OPENAI_API_KEY}}",
    },
  });

  return project("honcho", {
    resources: [db, api, deriver],
  });
});
