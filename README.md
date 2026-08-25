# hardened-containers

English · [한국어](README.ko.md)

Hardened container images for common open-source infrastructure, built from upstream
source on SUSE BCI and gated on **zero known CRITICAL/HIGH vulnerabilities**.

## What this is

Upstream container images often ship with known CVEs that the upstream project has no
incentive to fix quickly — usually in the base OS layer, sometimes in statically linked
dependencies. This repository rebuilds those images so the vulnerabilities are gone at
the source, and refuses to publish anything that still carries them.

- **Zero-CVE gate.** An image reaches the registry only after passing a gate that
  requires zero effective CRITICAL/HIGH findings. The gate is enforced, not advisory —
  a failing build publishes nothing.
- **Self-contained.** Clone the repo and you need only `docker` and `trivy`. Build,
  functional verification, SBOM generation, scanning, and the gate verdict all happen
  inside this repository. No other repo, token, or workflow is involved.
- **Deterministic tags.** No rolling tags. Every published tag carries the app version
  and the build date, and every dependency pin is a committed value — the tag is a
  record of what we actually verified.

Eight images are currently built: `adc`, `apisix`, `apisix-ingress-controller`,
`argocd`, `cloudnative-pg`, `cnpg-postgresql`, `etcd`, `keycloak`. The `images/`
directory is the single source of truth for that list. Published tags and digests are
recorded in [published.json](published.json).

> These images are **unofficial rebuilds** of their upstream projects. They are not
> affiliated with, endorsed by, or supported by any upstream project. See
> [NOTICE](NOTICE) for trademark and licensing notices.

## Quick start

```sh
git clone <this repo>
cd hardened-containers

# build → verify → SBOM → scan → gate  (no registry push)
IMAGE=etcd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

cat /tmp/out/cve-gate.md
```

If the gate passes, also check that `CoverageProbe` in `/tmp/out/trivy-reports/*.json`
reads `ok`. A value of `none` means the zero findings were not a measurement — the
scanner has no vulnerability data for that distribution, so "zero" proves nothing. The
gate fails on `none` for exactly this reason.

To push to a registry, set `REGISTRY` to your own:

```sh
REGISTRY=<your-registry> IMAGE=etcd BASE_OS=source \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

## Verifying a published image

Two separate things, with different lifetimes and different purposes.

| | Where it lives | Question it answers | Needs a service to read? |
|---|---|---|---|
| **The SBOM** | `sboms/<image>.cdx.json` in this repository | What is inside it? | No — it is in the repository |
| **Attestations** | GitHub Artifact Attestations, keyed by digest | Was this digest really produced by that repository's workflow? | Yes — `gh attestation verify` |

**What is inside** is read straight from the repository. It never expires, and a diff
shows exactly what changed between publications.

```sh
jq '.components | length' sboms/etcd.cdx.json
```

**Who produced it** is checked with the `gh` CLI — no cosign, no public key.

```sh
REF=$(jq -r '.images.etcd.ref'    published.json)
DIG=$(jq -r '.images.etcd.digest' published.json)

gh attestation verify "oci://${REF%:*}@${DIG}" --repo paasup/hardened-containers
```

> **Always pass `--repo`.** That is what pins *which* repository's workflow produced the
> image. Without it you have only established that something signed it.

The provenance is SLSA build provenance, and an SBOM attestation is attached alongside it.
Both attach to the **digest**, not the tag — a tag can later point at a different image.

## Using it for your own registry

Nothing here is tied to one registry. After forking:

1. **Repository variable** (Settings → Secrets and variables → Actions → Variables)
   - `REGISTRY_HOST` — where to push, e.g. `docker.io/myorg`.
     **If this is unset, CI builds and verifies but never pushes.** That is deliberate:
     a fork that runs the workflow without configuring anything must not attempt to push
     to someone else's registry.
2. **Repository secrets**
   - `DOCKERHUB_USER` / `DOCKERHUB_TOKEN` — registry credentials.
3. **Reset `published.json`.**
   ```sh
   echo '{"schemaVersion": 1, "images": {}}' > published.json
   ```
   `rescan.yml` pulls the tags recorded in this file. If you do not reset it, your fork
   will rescan the original repository's images instead of your own.
4. **Review `cve-exceptions.json`.** An exception is a record that someone accepted a
   risk. Do not inherit that judgement — re-make it for your environment.

## Known limitations

- **Builds are not reproducible.** Base images are referenced by tag
  (`bci-base:15.7`, `golang:1.26.6-trixie`) and pulled fresh on every build. This is a
  deliberate trade-off: keeping CVE counts at zero requires picking up the latest
  security patches, which pinning by digest would prevent. What was actually built is
  instead recorded by the published digest and the committed SBOM.
- **linux/amd64 only.** No multi-arch builds yet.
- **A passing gate does not prove the image works.** A CVE scanner cannot see runtime
  requirements. Verifying behaviour in your own environment is a separate step.
- **The verdict is a point-in-time result.** It says nothing about vulnerabilities
  disclosed afterwards. `rescan.yml` re-scans published images daily and rebuilds the
  ones that have drifted, but there is a lag.

## How it works

```
build → verify.sh → SBOM → scan → gate → push → attest + record
```

One script, `scripts/build/build-hardened-image.sh`, runs this for every image
regardless of type. What differs between images lives entirely in `images/<image>/`:
a Dockerfile, a `build.env` declaring the build contract, a `verify.sh` functional
check, and a README explaining what was changed relative to upstream and why.

Two broad shapes exist — images that reinstall upstream artifacts onto a different
distribution, and images compiled from upstream source — but both go through the same
orchestrator.

## Documentation

- **[docs/image-authoring/](docs/image-authoring/README.md) — start here**: the
  orchestration contract, the pipeline, supply-chain rules, and the checklist for
  adding an image
  - [base-os-policy.md](docs/image-authoring/base-os-policy.md) — choosing the runtime base OS (SUSE BCI)
  - [builder-languages.md](docs/image-authoring/builder-languages.md) — per-language builder rules, Go module CVEs
  - [scanner-caveats.md](docs/image-authoring/scanner-caveats.md) — why scanner output and image tags cannot be taken at face value
  - [ci.md](docs/image-authoring/ci.md) — CI behaviour, signing and attestation
  - [readme-template.md](docs/image-authoring/readme-template.md) — template for per-image READMEs
- [docs/architecture.md](docs/architecture.md) — the pipeline end to end
- [docs/decisions/](docs/decisions/) — ADRs recording why each image is built here
- [CONTRIBUTING.md](CONTRIBUTING.md) — how CI works here (your fork runs the full build), what to run before opening a PR
- [SECURITY.md](SECURITY.md) — what is and is not guaranteed, how to report a vulnerability

Documentation is English-first, with Korean kept alongside for READMEs
([README.ko.md](README.ko.md), `images/<image>/README.ko.md`).

## License

[Apache License 2.0](LICENSE) — this covers **the build definitions, scripts, and
documentation in this repository**.

It does not cover the images those builds produce. Third-party software included in a
built image remains under its own license. The authoritative record of what a given
image contains is its SBOM attestation. See [NOTICE](NOTICE) for details.
