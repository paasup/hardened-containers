# 0007. Replace the argocd image with a source-compiled self-build

- Status: Accepted

## Decision

The argocd image is built here. The build definition is
[images/argocd/](../../images/argocd/) — upstream source is compiled directly from a
pinned commit, and the bundled tools (helm, kustomize, git-lfs) are recompiled with the
same Go toolchain. The final runtime base is SUSE BCI (`bci-base`) — git, gpg, and ssh
are needed at runtime, so the variant with a package manager is used (unlike
[0002](0002-cloudnative-pg-operator-self-build.md), the micro seed approach is not used
here).

## Context

Most of the CVEs blocking the gate were not OS packages but **Go modules statically
linked into the binaries** (the evidence at the time: stdlib and the `x/crypto` family).
We were already on the latest release, so the newer-tag lever did not exist, and because
the modules live inside compiled binaries a base OS swap barely touched them.

Upstream's Dockerfile installs helm, kustomize, and git-lfs by downloading prebuilt
release binaries via `hack/install.sh`, and the Go version in those binaries is decided
by each of those upstream projects — raising the argocd tag does not change it. Partial
remediation did not work either: the same stdlib and `x/crypto` vulnerabilities were
present in five binaries across argocd itself and the three bundled tools, so fixing
only some left the rest untouched. Only recompiling everything brought the gate to zero.

## Rationale

- **Static linking was confirmed to make partial remediation ineffective** — most
  findings were stdlib and `x/crypto` vulnerabilities shared across all five binaries,
  with only a few unique to one. Rebuilding argocd alone, without the three bundled
  tools, did not bring the gate to zero.
- **A reusable design lowered the cost of repeating the fix.** Versions and module lists
  were lifted out of the Dockerfile into `source.build.env` values, and a single
  `GO_MODULE_UPGRADES` applies across all four projects — argocd, helm, kustomize, and
  git-lfs (`go-mod-upgrade.sh` filters it to the modules each project actually uses).
  `scripts/build/suggest-go-upgrades.py` derives suggested values from the scan report so
  nobody has to read through CVEs picking maxima.
- **Functional verification passed** (argocd's own version, nine symlinks, the three
  bundled tool versions, tini and connect-proxy execution, git/gpg/ssh, the LFS filter,
  and the `/app/config` structure). Because a passing gate does not prove the image
  works, this is checked by `images/argocd/verify.sh`. Actually starting the server and
  controller needs a Kubernetes API, so that is outside the smoke test's scope —
  deployment verification follows a separate procedure.
- **Reproducing the commands the chart actually runs caught a hidden requirement of the
  base swap.** The argo-cd chart's repo-server init container uses `cp --update=none`,
  a form that only works on GNU coreutils 9.3+. The initially chosen `bci-base:15.7` has
  an older coreutils — a combination that passes the gate but dies at deployment with
  `Init:CrashLoopBackOff`. `verify.sh` was changed to run that command directly so it is
  caught at build time, and the base was switched to `bci-base:16.0` (coreutils 9.6).

## Deliberate differences from upstream

| Item | Upstream | This image | Reason |
|---|---|---|---|
| Final base | `ubuntu` | `registry.suse.com/bci/bci-base` | These images use SUSE BCI only ([docs/image-authoring/](../image-authoring/README.md) rule 2). `pebble` disappears along with it |
| helm / kustomize / git-lfs | Download release binaries | Compile from source | The Go version in downloaded binaries cannot be controlled |
| helm version | Upstream pin | Latest | kustomize and git-lfs pins are already current, so they are kept |
| `tini` · `connect-proxy` | apt packages | Built from source | Neither exists in SLE_BCI. Built rather than dropping the functionality |
| Go toolchain | Upstream pin | `GO_BUILDER_TAG` | Resolves stdlib CVEs |
| Vulnerable modules | As-is | Force-upgraded via `GO_MODULE_UPGRADES` | |
| `BUILD_DATE` | Build timestamp | Fixed value | Build reproducibility |
| UI | node build | Same | Go embeds it into the binary, so it cannot be skipped |

The application code itself is the pinned tag unchanged — the minimal-diff principle.

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.** The same cost as
  [0001](0001-cnpg-postgresql-image.md),
  [0002](0002-cloudnative-pg-operator-self-build.md),
  [0003](0003-etcd-image-self-build.md), and [0004](0004-adc-self-build.md).
- **A person updates `SOURCE_COMMIT`, `GO_BUILDER_TAG`, and `GO_MODULE_UPGRADES`.** They
  are not tracked automatically — `suggest-go-upgrades.py` helps derive the values, but
  applying them is manual.
- **This is a configuration upstream does not test.** A BCI base combined with
  source-recompiled bundled tools is not in argo-cd's CI matrix.
- **Three extra tools must be built and re-verified on an ongoing basis.** The
  maintenance surface is larger than self-building argocd alone — for every new CVE fix,
  the SBOM scan must confirm the module upgrade actually applied to all four projects.
- **There is still no deployment verification of actual startup** (server, controller,
  repo-server). Only the gate PASS and a Kubernetes-API-free smoke test (versions, binary
  execution, the coreutils reproduction) have been confirmed — real deployment
  verification must be done as a separate procedure.

## Conditions for revisiting

- **If argo-cd, helm, kustomize, and git-lfs each resolve these modules in a new
  release** — moving to newer tags becomes possible again, which takes priority over
  self-building.
- **If unexpected runtime problems appear on `bci-base`** — reconsider another BCI
  variant (the same condition as
  [0002](0002-cloudnative-pg-operator-self-build.md)).
- **If real deployment verification (server, repository sync, repo-server init) finds a
  problem.**
- **If the coreutils requirement disappears or tightens through a chart change** —
  revisit `RUNTIME_BASE`.
