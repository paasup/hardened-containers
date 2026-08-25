#!/usr/bin/env bash
# =============================================================================
# rescan-published.sh
#   Re-pull an already-pushed image and re-run only SBOM, scan, and gate — it does not
#   build. The point is to answer, cheaply and on a daily schedule, "is a published image
#   that was clean yesterday now blocked by a new CVE?". All SBOM, scan, and gate logic
#   reuses scripts/gate/scan-image.sh and image-gate.py exactly as
#   build-hardened-image.sh does — nothing new is written here.
#
# Usage:
#   scripts/gate/rescan-published.sh <IMAGE> <OUT_DIR>
#
# Exit codes: 0 = gate PASS (no drift). Anything else = gate FAIL (drift) or no entry yet
#             in published.json (exit 2 — meaning it has not been published, so there is
#             nothing to rescan. Callers treat this as "needs a rebuild" too).
#
# Outputs are written to $OUT_DIR under the same filenames build-hardened-image.sh uses
# (cve-gate.md, cve-gate.json), so the workflow's artifact upload and Job Summary steps
# work unchanged whether or not a rebuild happens.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GATE_DIR="$REPO_ROOT/scripts/gate"

IMAGE="${1:?usage: rescan-published.sh <IMAGE> <OUT_DIR>}"
OUT_DIR="${2:?usage: rescan-published.sh <IMAGE> <OUT_DIR>}"
PUBLISHED_FILE="${PUBLISHED_JSON:-$REPO_ROOT/published.json}"

mkdir -p "$OUT_DIR/sbom" "$OUT_DIR/trivy-reports"

REF="$(python3 -c "
import json, sys
try:
    doc = json.load(open('$PUBLISHED_FILE'))
except FileNotFoundError:
    sys.exit(0)
print(doc.get('images', {}).get('$IMAGE', {}).get('ref', ''))
")"

if [ -z "$REF" ]; then
  echo "::warning::$IMAGE — no publication record in published.json; a first build is needed"
  exit 2
fi

echo "== pull =="
echo "   ref=$REF"
if ! docker pull "$REF" >/dev/null 2>&1; then
  echo "::error::pull failed — $REF"
  exit 1
fi

STEM="$(echo "$REF" | tr ':/' '__')"

echo "== SBOM =="
docker save "$REF" -o "$OUT_DIR/image.tar" 2>/dev/null
SBOM_FILE="$OUT_DIR/sbom/${STEM}.cdx.json"
trivy image --quiet --format cyclonedx --input "$OUT_DIR/image.tar" \
  > "$SBOM_FILE" 2>/dev/null
rm -f "$OUT_DIR/image.tar"
echo "   components: $(python3 -c "import json;print(len(json.load(open('$SBOM_FILE')).get('components') or []))" 2>/dev/null || echo '?')"

echo "== scan (all severities + coverage self-check) =="
REPORT_FILE="$OUT_DIR/trivy-reports/${STEM}.json"
SEVERITY="${SEVERITY:-UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL}" \
  bash "$GATE_DIR/scan-image.sh" "$SBOM_FILE" "$REPORT_FILE" "$OUT_DIR" >/dev/null || {
    echo "::error::scan failed — see $OUT_DIR/trivy-run.log"; exit 1; }
grep 'cov=' "$OUT_DIR/trivy-run.log" 2>/dev/null | sed 's/^/   /'

echo "== gate verdict =="
EXCEPTIONS_PATH="${CVE_EXCEPTIONS:-$REPO_ROOT/cve-exceptions.json}"
GATE_ARGS=(--report "$REPORT_FILE" --image-ref "$REF" --sbom "$SBOM_FILE"
           --summary-md "$OUT_DIR/cve-gate.md" --json-out "$OUT_DIR/cve-gate.json")
if [ "$EXCEPTIONS_PATH" != "none" ]; then
  [ -f "$EXCEPTIONS_PATH" ] || {
    echo "::error::exceptions file not found: $EXCEPTIONS_PATH (to omit deliberately, set CVE_EXCEPTIONS=none)"
    exit 2
  }
  GATE_ARGS+=(--exceptions "$EXCEPTIONS_PATH")
fi

python3 "$GATE_DIR/image-gate.py" "${GATE_ARGS[@]}" >/dev/null
exit $?
