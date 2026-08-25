---
name: self-build-image
description: Use when adding a self-built hardened image or changing an existing build definition. Requests like "build this image ourselves", "add a hardened image", "resolve the blocking CVE with a self-build", "run build-hardened-image.sh", or "a new image under images/" belong here. There are currently eight: adc, apisix, apisix-ingress-controller, argocd, cloudnative-pg, cnpg-postgresql, etcd, keycloak (the images/ directory is the single source of truth for the exact list).
---

# Self-built hardened images

In the CVE gate escalation order (newer upstream tag → base OS swap → **self-build** →
approved exception), you only get here when the first two do not resolve it.

## Rule — there is always one orchestrator

**`scripts/build/build-hardened-image.sh` builds every self-built image.** Whether it
reinstalls OS packages or compiles from source, the script is the same, and all the
difference lives in `images/<image>/`.

**Do not create a new orchestration script because "this image is different"** — the
sequence (build → functional verification → SBOM → scan → gate → push) is identical
regardless of image type. Do not rebuild SBOM, scanning, or the gate either —
`build-hardened-image.sh` already calls `scan-image.sh` and `image-gate.py`.

## Running it

```sh
IMAGE=<image> BASE_OS=<variant> bash scripts/build/build-hardened-image.sh /tmp/out
```

Once `images/<image>/<variant>.build.env` declares the contract (`DOCKERFILE`, `TARGET`,
`BUILD_ARGS`, …), the script does not need to know the image type. The full contract table
and the step-by-step procedure for adding an image are in
[docs/image-authoring/](../../../docs/image-authoring/README.md) — not duplicated here.

In CI, `build-image.yml` is already parameterised by the `image` input. Adding
`images/<image>/image.env` is enough to run it, with no workflow changes.

The build is triggered by `push`, not `pull_request` — a fork's code must never execute on
this repository's runners, and `verify.sh` runs on the host by design. Contributors get the
full pipeline in their own fork. Pull requests get static checks only
(`pr-checks.yml`, running `scripts/lint/repo-checks.sh`). See
[ci.md](../../../docs/image-authoring/ci.md) and
[CONTRIBUTING.md](../../../CONTRIBUTING.md).

## A new Dockerfile starts by choosing two axes

**The authoring rules themselves live in
[docs/image-authoring/](../../../docs/image-authoring/README.md)** — not duplicated here.
This table only tells you which section to read.

The two axes are **independent**. The same `bci-micro` final stage sits under a Go builder
or a Node builder.

**Axis 1 — the final runtime base** (what gets scanned and shipped. Rule 2)

| What the runtime needs | Choose | Precedents |
|---|---|---|
| OS packages and a shell (zypper install, a shell entrypoint) | `bci-base` | `adc` `apisix` `argocd` `cnpg-postgresql` |
| A single statically linked binary | `bci-micro` | `apisix-ingress-controller` `cloudnative-pg` `etcd` |
| The runtime tree assembled in the builder (a JVM, for instance) | `scratch` + a micro rootfs seed | `keycloak` |

→ To go outside these three, **first write down why none of them works.** With
`micro`/`scratch` you take on the nonroot account and the absence of `sed`/`grep` yourself
(see "Pick the BCI variant" in
[base-os-policy.md](../../../docs/image-authoring/base-os-policy.md)).

**Axis 2 — the builder stage** (does not survive into the final image, so rule 2 does not
apply → use the official language image as-is)

| Language | Builder | Pin keys |
|---|---|---|
| Go | `golang:${GO_BUILDER_TAG}` + `$BUILDPLATFORM`/`TARGETARCH` | `GO_BUILDER_TAG` · `GO_MODULE_UPGRADES` |
| Node | `node:*` (the runtime uses the **OS package** `nodejs24`) | `NODE_BUILDER_TAG` · `NODE_PKG` |
| JVM | BCI base — **replace only the vulnerable jars**, no recompilation | `<LIB>_OLD` / `<LIB>_VERSION` pairs |
| C · Lua | BCI base — **no static linking** (there is no static glibc) | a version ARG per component |

→ Details in
[builder-languages.md](../../../docs/image-authoring/builder-languages.md). Three things
are common to every language: **keep versions out of the Dockerfile and in `build.env`**,
**always register them in `BUILD_ARGS`** (miss it and the build silently uses the
default), and **preserve the upstream runtime contract** (`USER`, `ENTRYPOINT`, the file
layout).

## Everything the build fetches must be verified

Design rule 7. git sources are pinned by commit SHA (BuildKit's git context verifies
them); tarballs get their SHA256 committed in `build.env` and verified with
`sha256sum -c`. Never disable TLS verification, and never pipe a remote script into a
shell — replace it with a distribution package, or download, verify, then execute. Details
in "Everything the build fetches gets verified" in
[docs/image-authoring/](../../../docs/image-authoring/README.md).

