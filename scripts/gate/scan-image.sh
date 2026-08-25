#!/usr/bin/env bash
# =============================================================================
# scan-image.sh
#   Scan one CycloneDX SBOM with trivy (`trivy sbom`) and produce a vulnerability report.
#
#   Taking the SBOM as input means no image re-pull and no registry authentication
#   (offline).
#
#   Alongside the scan it performs a **coverage self-check**. If there are zero OS-package
#   findings, sentinel packages are injected into a copy of the SBOM and it is rescanned;
#   if they fire, the scanner is considered to know that distribution. The result is
#   recorded in the report's `CoverageProbe` (ok|none|n/a) and read by the gate
#   (image-gate.py) — it is the only way to tell "zero" apart from "not measured".
#
# Usage:
#   bash scripts/gate/scan-image.sh <sbom.cdx.json> <report.json> <out_dir>
#
#   Environment variables:
#     SEVERITY        severities to scan (default all — filtering makes re-evaluating
#                     effective severity impossible)
#     TRIVY_CACHE_DIR trivy cache directory (unset = trivy's default ~/.cache/trivy)
#
# Outputs:
#     <report.json>            trivy sbom scan result (+ CoverageProbe)
#     <out_dir>/trivy-run.log  run log
#
# Requires: trivy, python3, bash
# =============================================================================
set -uo pipefail

command -v trivy   >/dev/null || { echo "!! trivy binary not found" >&2; exit 127; }
command -v python3 >/dev/null || { echo "!! python3 not found" >&2; exit 127; }

SEVERITY="${SEVERITY:-UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL}"
[ -n "${TRIVY_CACHE_DIR:-}" ] && export TRIVY_CACHE_DIR

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- internal mode: coverage self-check --------------------------------------
#     args: --probe <sbom_file> <report_json> <probe_dir>
#
#     Records CoverageProbe at the top level of the report. The gate uses this value to
#     decide coverage.
#       ok    the scanner knows this distribution (zero really is zero)
#       none  the scanner has no data for it → gate failure
#       n/a   the SBOM has no OS packages (not applicable)
if [ "${1:-}" = "--probe" ]; then
  python3 - "$2" "$3" "$4" <<'PY'
import json, os, re, subprocess, sys, tempfile

sbom_path, report_path, probe_dir = sys.argv[1], sys.argv[2], sys.argv[3]
OS_PURL = re.compile(r"^pkg:(deb|rpm|apk)/([^/]+)/")
FLOOR = "0.0.1-1"   # lower than any real version

# Sentinels — package names for which an advisory is guaranteed to exist if the scanner
# knows that distribution. Several are used; if any one fires, data is considered present.
# They must be independent of what is installed — see docs/image-authoring/scanner-caveats.md.
SENTINELS = {
    "deb": ["openssl", "curl", "libxml2", "perl", "zlib1g", "libc6"],
    "rpm": ["openssl", "openssl-3", "curl", "libxml2-2", "glibc", "zlib"],
    "apk": ["openssl", "curl", "busybox", "zlib", "musl"],
}


def write(verdict):
    d = json.load(open(report_path))
    d["CoverageProbe"] = verdict
    json.dump(d, open(report_path, "w"))
    print(f"probe: {verdict}", file=sys.stderr)


sbom = json.load(open(sbom_path))
sample = next((c for c in (sbom.get("components") or [])
               if OS_PURL.match(c.get("purl") or "")), None)
if sample is None:
    write("n/a"); sys.exit(0)

# If there are already findings, the scanner evidently knows this distribution — no extra
# scan needed.
rep = json.load(open(report_path))
if any((r.get("Vulnerabilities") or []) for r in (rep.get("Results") or [])
       if r.get("Class") == "os-pkgs"):
    write("ok"); sys.exit(0)

