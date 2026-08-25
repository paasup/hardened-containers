# hardened-containers — harness engineering guide

## What this repository is

A standalone repository that builds, verifies, and gates hardened container images with
their CVEs removed. Images are pushed to the registry named by the repository variable
`REGISTRY_HOST` (locally, the `REGISTRY` environment variable).

**It works on its own, with no external dependencies.** Clone it, have `docker` and
`trivy`, and everything from build to gate verdict completes inside this repository.
There is no code that checks out another repository, uses another repository's tokens,
or calls another repository's workflows.

## Directory layout

```
hardened-containers/
├── images/<image>/          # image definitions — this directory is the single source of truth for the list
│   ├── <variant>.Dockerfile
│   ├── <variant>.build.env  # build contract (DOCKERFILE · TARGET · BUILD_ARGS · APP_VERSION)
│   ├── image.env            # holds only DEFAULT_BASE_OS
│   ├── verify.sh            # functional verification — runs on the host under bash
│   └── README.md            # why we build it ourselves + differences from upstream
├── scripts/
│   ├── build/
│   │   ├── build-hardened-image.sh   # the one orchestrator — build→verify→SBOM→scan→gate→push
│   │   └── suggest-go-upgrades.py    # suggests Go module/toolchain pins, applies with --apply
│   ├── lint/
│   │   └── repo-checks.sh            # static repository checks — runs locally and on every PR
│   └── gate/
│       ├── scan-image.sh             # trivy sbom scan + coverage self-check
│       └── image-gate.py             # the zero-CRITICAL/HIGH gate verdict
├── .github/workflows/       # build-image.yml (build/publish) · pr-checks.yml (static PR checks)
│                            # · rescan.yml (daily drift check)
├── docs/
│   ├── image-authoring/
│   │   ├── README.md            # entry point — orchestration rules, checklist, the two shapes
│   │   ├── base-os-policy.md    # choosing the base OS (SUSE BCI)
│   │   ├── builder-languages.md # per-language builder rules + Go module CVEs
│   │   ├── scanner-caveats.md   # why scanner output and tags cannot be trusted directly
│   │   ├── ci.md                # CI behaviour, signing and attestation
│   │   └── readme-template.md   # template for per-image README.md
│   ├── architecture.md          # the pipeline end to end
│   └── decisions/               # ADRs — why each image is built here
├── cve-exceptions.json      # approved CVE exceptions
├── published.json           # publication record — tag and digest of images that passed the gate and were pushed
├── sboms/<image>.cdx.json   # SBOM of each published image — committed so it outlives the build
├── LICENSE · NOTICE         # license scope + third-party and trademark notices
├── SECURITY.md              # what is guaranteed, how to report a vulnerability
├── CONTRIBUTING.md          # how CI works here, what to run before a PR
└── MEMORY.md                # current state and open items
```

## Design rules

1. **One orchestrator, always.** `build-hardened-image.sh` builds every image. Do not
   create a new script per image type (OS-package-reinstall versus source-compile) —
   the difference must live only in the files under `images/<image>/`.
2. **The final runtime base is SUSE BCI.** Builder stages are exempt (official language
   images are used as-is).
3. **Lift versions out as values.** Not hardcoded in the Dockerfile but in `build.env` —
   so that fixing a CVE does not mean editing the Dockerfile.
4. **No rolling tags.** The tag carries the build date, and dependency pins are committed
   values — because they are "a record of what we verified".
5. **Never rebuild SBOM, scanning, or the gate.** The two scripts in `scripts/gate/` work
   regardless of image type.
6. **A passing gate does not prove the image works.** A CVE scanner cannot see runtime
   requirements. Verifying behaviour in a real deployment is a separate step.
7. **Everything the build fetches gets verified.** Building a security image without
   verifying its ingredients defeats the purpose. Concretely:
   - Never disable TLS verification (`--no-check-certificate` and `curl -k` are
     forbidden).
   - Never pipe a remote script into a shell (`curl … | sh`). Replace it with a
     distribution package, or download it, verify the checksum, and then execute.
   - For tarballs, commit the SHA256 in `build.env` and verify with `sha256sum -c`. For
     git sources, pin by commit SHA rather than tag (BuildKit's git context guarantees
     integrity).
   - These values follow rules 3 and 4 — a checksum is also "a record of what we
     verified".
8. **Keep the means of verification alongside what is published.** People pulling an
   image do not read this repository's logs, and Actions artifacts expire — so two things
   outlive the run: the SBOM of every published image is **committed** to `sboms/`, and the
   pushed digest gets GitHub build-provenance and SBOM **attestations**. The first answers
   "what is inside it" with no service to call; the second answers "did this repository's
   workflow really produce it".

## Running locally

```sh
# build → verify → SBOM → scan → gate (no push)
IMAGE=<image> BASE_OS=<variant> bash scripts/build/build-hardened-image.sh /tmp/out

# through to a registry push
REGISTRY=<your-registry> IMAGE=<image> BASE_OS=<variant> \
  bash scripts/build/build-hardened-image.sh /tmp/out

# suggest Go module / toolchain pins
python3 scripts/build/suggest-go-upgrades.py --reports /tmp/out/trivy-reports --image <image>
```

`cve-gate.md` (markdown) and `cve-gate.json` (structured data) are left in `/tmp/out`.

## Adding an image

Follow the "Checklist for adding an image" in
[docs/image-authoring/](docs/image-authoring/README.md).

## Where work gets recorded

| Kind | Destination |
|------|--------|
| **What changed and why** (the history of completed work) | commit message · `images/<image>/README.md` |
| **A pitfall not to step into again** | [docs/image-authoring/](docs/image-authoring/README.md) |
| **Why one candidate was chosen over others** | [docs/decisions/](docs/decisions/) — ADRs |
| **Current state and what to do next** | [MEMORY.md](MEMORY.md) |

`MEMORY.md` is not where completed work accumulates — once an item is no longer "what to
do next", move it to one of the three above and delete it.

## Documentation language

Documentation is English. READMEs are bilingual: `README.md` (English) alongside
`README.ko.md` (Korean), for the repository root and for each image. **Korean is the
source of truth** — edit `README.ko.md` first, then carry the change into English.
