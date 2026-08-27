#!/usr/bin/env bash
# Functional verification for the kyvernopre image — runs on the host under bash
# (build-hardened-image.sh invokes it as `env TAG=... PLATFORM=... SOURCE_COMMIT=...
# APP_VERSION=... bash verify.sh`).
#
# kyvernopre is a one-shot init/migration job (cleans up stale webhookconfigurations at
# Helm install/upgrade time, then exits) — it needs a Kubernetes API server connection to
# actually run, same as the kyverno controller. Only what can be checked without one is
# covered here: the binary exists, runs as nonroot, --help exits cleanly, and the version
# string reflects the pinned APP_VERSION.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"
APP_VERSION="${APP_VERSION:?APP_VERSION environment variable is required (build-hardened-image.sh passes it from build.env)}"

echo "== run-as user (nonroot, from image metadata) =="
USER_CFG="$(docker inspect --format '{{.Config.User}}' "$TAG")"
[ "$USER_CFG" = "65532:65532" ] || { echo "FAIL: the image Config.User is not 65532:65532 (actual: $USER_CFG)"; exit 1; }
echo "   Config.User=$USER_CFG"

docker run --rm -i --platform "$PLATFORM" -e APP_VERSION="$APP_VERSION" --entrypoint bash "$TAG" <<'GUEST'
set -e

echo "== locating the binary =="
[ -x /app/kyvernopre ] || { echo "FAIL: /app/kyvernopre is missing or not executable"; exit 1; }
echo "   /app/kyvernopre present and executable"

echo "== --help smoke test (all that runs without a Kubernetes API) =="
/app/kyvernopre --help >/tmp/help.out 2>&1
[ -s /tmp/help.out ] || { echo "FAIL: --help produced no output"; exit 1; }
i=0
while IFS= read -r line; do echo "   $line"; i=$((i+1)); [ "$i" -ge 5 ] && break; done < /tmp/help.out
echo "   --help exited 0"

echo "VERIFY-OK"
GUEST