# Inject sentinels into a copy. The original is never touched.
# The distro and arch qualifiers (distro=, arch=) must be copied verbatim from an
# installed package — trivy decides which distribution database to consult from the
# purl's distro.
ptype, namespace = OS_PURL.match(sample["purl"]).groups()
qs = sample["purl"].partition("?")[2]
comps = sbom.setdefault("components", [])
for i, name in enumerate(SENTINELS[ptype]):
    comps.append({
        "bom-ref": f"coverage-probe-{i}", "type": "library",
        "name": name, "version": FLOOR,
        "purl": f"pkg:{ptype}/{namespace}/{name}@{FLOOR}" + (f"?{qs}" if qs else ""),
    })

os.makedirs(probe_dir, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=probe_dir, suffix=".cdx.json")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(sbom, f)
    p = subprocess.run(
        ["trivy", "sbom", "--quiet", "--scanners", "vuln",
         "--severity", "UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL",
         "--cache-backend", "memory", "--skip-db-update", "--format", "json", tmp],
        capture_output=True, text=True)
    if p.returncode != 0:
        # If the probe fails, do not invent a verdict. Leaving the key absent makes the
        # gate treat it conservatively, exactly as it treats a pre-probe report (zero
        # total findings → failure).
        print("probe: failed — " + (p.stderr or "").strip()[:200], file=sys.stderr)
        sys.exit(0)
    got = sum(len(r.get("Vulnerabilities") or [])
              for r in (json.loads(p.stdout).get("Results") or [])
              if r.get("Class") == "os-pkgs")
    write("ok" if got > 0 else "none")
finally:
    os.unlink(tmp)
PY
  exit 0
fi

# --- main mode --------------------------------------------------------------
SBOM="${1:?usage: scan-image.sh <sbom.cdx.json> <report.json> <out_dir>}"
REPORT="${2:?usage: scan-image.sh <sbom.cdx.json> <report.json> <out_dir>}"
OUT_DIR="${3:?usage: scan-image.sh <sbom.cdx.json> <report.json> <out_dir>}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
LOG="$OUT_DIR/trivy-run.log"

[ -f "$SBOM" ] || { echo "!! SBOM not found: $SBOM" >&2; exit 1; }
mkdir -p "$OUT_DIR"

{
  echo "==================================================================="
  echo "SBOM SCAN START : $(ts)"
  echo "trivy    : $(trivy --version 2>/dev/null | head -1)   (trivy sbom, offline)"
  echo "severity : $SEVERITY"
  echo "==================================================================="
} | tee "$LOG" >&2

echo ">> [$(ts)] warming the vulnerability database..." | tee -a "$LOG" >&2
trivy image --download-db-only >>"$LOG" 2>&1 \
  || { echo "!! database download failed" | tee -a "$LOG" >&2; exit 1; }

echo ">> [$(ts)] scanning..." | tee -a "$LOG" >&2
if ! trivy sbom --quiet --scanners vuln --severity "$SEVERITY" \
      --cache-backend memory --skip-db-update \
      --format json "$SBOM" > "$REPORT" 2>>"$LOG"; then
  echo "!! scan failed — see $LOG" | tee -a "$LOG" >&2
  exit 1
fi

# --- coverage self-check -----------------------------------------------------
# Zero os-pkgs findings has two possible causes, indistinguishable by the number alone:
#   (a) the image really is clean        (b) the scanner has no data for that distribution
# So we ask the scanner directly — inject vulnerable sentinel packages into a copy of the
# SBOM and rescan. If they fire it is (a); if it is still zero it is (b).
probe_dir="$OUT_DIR/.probe"
bash "$SELF" --probe "$SBOM" "$REPORT" "$probe_dir" 2>>"$LOG" || true
rm -rf "$probe_dir"

# NOTE: the `cov=` prefix is a string contract — build-hardened-image.sh and
# rescan-published.sh grep for it. Do not reword it.
cov="$(python3 -c "import json;print(json.load(open('$REPORT')).get('CoverageProbe','?'))" 2>/dev/null || echo '?')"
echo ">> [$(ts)] done  cov=$cov" | tee -a "$LOG" >&2
