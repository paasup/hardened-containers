#!/usr/bin/env bash
# Functional verification for the adc image. Why it runs on the host under bash:
# see "verify.sh runs on the host, under bash" in image-authoring/README.md.
#
# Most adc commands (dump/diff/sync) require a real APISIX/API7 backend, so that integration is
# outside this smoke test's scope — only what can be checked without a backend is covered.
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"

echo "== run-as user (nonroot) =="
USER_CFG="$(docker inspect --format '{{.Config.User}}' "$TAG")"
[ "$USER_CFG" = "adc" ] || { echo "FAIL: the image Config.User is not adc (actual: $USER_CFG)"; exit 1; }
echo "   Config.User=$USER_CFG"

docker run --rm -i --platform "$PLATFORM" --entrypoint sh "$TAG" <<'GUEST'
set -e

echo "== version =="
OUT="$(/usr/bin/node /adc/main.cjs --version)"
echo "   $OUT"
case "$OUT" in
  *0.29.0*) ;;
  *) echo "FAIL: version output does not contain 0.29.0"; exit 1 ;;
esac

echo "== --help smoke test (all that runs without a backend) =="
OUT="$(/usr/bin/node /adc/main.cjs --help)"
case "$OUT" in
  *"dump"*"diff"*"sync"*) ;;
  *) echo "FAIL: --help output lacks the expected commands (dump/diff/sync)"; exit 1 ;;
esac
echo "   dump/diff/sync commands present"

echo "VERIFY-OK"
GUEST
