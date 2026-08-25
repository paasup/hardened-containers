#!/usr/bin/env bash
# Functional verification for the keycloak image — runs on the host under bash
# (build-hardened-image.sh invokes it as
# `env TAG=... PLATFORM=... <every build.env variable> bash verify.sh`).
#
# Printing VERIFY-OK on the last line means it passed.
#
# What is checked
#   1. The shell tools kc.sh depends on (sed, grep, readlink, dirname, uname) and java 21
#   2. The locale (en_US.UTF-8) and timezone (TZ=Asia/Seoul)
#   3. The internal version of each overlaid jar (META-INF/maven/**/pom.properties) —
#      filenames are preserved, so this is checked by content
#   4. That bin/client was removed
#   5. A real startup — realm creation and admin token issuance
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"
KEYCLOAK_VERSION="${KEYCLOAK_VERSION:?must be passed from build.env}"
NETTY_OLD="${NETTY_OLD:?}"     ; NETTY_VERSION="${NETTY_VERSION:?}"
JACKSON_OLD="${JACKSON_OLD:?}" ; JACKSON_VERSION="${JACKSON_VERSION:?}"
PGJDBC_OLD="${PGJDBC_OLD:?}"   ; PGJDBC_VERSION="${PGJDBC_VERSION:?}"
MICROMETER_OLD="${MICROMETER_OLD:?}" ; MICROMETER_VERSION="${MICROMETER_VERSION:?}"

WORK="$(mktemp -d)"
CID=""
CCID=""
cleanup() {
  [ -n "$CID" ]  && docker rm -f "$CID"  >/dev/null 2>&1 || true
  [ -n "$CCID" ] && docker rm -f "$CCID" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

LIBDIR=/opt/keycloak/lib/lib/main

# ------------------------------------------------------------------ steps 1-2 and 4
docker run --rm -i --platform "$PLATFORM" -e TZ=Asia/Seoul \
  -e NETTY_OLD="$NETTY_OLD" --entrypoint sh "$TAG" <<'GUEST'
set -e
LIB=/opt/keycloak/lib/lib/main

echo "== the shell tools kc.sh uses =="
for b in sh bash sed grep readlink dirname uname java; do
  p=$(command -v "$b") || { echo "FAIL: $b not found on PATH"; exit 1; }
  echo "   $b -> $p"
done

echo "== java 21 =="
VER="$(java -version 2>&1 | head -1)"
echo "   $VER"
case "$VER" in
  *'"21'*) ;;
  *) echo "FAIL: this is not java 21"; exit 1 ;;
esac

echo "== locale / timezone =="
CHARMAP="$(locale charmap 2>/dev/null || echo '?')"
echo "   LANG=$LANG charmap=$CHARMAP"
[ "$CHARMAP" = "UTF-8" ] || { echo "FAIL: the en_US.UTF-8 locale is missing (check glibc-locale-base)"; exit 1; }
TZNAME="$(date +%Z)"
echo "   TZ=Asia/Seoul -> $TZNAME"
[ "$TZNAME" = "KST" ] || { echo "FAIL: tzdata does not know Asia/Seoul (got: $TZNAME)"; exit 1; }

echo "== confirming bin/client was removed =="
# An uber-jar that shades jackson, so jar replacement cannot fix it — removed entirely.
if [ -e /opt/keycloak/bin/client ]; then
  echo "FAIL: bin/client is still present — the removal step in overlay-jars.sh did not run"; exit 1
fi
echo "   absent (as expected)"

echo "== distribution layout =="
[ -d "$LIB" ] || { echo "FAIL: $LIB is missing"; exit 1; }
n=0; for f in "$LIB"/io.netty.*-"$NETTY_OLD"*.jar; do [ -e "$f" ] && n=$((n+1)); done
echo "   ${n} netty jar files (preserved filenames are expected — contents verified on the host)"
[ "$n" -gt 0 ] || { echo "FAIL: there are no netty jars"; exit 1; }
GUEST

# ------------------------------------------------------------------ step 3
# By design the filenames are preserved, so they cannot tell you whether the replacement
# happened. The jars are copied out and their internal pom.properties is read — the same
# basis trivy uses to determine a version. (Checked with the host's python3 so unzip need
#  not be added to the guest; build-hardened-image.sh already requires python3.)
echo "== verifying overlaid jar contents (metadata inside the jar) =="
CCID="$(docker create --platform "$PLATFORM" "$TAG")"

check_jar() {   # $1 = filename inside the container, $2 = expected version
  local name="$1" want="$2" got
  docker cp "$CCID:$LIBDIR/$name" "$WORK/$name" >/dev/null
  got="$(python3 - "$WORK/$name" <<'PY'
import sys, zipfile, re
# First choice: META-INF/maven/**/pom.properties (netty, jackson, and most others)
# Second choice: Bundle-Version / Implementation-Version in MANIFEST.MF
#        (measured: pgjdbc ships no pom.properties and uses only the OSGi Bundle-Version)
with zipfile.ZipFile(sys.argv[1]) as z:
    for n in z.namelist():
        if re.fullmatch(r'META-INF/maven/[^/]+/[^/]+/pom\.properties', n):
            for line in z.read(n).decode().splitlines():
                if line.startswith('version='):
                    print(line.split('=', 1)[1].strip()); sys.exit(0)
    try:
        mf = z.read('META-INF/MANIFEST.MF').decode('utf-8', 'replace')
    except KeyError:
        print('NOT-FOUND'); sys.exit(0)
    # MANIFEST wraps at 72 bytes and continues on the next line with a one-space indent
    mf = mf.replace('\r\n', '\n').replace('\n ', '')
    for key in ('Bundle-Version', 'Implementation-Version'):
        m = re.search(rf'^{key}:\s*(\S+)\s*$', mf, re.M)
        if m:
            print(m.group(1)); sys.exit(0)
print('NOT-FOUND')
PY
)"
  if [ "$got" != "$want" ]; then
    echo "FAIL: the internal version of $name is '$got' (expected '$want') — the overlay was not applied"
    exit 1
  fi
  echo "   $name -> embedded version=$got"
}

