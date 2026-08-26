# Image authoring rules

**This is the entry point for the documentation in this repository.** Start here when
adding an image, changing an existing build definition, or working out what
`build-image.yml` does. Topic-specific rules live in separate documents linked below.

Self-built images live in `images/<image>/` (that directory is the single source of
truth for the list) and are pushed to the registry named by the repository variable
`REGISTRY_HOST`. What follows is how the framework works and the rules to follow when
adding or changing an image.

## Contents

| Document | Covers |
| --- | --- |
| (this document) | comment rules · the orchestration contract (rule 1) · base OS policy overview (rule 2) · supply-chain rules · the two image shapes · the new-image checklist |
| [base-os-policy.md](base-os-policy.md) | Choosing the runtime base OS (SUSE BCI) — when to use which BCI variant, measuring versions, the "seed" rootfs, tools missing from `bci-micro`, SLE package names |
| [builder-languages.md](builder-languages.md) | Builder-stage rules per language (Go · Node · JVM · C/Lua), handling Go module CVEs, pin drift |
| [scanner-caveats.md](scanner-caveats.md) | Why trivy output cannot be taken at face value, and how to confirm an image tag's actual base OS |
| [ci.md](ci.md) | Why the build is triggered by `push`, how `build-image.yml`, `pr-checks.yml`, and `rescan.yml` behave, signing and attestation, the publication record (`published.json`) |
| [support-policy.md](support-policy.md) | What "latest" means per application — declaring the upstream line an image sits on, the daily end-of-life check, and publishing more than one line |
| [readme-template.md](readme-template.md) | Template for per-image `README.md` |

## Comment rules — mechanism in code, rationale in docs

Comments in Dockerfiles, `*.build.env`, `verify.sh`, and `scripts/` explain **what this
code does, and any non-obvious constraint or workaround** — one to three lines, no more.

The following do *not* belong in comments. Move them per the "Where work gets recorded"
table in [CLAUDE.md](../../CLAUDE.md):

| Content | Destination |
| --- | --- |
| Why build this ourselves, why this approach was chosen (candidates compared, alternatives rejected) | an ADR in `docs/decisions/` |
| What was changed and why (differences from upstream, package mappings) | the image's `README.md` |
| Reproducible CVE numbers, counts, version lists | the commit message — the gate re-measures these on every run. Never freeze a snapshot in code or an ADR as if it stays current |
| Pitfalls shared across images (`CoverageProbe`, tools missing from `bci-micro`, Go module CVEs) | this document and the topic documents below — if a section already covers it, just point at that section |

One exception: the **upstream correspondence table** at the top of a Dockerfile (what is
the same, what differs) is a structural record and stays in the code. Only the
multi-line "why" prose around it moves out to the README or an ADR.

## Rule 1 — one orchestrator, and it does not know about image types

**`scripts/build/build-hardened-image.sh` builds every image.** Whether an image
reinstalls OS packages or compiles from source, the script is the same — all the
difference lives in `images/<image>/`.

**Writing a new orchestration script is a last resort.** "This image is different" is
not a reason. The sequence (build → functional verification → SBOM → scan → gate →
push) is identical regardless of image type; the differences belong inside the
Dockerfile, in what gets installed or compiled and how.

### The contract `build-hardened-image.sh` requires

If `images/<image>/<variant>.build.env` declares the following, the script does not need
to know anything about the image:

| Key | Meaning |
| --- | --- |
| `DOCKERFILE` | Path relative to `images/<image>/` |
| `TARGET` | Stage name passed to `docker build --target` |
| `BUILD_ARGS` | Space-separated variable names. Only those listed are passed as `--build-arg` |
| `APP_VERSION` | Generic version string used for the tag prefix and passed to `verify.sh` (the only required value) |

Any other image-specific variable (`PG_MAJOR`, `SOURCE_COMMIT`, …) only has to be
written in `build.env` — it is **automatically passed to `verify.sh` as an environment
variable**, so the script never needs to know what to forward.

