# Windrose Dedicated Server — Development

This document covers local development, image builds, and CI workflows. For production setup and daily operations, see [README.md](README.md).

## Table of contents

- [Local development quick start](#local-development-quick-start)
- [Fast local test](#fast-local-test)
- [Developer image channels](#developer-image-channels)
- [Local smoke build commands](#local-smoke-build-commands)
- [Build and release workflows](#build-and-release-workflows)
- [Environment for local testing](#environment-for-local-testing)

---

## Local development quick start

Most users can skip this section. Use the dev override only when you want to test local changes to the image or startup scripts:

```bash
# Build locally and start with the dev override
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build

# Restart after editing entrypoint.sh
docker compose -f docker-compose.yml -f docker-compose.dev.yml restart windrose

# Stop the dev stack
docker compose -f docker-compose.yml -f docker-compose.dev.yml down
```

The default [docker-compose.yml](docker-compose.yml) is for stable published images, while [docker-compose.dev.yml](docker-compose.dev.yml) is for local development.

---

## Fast local test

Use this flow when you want to test local changes immediately without committing and without pulling a new image from GHCR:

```bash
# 1) Build local image from current working tree
docker compose -f docker-compose.yml -f docker-compose.dev.yml build windrose

# 2) Start with the locally built image
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d windrose

# 3) Watch startup logs
docker compose -f docker-compose.yml -f docker-compose.dev.yml logs -f windrose
```

Notes:

- `docker-compose.dev.yml` sets `image: windrose-ds:dev` and `pull_policy: never`, so Compose uses your local build.
- This keeps existing mounted data (`./data`, `./steam-home`) and does not require any Git push/tag workflow.
- If you only changed mounted scripts (`entrypoint.sh`, `healthcheck.sh`, files in `./scripts`), a rebuild is not required. Use:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml restart windrose
```

---

## Developer image channels

These channels are published automatically from the `main` branch.

- `dev`, `dev-staging`, `dev-debug`: automatically published developer channels from the `main` branch.

---

## Local smoke build commands

Use these commands when you want to verify all image variants locally before pushing changes:

```bash
# stable
docker build \
   --build-arg WINE_FLAVOR=stable \
   --build-arg ENABLE_WINETRICKS=false \
   --build-arg INSTALL_DEBUG_TOOLS=false \
   --build-arg DEFAULT_WINEDEBUG=-all \
   -t windrose-smoke:stable .

# staging
docker build \
   --build-arg WINE_FLAVOR=staging \
   --build-arg ENABLE_WINETRICKS=true \
   --build-arg WINETRICKS_PACKAGES='win10 vcrun2022' \
   --build-arg INSTALL_DEBUG_TOOLS=false \
   --build-arg DEFAULT_WINEDEBUG=-all \
   -t windrose-smoke:staging .

# debug
docker build \
   --build-arg WINE_FLAVOR=stable \
   --build-arg ENABLE_WINETRICKS=false \
   --build-arg INSTALL_DEBUG_TOOLS=true \
   --build-arg DEFAULT_WINEDEBUG='warn+timestamp' \
   -t windrose-smoke:debug .
```

---

## Build and release workflows

- [`.github/workflows/ci.yml`](.github/workflows/ci.yml): validates shell syntax and builds the stable, staging, and debug images in CI.
- [`.github/workflows/docker-developer.yml`](.github/workflows/docker-developer.yml): publishes developer images from `main`.
- [`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml): publishes release images from version tags.

---

## Environment for local testing

Copy `.env.dev.example` to `.env` for local development and notifier testing:

```bash
cp .env.dev.example .env
```
