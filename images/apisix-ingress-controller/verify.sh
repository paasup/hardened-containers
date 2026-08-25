#!/usr/bin/env bash
# Functional verification for the apisix-ingress-controller image — runs on the host under
# bash (build-hardened-image.sh invokes it as
# `env TAG=... PLATFORM=... SOURCE_COMMIT=... bash verify.sh`).
#
# Actually starting the controller requires a connection to a Kubernetes API server, which is
# outside this smoke test's scope (see README.md). Only what can be checked without a
# Kubernetes API is covered here: the binary exists, the version string reflects the pinned
# commit, --help exits cleanly, and the run-as user.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"
SOURCE_COMMIT="${SOURCE_COMMIT:?SOURCE_COMMIT environment variable is required (build-hardened-image.sh passes it from build.env)}"

echo "== run-as user (nonroot, from image metadata) =="
USER_CFG="$(docker inspect --format '{{.Config.User}}' "$TAG")"
[ "$USER_CFG" = "65532:65532" ] || { echo "FAIL: the image Config.User is not 65532:65532 (actual: $USER_CFG)"; exit 1; }
echo "   Config.User=$USER_CFG"

docker run --rm -i --platform "$PLATFORM" -e SOURCE_COMMIT="$SOURCE_COMMIT" --entrypoint sh "$TAG" <<'GUEST'
set -e

echo "== locating the binary =="
[ -x /app/apisix-ingress-controller ] || { echo "FAIL: /app/apisix-ingress-controller is missing or not executable"; exit 1; }
echo "   /app/apisix-ingress-controller present and executable"

echo "== version (confirming the pinned commit) =="
OUT="$(/app/apisix-ingress-controller version --long)"
while IFS= read -r line; do echo "   $line"; done <<EOF
$OUT
EOF
case "$OUT" in
  *"$SOURCE_COMMIT"*) ;;
  *) echo "FAIL: version output lacks the pinned commit ($SOURCE_COMMIT) — check the ldflags injection"; exit 1 ;;
esac

echo "== --help smoke test (all that runs without a Kubernetes API) =="
/app/apisix-ingress-controller --help >/dev/null
echo "   --help exited 0"

echo "VERIFY-OK"
GUEST
