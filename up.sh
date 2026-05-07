#!/usr/bin/env sh
set -eu

set -a
. ./.env
set +a

envsubst < docker/garage.toml > docker/garage.generated.toml
trap 'rm -f docker/garage.generated.toml' EXIT

docker compose -p infra -f docker/docker-compose.yml up -d postgres

# Wait until postgres is ready (max 10 attempts)
attempt=1
max_attempts=10
until docker compose -p infra -f docker/docker-compose.yml exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  echo "Waiting for postgres to become ready... attempt ${attempt}/${max_attempts}"
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Postgres did not become ready after ${max_attempts} attempts" >&2
    docker compose -p infra -f docker/docker-compose.yml logs postgres --tail=100 >&2 || true
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done

docker compose -p infra -f docker/docker-compose.yml up -d rabbitmq
docker compose -p infra -f docker/docker-compose.yml up -d garage

# Initialize Keycloak DB/user
docker compose -p infra -f docker/docker-compose.yml exec -T postgres psql -U "$POSTGRES_USER" -d postgres <<SQL
CREATE USER "$KEYCLOAK_DB_USER" WITH ENCRYPTED PASSWORD '$KEYCLOAK_DB_PASSWORD';
CREATE DATABASE "$KEYCLOAK_DB" OWNER "$KEYCLOAK_DB_USER";
SQL

docker compose -p infra -f docker/docker-compose.yml up -d keycloak
