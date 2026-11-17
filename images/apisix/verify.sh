#!/usr/bin/env bash
# Functional verification for the apisix image — runs on the host under bash
# (build-hardened-image.sh invokes it as `env TAG=... PLATFORM=... <build.env vars> bash verify.sh`).
#
# What it checks, in order:
#   1. `apisix version` reports the version this build claims (read from APP_VERSION, never
#      hardcoded — a literal here silently outlives the next version bump)
#   1b. nginx and the bundled openssl CLI are both built with, and load at run time, the
#      pinned OPENSSL_VERSION (read from build.env) — not the base OS libopenssl3
#   2. `apisix init` + `nginx -t` produce a config nginx accepts
#   3. A real openresty worker starts, proving the compiled-in nginx modules load and the
#      Lua plugin set parses
#   4. An unrouted path returns 404 — the router really handled the request
#   5. A configured route returns its response — routing actually matches
#   6. Two plugins in different phases take effect on that route — the plugin pipeline runs
#
# Why 5 and 6 exist: loading is not behaviour. A minor upgrade can leave every module
# loading cleanly while changing what plugins do, and a check that only asks for a 404 on
# an empty config cannot see that. `mocking` needs no upstream (it answers in the access
# phase), so this stays a self-contained smoke test with no second container to serve it.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"
APP_VERSION="${APP_VERSION:?must be passed from build.env}"
OPENSSL_VERSION="${OPENSSL_VERSION:?must be passed from build.env}"

echo "== apisix version (expecting $APP_VERSION) =="
OUT="$(docker run --rm --platform "$PLATFORM" --entrypoint sh "$TAG" -c '
export PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin
/usr/bin/apisix version
')"
echo "   $OUT"
case "$OUT" in
  *"$APP_VERSION"*) ;;
  *) echo "FAIL: apisix version output does not contain $APP_VERSION"; exit 1 ;;
esac

echo "== OpenSSL is the pinned build (expecting $OPENSSL_VERSION) =="
# nginx -V prints "built with OpenSSL <ver> ..." and, only when the library it loads at run
# time differs, appends "(running with OpenSSL <other>)". Both must be ours: a match on the
# build line alone would pass an nginx that resolved the base OS libssl at run time.
# OpenSSL 3's `openssl version` always prints "<built> (Library: <loaded>)", so both halves
# are compared — the CLI shipped in openssl3/bin once loaded the system libopenssl3 that way.
SSL_OUT="$(docker run --rm --platform "$PLATFORM" --entrypoint sh "$TAG" -c '
/usr/local/openresty/nginx/sbin/nginx -V 2>&1 | grep "^built with OpenSSL"
echo "--- cli"
/usr/local/openresty/openssl3/bin/openssl version
')"
printf '%s\n' "$SSL_OUT" | sed 's/^/   /'
NGINX_SSL="$(printf '%s\n' "$SSL_OUT" | grep '^built with OpenSSL' || true)"
case "$NGINX_SSL" in
  "built with OpenSSL $OPENSSL_VERSION "*) ;;
  *) echo "FAIL: nginx is not built with OpenSSL $OPENSSL_VERSION"; exit 1 ;;
esac
case "$NGINX_SSL" in
  *"running with"*) echo "FAIL: nginx loads a different OpenSSL at run time than it was built with"; exit 1 ;;
esac
CLI_SSL="$(printf '%s\n' "$SSL_OUT" | sed -n '/^--- cli$/{n;p;}')"
case "$CLI_SSL" in
  "OpenSSL $OPENSSL_VERSION "*) ;;
  *) echo "FAIL: the bundled openssl CLI was not built from OpenSSL $OPENSSL_VERSION"; exit 1 ;;
esac
case "$CLI_SSL" in
  *"(Library: OpenSSL $OPENSSL_VERSION "*) ;;
  *) echo "FAIL: the bundled openssl CLI loads a libcrypto other than $OPENSSL_VERSION"; exit 1 ;;
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
# One route with two plugins in different phases: mocking answers in the access phase (so
# no upstream is needed) and response-rewrite adds a header in the header-filter phase.
# Together they prove the route matched and the plugin pipeline ran end to end.
cat > conf/apisix.yaml <<EOF
routes:
  - uri: /verify-route
    plugins:
      mocking:
        response_status: 200
        content_type: text/plain
        response_example: "verify-mocking-ok"
      response-rewrite:
        headers:
          set:
            X-Verify-Chain: chain-ok
#END
EOF
/usr/bin/apisix init >/tmp/init.log 2>&1
/usr/local/openresty/nginx/sbin/nginx -p /usr/local/apisix -t >>/tmp/init.log 2>&1
exec /usr/local/openresty/bin/openresty -p /usr/local/apisix -g "daemon off;"
' >/dev/null
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT

# Every request below runs curl in the apisix container's own network namespace.
curl_in() {   # $@ = curl arguments
  docker run --rm --platform "$PLATFORM" --network "container:$CONTAINER" curlimages/curl:latest "$@" 2>/dev/null || true
}

echo "== waiting for an HTTP response (up to 15s) =="
# curl prints "000" for %{http_code} even when the connection itself fails — that is not an
# empty string, so `[ -n "$CODE" ]` alone would mistake a failed connection for success.
# "000" is treated as a failure explicitly.
ok=0
for i in $(seq 1 15); do
  CODE="$(curl_in -s -o /dev/null -w '%{http_code}' -m 2 http://127.0.0.1:9080/)"
  if [ -n "$CODE" ] && [ "$CODE" != "000" ]; then ok=1; break; fi
  sleep 1
done
if [ "$ok" != "1" ]; then
  echo "FAIL: port 9080 gave no valid HTTP response within 15 seconds (last attempt: '${CODE:-none}')"
  docker logs "$CONTAINER" 2>&1 | tail -40
  exit 1
fi
echo "   HTTP $CODE (404 is expected on an unrouted path — it means the nginx/APISIX router really handled the request)"
case "$CODE" in
  404) ;;
  *) echo "FAIL: got $CODE instead of the expected 404 on an unrouted path — check the logs"; docker logs "$CONTAINER" 2>&1 | tail -40; exit 1 ;;
esac

echo "== configured route responds (routing + access-phase plugin) =="
ROUTE_BODY="$(curl_in -s -m 5 http://127.0.0.1:9080/verify-route)"
echo "   body: ${ROUTE_BODY:-<empty>}"
case "$ROUTE_BODY" in
  *verify-mocking-ok*) ;;
  *) echo "FAIL: /verify-route did not return the mocked body — the route did not match, or the plugin did not run"
     docker logs "$CONTAINER" 2>&1 | tail -40; exit 1 ;;
esac

echo "== plugin pipeline reaches the header-filter phase =="
ROUTE_HDRS="$(curl_in -s -D - -o /dev/null -m 5 http://127.0.0.1:9080/verify-route)"
if ! printf '%s' "$ROUTE_HDRS" | grep -qi '^X-Verify-Chain: *chain-ok'; then
  echo "FAIL: response-rewrite did not set X-Verify-Chain — the plugin pipeline stopped after the access phase"
  printf '%s\n' "$ROUTE_HDRS" | sed 's/^/     /'
  docker logs "$CONTAINER" 2>&1 | tail -40
  exit 1
fi
echo "   X-Verify-Chain: chain-ok"

echo "VERIFY-OK"
