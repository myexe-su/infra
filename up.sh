#!/usr/bin/env sh
set -eu

set -a
. ./.env
set +a

cp docker/garage/garage.toml docker/garage/garage.generated.toml
sed -i '' "s|^root_domain = .*|root_domain = \"$GARAGE_WEB_ROOT_DOMAIN\"|" docker/garage/garage.generated.toml
sed -i '' "s|^metrics_token = .*|metrics_token = \"$GARAGE_METRICS_TOKEN\"|" docker/garage/garage.generated.toml
sed -i '' "s|^admin_token = .*|admin_token = \"$GARAGE_ADMIN_TOKEN\"|" docker/garage/garage.generated.toml
trap 'rm -f docker/garage/garage.generated.toml' EXIT

docker compose -p infra -f docker/docker-compose.yml --env-file .env build garage
docker compose -p infra -f docker/docker-compose.yml --env-file .env up -d

attempt=1
max_attempts=10
until docker compose -p infra -f docker/docker-compose.yml --env-file .env exec -T vault sh -c 'VAULT_ADDR=http://127.0.0.1:8200 vault status' >/dev/null 2>&1; do
  echo "Waiting for vault to become ready... attempt ${attempt}/${max_attempts}"
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Vault did not become ready after ${max_attempts} attempts" >&2
    docker compose -p infra -f docker/docker-compose.yml --env-file .env logs vault --tail=100 >&2 || true
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done
