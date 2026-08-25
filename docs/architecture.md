# Architecture and build pipeline

English · [한국어](architecture.ko.md)

The purpose of this repository is to produce **zero-CVE container images**, gate them
strictly, and publish them for production use. This is not "use the upstream image, and
build our own only when that fails". A tightly controlled **deterministic hardening
pipeline** is the premise and the only workflow: every image's vulnerabilities are
driven to zero.

## 1. Architectural philosophy

* **One orchestrator.** A single shell script,
  `scripts/build/build-hardened-image.sh`, controls the entire pipeline lifecycle for
  every image.
* **Self-contained.** This repository depends on no feature of a particular CI system
  and on no other repository. Locally or on a CI runner, it behaves the same as long as
  `docker` and `trivy` are installed.
* **Unified on SUSE BCI.** The application build stays as close to upstream as possible,
  while the final runtime layer (the base OS) is replaced wholesale with SUSE BCI,
  permanently removing distribution-specific OS vulnerabilities.
* **Deterministic tagging.** Rolling tags such as `latest` are not permitted. Every
  published image gets an explicit `[version]-security-hardened-[build-date]` tag.
* **Verified inputs.** Everything the build fetches is verified — git sources by commit
  SHA, tarballs by committed SHA256. TLS verification is never disabled and no
  unverified remote script is ever piped into a shell.
* **Verifiable outputs.** Every published image's SBOM is committed to the repository, and
  every published digest carries build-provenance and SBOM attestations — so consumers can
  check what they pulled without trusting this repository's logs.

---

## 2. From adding an image to maintaining it daily

Build → Verify → SBOM → Scan → Gate → Push runs sequentially and atomically inside the
single entry point `build-hardened-image.sh`, and stops immediately on any failure
(fail-fast). The only CI entry point that calls it is the `build-image.yml` workflow —
**when** it is called is what differs between a new image and an already-published one.
Deciding when to call it for published images is the job of a separate workflow,
`rescan.yml`, which re-scans daily and calls `build-image.yml` when needed rather than
duplicating any rebuild logic.

```mermaid
flowchart TD
    subgraph P1["1. Author a new image (human, local)"]
        A1["write images/&lt;image&gt;/<br/>Dockerfile · build.env · verify.sh · README.md · image.env"]
        A2["local: build-hardened-image.sh<br/>(no push) build→verify→SBOM→scan→gate"]
        A1 --> A2
    end
    A2 -->|gate PASS| B[push the branch / open a PR]

    subgraph P2["2. push trigger (automatic, build-image.yml)"]
        C1[detect changed images/&lt;image&gt;/ from the diff]
        C2["build→verify→SBOM→scan→gate<br/>(no REGISTRY → push impossible)"]
        C1 --> C2
    end
    B --> C1

    C2 -->|gate PASS, merged| Dispatch1["3. First publication — human runs<br/>gh workflow run build-image.yml<br/>image=&lt;new&gt;, push=true (from main)"]

    subgraph BI["build-image.yml (called by a human or by rescan.yml)"]
        D4[build→verify→SBOM→scan→gate]
        D5["gate PASS → push → attest<br/>+ commit published.json &amp; SBOM"]
        D4 --> D5
    end
    Dispatch1 --> D4

    D5 -->|published; rescanned from the next day| P3

    subgraph P3["4. Maintenance loop — rescan.yml (daily 03:00 KST + manual)"]
        E3[every image]
        E4["rescan-published.sh re-scans<br/>the tag in published.json (no build)"]
        E5{gate result}
        E6[clean → done for the day]
        E7["drift → gh workflow run<br/>build-image.yml"]
        E3 --> E4 --> E5
        E5 -->|PASS| E6
        E5 -->|FAIL| E7
    end

    E7 -.->|workflow_dispatch| D4
    E6 -.->|next day| E3
    P3 -.->|image files changed again| C1
    P3 -.->|check rescan result only| Manual["human runs<br/>gh workflow run rescan.yml"]
    Manual --> E3
```

