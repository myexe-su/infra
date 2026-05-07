#!/usr/bin/env sh

set -a
. ./.env
set +a

docker compose -f docker/docker-compose.yml --env-file .env up -d postgres
docker compose -f docker/docker-compose.yml --env-file .env up -d rabbitmq

sed -i '' "s|^metrics_token = .*|metrics_token = \"$GARAGE_METRICS_TOKEN\"|" docker/garage.toml
sed -i '' "s|^admin_token = .*|admin_token = \"$GARAGE_ADMIN_TOKEN\"|" docker/garage.toml
docker compose -f docker/docker-compose.yml --env-file .env up -d garage

# Create Keycloak DB/user if missing (idempotent)
docker compose -f docker/docker-compose.yml --env-file .env exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$KEYCLOAK_DB_USER') THEN
    EXECUTE format('CREATE USER %I WITH ENCRYPTED PASSWORD %L', '$KEYCLOAK_DB_USER', '$KEYCLOAK_DB_PASSWORD');
  END IF;
END
\$\$;

DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$KEYCLOAK_DB') THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I', '$KEYCLOAK_DB', '$KEYCLOAK_DB_USER');
  END IF;
END
\$\$;
SQL
docker compose -f docker/docker-compose.yml --env-file .env up -d keycloak
