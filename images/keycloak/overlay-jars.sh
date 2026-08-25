#!/usr/bin/env bash
# Replaces the vulnerable jars shipped inside the Keycloak distribution with fixed versions.
# Runs only in suse.Dockerfile's builder stage (never used directly on the host).
#
# Why this is needed
#   12 of the 17 blocking CVEs are jars in /opt/keycloak/lib/lib/main/. Those versions are
#   pinned by the Quarkus 3.33.2.1 BOM, so neither a newer keycloak tag nor a base OS swap
#   changes them. This is the same kind of dependency override as the etcd image's
#   `go.work replace`.
#
# Why the filenames are preserved
#   A Quarkus fast-jar distribution references jar filenames directly through the Class-Path in
#   lib/quarkus-run.jar. Renaming them breaks the classpath. Keeping the name and changing only
#   the contents means:
#   - runtime: the classpath keeps working
#   - SBOM: trivy reads META-INF/maven/**/pom.properties inside the jar, so the new version is
#           reported accurately (this is not disguising a version through the filename — the
#           contents really are the new version)
#
# Integrity
#   The .sha1 from Maven Central is fetched alongside and verified. A mismatch exits immediately.
#
# Failure condition
#   If any spec finds no file at its OLD version, the script fails. That prevents the state
#   where upstream bumped a dependency and this script silently does nothing (leaving the CVE
#   in place while the build succeeds).
set -euo pipefail

KC_HOME="${1:?usage: overlay-jars.sh <KEYCLOAK_HOME>}"
LIB="$KC_HOME/lib/lib/main"
M2="${M2_BASE:-https://repo1.maven.org/maven2}"

[ -d "$LIB" ] || { echo "FAIL: $LIB is missing — check whether the distribution layout changed"; exit 1; }

: "${NETTY_OLD:?}"      "${NETTY_VERSION:?}"
: "${JACKSON_OLD:?}"    "${JACKSON_VERSION:?}"
: "${PGJDBC_OLD:?}"     "${PGJDBC_VERSION:?}"
: "${MICROMETER_OLD:?}" "${MICROMETER_VERSION:?}"

# groupId (filename prefix) | groupPath (Maven path) | artifact filter | OLD | NEW
#   An artifact filter of '*' targets every jar with that groupId at the OLD version.
SPECS=(
  "io.netty|io/netty|*|${NETTY_OLD}|${NETTY_VERSION}"
  "com.fasterxml.jackson.core|com/fasterxml/jackson/core|jackson-core|${JACKSON_OLD}|${JACKSON_VERSION}"
  "com.fasterxml.jackson.core|com/fasterxml/jackson/core|jackson-databind|${JACKSON_OLD}|${JACKSON_VERSION}"
  "org.postgresql|org/postgresql|postgresql|${PGJDBC_OLD}|${PGJDBC_VERSION}"
  "io.micrometer|io/micrometer|*|${MICROMETER_OLD}|${MICROMETER_VERSION}"
)

fetch() {   # $1 = url, $2 = output path
  local url="$1" out="$2" want got
  curl -fsSL --retry 3 --retry-delay 2 -o "$out" "$url"
  want="$(curl -fsSL --retry 3 --retry-delay 2 "$url.sha1" | tr -d '[:space:]')"
  got="$(sha1sum "$out" | cut -d' ' -f1)"
  [ "$want" = "$got" ] || { echo "FAIL: sha1 mismatch for $url (expected $want, got $got)"; exit 1; }
}

total=0
for spec in "${SPECS[@]}"; do
  IFS='|' read -r gid gpath filter old new <<<"$spec"

  matched=0
  for f in "$LIB/$gid."*"-$old"*.jar; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"

    rest="${base#"$gid."}"          # netty-codec-http-4.1.135.Final.jar
    rest="${rest%.jar}"             # netty-codec-http-4.1.135.Final
    artifact="${rest%%-"$old"*}"    # netty-codec-http
    tail="${rest#*-"$old"}"         # '' or -linux-x86_64 (a classifier)

    if [ "$filter" != "*" ] && [ "$artifact" != "$filter" ]; then continue; fi

    url="$M2/$gpath/$artifact/$new/$artifact-$new$tail.jar"
    fetch "$url" "$f.new"
    mv "$f.new" "$f"                # filename preserved — only the contents are replaced
    echo "overlay: $base  <=  $artifact-$new$tail.jar"
    matched=$((matched + 1))
  done

  if [ "$matched" -eq 0 ]; then
    echo "FAIL: no jar matches spec '$gid/$filter@$old'."
    echo "      Upstream may already have bumped the version — re-check *_OLD in build.env,"
    echo "      and if it is resolved, remove that spec (leaving it means the build succeeds"
    echo "      with the CVE still present)."
    exit 1
  fi
  total=$((total + matched))
done

echo "overlay: replaced ${total} jars"

# keycloak-admin-cli is an uber-jar that shades jackson, so jar replacement cannot fix it
# (measured from the SBOM: the FilePath of jackson-databind@2.21.2 is
# bin/client/keycloak-admin-cli-*.jar). Being a standalone CLI (kcadm.sh/kcreg.sh) that the
# server JVM never loads, it is removed from the hardened image.
# This is the only functional difference from upstream — documented in README.md.
if [ -d "$KC_HOME/bin/client" ]; then
  rm -rf "$KC_HOME/bin/client"
  echo "removed: bin/client (kcadm/kcreg — jackson shaded uber-jar, unused by the server runtime)"
else
  echo "FAIL: bin/client is missing — the distribution layout changed. Re-check the removal assumption"
  exit 1
fi
