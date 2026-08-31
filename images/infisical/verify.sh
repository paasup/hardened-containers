#!/usr/bin/env bash
# Functional verification for the infisical image — runs on the host under bash
# (build-hardened-image.sh invokes it as `env TAG=... PLATFORM=... APP_VERSION=... bash
# verify.sh`).
#
# Unlike this repository's single-binary self-builds, this app is self-contained enough
# to verify for real: it needs only Postgres and Redis, both trivial to run as
# throwaway containers for the duration of this check. So instead of a CLI-only smoke
# test, this actually boots the server against real dependencies and polls the same
# `/api/status` endpoint the upstream Helm chart's readiness probe uses (confirmed via
# GitHub code search against the pinned commit) — auto-migration-on-boot
# (auto-start-migrations.ts upstream) running to completion against a real Postgres is
# itself a meaningful check that the npm `overrides` force-upgrades (build.env
# NPM_OVERRIDES) did not break dependency resolution or break the app at runtime.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"

NET="infisical-verify-$$"
PG="infisical-verify-pg-$$"
REDIS="infisical-verify-redis-$$"
APP="infisical-verify-app-$$"

cleanup() {
  docker rm -f "$APP" "$PG" "$REDIS" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== run-as user (nonroot, from image metadata) =="
USER_CFG="$(docker inspect --format '{{.Config.User}}' "$TAG")"
[ "$USER_CFG" = "1001" ] || { echo "FAIL: the image Config.User is not 1001 (actual: $USER_CFG)"; exit 1; }
echo "   Config.User=$USER_CFG"

echo "== starting throwaway Postgres + Redis =="
docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_USER=infisical -e POSTGRES_PASSWORD=infisical-verify -e POSTGRES_DB=infisical \
  postgres:16-alpine >/dev/null
docker run -d --name "$REDIS" --network "$NET" redis:7-alpine >/dev/null

echo "   waiting for Postgres to accept connections..."
for i in $(seq 1 60); do
  if docker exec "$PG" pg_isready -U infisical >/dev/null 2>&1; then break; fi
  [ "$i" -eq 60 ] && { echo "FAIL: Postgres did not become ready in time"; docker logs "$PG"; exit 1; }
  sleep 1
done
echo "   Postgres ready"

echo "== starting the image against them =="
docker run -d --name "$APP" --network "$NET" --platform "$PLATFORM" \
  -e DB_CONNECTION_URI="postgres://infisical:infisical-verify@${PG}:5432/infisical" \
  -e REDIS_URL="redis://${REDIS}:6379" \
  -e AUTH_SECRET="verify-only-secret-do-not-use-in-production-0123456789abcdef" \
  -e ENCRYPTION_KEY="0123456789abcdef0123456789abcdef" \
  -e SITE_URL="http://localhost:8080" \
  "$TAG" >/dev/null

echo "   waiting for /api/status to respond..."
OK=""
for i in $(seq 1 90); do
  if docker exec "$APP" node -e '
    const http = require("http");
    const req = http.get("http://127.0.0.1:8080/api/status", (res) => process.exit(res.statusCode === 200 ? 0 : 1));
    req.on("error", () => process.exit(1));
    req.setTimeout(2000, () => { req.destroy(); process.exit(1); });
  ' >/dev/null 2>&1; then
    OK=1
    break
  fi
  if ! docker inspect --format '{{.State.Running}}' "$APP" 2>/dev/null | grep -q true; then
    echo "FAIL: container exited before becoming healthy"; docker logs "$APP"; exit 1
  fi
  sleep 1
done
[ -n "$OK" ] || { echo "FAIL: /api/status did not return 200 within 90s"; docker logs "$APP"; exit 1; }
echo "   /api/status returned 200 — server booted, auto-migrations completed against a real Postgres"

echo "VERIFY-OK"
