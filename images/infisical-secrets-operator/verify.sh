#!/usr/bin/env bash
# Functional verification for the infisical-secrets-operator image — runs on the host
# under bash (build-hardened-image.sh invokes it as
# `env TAG=... PLATFORM=... SOURCE_COMMIT=... APP_VERSION=... bash verify.sh`).
#
# This is a controller-runtime manager: actually starting it requires a Kubernetes API
# server connection, which is outside this smoke test's scope (same caveat as
# images/apisix-ingress-controller/README.md). Checked instead: the binary exists, ldflags
# injection actually reached the compiled binary (confirmed via the baked-in User-Agent
# string rather than a --version flag — upstream's main.go has none), --help exits
# cleanly (Go's flag package special-cases ErrHelp under ExitOnError to exit 0), and the
# run-as user.
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

echo "== ldflags injection (Version string baked into the binary) =="
# bci-micro has no grep (docs/image-authoring/base-os-policy.md), so the binary is
# extracted to the host and checked there instead of inside the guest.
#
# internal/util.Version (the ldflags target) is only ever consumed at *runtime*, inside
# fmt.Sprintf("%s/%s", USER_AGENT_NAME, Version) to build the outbound HTTP User-Agent —
# that concatenation does not exist as one static string in the compiled binary, so this
# checks for the injected value on its own rather than the concatenated form.
CCID="$(docker create --platform "$PLATFORM" "$TAG")"
WORK="$(mktemp -d)"
trap 'docker rm -f "$CCID" >/dev/null 2>&1; rm -rf "$WORK"' EXIT
docker cp "$CCID:/manager" "$WORK/manager" >/dev/null
grep -qa -- "$APP_VERSION" "$WORK/manager" || {
  echo "FAIL: binary does not contain the injected version string ($APP_VERSION) — check the ldflags injection"
  exit 1
}
echo "   found injected version string: $APP_VERSION"

echo "== --help smoke test (Go flag package, exits 0 on ErrHelp; no Kubernetes API contacted) =="
set +e
docker run --rm -i --platform "$PLATFORM" --entrypoint /manager "$TAG" --help >/tmp/help.out 2>&1
HELP_RC=$?
set -e
sed 's/^/   /' /tmp/help.out
[ "$HELP_RC" -eq 0 ] || { echo "FAIL: --help exited $HELP_RC, expected 0"; exit 1; }
case "$(cat /tmp/help.out)" in
  *-leader-elect*) ;;
  *) echo "FAIL: --help output did not list the expected flags"; exit 1 ;;
esac
echo "   exited 0 with flag usage, as expected"

echo "VERIFY-OK"
