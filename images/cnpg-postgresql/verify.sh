#!/usr/bin/env bash
# Functional verification for the CNPG PostgreSQL image — runs on the host under bash
# (build-hardened-image.sh invokes it as
# `env TAG=... PLATFORM=... PG_MAJOR=... bash verify.sh`). This image has a shell (`/bin/sh`),
# so the actual checks are performed by a guest shell script inside the container.
#
# Printing VERIFY-OK on the last line means it passed. build-hardened-image.sh judges by that.
#
# What gets verified differs per image, so this file lives in the image's directory.
#
# What CNPG requires of the image (per the operator's source)
#   - uid 26 — anything else breaks the permissions on operator-managed volumes
#   - initdb, pg_ctl, and postgres must be findable on PATH (paths are not hardcoded)
#   - the extensions the chart declares must actually be creatable
set -e

TAG="${TAG:?TAG environment variable is required}"
PLATFORM="${PLATFORM:-linux/amd64}"
PG_MAJOR="${PG_MAJOR:?PG_MAJOR environment variable is required (build-hardened-image.sh passes it from build.env)}"

docker run --rm -i --platform "$PLATFORM" -e PG_MAJOR="$PG_MAJOR" --entrypoint sh "$TAG" <<'GUEST'
set -e

export PGDATA=/tmp/_verify
export PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:/usr/pgsql-${PG_MAJOR}/bin:$PATH"

echo "== run-as user =="
uid=$(id -u)
gid=$(id -g)
gname=$(id -gn 2>/dev/null || echo '?')
echo "   uid=$uid gid=$gid($gname)"
[ "$uid" = "26" ] || { echo "FAIL: uid=$uid — CNPG requires 26"; exit 1; }

# gid only warns rather than failing. Depending on the base OS, gid 26 may already be taken by
# another group (`tape` on Ubuntu, for instance) — it still works, but the hygiene problem
# remains.
if [ "$gname" != "postgres" ]; then
  echo "   WARN: the group name for gid $gid is '$gname' (not postgres)"
fi

echo "== locating binaries (via PATH) =="
for b in initdb pg_ctl postgres psql; do
  p=$(command -v "$b") || { echo "FAIL: $b not found on PATH"; exit 1; }
  echo "   $b → $p"
done

echo "== initdb + startup =="
initdb -D "$PGDATA" -A trust >/dev/null
pg_ctl -D "$PGDATA" -w start >/dev/null \
  -o "-c shared_preload_libraries=pgaudit,pg_stat_statements -c unix_socket_directories=/tmp"
psql -h /tmp -U postgres -Atc "SELECT version();" | sed 's/^/   /'

echo "== creating extensions =="
# The same list the chart (cnpg-cluster) declares through the Database CRD.
psql -h /tmp -U postgres -q -c \
  "CREATE EXTENSION pgaudit; CREATE EXTENSION vector; CREATE EXTENSION pg_stat_statements;"
psql -h /tmp -U postgres -Atc \
  "SELECT extname||' '||extversion FROM pg_extension ORDER BY 1;" | sed 's/^/   /'

echo "== libxml2 linkage (XML functions) =="
psql -h /tmp -U postgres -Atc \
  "SELECT xml_is_well_formed_document('<a>x</a>');" | sed 's/^/   /'

echo "== locales =="
# Upstream standard includes all locales. Fewer of them changes sorting and comparison behaviour.
n=$(psql -h /tmp -U postgres -Atc "SELECT count(*) FROM pg_collation;")
echo "   pg_collation: ${n}"
[ "$n" -gt 100 ] || echo "   WARN: only ${n} collations — a locale package may be missing"

pg_ctl -D "$PGDATA" -w stop >/dev/null
echo "VERIFY-OK"
GUEST