check_jar "io.netty.netty-codec-http-${NETTY_OLD}.jar"                          "$NETTY_VERSION"
check_jar "io.netty.netty-codec-${NETTY_OLD}.jar"                               "$NETTY_VERSION"
check_jar "com.fasterxml.jackson.core.jackson-databind-${JACKSON_OLD}.jar"      "$JACKSON_VERSION"
check_jar "com.fasterxml.jackson.core.jackson-core-${JACKSON_OLD}.jar"          "$JACKSON_VERSION"
check_jar "org.postgresql.postgresql-${PGJDBC_OLD}.jar"                         "$PGJDBC_VERSION"
check_jar "io.micrometer.micrometer-core-${MICROMETER_OLD}.jar"                 "$MICROMETER_VERSION"

docker rm -f "$CCID" >/dev/null 2>&1 || true
CCID=""

# ------------------------------------------------------------------ step 5
echo "== real startup (start-dev, the built-in dev-file DB) =="
ADMIN_USER="verify-admin"
ADMIN_PASS="verify-$$-$RANDOM"

# Let the kernel pick the host port (avoids fixed-port collisions on CI runners).
CID="$(docker run -d --platform "$PLATFORM" \
  -p 127.0.0.1::8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME="$ADMIN_USER" \
  -e KC_BOOTSTRAP_ADMIN_PASSWORD="$ADMIN_PASS" \
  -e TZ=Asia/Seoul \
  "$TAG" start-dev)"
HOSTPORT="$(docker port "$CID" 8080/tcp | head -1 | rev | cut -d: -f1 | rev)"
BASE="http://127.0.0.1:${HOSTPORT}"
echo "   container=${CID:0:12}  base=$BASE"

# Why the default is generous: running linux/amd64 under QEMU on an arm64 host takes ~100
# seconds for Quarkus augmentation alone, and full startup can exceed ~300 seconds — 180 could
# cut off during liquibase schema creation. On a native amd64 runner it finishes in one to two
# minutes, and the loop exits as soon as it is up, so a large value costs nothing.
BOOT_TIMEOUT="${VERIFY_BOOT_TIMEOUT:-600}"
echo "== waiting for the master realm to come up (up to ${BOOT_TIMEOUT}s) =="
ok=0
for i in $(seq 1 "$BOOT_TIMEOUT"); do
  if curl -fsS "$BASE/realms/master/.well-known/openid-configuration" >"$WORK/disco.json" 2>/dev/null; then
    ok=1; echo "   responded after ${i}s"; break
  fi
  if [ -z "$(docker ps -q --filter "id=$CID")" ]; then
    echo "FAIL: the container died"; docker logs "$CID" 2>&1 | tail -40; exit 1
  fi
  # Log progress every 30 seconds — so the logs distinguish "slow" from "stuck".
  if [ $((i % 30)) -eq 0 ]; then
    echo "   ...${i}s: $(docker logs "$CID" 2>&1 | tail -1 | cut -c1-140)"
  fi
  sleep 1
done
if [ "$ok" != 1 ]; then
  echo "FAIL: OIDC discovery did not respond within ${BOOT_TIMEOUT} seconds"
  docker logs "$CID" 2>&1 | tail -60
  exit 1
fi
ISSUER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["issuer"])' "$WORK/disco.json")"
echo "   issuer=$ISSUER"

echo "== issuing an admin token (bootstrap account + DB migration check) =="
curl -fsS -X POST "$BASE/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "grant_type=password" \
  -d "username=$ADMIN_USER" --data-urlencode "password=$ADMIN_PASS" \
  > "$WORK/token.json"
python3 - "$WORK/token.json" <<'PY'
import json, sys
tok = json.load(open(sys.argv[1]))
assert tok.get("access_token"), f"no access_token: {tok}"
print(f"   access_token issued OK (expires_in={tok.get('expires_in')}s)")
PY

echo "== calling the admin REST API (realms list) =="
AT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["access_token"])' "$WORK/token.json")"
curl -fsS -H "Authorization: Bearer $AT" "$BASE/admin/realms" > "$WORK/realms.json"
python3 - "$WORK/realms.json" <<'PY'
import json, sys
realms = [r["realm"] for r in json.load(open(sys.argv[1]))]
assert "master" in realms, f"no master realm: {realms}"
print(f"   realms={realms}")
PY

# Evidence that the netty/jackson overlay works in the real HTTP stack — every request above
# was handled on Quarkus (netty) and serialised to JSON by jackson.
echo "VERIFY-OK"
