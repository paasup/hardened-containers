# CI — `build-image.yml`, `pr-checks.yml`, and `rescan.yml`

Detail behind [image-authoring/](README.md). There are three workflows — **only
`build-image.yml` builds**. `rescan.yml` adds no gate or build logic of its own and just
calls `build-image.yml` when needed (rule 1 — one orchestrator, always), and
`pr-checks.yml` builds nothing at all.

## Why the build is triggered by `push`, not `pull_request`

`verify.sh` runs on the host under bash, by design — some final images have no shell, so
the verification script cannot live inside the container. Running a build therefore means
executing this repository's scripts on a runner.

On a public repository, a `pull_request`-triggered build would let any fork's pull request
execute arbitrary commands on the maintainers' runners. So the heavy build listens for
`push` instead. A `push` event only fires for commits that are already in this repository,
and pushing a branch requires write access — **untrusted code cannot reach these runners at
all.** That is a structural property, not a condition that could be mis-written or later
relaxed.

Contributors are not blocked by it: the workflow file exists in their fork too, so a push
to a branch there runs the whole pipeline on their own runners. Pull requests still get
static checks from `pr-checks.yml`. See [CONTRIBUTING.md](../../CONTRIBUTING.md).

## `build-image.yml` — build, verify, gate, push

The runner is a single script, `scripts/build/build-hardened-image.sh`, which calls
build → `verify.sh` → SBOM → `scan-image.sh` → `image-gate.py` in order.

**The gate in this workflow is enforced.** If it fails, nothing is pushed and the
publication record is not updated.

| Trigger | Target selection | Build/verify/gate | Registry push | `published.json` update |
|---|---|---|---|---|
| `workflow_dispatch` | `image` input (required) · `base_os` (defaults to `DEFAULT_BASE_OS` in `image.env`) · `push` (default `true`) | ✅ | only with `push=true`, from the default branch | on gate PASS + successful push |
| `push` (`images/**`, `scripts/**`, any branch) | Changed `images/<image>/` detected from the diff | ✅ | ❌ | ❌ |

Branches are deliberately unrestricted (`branches: ['**']`): narrowing to the default
branch would remove a fork contributor's CI, which is the whole point of the `push`
trigger. Naming `branches` also excludes tag pushes, which a `paths` filter alone would
not. Compute is bounded instead by `concurrency` cancellation and the fan-out cap below.

This workflow has no schedule of its own — a person invokes it via `workflow_dispatch`, or
`rescan.yml` calls it after detecting drift.

A `push` run cannot push to a registry because it never passes `REGISTRY` — the tag stays
`localhost/...`, so a registry push is not even possible. That is the verification-only
safeguard.

### The fan-out cap

A change under `scripts/**` alters the orchestrator itself, so in principle it should be
verified against every image. Doing that on every push would cost up to eight hours of
runner time. Instead it targets a representative subset covering both image shapes and all
three base variants — `etcd` (source-compiled, bci-micro), `cnpg-postgresql` (OS-package
reinstall, bci-base), and `keycloak` (scratch plus micro rootfs seed). A full sweep stays
available through `workflow_dispatch`.

**The cap is always logged.** A silent subset would read as "everything was verified".

A brand-new branch has no diff base (`github.event.before` is all zeros), so it falls back
to the same subset rather than building everything.

### Publishing is restricted to the default branch

`workflow_dispatch` lets a person choose any ref. Without a restriction, someone with write
access could push a branch carrying a modified build script, dispatch from it, and publish
an arbitrary image to the production registry — signed with this repository's OIDC
identity. Two things prevent that:

- The "Decide whether to publish" step refuses to enable publishing unless
  `github.ref` is the default branch.
- The `record` job runs in the `production` GitHub Environment. Configure that environment
  with **Deployment branches: selected → the default branch**, and keep the registry
  secrets there rather than at repository level. Unlike an `if:`, that cannot be edited
  away in a pull request.

The registry comes from the repository variable `REGISTRY_HOST` (Settings → Secrets and
variables → Actions → Variables). Credentials come from the `DOCKERHUB_USER` and
`DOCKERHUB_TOKEN` secrets. **If `REGISTRY_HOST` is empty, publishing cannot be enabled** —
that way a fork running the workflow without configuring anything verifies and stops,
rather than attempting to push to someone else's registry.

### Job permissions

Split so that no job holds a credential it does not need, and so that write access and an
OIDC token never coexist with running this repository's own code.

| Job | Permissions | Runs repository code? |
|---|---|---|
| `discover` | inherits `contents: read` | No — a git diff only |
| `build` | `contents: read` | **Yes** — Dockerfiles and `verify.sh` |
| `attest` | `contents: read`, `id-token: write`, `attestations: write` | No — reads a digest and calls the action |
| `record` | `contents: write` (environment `production`) | No — reads the records and commits |

The `build` job holds nothing but read. It is the only job that executes a Dockerfile or
`verify.sh`, so an OIDC token there would let repository code mint an identity for this
repository — instead attestation happens in its own job that runs none of it.


### What a published image is accompanied by

Two separate things, with different lifetimes and different purposes.

| | Where it lives | What it answers | Needs a service to read? |
|---|---|---|---|
| **The SBOM** | Committed to `sboms/<image>.cdx.json` | What is inside the published image | No — it is in the repository |
| **Attestations** | GitHub Artifact Attestations, keyed by digest | Was this digest really produced by this repository's workflow | Yes — `gh attestation verify` |

