#!/usr/bin/env bash
# Functional verification for the etcd image — runs on the host under bash
# (build-hardened-image.sh invokes it as
# `env TAG=... PLATFORM=... SOURCE_COMMIT=... XTEXT_FIX_VERSION=... bash verify.sh`).
# The final base (bci-micro) has bash and coreutils, so the guest-shell pattern is used.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
#
# What this image is required to do
#   - /usr/local/bin/etcd, etcdctl, and etcdutl must be on PATH (the chart's startup,
#     liveness, and readiness probes hardcode /usr/local/bin/etcdctl)
#   - It must start as a single node and complete a real put/get round trip — an image that
#     does not work is worthless, even at zero gate findings
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"
SOURCE_COMMIT="${SOURCE_COMMIT:?SOURCE_COMMIT environment variable is required (build-hardened-image.sh passes it from build.env)}"

docker run --rm -i --platform "$PLATFORM" -e SOURCE_COMMIT="$SOURCE_COMMIT" --entrypoint sh "$TAG" <<'GUEST'
set -e

echo "== locating binaries (via PATH) =="
for b in etcd etcdctl etcdutl; do
  p=$(command -v "$b") || { echo "FAIL: $b not found on PATH"; exit 1; }
  echo "   $b -> $p"
done

echo "== version (confirming the pinned commit) =="
# There is no sed — bci-micro has bash and coreutils, but sed is a separate package and is
# absent. Indent with a pure shell loop instead.
OUT="$(etcd --version)"
while IFS= read -r line; do echo "   $line"; done <<EOF
$OUT
EOF
case "$OUT" in
  *"$SOURCE_COMMIT"*) ;;
  *) echo "FAIL: version output lacks the pinned commit ($SOURCE_COMMIT) — check the ldflags injection"; exit 1 ;;
esac

echo "== single-node startup =="
export ETCD_DATA_DIR=/tmp/verify-data
export ETCD_LISTEN_CLIENT_URLS=http://127.0.0.1:2379
export ETCD_ADVERTISE_CLIENT_URLS=http://127.0.0.1:2379
export ETCD_LISTEN_PEER_URLS=http://127.0.0.1:12380
export ETCD_INITIAL_ADVERTISE_PEER_URLS=http://127.0.0.1:12380
export ETCD_INITIAL_CLUSTER=default=http://127.0.0.1:12380
export ETCD_NAME=default
etcd >/tmp/etcd-verify.log 2>&1 &
ETCD_PID=$!

trap 'kill $ETCD_PID 2>/dev/null || true' EXIT

echo "== waiting for health (up to 30s) =="
ok=0
for i in $(seq 1 30); do
  if etcdctl endpoint health >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
if [ "$ok" != "1" ]; then
  echo "FAIL: etcd did not become healthy within 30 seconds"
  cat /tmp/etcd-verify.log
  exit 1
fi
HEALTH="$(etcdctl endpoint health)"
while IFS= read -r line; do echo "   $line"; done <<EOF
$HEALTH
EOF

echo "== put/get round trip =="
etcdctl put smoke-test ok >/dev/null
answer="$(etcdctl get smoke-test --print-value-only)"
[ "$answer" = "ok" ] || { echo "FAIL: unexpected get response (got: '$answer')"; exit 1; }
echo "   get smoke-test => '$answer'"

kill "$ETCD_PID" 2>/dev/null || true
trap - EXIT

echo "VERIFY-OK"
GUEST
