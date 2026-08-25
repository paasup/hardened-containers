#!/usr/bin/env bash
# =============================================================================
# build-hardened-image.sh
#   When an upstream image cannot meet the zero-CRITICAL/HIGH target, build and verify
#   an image based on the upstream Dockerfile with the base OS replaced and security
#   updates applied.
#
#   Runs build -> functional verification -> vulnerability scan -> gate verdict in one go.
#   If functional verification fails it never reaches the scan (an image with zero CVEs
#   that does not work is worthless).
#
# Usage:
#   IMAGE=<image> BASE_OS=<variant> bash scripts/build/build-hardened-image.sh <OUT_DIR> [TAG]
#   REGISTRY=<your-registry> IMAGE=<image> BASE_OS=<variant> bash scripts/build/build-hardened-image.sh <OUT_DIR>
#
# The build definition is not in this script. It sources images/<IMAGE>/<BASE_OS>.build.env
# for the base, versions, extensions, and build-arg list, and delegates functional
# verification to images/<IMAGE>/verify.sh.
# (Hardcoded verification breaks as soon as there is more than one base OS.)
#
# One script handles every image type — see rule 1 in docs/image-authoring/README.md.
# Variables declared in build.env are passed straight through to verify.sh (see below).
#
# Environment variables:
#   IMAGE          image directory name    (required — images/<IMAGE>/. no default)
#   BASE_OS        build variant filename  (required — images/<IMAGE>/<BASE_OS>.build.env)
#   PLATFORM       build platform          (default linux/amd64)
#   REGISTRY       registry to push to     (unset = no push. TAG is derived from it too)
#   IMAGE_REPO     repository name within the registry (default $IMAGE)
#   SEVERITY       scan severities         (default all — filtering makes the verdict impossible)
#   CVE_EXCEPTIONS path to the approved-exceptions JSON (default <repo>/cve-exceptions.json.
#                  Pass `none` to judge with no exceptions at all — silently continuing
#                  when the file is missing is not allowed, because a legitimate image
#                  would then be blocked without explanation)
#   build.env values can be overridden by an environment variable of the same name
#                  (e.g. APP_VERSION=18.5)
#
# Outputs (OUT_DIR):
#   build.log                 build log
#   verify.log                functional verification log
#   push.log                  push log (only when REGISTRY is set)
#   sbom/<tag>.cdx.json       CycloneDX SBOM
#   trivy-reports/<tag>.json  all-severity scan result (+ CoverageProbe)
#   cve-gate.md · cve-gate.json  gate verdict summary
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_DIR="$REPO_ROOT/scripts/gate"

OUT_DIR="${1:?usage: build-hardened-image.sh <OUT_DIR> [TAG]}"
IMAGE="${IMAGE:?IMAGE is required — the images/<IMAGE>/ directory name}"
BASE_OS="${BASE_OS:?BASE_OS is required — the images/<IMAGE>/<BASE_OS>.build.env filename}"
IMAGE_DIR="$REPO_ROOT/images/$IMAGE"
ENV_FILE="$IMAGE_DIR/$BASE_OS.build.env"

[ -d "$IMAGE_DIR" ] || { echo "::error::no such image directory: $IMAGE_DIR"; exit 2; }
[ -f "$ENV_FILE" ]  || { echo "::error::no such build.env: $ENV_FILE"; exit 2; }

# build.env holds **defaults**. It must not overwrite an already-set environment variable.
# (Plain `. "$ENV_FILE"` would ignore anything specified externally.)
# The names read are also recorded in ENV_FILE_VARS so that everything written in
# build.env can be passed wholesale to verify.sh as environment variables — that way this
# script never needs to know which values a given image requires.
ENV_FILE_VARS=()
while IFS= read -r line; do
  case "$line" in ''|'#'*|[[:space:]]*) continue ;; esac
  name="${line%%=*}"
  case "$name" in ''|*[!A-Za-z0-9_]*) continue ;; esac
  ENV_FILE_VARS+=("$name")
  if [ -z "${!name+set}" ]; then
    eval "$line"
  else
    echo "   (external value wins: $name=${!name})"
  fi
done < "$ENV_FILE"