The SBOM is committed rather than left as a build artifact because Actions artifacts
expire (90 days by default) while [NOTICE](../../NOTICE) points at the SBOM as the
authoritative statement of what an image contains. Committed, it is permanent, diffable,
and readable offline.

Attestations are produced by `actions/attest-build-provenance` (SLSA build provenance)
and `actions/attest-sbom`, in a **separate `attest` job**. That job runs none of this
repository's code — it reads the digest from the artifact the build job uploaded — so the
OIDC token never coexists with executing a Dockerfile or `verify.sh`. `push-to-registry`
is false, so the attestation is stored by GitHub and the job needs no registry
credentials.

Verification instructions are in the [README](../../README.md).

## `pr-checks.yml` — static checks on a pull request

Because the build moved to `push`, a pull request page would otherwise show no checks at
all. This workflow restores a signal without restoring the risk: it runs
`scripts/lint/repo-checks.sh`, which only reads files — no docker, no registry, no
secrets, a read-only token, and a five-minute cap.

This is the one place a fork's contents reach this repository's runners, and the worst a
malicious pull request achieves there is about a minute of wasted compute.

The same script is what contributors run locally before opening a pull request, so the
failure they see is the failure a reviewer sees. What it checks:

| Check | Why it exists |
|---|---|
| Internal path references resolve | ADR renumbering silently broke nine references once |
| No `--no-check-certificate`, no `curl \| sh` | Design rule 7 |
| Every remote download verifies a checksum in the same `RUN` | Otherwise a tarball has no integrity guarantee |
| `build.env` declares the contract, and every `BUILD_ARGS` name is assigned | An unassigned name builds silently with the Dockerfile default |
| `# syntax=` is the first line | A comment above it silently voids the directive — this was true of all six Dockerfiles once |
| Every README has its Korean counterpart, cross-linked | The bilingual rule |
| bash, python, json, and workflow YAML parse | Baseline |

Every one of these exists because that mistake was actually made here. Adding a check is
how a class of mistake stops recurring.

## `rescan.yml` — daily drift check

The original principle was that this repository does not decide whether a deployed
image has fallen out of compliance. That judgement used to come from external
monitoring; when that went away, this repository took it over. Rather than putting a
schedule on `build-image.yml`, it lives in a **separate workflow** — "build" and "check
daily whether what we already published is still clean" are different jobs, and making
the second merely call the first is a relationship worth showing in the file boundary.

| Trigger | Target selection | Behaviour |
|---|---|---|
| `schedule` (daily, 03:00 KST) | every image | the procedure below |
| `workflow_dispatch` | `image` (empty = all) · `push` (default `true`) | the same procedure, manually |

1. **Rescan** — `scripts/gate/rescan-published.sh <image> <out_dir>` pulls the current
   tag recorded in `published.json` and re-runs SBOM, scan, and gate only (no build).
   It reuses `scan-image.sh` and `image-gate.py` exactly as the build path does.
2. **Drift verdict** — if the gate still passes, nothing happens for that image that day
   (no rebuild, no new tag, no push — this avoids wasting CI time and tag space). A
   failure means an image that was clean yesterday is now blocked by a new CVE: that is
   "drift".
3. **Rebuild call** — if there is drift and the `push` input is not `false`, the job
   uses its `GITHUB_TOKEN` (`actions: write`) to run
   `gh workflow run build-image.yml -f image=<image> -f push=true`. The rebuild,
   verification, SBOM, scan, gate, and push are all performed by `build-image.yml`
   itself. Whether the rebuild actually resolves the CVE is decided by that workflow's
   gate — if it does not, nothing is pushed.
4. **Failure notification** — there is no automatic issue creation. If the gate keeps
   failing on rebuild, the `build-image.yml` job stays in a failed state and GitHub
   Actions' default notification (email, per repository watch settings) carries it.

An image with no entry in `published.json` yet (before first publication) has nothing to
rescan, so it is treated as drifted and `build-image.yml` is called immediately.

**To see rescan results without triggering a rebuild**, run it manually with
`push=false` — drift is reported in the Job Summary and artifacts, but
`build-image.yml` is not called:

```sh
gh workflow run rescan.yml -f image=<image> -f push=false   # rescan only, never rebuild
gh workflow run rescan.yml -f image=<image>                 # rebuild immediately on drift
gh workflow run rescan.yml                                  # omit image = every image
```

## Publication record — `published.json`

This file is updated and committed only when the gate passed *and* the registry push
actually happened — it records which image passed the gate and was really pushed, at
which tag and digest.

```json
{
  "schemaVersion": 1,
  "images": {
    "<image>": {
      "ref": "<REGISTRY_HOST>/<image>:<tag>",
      "tag": "<tag>",
      "digest": "sha256:...",
      "gate": "pass"
    }
  }
}
```

**Why the `digest` is recorded too** — a tag alone cannot later confirm that a running
image is the build that was verified. With the digest you can compare against the actual
digest of what is deployed.

**A record is only written for an image that really was pushed.**
`build-hardened-image.sh` exits non-zero if the push fails or the digest cannot be read,
and the build job additionally refuses to emit a record with an empty tag or digest — two
independent guards, because a false "published" record is worse than a failed build.

Each matrix entry uploads its own `{image, ref, tag, digest}` record as an artifact, and
the single `record` job merges them into one commit. (Job outputs cannot be used here:
outputs from a matrix job are overwritten by each entry, so only the last image would
survive.) Because just one job commits, matrix entries no longer contend with each other
at all; the rebase-and-retry loop remains only for contention with another workflow run.