The four stages:

1. **Author a new image (human, local)** — once the files are written, build, verify,
   and check the gate locally without pushing (see the new-image checklist in
   [image-authoring/README.md](image-authoring/README.md)).
2. **`push` trigger (automatic, `build-image.yml`)** — pushing the branch runs the same
   pipeline again for the changed images only, in verification-only mode where pushing to
   a registry is impossible. Contributors working in a fork get this automatically in
   their own fork; see [image-authoring/ci.md](image-authoring/ci.md).
3. **First publication — a human runs `build-image.yml` directly** — after merging,
   running it from `main` with `push=true` is what first pushes to the `REGISTRY_HOST`
   registry and creates the first `published.json` entry. From then on it is a "published
   image".
4. **Maintenance loop — `rescan.yml` (daily, automatic and manual)** — published images
   are re-scanned every day. If clean, nothing happens; if CVE drift appears,
   `rescan.yml` calls `build-image.yml` for that image alone to rebuild and republish
   (the rebuild logic itself is never duplicated). See "daily drift check" in
   [image-authoring/ci.md](image-authoring/ci.md).

---

## 3. Pipeline phases in detail

### Phase 1: Build

* **Input**: `images/<image>/<variant>.build.env` (versions and arguments),
  `<variant>.Dockerfile`
* **Behaviour**: reads the configured variables (`APP_VERSION`, `TARGET`, …) and runs
  `docker build`.
* **Characteristic**: the build reuses upstream's own logic (builder stages) as far as
  possible, but the runtime base is unconditionally replaced with SUSE BCI. Every source
  the build fetches is integrity-checked — commit SHA for git, committed SHA256 for
  tarballs.

### Phase 2: Verify (functional smoke test)

* **Input**: `images/<image>/verify.sh`
* **Behaviour**: starts the freshly built image (the script runs on the host) and checks
  that basic functionality is intact.
* **What is checked**:
  * `--version` matches the intended version.
  * The image runs correctly as non-root, without needing root.
  * `--help` and the basic commands work.

### Phase 3: SBOM

* **Tool**: `trivy image --format cyclonedx` (invoked inside
  `build-hardened-image.sh` / `rescan-published.sh`)
* **Behaviour**: extracts which packages, libraries, and dependency modules the image
  contains as a CycloneDX SBOM, written to the output directory.

### Phase 4: Scan

* **Tool**: `scripts/gate/scan-image.sh`
* **Behaviour**: calls `trivy` against the extracted SBOM and produces the vulnerability
  list across all severities as JSON.
* **Characteristic**: beyond a plain scan, it runs a self-check (`CoverageProbe`) that
  confirms trivy can actually scan this distribution base at all.

### Phase 5: Gate

* **Tool**: `scripts/gate/image-gate.py`
* **Behaviour**:
  1. Checks that `CoverageProbe` reads `ok` — eliminating false negatives where zero
     findings merely means the scanner could not read the distribution.
  2. Cross-checks NVD against the vendor (SUSE) rating (`max(NVD, vendor)`) and
     determines whether even one effective CRITICAL or HIGH vulnerability remains.
  3. Ignores entries registered in the exception list (`cve-exceptions.json`).
* **Result**: any violation is a hard error that stops the pipeline. Only images that
  pass this gate count as "zero-CVE".

### Phase 6: Push, attest, and record

* **Behaviour**: only images that passed the gate are pushed to the registry named by
  the repository variable `REGISTRY_HOST`. A failed push is an error, not a warning.
* **Attestation**: after a successful push, GitHub build provenance and an SBOM
  attestation are attached to the image **digest**, by a job that runs none of this
  repository's code.
* **Follow-up**: under CI (`build-image.yml`), the pushed tag and digest are written to
  `published.json`, and the SBOM is committed to `sboms/<image>.cdx.json` so it outlives
  the run. Both are done by a separate job that holds the write permission — the build job
  itself has none.