The default build variant is declared separately, in `images/<image>/image.env` as
`DEFAULT_BASE_OS` — used when no `base_os` input is given.

### `verify.sh` runs on the host, under bash

It is not a shell script piped into the guest container over stdin. It is invoked as
`env TAG=... PLATFORM=... <build.env variables> bash images/<image>/verify.sh`.

**Why**: an image may have no shell at all (distroless-style final images have no
`/bin/sh`). A host-side script can still use a guest shell where one exists
(`docker run --entrypoint sh ... <<'EOF'`) and can run a binary directly where one does
not (`docker run --entrypoint <binary>`) — running on the host is the superset. The
script must print `VERIFY-OK` to be treated as passing.

## Rule 2 — the runtime base OS is SUSE BCI

Consistency across images comes first: every image is BCI, and trivy's SLES coverage is
confirmed by a positive control on every scan (the gate's `CoverageProbe`).

- When this policy conflicts with "stay as close to upstream as possible", **record
  which one won and why in that image's README.** Having a policy is not a reason to
  skip the record.
- Builder stages (used to compile, not present in the final image) are out of scope —
  official language images (`golang`, …) are fine there. The policy applies only to the
  **final stage, which is what gets scanned and shipped**.

Choosing a BCI variant, measuring versions, the "seed" rootfs, tools missing from
`bci-micro`, and the SLE package-name differences are in
**[base-os-policy.md](base-os-policy.md)**.

## Builder-stage rules per language

Rule 2 above governs the final stage; builder stages are separate. Go, Node, JVM, and
C/Lua conventions, Go module CVE handling (`suggest-go-upgrades.py`), and pin drift are
in **[builder-languages.md](builder-languages.md)**.

## Everything the build fetches gets verified

[CLAUDE.md](../../CLAUDE.md) design rule 7. Building a security image without verifying
its ingredients defeats the purpose — the gate can confirm zero CVEs, and it means
nothing if that zero-CVE binary was compiled from source a man-in-the-middle swapped
out.

| Fetched | How integrity is established |
| --- | --- |
| git source | Pinned by **commit SHA**, not tag (`SOURCE_COMMIT`). BuildKit's git context verifies it — no separate checksum needed |
| tarball | SHA256 committed in `build.env`, verified with `sha256sum -c -` |
| remote install script | Replace it with a distribution package. If unavoidable, download, verify the checksum, then execute |
| distribution packages | Left to the package manager's GPG verification (zypper's default) |

**What we do not do**

- `--no-check-certificate` / `curl -k` — never disable TLS verification. If there is a
  real certificate problem, fix it by installing the CA, not by removing the check.
- `curl … | sh` / `curl … | perl -` — this executes an unverified remote script on every
  build. The moment the remote changes, something else gets installed, silently.

Checksums follow rules 3 and 4 like any other pin: keep them as values in `build.env`
and update them when the version changes. See `images/apisix/source.build.env` for how
they are derived and cross-checked.

## Do not take scanner output or tags at face value

Why trivy results and tag names cannot be trusted directly, and how the gate catches it,
is in **[scanner-caveats.md](scanner-caveats.md)**.

## Preserve the upstream runtime contract

The point is to remove CVEs, **not to change behaviour.** The scanner cannot see any of
this, so it is on people to get right.

- **Keep `USER` and `ENTRYPOINT` identical to upstream.** Changing the uid breaks volume
  permissions; changing the entrypoint breaks the chart's `args`.
- **Recreate the file layout upstream produced** — symlinks, empty directories,
  permissions and all. Operators and charts depend on it. (Mistaking a symlink for
  incidental scaffolding and deleting it can break multi-arch detection, failing
  reconciliation with `invalid architecture`.)
- **Reproduce in `verify.sh` whatever the chart runs against this image.** Then a base
  OS change fails at build time instead of in production — details in
  [base-os-policy.md](base-os-policy.md).
