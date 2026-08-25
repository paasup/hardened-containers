# argocd (self-built)

English · [한국어](README.ko.md)

A hardened replacement for `quay.io/argoproj/argocd`. Upstream source is compiled
directly from a pinned commit, and the bundled tools upstream downloads as release
binaries (helm, kustomize, git-lfs) are rebuilt with the same Go toolchain.

> This image is an **unofficial rebuild** of Argo CD. It is not affiliated with, endorsed
> by, or supported by the upstream project. See [NOTICE](../../NOTICE) for trademark and
> licensing notices.

```sh
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

The decision, the candidates compared, and the costs accepted are in
[ADR 0007](../../docs/decisions/0007-argocd-self-build.md); image selection rules and the
build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

Most of this image's blocking CVEs are **Go modules statically linked into the binaries**,
not OS packages. That makes both higher-level levers useless.

- **A newer tag is not available** — we are already on the latest release. The bundled
  tools are each at their latest too, and their old Go is each upstream project's choice,
  so raising versions does not change it.
- **A base OS swap barely touches them** — the modules live inside compiled binaries.

Upstream's Dockerfile installs helm, kustomize, and git-lfs by **downloading prebuilt
release binaries** via `hack/install.sh`. We cannot control the Go version inside those
binaries, so all three are recompiled from source alongside argocd itself.

Partial remediation is ineffective — the same `stdlib` and `x/crypto` vulnerabilities are
present in all five binaries, so fixing one leaves the rest untouched. Only a few findings
are unique to a single binary; most are shared, so everything has to be rebuilt for the
gate to reach zero.

`pebble` is not something we added — it comes with the ubuntu base, and disappears when
the base becomes SUSE BCI.

## Deliberate differences from upstream

| Item | Upstream | This image | Reason |
|---|---|---|---|
| Final base | `ubuntu` | `registry.suse.com/bci/bci-base` | These images use SUSE BCI only ([docs/image-authoring/](../../docs/image-authoring/README.md) rule 2). `pebble` disappears along with it |
| helm / kustomize / git-lfs | Download release binaries | Compile from source | The Go version in downloaded binaries cannot be controlled |
| helm version | Upstream pin | Latest | kustomize and git-lfs pins are already current, so they are kept |
| `tini` · `connect-proxy` | apt packages | Built from source | Neither exists in SLE_BCI. Built rather than dropping the functionality |
| Go toolchain | Upstream pin | `GO_BUILDER_TAG` | Resolves stdlib CVEs |
| Vulnerable modules | As-is | Force-upgraded via `GO_MODULE_UPGRADES` | |
| `BUILD_DATE` | Build timestamp | Fixed value | Build reproducibility |
| UI | node build | **Identical** | Go embeds it into the binary, so it cannot be skipped |

The application code itself is the pinned tag unchanged — the minimal-diff principle.

### SLE package mapping

Upstream's apt list translated to SLE_BCI names (see
[docs/image-authoring/](../../docs/image-authoring/README.md)). The list itself lives in
`RUNTIME_PACKAGES` in `source.build.env`.

| ubuntu | SLE_BCI |
|---|---|
| `git` | `git-core` |
| `tzdata` | `timezone` |
| `gpg` · `gpg-agent` | `gpg2` |
| `openssh-client` | `openssh-clients` |
| `ca-certificates` | `ca-certificates` (same) |
| `tini` | **absent** → built from source |
| `connect-proxy` | **absent** → built from source |

## Version management

The following are **not tracked automatically** — someone reading an upstream release and
editing `source.build.env` to open a PR is itself the update trigger.

| Value | What |
| --- | --- |
| `SOURCE_COMMIT` | The argocd pinned commit |
| `HELM_VERSION` · `KUSTOMIZE_VERSION` · `GIT_LFS_VERSION` | Bundled tool versions |
| `TINI_VERSION` · `SSH_CONNECT_VERSION` | Versions of components built from source because SLE_BCI lacks them |
| `NODE_BUILDER_TAG` | The UI builder's Node version — kept aligned with upstream's Dockerfile pin |

`GO_BUILDER_TAG` and `GO_MODULE_UPGRADES` are different — not fully manual, since
`suggest-go-upgrades.py` derives candidate values from the gate report (see "Handling the
next CVE" below). Deriving the value is semi-automatic; applying it is still a person
opening a PR.

**Suggested review cadence**: whenever the gate reports a blocking CVE for this image
again, or when argo-cd, helm, kustomize, and git-lfs each resolve these modules in a new
release — moving to newer tags becomes possible again, which always takes priority over
keeping this self-build.

## Building and verifying

```sh
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

Confirm zero effective C/H in `cve-gate.md`. Also check that the coverage self-check
(`CoverageProbe`) reads `ok` — `none` means the zero findings were not a measurement but
an absence of scanner data for that distribution.

What `verify.sh` checks — the argocd version string, the nine upstream symlinks, the
versions of the three bundled tools, that tini and connect-proxy run, that git/gpg/ssh
exist, the LFS filter in `/etc/gitconfig`, and the `/app/config` directory structure and
wrapper scripts. It also reproduces the `cp --update=none` command the argo-cd chart's
repo-server init container actually runs, directly confirming the GNU coreutils 9.3+
requirement — this check is what catches a base OS change.

**A passing gate does not prove the image works.** Actually starting it needs a Kubernetes
API and is outside the smoke test's scope — deployment verification follows a separate
procedure.

### Handling the next CVE — do not touch the Dockerfile

Neither versions nor the module list are hardcoded in the Dockerfile. When a new blocking
CVE appears, **only `source.build.env`** changes.

```sh
# 1) derive the upgrade values from the gate report (do not hunt for them by hand)
python3 scripts/build/suggest-go-upgrades.py --reports sbom-out/trivy-reports --image argocd

# 2) apply the printed GO_MODULE_UPGRADES / GO_BUILDER_TAG to source.build.env

# 3) rebuild — this runs through to the gate in one go
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

| New CVE type | Value to change |
|---|---|
| Go `stdlib` | `GO_BUILDER_TAG` |
| A Go module | Add `<module>@<version>` to `GO_MODULE_UPGRADES` |
| An OS package | `RUNTIME_BASE` or `RUNTIME_PACKAGES` |
| A new component release | The relevant `*_VERSION` |

`GO_MODULE_UPGRADES` is **applied across all four projects** — argocd, helm, kustomize,
and git-lfs. [go-mod-upgrade.sh](go-mod-upgrade.sh) filters it to the modules present in
each project's dependency graph, so one list can be reused as-is — a necessary filter,
because `go get` will otherwise add a module that is not a dependency to `go.mod`.

> A suggestion is the **minimum** the CVEs require. Inter-module constraints may force it
> higher — if the build fails with `requires <module>@vX, not @vY`, raise it to that
> version.
