# 0004. Replace the adc image with a self-build

- Status: Accepted

## Decision

The adc image (the APISIX/API7 management CLI, a sidecar to
apisix-ingress-controller) is built here. The build definition is
[images/adc/](../../images/adc/) — upstream's builder for the final stage
(`node:lts-bookworm-slim`, bundling `main.cjs` with pnpm + nx) is reused unchanged, and
only the final stage base is switched to SUSE BCI
(`registry.suse.com/bci/bci-base:15.7` plus `nodejs24`). The application code is 100%
identical to upstream — the same pattern as `cnpg-postgresql` (the
OS-package-reinstall shape).

## Context

Upstream `ghcr.io/api7/adc:0.29.0` moved its final stage to
`gcr.io/distroless/nodejs24-debian13:nonroot`, bringing CRITICAL/HIGH to zero **by
vendor rating**. That number reflects vendor severity only. The gate re-evaluates with
`max(vendor, NVD)`, and under that view the glibc regex/collating stack-overflow family
(CVE-2019-1010022, CVE-2019-1010023, CVE-2018-20796, CVE-2019-9192 — the evidence at the
time; the gate re-measures current state on every run) came back as effective
CRITICAL/HIGH. These are a vendor-downgrade case that Debian has permanently fixed as
"affected, no fix available", so raising the tag does not resolve them.

**We were already on the latest upstream tag, so the newer-tag lever was unavailable and
the only remaining lever was a base OS swap.**

## Rationale

- **Pre-verification confirmed that changing the base OS changes the vendor verdict.**
  Building a minimal configuration (SUSE BCI `bci-base:15.7` with `nodejs24` installed),
  extracting an SBOM, and scanning it showed the same glibc CVEs are not raised against
  SUSE's glibc — this is the class of finding that a distribution change resolves,
  because the vendor verdict differs (the same pattern as `cnpg-postgresql`).
- **This is a minimal-diff self-build.** It is simpler than the shape that compiles
  source across several modules — the application code (the `main.cjs` bundle) and the
  builder stage (`node:lts-bookworm-slim`, pnpm + nx) are reused 100% identically to
  upstream. All that changes is one line of final-stage base plus the package install,
  entrypoint path, and non-root account creation that follow from it.
- **Functional verification passed** (version, `--help` command listing, non-root
  execution). Because a passing gate does not prove the image works, this is checked by
  `images/adc/verify.sh`. Most adc commands (dump/diff/sync) require an actual
  APISIX/API7 backend, so that integration is outside this smoke test's scope —
  deployment verification follows a separate procedure (not yet performed).

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.** The same cost as
  [0001](0001-cnpg-postgresql-image.md),
  [0002](0002-cloudnative-pg-operator-self-build.md), and
  [0003](0003-etcd-image-self-build.md).
- **A person updates `SOURCE_COMMIT`.** It is not tracked automatically — when upstream
  ships a new release, or one that already resolves the CVEs above, someone editing
  `source.build.env` and opening a PR is itself the update trigger.
- **This is a configuration upstream does not test.** A BCI-based Node runtime is not in
  `api7/adc`'s CI matrix.
- **There is still no deployment verification against a real APISIX/API7 backend.** Only
  the gate PASS and a backend-free smoke test (version plus `--help`) have been
  confirmed — a dump/diff/sync round trip alongside apisix-ingress-controller must be
  done as a separate procedure.

## Conditions for revisiting

- **If `api7/adc` ships a new release that resolves these CVEs** — moving to a newer tag
  becomes possible again, which takes priority over self-building.
- **If unexpected runtime problems appear on `bci-base`** — reconsider another BCI
  variant (the same condition as
  [0002](0002-cloudnative-pg-operator-self-build.md)).
- **If deployment verification alongside apisix-ingress-controller (dump/diff/sync)
  finds a problem.**