PLATFORM="${PLATFORM:-linux/amd64}"
DOCKERFILE="$IMAGE_DIR/${DOCKERFILE:?build.env has no DOCKERFILE}"
TARGET="${TARGET:-patched}"
: "${BUILD_ARGS:?build.env has no BUILD_ARGS}"
# APP_VERSION is the only required value that is independent of image type — it is used
# both for the tag prefix and by verify.sh. Values meaningful only to one image (PG_MAJOR
# and the like) are not required here; passing ENV_FILE_VARS through is enough.
: "${APP_VERSION:?build.env has no APP_VERSION}"

# The tag carries the build date. Even at the same app version, the result of base
# updates differs from one point in time to another.
# The tag is derived from REGISTRY so that where we push and where the tag points cannot
# diverge.
BUILD_DATE="$(date -u +%Y%m%d)"
APP_VER="$APP_VERSION"
IMAGE_REPO="${IMAGE_REPO:-$IMAGE}"
DEFAULT_TAG="${APP_VER}-${TAG_SLUG:-$BASE_OS}-hardened-${BUILD_DATE}"
if [ -n "${REGISTRY:-}" ]; then
  TAG="${2:-${REGISTRY%/}/${IMAGE_REPO}:${DEFAULT_TAG}}"
else
  # Local build with no push. A name without a registry cannot even be pushed.
  TAG="${2:-localhost/${IMAGE_REPO}:${DEFAULT_TAG}}"
fi

mkdir -p "$OUT_DIR/sbom" "$OUT_DIR/trivy-reports"
STEM="$(echo "$TAG" | tr ':/' '__')"

# Only the names build.env declares are passed as --build-arg. The argument set differs
# per base OS (deb-family: EXTENSIONS/STANDARD_ADDITIONAL_…; suse: SLE_REPO/PGDG_KEY).
BA=()
for name in $BUILD_ARGS; do
  BA+=(--build-arg "$name=${!name-}")
done

echo "== build =="
echo "   image=$IMAGE  base_os=$BASE_OS  target=$TARGET  platform=$PLATFORM"
echo "   dockerfile=${DOCKERFILE#$REPO_ROOT/}"
echo "   tag=$TAG"
# --pull is explicit. Without it a stale local cache on the runner can be used, silently
# breaking the assumption scheduled rebuilds rely on: that the base image is fetched fresh
# every time.
if ! docker build --pull --platform "$PLATFORM" -f "$DOCKERFILE" --target "$TARGET" \
      "${BA[@]}" -t "$TAG" "$IMAGE_DIR" > "$OUT_DIR/build.log" 2>&1; then
  echo "::error::build failed — see $OUT_DIR/build.log"; tail -20 "$OUT_DIR/build.log"; exit 1
fi
echo "   OK"

echo "== functional verification =="
# The image directory owns what gets verified. Hardcoding it here breaks as variants grow.
#
# verify.sh **runs on the host under bash** and issues whatever `docker run` it needs
# itself (rather than injecting a script into a guest shell over stdin). Some final
# images have no shell at all, as with distroless — a host-side script can still use a
# guest shell where one exists (`docker run --entrypoint sh ... <<'EOF'`) and can run a
# binary directly where one does not (`docker run --entrypoint <binary>`), so running on
# the host is the superset.
VERIFY_SH="$IMAGE_DIR/verify.sh"
[ -f "$VERIFY_SH" ] || { echo "::error::no such verify.sh: $VERIFY_SH"; exit 2; }
# Pass every variable read from build.env through as an environment variable — this
# script then never needs to know what verify.sh requires. TAG and PLATFORM are always
# passed, as the target under test and the platform to run it on.
VERIFY_ENV_ASSIGN=(TAG="$TAG" PLATFORM="$PLATFORM")
for name in "${ENV_FILE_VARS[@]}"; do
  VERIFY_ENV_ASSIGN+=("$name=${!name-}")
done
# NOTE: VERIFY-OK and WARN: are a string contract with every images/*/verify.sh.
# Do not translate or reword them.
if ! env "${VERIFY_ENV_ASSIGN[@]}" bash "$VERIFY_SH" > "$OUT_DIR/verify.log" 2>&1 \
   || ! grep -q VERIFY-OK "$OUT_DIR/verify.log"; then
  echo "::error::functional verification failed — see $OUT_DIR/verify.log"; cat "$OUT_DIR/verify.log"; exit 1
