#!/usr/bin/env python3
"""
image-gate.py — the gate that decides whether one self-built image meets the
zero-CRITICAL/HIGH target.

Background on why scanner output cannot be trusted directly (vendor downgrades, missing
data coverage, and so on): see the "Do not take scanner output at face value" section of
docs/image-authoring/scanner-caveats.md.

Verdict: for each CVE, compute `effective_severity = max(vendor rating, NVD CVSS
rating)`; anything HIGH or above blocks (unless an approved exception applies). The input
report must have been scanned at all severities (the default in `scan-image.sh`) — a
filtered report makes the vendor-downgrade comparison impossible.

It also reads the `CoverageProbe` self-check that `scan-image.sh` leaves in the report, to
distinguish zero findings meaning "safe" from zero findings meaning "the scanner has no
data for this distribution".

    ok    the scanner knows this distribution → zero really is zero
    none  the scanner has no data            → **blocked**
    n/a   the SBOM has no OS packages
    (key absent)  a pre-probe report → blocked if the total finding count is zero
                  (the conservative default)

Usage
-----
    python3 scripts/gate/image-gate.py \\
        --report     out/trivy-reports/etcd.json \\
        --image-ref  <registry>/etcd:3.7.1-source-hardened-20260824 \\
        --exceptions cve-exceptions.json \\
        --sbom       out/sbom/etcd.cdx.json \\
        --summary-md out/cve-gate.md \\
        --json-out   out/cve-gate.json

`--image-ref` is required — approved exceptions match on a substring of the image ref
(`exception_applies`), so without it no exception would ever apply and the image would be
blocked silently. Making it mandatory prevents that state.

Exit codes
    0  gate passed
    1  gate failed (unapproved CRITICAL/HIGH present, or a data coverage problem)
    2  execution error
"""

import argparse
import json
import os
import sys
from datetime import date, datetime

RANK = {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1, "UNKNOWN": 0}


def nvd_severity(score):
    """Convert an NVD CVSS v3 score to a severity. None if there is no score."""
    if score is None:
        return None
    if score >= 9.0:
        return "CRITICAL"
    if score >= 7.0:
        return "HIGH"
    if score >= 4.0:
        return "MEDIUM"
    return "LOW"


def effective_severity(vendor_sev, nvd_sev):
    """Effective severity = max(vendor, NVD). This stops a vendor downgrade from letting
    something through the gate. UNKNOWN when neither is available."""
    vend = vendor_sev or "UNKNOWN"
    nvd = nvd_sev or "UNKNOWN"
    return vend if RANK.get(vend, 0) >= RANK.get(nvd, 0) else nvd


def load_exceptions(path):
    """
    The list of approved exceptions.

    Format (JSON):
      {"exceptions": [
         {"id": "CVE-2026-8376",
          "images": ["*"],                  # or a substring match on a specific image
          "reason": "32-bit builds only — we ship x86_64",
          "expires": "2026-10-31"}
      ]}

    An entry past its `expires` date is not honoured (forcing a re-review).
    """
    if not path or not os.path.exists(path):
        return [], []
    with open(path) as f:
        data = json.load(f)
    active, expired = [], []
    today = date.today()
    for e in data.get("exceptions") or []:
        exp = e.get("expires")
        if exp:
            try:
                if datetime.strptime(exp, "%Y-%m-%d").date() < today:
                    expired.append(e)
                    continue
            except ValueError:
                raise SystemExit(f"malformed `expires` in an exception entry: {exp!r} (want YYYY-MM-DD)")
        active.append(e)
    return active, expired


def exception_applies(exc, cve_id, image_ref):
    if exc.get("id") != cve_id:
        return False
    pats = exc.get("images") or ["*"]
    return any(p == "*" or p in image_ref for p in pats)


