# adc — self-built

English · [한국어](README.ko.md)

adc (the APISIX/API7 management CLI, a sidecar to apisix-ingress-controller), built
directly from upstream source onto SUSE BCI. It runs as a sidecar container in
apisix-ingress-controller deployments.

> This image is an **unofficial rebuild** of api7/adc. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0004](../../docs/decisions/0004-adc-self-build.md); image selection rules and the
build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

Upstream moved to a distroless image, bringing CRITICAL/HIGH to zero **by vendor
rating** — but that number reflects vendor severity only. The gate re-evaluates with
`max(vendor, NVD)`, and under that view several OS package (glibc) CVEs still block as
effective CRITICAL/HIGH. The distribution has permanently fixed these as "affected, no
fix available", so raising the tag does not resolve them.

Pre-verification showed that the same dependencies on SUSE BCI (SUSE BCI plus the Node
package) do not raise those OS vulnerabilities — this is the class of finding a base OS
swap alone resolves, because the vendor verdict differs.

This shape is simpler than a self-build that compiles source across several modules — the
application code (the main.cjs bundle) is 100% identical to upstream and the builder stage
is reused unchanged. All that changes is one line of base in the final runtime stage. It
is the same pattern as `cnpg-postgresql` (the OS-package-reinstall shape).

## Differences from upstream

Upstream's Dockerfile (`libs/tools/src/docker/Dockerfile`, tag `v0.29.0`) has two stages:

```dockerfile
FROM node:lts-bookworm-slim AS builder      # bundle to a single main.cjs with pnpm + nx
...
FROM gcr.io/distroless/nodejs24-debian13:nonroot
COPY --from=builder /build/dist/apps/cli/main.cjs .
ENTRYPOINT [ "/nodejs/bin/node", "main.cjs" ]
```

The builder stage (the pnpm/nx build) is out of policy scope
([image-authoring/](../../docs/image-authoring/README.md) rule 2 — builder stages are not
scanned or shipped, so the base OS policy does not apply) and is reused from upstream
as-is.

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Final base | `gcr.io/distroless/nodejs24-debian13:nonroot` | `registry.suse.com/bci/bci-base:15.7` + `zypper install nodejs24` | Avoids the OS package CVEs and standardises the base OS across images (the same Node 24 major is kept — being a standard SUSE package, there is no distroless-specific `-devel` problem) |
| Entrypoint path | `/nodejs/bin/node` | `/usr/bin/node` | Where zypper installs it |
| Non-root user | Provided by the distroless `:nonroot` tag | A system account `adc` created explicitly | `bci-base` has no nonroot variant tag |
| Builder stage | `node:lts-bookworm-slim` (pnpm + nx build) | Identical — out of policy scope | Only the final stage is scanned and shipped |
| Application code | The `main.cjs` bundle | Identical | Reusing the builder stage as-is keeps the diff minimal |

Build time is under two minutes (mostly pnpm install plus nx build).

## Building and verifying

```sh
# local build (no push)
IMAGE=adc BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# through to a registry push
IMAGE=adc BASE_OS=source REGISTRY=<your-registry> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is **build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.** `verify.sh` checks non-root execution, `--version` output, and the command
list in `--help` (dump/diff/sync) — **most adc commands require an actual APISIX/API7
backend, so that integration is outside this smoke test's scope**. Deployment
verification follows a separate procedure.

After the build, `<OUT_DIR>/cve-gate.md` (the summary) and `cve-gate.json` remain. Two
things to check: that effective CRITICAL/HIGH is `0/0`, and that `CoverageProbe` reads
`ok` (the self-check that rescans the SBOM with sentinel packages to confirm trivy really
covers this base) — `none` means the zero findings were not a measurement but the scan
failing to read this base, and the gate withholds a pass.

### Source and version management

| Item | Value |
| --- | --- |
| Source | `https://github.com/api7/adc.git` |
| Pinned commit | `SOURCE_COMMIT` in `source.build.env` — the actual commit the `v0.29.0` tag points at (a lightweight tag, with no peeled commit) |
| Builder | `node:lts-bookworm-slim`, same as upstream — out of policy scope (builder stage) |
| Final base | `registry.suse.com/bci/bci-base:15.7` + `nodejs24` |

`SOURCE_COMMIT` is **not tracked automatically.** As with the other self-built images,
someone reading a new upstream release (or a version that already resolves the CVEs
above) and editing `source.build.env` to open a PR is itself the update trigger.

**Suggested review cadence**: whenever the gate reports a blocking CVE for this image
again, or `api7/adc` ships its next release — if that release already resolves the CVEs
above, moving to it always takes priority over keeping this self-build.

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — the builder stage (unchanged from upstream) plus a SUSE BCI final stage |
| `source.build.env` | Pinned commit and versions (only names listed in `BUILD_ARGS` are passed as `--build-arg`) |
| `verify.sh` | Functional verification — non-root, version, `--help` command list |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/adc:0.29.0-security-hardened-20260812
                └ app ┘└ slug ┘└hardened┘└ build date ┘
```

Even at the same application version, the state of base packages can differ from one
rebuild to the next — hence no rolling tags, and the build date in the tag.

## Not done yet — deployment verification

Only the gate PASS and the functional smoke test (version plus help) have been confirmed.
**Whether dump/diff/sync work correctly against a real APISIX/API7 backend, alongside
apisix-ingress-controller, has not been checked** — this must be done as a separate
deployment verification procedure (the apisix-ingress-controller self-build has already
completed the same procedure; follow the same approach).
