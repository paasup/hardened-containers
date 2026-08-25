#!/usr/bin/env bash
# Functional verification for the apisix image — runs on the host under bash
# (build-hardened-image.sh invokes it as `env TAG=... PLATFORM=... bash verify.sh`). It checks
# `apisix version`, the nginx configuration syntax, and then starts a real nginx worker from a
# standalone configuration and confirms it answers an HTTP request.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"

echo "== apisix version =="
OUT="$(docker run --rm --platform "$PLATFORM" --entrypoint sh "$TAG" -c '
export PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin
/usr/bin/apisix version
')"
echo "   $OUT"
case "$OUT" in
  *3.17.0*) ;;
  *) echo "FAIL: apisix version output does not contain 3.17.0"; exit 1 ;;
esac

echo "== nginx configuration syntax check (init + nginx -t) =="
CONTAINER="verify-apisix-$$"
docker run -d --rm --platform "$PLATFORM" --name "$CONTAINER" --entrypoint sh "$TAG" -c '
export PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin
cd /usr/local/apisix
export APISIX_STAND_ALONE=true
cat > conf/config.yaml <<EOF
deployment:
  role: data_plane
  role_data_plane:
    config_provider: yaml
EOF
cat > conf/apisix.yaml <<EOF
routes:
#END
EOF
/usr/bin/apisix init >/tmp/init.log 2>&1
/usr/local/openresty/nginx/sbin/nginx -p /usr/local/apisix -t >>/tmp/init.log 2>&1
exec /usr/local/openresty/bin/openresty -p /usr/local/apisix -g "daemon off;"
' >/dev/null
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT

echo "== waiting for an HTTP response (up to 15s) =="
# curl prints "000" for %{http_code} even when the connection itself fails — that is not an
# empty string, so `[ -n "$CODE" ]` alone would mistake a failed connection for success.
# "000" is treated as a failure explicitly.
ok=0
for i in $(seq 1 15); do
  CODE="$(docker run --rm --platform "$PLATFORM" --network "container:$CONTAINER" curlimages/curl:latest \
            -s -o /dev/null -w '%{http_code}' -m 2 http://127.0.0.1:9080/ 2>/dev/null || true)"
  if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then ok=1; break; fi
  sleep 1
done
if [ "$ok" != "1" ]; then
  echo "FAIL: port 9080 gave no valid HTTP response within 15 seconds (last attempt: '${CODE:-none}')"
  docker logs "$CONTAINER" 2>&1 | tail -40
  exit 1
fi
echo "   HTTP $CODE (404 is expected with no routes — it means the nginx/APISIX router really handled the request)"
case "$CODE" in
  404) ;;
  *) echo "FAIL: got $CODE instead of the expected 404 (no routes) — check the logs"; docker logs "$CONTAINER" 2>&1 | tail -40; exit 1 ;;
esac

echo "VERIFY-OK"
