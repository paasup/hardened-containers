# Security policy

## What this repository does and does not guarantee

This repository builds hardened container images and enforces **zero known CRITICAL/HIGH
vulnerabilities** as a gate before publishing. Understanding the exact scope of that
sentence matters.

**What is guaranteed**

- A published image had zero effective CRITICAL/HIGH vulnerabilities at the time it was
  published, judged by trivy taking the higher of the vendor and NVD rating. Approved
  exceptions are published in [cve-exceptions.json](cve-exceptions.json) together with
  their rationale and expiry date.
- That the verdict was an actual measurement — a "zero" that merely means the scanner has
  no data for that distribution is caught by the coverage self-check (`CoverageProbe`) and
  fails the gate.
- Published images carry GitHub build-provenance and SBOM attestations, and the SBOM of
  every published image is committed to this repository under `sboms/` (see
  "Verification" below).

**What is not guaranteed**

- **A passing gate does not prove the image works.** A CVE scanner cannot see runtime
  requirements. Verifying behaviour in your deployment environment is your
  responsibility.
- **Vulnerabilities disclosed after publication.** The verdict is a point-in-time result.
  `rescan.yml` re-scans daily and rebuilds on drift, but there is a lag between the rescan
  and the rebuild.
- **Unknown vulnerabilities**, vulnerabilities the scanner does not yet know about, and
  errors in scanner data.
- **The security of the upstream projects themselves.** This repository only rebuilds
  upstream source.

## Reporting a vulnerability

For problems found **in this repository's build definitions, scripts, or CI** (a
supply-chain flaw in the build process, a logic flaw that could bypass the gate, exposed
credentials), please report privately through GitHub
[Security Advisories](../../security/advisories/new). Please do not open a public issue.

Response targets are below. They are goals subject to available resources, not
contractual obligations.

| Stage | Target |
|---|---|
| Acknowledgement | within 5 business days |
| Initial assessment | within 10 business days |
| Fix or mitigation | by agreement, depending on severity |

**A CVE found in a published image** is usually not a defect in this repository but a
problem in the upstream project or the base OS. Even so, an issue is useful — we need to
find out why the gate missed it (an expired exception, a scanner coverage gap). That
said, **please report vulnerabilities in the upstream software itself to that upstream
project.**

**Please do not report upstream projects' vulnerabilities here.** We do not maintain that
code and cannot coordinate a report received here on their behalf.

## Verification

Published images can be verified with the `gh` CLI:

```sh
gh attestation verify oci://<image>@<digest> --repo <owner>/<repo>
```

The exact commands are in the "Verifying a published image" section of the
[README](README.md).

**`--repo` is what makes the check meaningful** — it asserts *which* repository's workflow
produced the image. Verifying without pinning the repository proves only that something
signed it.

What an image contains is recorded separately, in `sboms/<image>.cdx.json` in this
repository. That file needs no service to read and does not expire.

## Supported versions

This repository maintains **only the current published tag** for each image
([published.json](published.json)). Older tags are not rebuilt and receive no backports.
No rolling tags such as `latest` are published — a tag is a record of what we verified.