def analyze(path, image_ref):
    d = json.load(open(path))
    os_info = (d.get("Metadata") or {}).get("OS") or {}
    findings = []
    # Preserve per-Result metadata. It is needed for the coverage verdict — looking only
    # at the total finding count would let an image pass on language-package findings
    # while OS packages returned zero.
    results_meta = []
    for res in d.get("Results") or []:
        results_meta.append({
            "class": res.get("Class") or "",
            "type": res.get("Type") or "",
            "n": len(res.get("Vulnerabilities") or []),
        })
        for v in res.get("Vulnerabilities") or []:
            nvd = ((v.get("CVSS") or {}).get("nvd") or {}).get("V3Score")
            findings.append(
                {
                    "id": v.get("VulnerabilityID"),
                    "pkg": v.get("PkgName"),
                    "installed": v.get("InstalledVersion"),
                    "vendor_sev": v.get("Severity") or "UNKNOWN",
                    "sev_source": v.get("SeveritySource"),
                    "nvd_score": nvd,
                    "nvd_sev": nvd_severity(nvd),
                    "status": v.get("Status"),
                    "fixed": v.get("FixedVersion") or "",
                }
            )
    return {
        "image": image_ref,
        "os": f"{os_info.get('Family','?')} {os_info.get('Name','?')}",
        "eosl": bool(os_info.get("EOSL")),
        "findings": findings,
        "results_meta": results_meta,
        # The coverage self-check result from scan-image.sh (ok|none|n/a). A missing key
        # means an older, pre-probe report.
        "coverage_probe": d.get("CoverageProbe"),
    }


def sbom_os_package_count(sbom_path):
    """Number of OS packages (deb/rpm/apk) in the SBOM. Gives context for judging whether
    zero os-pkgs findings is anomalous."""
    if not sbom_path or not os.path.exists(sbom_path):
        return None
    import re
    d = json.load(open(sbom_path))
    n = 0
    for c in d.get("components") or []:
        if re.match(r"pkg:(deb|rpm|apk)/", c.get("purl") or ""):
            n += 1
    return n


def evaluate(img, exceptions):
    """Judge one image. Returns the verdict as a dict."""
    blocking = []      # items blocking the gate (per unique CVE)
    excepted = []      # items covered by an approved exception
    underrated = []    # items the vendor rated below NVD (where NVD >= HIGH)

    # Collapse to unique CVEs. Counting the same CVE once per package it was split across
    # would overstate the real risk.
    by_cve = {}
    for f in img["findings"]:
        cur = by_cve.setdefault(f["id"], {"id": f["id"], "pkgs": set(), "vendor_sev": "UNKNOWN",
                                          "nvd_sev": None, "nvd_score": None,
                                          "status": set(), "fixed": set()})
        cur["pkgs"].add(f["pkg"])
        if RANK.get(f["vendor_sev"], 0) > RANK.get(cur["vendor_sev"], 0):
            cur["vendor_sev"] = f["vendor_sev"]
        if f["nvd_sev"] and RANK.get(f["nvd_sev"], 0) > RANK.get(cur["nvd_sev"] or "UNKNOWN", 0):
            cur["nvd_sev"] = f["nvd_sev"]
            cur["nvd_score"] = f["nvd_score"]
        if f["status"]:
            cur["status"].add(f["status"])
        if f["fixed"]:
            cur["fixed"].add(f["fixed"])

    for cve in by_cve.values():
        vend = cve["vendor_sev"]
        nvd = cve["nvd_sev"]
        effective = effective_severity(vend, nvd)
        cve["effective_sev"] = effective

        if nvd and RANK.get(nvd, 0) > RANK.get(vend, 0) and RANK.get(nvd, 0) >= RANK["HIGH"]:
            underrated.append(cve)

        if RANK.get(effective, 0) < RANK["HIGH"]:
            continue

        exc = next((e for e in exceptions if exception_applies(e, cve["id"], img["image"])), None)
        if exc:
            cve["exception"] = exc
            excepted.append(cve)
        else:
            blocking.append(cve)

    # coverage_probe verdict — the meaning of each value is in the module docstring.
    probe = img.get("coverage_probe")
    rm = img.get("results_meta") or []
    os_results = [r for r in rm if r["class"] == "os-pkgs"]

    if probe is not None:
        no_data = probe == "none"
        os_silent = False
    else:
        # An older, pre-probe report — block conservatively if the total finding count is
        # zero.
        no_data = len(img["findings"]) == 0
        os_silent = bool(os_results) and sum(r["n"] for r in os_results) == 0

    return {
        "coverage_probe": probe,
        "os_silent": os_silent,
        "os_pkg_count": img.get("os_pkg_count"),
        "image": img["image"],
        "os": img["os"],
        "eosl": img["eosl"],
        "total_findings": len(img["findings"]),
        "unique_cves": len(by_cve),
        "blocking": sorted(blocking, key=lambda c: (-RANK.get(c["effective_sev"], 0), c["id"])),
        "excepted": sorted(excepted, key=lambda c: c["id"]),
        "underrated": sorted(underrated, key=lambda c: -(c["nvd_score"] or 0)),
        "no_data": no_data,
        "counts": {
            "vendor": {s: sum(1 for c in by_cve.values() if c["vendor_sev"] == s) for s in ("CRITICAL", "HIGH")},
            "nvd": {s: sum(1 for c in by_cve.values() if c["nvd_sev"] == s) for s in ("CRITICAL", "HIGH")},
            "effective": {s: sum(1 for c in by_cve.values() if c["effective_sev"] == s) for s in ("CRITICAL", "HIGH")},
        },
    }