`bash scripts/lint/repo-checks.sh` enforces this and the other repository invariants. Run
it before opening a pull request — it is also what `pr-checks.yml` runs. When you hit a new
class of mistake, add a check there rather than only fixing the instance.

## Scheduled rebuilds are automatic — drift is checked daily

A separate workflow, `rescan.yml`, re-scans every image daily (03:00 KST by default) with
`scripts/gate/rescan-published.sh` (it does not build). If the published tag is still
clean, nothing happens that day; if the gate newly fails (drift), it calls
`build-image.yml` for that image alone to rebuild and push — the rebuild logic exists in
exactly one place, `build-image.yml`. Details in the "`rescan.yml` — daily drift check"
section of [ci.md](../../../docs/image-authoring/ci.md).

When something must land now and cannot wait for the next schedule, call it by hand:

```sh
gh workflow run self-build-image --repo paasup/hardened-containers -f image=<image>
```

Whether Go module and toolchain pins have fallen behind can be checked inside this
repository:

```sh
python3 scripts/build/suggest-go-upgrades.py --reports <trivy-reports dir> --image <image>
python3 scripts/build/suggest-go-upgrades.py --reports <trivy-reports dir> \
  --image <image> --apply --dry-run
```

For a full freshness check including non-Go pins (`SOURCE_COMMIT`, jar versions), or to
judge "should we still be self-building this image", use the
[pin-freshness-check](../pin-freshness-check/SKILL.md) skill. If the gate is blocked on
CRITICAL/HIGH and an exception needs registering, use the
[cve-exception-review](../cve-exception-review/SKILL.md) skill.

## README.md follows a fixed shape

Whether writing a new one or revising an existing one, follow the order in
[readme-template.md](../../../docs/image-authoring/readme-template.md) — not duplicated
here. READMEs are bilingual: `README.md` (English) alongside `README.ko.md` (Korean), with
Korean as the source of truth. The "Version management" section is the easy one to skip,
and skipping it leads straight to the pitfall below.

## Comments carry mechanism; documents carry rationale

Do not write long explanations of "why we build this ourselves", CVE evidence, or
candidate comparisons in Dockerfile, `build.env`, or `verify.sh` comments — those belong
in the README and the ADR. The full rule is in the "Comment rules" section of
[docs/image-authoring/](../../../docs/image-authoring/README.md).

## Measured pitfalls

- **An `ARG` used in a `FROM` must be declared before the first `FROM` (global scope).**
  Declared inside a stage it becomes local to that stage, is not used to resolve later
  `FROM` image names, and the build fails with an empty image name.
- **The `# syntax=` parser directive must be the very first line of the file.** Put a
  comment above it and it silently stops being a directive, so the pinned frontend is not
  used.
- **A passing gate does not prove the image works.** A CVE scanner cannot see runtime
  requirements at all (an operator depending on its own file layout, for instance).
  Verifying behaviour in a real deployment is a separate step.
- **Check that `CoverageProbe` reads `ok`.** `none` means the zero findings were not a
  measurement but an absence of scanner data for that distribution.
- **No rolling tags.** Even at the same application version the result of base updates
  differs from one point in time to another, so the tag includes the build date (for
  example `1.30.0-security-hardened-20260804`).
- **The price of pinning is that pins fall behind.** With no source change, a newly
  disclosed CVE turns yesterday's PASS into today's FAIL. Check with
  `suggest-go-upgrades.py` first whether a rebuild resolves it.
- **Rebuilding on the same day collides with that tag.** A node's cached old digest gets
  reused (`imagePullPolicy: IfNotPresent`) and the fix appears "not applied". Set
  `imagePullPolicy: Always` manually on the workload under test and confirm by digest —
  apply it to deployment values only temporarily, then revert.
- **If the README does not list the manual pins, the next person assumes they update
  automatically.** Values no script touches — `SOURCE_COMMIT`, hand-raised library and jar
  versions — must be marked "not tracked automatically" in the README's "Version
  management" section. Two of the eight images (the one with many complex pins, and the
  one with the exact PGDG EVR pin) were once left without that section entirely.
- **Leaving a CVE handled through `cve-exceptions.json` in the README's "Why we build this
  ourselves" tally makes it look like the self-build fixed everything.** Distinguish, in
  the README, CVEs whose risk was accepted through an exception from those actually fixed
  by changing code or packages — if the tally does not add up against the real remediation
  record (a CVE in the tally that is not an overlay target, say), that cross-check has
  broken.

## Wrapping up

What this repository does ends at build, verify, gate, push, and the `published.json`
update (see [ci.md](../../../docs/image-authoring/ci.md)). Record the investigation and
the rationale for decisions in commit messages and
[MEMORY.md](../../../MEMORY.md).