- Keep an **upstream correspondence table** at the top of the Dockerfile (what is
  identical, what differs). Every existing image follows this format.

## CI

How `build-image.yml` works (target selection per trigger, push, updating the
publication record), how signing and attestation work, and the `published.json` schema
are in **[ci.md](ci.md)**.

## Two shapes (both use the same script)

| Shape | What the Dockerfile does | Shell present? |
| --- | --- | --- |
| Reinstall OS packages | Reinstall upstream's shipped artifacts onto a different distribution (zypper/apt/…) | Usually yes — verify via a guest script |
| Compile from source | Compile an upstream pinned commit directly with `go build` or similar | Depends on the final base |

Either way, only three files are new: `<variant>.Dockerfile`, `<variant>.build.env`,
`verify.sh` (plus `README.md`).

## Checklist for adding an image

1. **Have you established why the upstream image is vulnerable?** Work out why the
   upstream image fails a gate that takes the higher of the vendor and NVD severity.
   Whether the CVEs come from OS packages or from the application binary itself (Go
   modules, statically linked libraries) determines the hardening strategy — a base OS
   swap versus compiling from source. Record that analysis (in the PR description or
   `MEMORY.md`).
2. **Decide which shape it is** ("reinstall upstream artifacts on another distribution"
   versus "compile from source"). Choose the final base OS now
   ([base-os-policy.md](base-os-policy.md)).
3. Write `images/<image>/<variant>.Dockerfile`, `<variant>.build.env`, `verify.sh`,
   `README.md`, and `image.env`. Record the correspondence with, and differences from,
   the upstream Dockerfile in a comment at the top of the file. `README.md` follows
   [readme-template.md](readme-template.md).
   **Any `ARG` used in a `FROM` must be declared before the first `FROM` (global
   scope).** Declared inside a stage it becomes local to that stage, is not used to
   resolve later `FROM` image names, and the build fails with an empty image name.
4. **Run the static checks.** They take about a second and cover most of what follows —
   the supply-chain rules, the `build.env` contract, the syntax directive, path
   references, and the bilingual README pair. The same script runs on every pull request
   (`pr-checks.yml`), so a failure here is the failure a reviewer would see:
   ```sh
   bash scripts/lint/repo-checks.sh
   ```
   Each check exists because that mistake was actually made here. If you find a new class
   of mistake, add a check rather than only fixing the instance.
5. Build locally:
   ```sh
   IMAGE=<image> BASE_OS=<variant> bash scripts/build/build-hardened-image.sh /tmp/out
   ```
   Check `cve-gate.md` for zero effective C/H. Also check that `CoverageProbe` reads
   `ok` — `none` means the zero findings were not a measurement but an absence of
   scanner data for that distribution, and the gate blocks on it.
6. **A passing gate does not prove the image works.** A CVE scanner cannot see runtime
   requirements unrelated to CVEs (an operator depending on its own file layout, for
   instance). Verifying behaviour in a real deployment is a separate step. Confirm the
   reason for every deliberate difference from upstream and record it in the README.
7. **When you refer to a path in an upstream repository, put the word "upstream" on the
   same line.** `repo-checks.sh` verifies that every path this repository mentions
   actually exists, and that word is how it tells someone else's path apart from ours
   (see etcd's `upstream scripts/build_lib.sh`).
8. This repository's responsibility ends at updating `published.json`.
9. CI automation: `build-image.yml` is already parameterised by the `image` input —
   adding `images/<image>/image.env` is enough to run it, with no workflow changes. Note
   that the build is triggered by `push`, not `pull_request`; a fork contributor gets the
   full pipeline in their own fork. See [ci.md](ci.md) and
   [CONTRIBUTING.md](../../CONTRIBUTING.md).

## Never rebuild SBOM, scanning, or the gate

`scripts/gate/scan-image.sh` and `scripts/gate/image-gate.py` work regardless of image
type and already include the coverage self-check (`CoverageProbe`).
`build-hardened-image.sh` calls both — do not reimplement either per image.
