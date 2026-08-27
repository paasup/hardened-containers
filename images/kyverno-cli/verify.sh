#!/usr/bin/env bash
# Functional verification for the kyverno-cli image — runs on the host under bash
# (build-hardened-image.sh invokes it as `env TAG=... PLATFORM=... SOURCE_COMMIT=...
# APP_VERSION=... bash verify.sh`).
#
# Unlike images/kyverno/ (a controller that needs a Kubernetes API server to do anything
# beyond --help), this is a standalone CLI built with cobra
# (cmd/cli/kubectl-kyverno/commands/command.go) that ships a real, side-effect-free
# `version` subcommand — so verification here checks more than just "did --help exit 0":
# it checks that the printed version string actually reflects the pinned APP_VERSION,
# the same ldflags symbol (pkg/version.BuildVersion) images/kyverno/ relies on.
#
# `kyverno test` / `kyverno apply` are not exercised here — both need policy/resource
# input to do anything meaningful, which is outside a smoke test's scope.
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
[ -x /app/kubectl-kyverno ] || { echo "FAIL: /app/kubectl-kyverno is missing or not executable"; exit 1; }
echo "   /app/kubectl-kyverno present and executable"

echo "== --help smoke test =="
/app/kubectl-kyverno --help >/tmp/help.out 2>&1
[ -s /tmp/help.out ] || { echo "FAIL: --help produced no output"; exit 1; }
echo "   --help exited 0"

echo "== version subcommand (side-effect-free, no cluster needed) =="
/app/kubectl-kyverno version >/tmp/version.out 2>&1
VERSION_LINE=""
while IFS= read -r line; do
  echo "   $line"
  case "$line" in
    Version:*) VERSION_LINE="$line" ;;
  esac
done < /tmp/version.out
[ -n "$VERSION_LINE" ] || { echo "FAIL: 'version' subcommand produced no 'Version:' line"; exit 1; }
case "$VERSION_LINE" in
  *"$APP_VERSION"*) ;;
  *) echo "FAIL: version subcommand does not report the pinned APP_VERSION ($APP_VERSION): $VERSION_LINE"; exit 1 ;;
esac
echo "   version subcommand exited 0 and reports $APP_VERSION"

echo "VERIFY-OK"
GUEST
