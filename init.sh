#!/usr/bin/env sh
set -eu

set -a
. ./.env
set +a

attempt=1
max_attempts=20
until docker compose -p infra -f docker/docker-compose.yml --env-file .env exec -T garage /garage -c /etc/garage.toml status >/dev/null 2>&1; do
  echo "Waiting for garage to become ready... attempt ${attempt}/${max_attempts}"
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Garage did not become ready after ${max_attempts} attempts" >&2
    docker compose -p infra -f docker/docker-compose.yml --env-file .env logs garage --tail=100 >&2 || true
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done

(docker compose -p infra -f docker/docker-compose.yml --env-file .env exec -T garage /garage -c /etc/garage.toml bucket website --allow "$GARAGE_DEFAULT_BUCKET" || true)
(docker compose -p infra -f docker/docker-compose.yml --env-file .env exec -T garage /garage -c /etc/garage.toml bucket allow --key "$GARAGE_DEFAULT_ACCESS_KEY" --read "$GARAGE_DEFAULT_BUCKET" || true)

attempt=1
max_attempts=10
until docker compose -p infra -f docker/docker-compose.yml --env-file .env exec -T postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
  echo "Waiting for postgres to become ready... attempt ${attempt}/${max_attempts}"
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Postgres did not become ready after ${max_attempts} attempts" >&2
    docker compose -p infra -f docker/docker-compose.yml --env-file .env logs postgres --tail=100 >&2 || true
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done

docker compose -p infra -f docker/docker-compose.yml --env-file .env exec -T postgres psql -U "$POSTGRES_USER" -d postgres -tc "SELECT 1 FROM pg_roles WHERE rolname = '$KEYCLOAK_DB_USER'" | grep -q 1 || \
  docker compose -p infra -f docker/docker-compose.yml --env-file .env exec -T postgres psql -U "$POSTGRES_USER" -d postgres -c "CREATE USER \"$KEYCLOAK_DB_USER\" WITH ENCRYPTED PASSWORD '$KEYCLOAK_DB_PASSWORD'"

docker compose -p infra -f docker/docker-compose.yml --env-file .env exec -T postgres psql -U "$POSTGRES_USER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$KEYCLOAK_DB'" | grep -q 1 || \
  docker compose -p infra -f docker/docker-compose.yml --env-file .env exec -T postgres psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE \"$KEYCLOAK_DB\" OWNER \"$KEYCLOAK_DB_USER\""
