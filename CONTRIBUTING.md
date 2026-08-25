# Contributing

Thanks for taking the time. This document is mostly about one thing that is unusual here:
**pull requests from a fork do not run the image build on this repository — they run it in
your fork instead.** That is deliberate, and it is not a downgrade. Read the next section
before anything else.

## How CI works here, and why

`verify.sh` runs on the host under bash, by design — some final images have no shell at
all, so the verification script cannot live inside the container. The consequence is that
running the build means executing this repository's scripts on a runner.

On a public repository, a `pull_request`-triggered build would therefore let any fork's
pull request execute arbitrary commands on the maintainers' runners. So the heavy build is
triggered by `push`, not `pull_request`. A `push` event only fires for commits already in
the repository, and pushing a branch requires write access — untrusted code cannot reach
those runners at all.

**The same workflow file is in your fork.** Push to a branch in your fork and the whole
pipeline — build, verify, SBOM, scan, gate — runs there automatically, on your own runners.
You get exactly the CI a maintainer would get.

| Where | What runs | Automatic? |
|---|---|---|
| Your fork, on push | The full pipeline (`build-image.yml`) | Yes — after you enable Actions once |
| The upstream pull request | Static checks only (`pr-checks.yml`) | Yes |
| Upstream full build | A maintainer runs `workflow_dispatch` | On review |

A pull request here showing only "pr-checks" is normal. It does not mean your change went
unverified.

## Getting set up

1. **Fork the repository** and clone your fork.
2. **Enable Actions in your fork** — the Actions tab, then the "I understand my workflows,
   go ahead and enable them" button. GitHub disables workflows in forks by default, so this
   one-time step is what turns your fork's CI on.
3. Create a branch and make your change.

## Before you open a pull request

**Run the static checks.** They take about a second and catch most mistakes:

```sh
bash scripts/lint/repo-checks.sh
```

**Build and gate the image you changed.** This repository is self-contained by design: what
you run locally is the same pipeline CI runs, not a reduced version of it. You need only
`docker` and `trivy`.

```sh
IMAGE=<image> BASE_OS=<variant> bash scripts/build/build-hardened-image.sh /tmp/out
cat /tmp/out/cve-gate.md
```

Two things to confirm in that output:

- Effective CRITICAL/HIGH is **0/0**.
- `CoverageProbe` reads **`ok`**. A `none` means the zero findings were not a measurement
  but an absence of scanner data for that distribution — the gate blocks on it.

`BASE_OS` is the `DEFAULT_BASE_OS` value in `images/<image>/image.env` unless you are
deliberately building another variant.

## Opening the pull request

Include:

- **A link to the successful run in your fork** (Actions → the run for your branch).
- **The `cve-gate.md` output** for the image you changed, pasted into the description.
- What changed relative to upstream, and why — the same standard the image READMEs hold.

A maintainer reviews the diff and, when it looks right, runs the build on this repository
via `workflow_dispatch` before merging.

## Rules that will come up in review

**Everything the build fetches must be verified.** This is design rule 7 in
[CLAUDE.md](CLAUDE.md), and it is the point of the whole repository — a hardened image
built from unverified ingredients is not hardened.

- Never disable TLS verification. No `--no-check-certificate`, no `curl -k`. If a
  certificate genuinely fails, install the CA; do not remove the check.
- Never pipe a remote script into a shell. No `curl … | sh`. Use a distribution package,
  or download, verify a checksum, then execute.
- Pin git sources by **commit SHA**, not by tag.
- For tarballs, commit the **SHA256** in `build.env` and verify it with `sha256sum -c` in
  the same `RUN` that downloads it. See `images/apisix/source.build.env` for how the values
  are derived and cross-checked.

`scripts/lint/repo-checks.sh` enforces all of these, so you will see them fail locally
before a reviewer ever sees them.

**Do not add a second orchestrator.** `scripts/build/build-hardened-image.sh` builds every
image, whatever its shape. Differences belong inside `images/<image>/`, not in a new
script. Likewise, never reimplement SBOM generation, scanning, or the gate.

**Keep the upstream runtime contract.** `USER`, `ENTRYPOINT`, and the file layout must
match upstream. A CVE scanner cannot see any of this, so a passing gate does not tell you
that you preserved it.

## Adding a new image

Follow the checklist in
[docs/image-authoring/](docs/image-authoring/README.md). It covers choosing the base OS,
the `build.env` contract, and what `verify.sh` has to do. The
[readme-template.md](docs/image-authoring/readme-template.md) defines the structure of a
per-image README.

Note that an ADR in [docs/decisions/](docs/decisions/) is expected when candidates were
compared and one was rejected — not for changes with only one possible course of action.

## Documentation language

READMEs are bilingual: `README.md` (English) alongside `README.ko.md` (Korean), for the
repository root and for every image. **Korean is the source of truth** — edit
`README.ko.md` first, then carry the change into English. Everything else (the `docs/`
tree, code comments) is English only.

To keep the two from drifting, do not put volatile figures — CVE numbers, counts, versions
— in either README as a snapshot. The gate re-measures them on every run.

## Reporting a vulnerability

Do not open a public issue. See [SECURITY.md](SECURITY.md) for the private reporting path
and for what this project does and does not guarantee.