def gate_verdict(r):
    return "PASS" if (len(r["blocking"]) == 0 and not r["no_data"]) else "FAIL"


SUMMARY_LEGEND = (
    "> **Effective C/H** is the count of unique CVEs aggregated as "
    "`max(vendor rating, NVD rating)`, and it is **the sole basis for the gate verdict**. "
    "**Downgraded** is the number of CVEs the vendor rated below NVD — a non-zero value "
    "means there are findings that \"look safe by vendor rating but carry risk closer to "
    "the NVD rating\", and it is worth confirming that the base OS swap did more than "
    "just lower the number."
)


def render_md(r, expired_exceptions):
    L = []
    A = L.append
    verdict = gate_verdict(r)
    A(f"## 🎯 CVE gate: {verdict}")
    A("")
    A("Target: **zero** CRITICAL/HIGH (unique CVEs, taking the higher of the vendor and NVD rating)")
    A("")
    c = r["counts"]
    PROBE_LABEL = {"ok": "✅ ok", "none": "❌ none", "n/a": "– n/a"}
    src = PROBE_LABEL.get(r.get("coverage_probe"), "? not measured")
    under = len(r["underrated"])
    A("| Image | OS | Coverage | EOSL | Effective C/H | Blocking | Excepted | Downgraded |")
    A("|---|---|---|---|---:|---:|---:|---:|")
    A(
        f"| `{r['image']}` | {r['os']} | {src} | "
        f"{'⚠️ EOL' if r['eosl'] else '-'} | "
        f"**{c['effective']['CRITICAL']}/{c['effective']['HIGH']}** | "
        f"{len(r['blocking'])} | {len(r['excepted'])} | "
        f"{('⚠️ ' + str(under)) if under else '-'} |"
    )
    A("")
    A(SUMMARY_LEGEND)
    A("")
    A("> **Coverage** is the result of asking the scanner directly whether it knows this "
      "distribution (a positive control: sentinel vulnerable packages are injected into a "
      "copy of the SBOM and rescanned). `ok` = data present, so zero really is zero / "
      "`none` = no data, therefore **blocked** / `n/a` = no OS packages / "
      "`not measured` = a pre-probe report.")
    A("")

    if r["no_data"]:
        A(f"### ❌ Data coverage problem — `{r['image']}`")
        A("")
        if r.get("coverage_probe") == "none":
            A(f"The self-check returned **`none`** — even after injecting sentinel vulnerable "
              f"packages into a copy of the SBOM and rescanning, there were zero findings. The "
              f"scanner has **no** security data for `{r['os']}`. This image's zero is not a "
              "measurement, so the gate fails.")
        else:
            A(f"All-severity findings are **zero** and there is no self-check result (a pre-probe "
              f"report). The possibility that `{r['os']}` data is simply absent cannot be ruled "
              "out, so this fails.")
        A("")

    if r["blocking"]:
        A(f"### Blocking findings — `{r['image']}`")
        A("")
        A("| CVE | Effective | Vendor | NVD | Package | Status | Fixed version |")
        A("|---|---|---|---|---|---|---|")
        for c in r["blocking"]:
            pkgs = ", ".join(sorted(c["pkgs"])[:3]) + ("…" if len(c["pkgs"]) > 3 else "")
            nvd = c["nvd_sev"] or "-"
            if c["nvd_score"]:
                nvd = f"{nvd} ({c['nvd_score']})"
            status = "/".join(sorted(c["status"])) or "-"
            fixed = "/".join(sorted(c["fixed"])) or "(none)"
            A(f"| {c['id']} | **{c['effective_sev']}** | {c['vendor_sev']} | {nvd} | "
              f"{pkgs} | {status} | {fixed} |")
        A("")

    if r["underrated"]:
        A(f"### ⚠️ Vendor downgrades — `{r['image']}`")
        A("")
        A("Findings the vendor rated below NVD. By vendor rating alone they pass the gate, "
          "but the real risk is closer to the NVD rating.")
        A("")
        A("| CVE | NVD | Vendor | Package |")
        A("|---|---|---|---|")
        for c in r["underrated"]:
            pkgs = ", ".join(sorted(c["pkgs"])[:3]) + ("…" if len(c["pkgs"]) > 3 else "")
            A(f"| {c['id']} | {c['nvd_sev']} ({c['nvd_score']}) | {c['vendor_sev']} | {pkgs} |")
        A("")

    if r["excepted"]:
        A("### Approved exceptions")
        A("")
        A("| CVE | Image | Expires | Reason |")
        A("|---|---|---|---|")
        for c in r["excepted"]:
            e = c["exception"]
            A(f"| {c['id']} | `{r['image']}` | {e.get('expires','(none)')} | {e.get('reason','')} |")
        A("")

    if expired_exceptions:
        A("### ⏰ Expired exceptions — re-review needed")
        A("")
        for e in expired_exceptions:
            A(f"- `{e.get('id')}` (expired {e.get('expires')}) — {e.get('reason','')}")
        A("")

    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True, help="trivy report JSON (an all-severity scan result)")
    ap.add_argument("--image-ref", required=True,
                     help="image reference (e.g. <registry>/etcd:<tag>). Used to match approved "
                          "exceptions — omit it and no exception can ever apply")
    ap.add_argument("--exceptions", default="", help="approved-exceptions JSON")
    ap.add_argument("--sbom", default="", help="path to the CycloneDX SBOM (for OS package count context)")
    ap.add_argument("--summary-md", default="", help="path to write the markdown verdict summary")
    ap.add_argument("--json-out", default="", help="path to write the verdict as JSON")
    ap.add_argument("--warn-only", action="store_true", help="exit 0 even on failure")
    args = ap.parse_args()

    if not os.path.isfile(args.report):
        print(f"::error::report not found: {args.report}", file=sys.stderr)
        return 2

    exceptions, expired = load_exceptions(args.exceptions)
    img = analyze(args.report, args.image_ref)
    if args.sbom:
        img["os_pkg_count"] = sbom_os_package_count(args.sbom)
    r = evaluate(img, exceptions)

    md = render_md(r, expired)
    print(md)
    if args.summary_md:
        with open(args.summary_md, "w") as f:
            f.write(md + "\n")
    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(r, f, indent=2, default=lambda o: sorted(o) if isinstance(o, set) else str(o))

    if r["no_data"]:
        why = ("self-check returned none — the scanner has no data" if r.get("coverage_probe") == "none"
               else "zero findings and no self-check result")
        print(f"::error::data coverage problem — {r['image']} ({r['os']}) {why}", file=sys.stderr)
    for c in r["blocking"]:
        print(f"::error::{r['image']}: {c['id']} {c['effective_sev']} "
              f"(vendor {c['vendor_sev']} / NVD {c['nvd_sev'] or '-'})", file=sys.stderr)

    failed = bool(r["blocking"] or r["no_data"])
    if failed:
        print(f"\ngate failed — {len(r['blocking'])} blocking"
              + (", data coverage problem" if r["no_data"] else ""), file=sys.stderr)
        return 0 if args.warn_only else 1
    print("\ngate passed — zero effective CRITICAL/HIGH", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
