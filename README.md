# Infra playground

Local infrastructure startup via Docker Compose:
- Postgres
- RabbitMQ
- Garage
- Keycloak

## Configure

```bash
cp .env.example .env
```

Then edit `.env` (ports, usernames/passwords, tokens).

## Up

```bash
./up.sh
```

## Down

```bash
./down.sh
```

## Important

Use `./up.sh` and `./down.sh` for lifecycle operations.
Do not start the stack with plain `docker compose up` before running `./up.sh`, because `up.sh` applies required Garage token values and initializes Keycloak database/user.

## What `up.sh` does

1. Loads variables from `.env`.
2. Starts `postgres`.
3. Starts `rabbitmq`.
4. Injects `GARAGE_METRICS_TOKEN` and `GARAGE_ADMIN_TOKEN` into `docker/garage.toml`.
5. Starts `garage`.
6. Creates the Keycloak database and user in Postgres if they do not exist.
7. Starts `keycloak`.
