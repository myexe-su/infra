#!/usr/bin/env sh
docker compose -p infra-kafka -f docker/docker-compose.kafka.yml --env-file .env down
