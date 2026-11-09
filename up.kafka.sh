#!/usr/bin/env sh
set -eu

set -a
. ./.env
set +a

docker compose -p infra-kafka -f docker/docker-compose.kafka.yml --env-file .env up -d

attempt=1
max_attempts=20
until docker compose -p infra-kafka -f docker/docker-compose.kafka.yml --env-file .env exec -T kafka sh -c 'nc -z localhost 9092' >/dev/null 2>&1; do
  echo "Waiting for kafka to become ready... attempt ${attempt}/${max_attempts}"
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "Kafka did not become ready after ${max_attempts} attempts" >&2
    docker compose -p infra-kafka -f docker/docker-compose.kafka.yml --env-file .env logs kafka --tail=100 >&2 || true
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 1
done
