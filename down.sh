#!/usr/bin/env sh
docker compose -p infra -f docker/docker-compose.yml --env-file .env down
