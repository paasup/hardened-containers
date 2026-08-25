#!/usr/bin/env bash
# Functional verification for the cloudnative-pg operator image — runs on the host under bash
# and invokes the binary directly with `docker run --entrypoint /manager` (which works whether
# or not the guest has a shell). Actually starting the controller (which needs a Kubernetes
# API) is out of scope — a dev cluster deployment test covers that.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"
SOURCE_COMMIT="${SOURCE_COMMIT:?SOURCE_COMMIT environment variable is required (build-hardened-image.sh passes it from build.env)}"
SHORT_COMMIT="${SOURCE_COMMIT:0:8}"

echo "== manager version =="
OUT="$(docker run --rm --platform "$PLATFORM" --entrypoint /manager "$TAG" version)"
echo "   $OUT"
case "$OUT" in
  *"$SHORT_COMMIT"*) ;;
  *) echo "FAIL: version output lacks the pinned commit ($SHORT_COMMIT) — check the ldflags injection"; exit 1 ;;
esac

echo "== run-as user (nonroot, from image metadata) =="
# There is no shell, so `id` cannot be run inside the container — the default User the image
# declares is checked instead. The version run above already succeeded as that default user
# (a permissions problem would not have got this far).
USER_CFG="$(docker inspect --format '{{.Config.User}}' "$TAG")"
[ "$USER_CFG" = "65532:65532" ] || { echo "FAIL: the image Config.User is not 65532:65532 (actual: $USER_CFG)"; exit 1; }
echo "   Config.User=$USER_CFG"

echo "== --help smoke test (all that runs without a Kubernetes API) =="
docker run --rm --platform "$PLATFORM" --entrypoint /manager "$TAG" --help >/dev/null
echo "   /manager --help exited 0"

echo "VERIFY-OK"