fi
sed -n '1,40p' "$OUT_DIR/verify.log" | sed 's/^/   /'
grep -q 'WARN:' "$OUT_DIR/verify.log" && echo "   (warnings present — see verify.log)"

echo "== SBOM =="
docker save "$TAG" -o "$OUT_DIR/image.tar" 2>/dev/null
SBOM_FILE="$OUT_DIR/sbom/${STEM}.cdx.json"
trivy image --quiet --format cyclonedx --input "$OUT_DIR/image.tar" \
  > "$SBOM_FILE" 2>/dev/null
rm -f "$OUT_DIR/image.tar"
echo "   components: $(python3 -c "import json;print(len(json.load(open('$SBOM_FILE')).get('components') or []))" 2>/dev/null || echo '?')"

echo "== scan (all severities + coverage self-check) =="
# Reuse scan-image.sh — see design rule 5 in CLAUDE.md.
# Do not filter by severity — re-evaluating vendor downgrades needs all-severity data.
REPORT_FILE="$OUT_DIR/trivy-reports/${STEM}.json"
SEVERITY="${SEVERITY:-UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL}" \
  bash "$GATE_DIR/scan-image.sh" "$SBOM_FILE" "$REPORT_FILE" "$OUT_DIR" >/dev/null || {
    echo "::error::scan failed — see $OUT_DIR/trivy-run.log"; exit 1; }
grep 'cov=' "$OUT_DIR/trivy-run.log" 2>/dev/null | sed 's/^/   /'

echo "== gate verdict =="
# Why the exceptions file is mandatory: see docs/image-authoring/builder-languages.md.
# Exceptions match on a substring of the $TAG passed as --image-ref.
EXCEPTIONS_PATH="${CVE_EXCEPTIONS:-$REPO_ROOT/cve-exceptions.json}"
GATE_ARGS=(--report "$REPORT_FILE" --image-ref "$TAG" --sbom "$SBOM_FILE"
           --summary-md "$OUT_DIR/cve-gate.md" --json-out "$OUT_DIR/cve-gate.json")
if [ "$EXCEPTIONS_PATH" != "none" ]; then
  [ -f "$EXCEPTIONS_PATH" ] || {
    echo "::error::exceptions file not found: $EXCEPTIONS_PATH (to omit deliberately, set CVE_EXCEPTIONS=none)"
    exit 2
  }
  GATE_ARGS+=(--exceptions "$EXCEPTIONS_PATH")
fi

python3 "$GATE_DIR/image-gate.py" "${GATE_ARGS[@]}" >/dev/null
RC=$?

if [ -n "${REGISTRY:-}" ] && [ "$RC" -eq 0 ]; then
  echo "== push =="
  # A failed push is **an error**. Downgrading it to a warning would leave the gate
  # result ($RC=0) as the exit code, so the caller (CI) would mistake it for a successful
  # publication and record an empty digest in published.json.
  if ! docker push "$TAG" > "$OUT_DIR/push.log" 2>&1; then
    echo "::error::push failed — see $OUT_DIR/push.log"; tail -20 "$OUT_DIR/push.log"; exit 1
  fi
  echo "   $TAG"

  # Without the digest there is no way to name what was published — it is the core value
  # of the publication record, so failing to read it is also an error (never record an
  # empty string).
  DIGEST="$(docker buildx imagetools inspect "$TAG" --format '{{json .Manifest}}' 2>/dev/null \
    | python3 -c "import json,sys;print(json.load(sys.stdin).get('digest',''))" 2>/dev/null)"
  if [ -z "$DIGEST" ]; then
    echo "::error::push succeeded but the digest could not be determined — $TAG"; exit 1
  fi
  echo "   digest=$DIGEST"
  echo "$DIGEST" > "$OUT_DIR/.digest"
fi

echo
echo "== result =="
echo "   gate: $([ "$RC" -eq 0 ] && echo PASS || echo FAIL)   summary: $OUT_DIR/cve-gate.md"
exit "$RC"
