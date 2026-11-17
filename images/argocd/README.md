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

- **A newer tag does not get us there** — argo-cd is on the newest patch of its support
  line (`SUPPORT_LINE`). The Go toolchain and modules inside the upstream image, and the
  bundled tool binaries, are each upstream project's choice, so raising the tag does not
  change them on our schedule.
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
| helm version | Upstream pin | Newest patch of the newest minor that is still patched | helm patches only its newest minor — the 4.2 line has had no release since 4.3.0. Upstream's release-3.6 ships the same helm |
| git-lfs version | Upstream pin | The release carrying the security fixes | Upstream v3.5.4's 3.7.1 is affected by HIGH security advisories fixed only in 3.8.1 (no 3.7.x backport). See "What the scanner cannot see" below |
| kustomize version | Upstream pin | **Identical** | 5.8.3 declares `go 1.27.0`, so it does not build under the 1.26 builder, and it carries no security fix ("No functional changes"). Raise it when the builder moves to Go 1.27 |
| git source pinning | (tag) | Commit SHA (`*_COMMIT`) | Not just argocd itself — helm, kustomize, git-lfs, tini, and connect are all fetched by the commit their tag points at, verified by BuildKit's git context (rule 7) |
| zypper retry | — | The whole transaction, refresh through install, is retried | The SLE_BCI mirror also drops during package downloads. RPM signatures are still checked on every attempt |
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
| `HELM_VERSION` · `KUSTOMIZE_VERSION` · `GIT_LFS_VERSION` | Bundled tool versions — baked in via ldflags and checked by `verify.sh` |
| `TINI_VERSION` · `SSH_CONNECT_VERSION` | Versions of components built from source because SLE_BCI lacks them — a record, not build args (`verify.sh` checks `TINI_VERSION`) |
| `HELM_COMMIT` · `KUSTOMIZE_COMMIT` · `GIT_LFS_COMMIT` · `TINI_COMMIT` · `SSH_CONNECT_COMMIT` | The commit actually fetched — **always** raised together with its `*_VERSION`. Resolve with `git ls-remote <repo> 'refs/tags/<tag>' 'refs/tags/<tag>^{}'`; for an annotated tag use the `^{}` commit |
| `NODE_BUILDER_TAG` | The UI builder's Node version — kept aligned with upstream's Dockerfile pin |

`GO_BUILDER_TAG` and `GO_MODULE_UPGRADES` are different — not fully manual, since
`suggest-go-upgrades.py` derives candidate values from the gate report (see "Handling the
next CVE" below). Deriving the value is semi-automatic; applying it is still a person
opening a PR.

No `cve-exceptions.json` entry targets this image — everything that passes the gate passes
because a version was raised.

### What the scanner cannot see — advisories in the bundled tools themselves

A vulnerability in a bundled tool's **own code** is only caught if the scanner knows that
binary's main module version. In the SBOM, argocd, helm, and kustomize carry a main module
version, but git-lfs (`github.com/git-lfs/git-lfs/v3`) has **none** — git-lfs's version is a
constant (`config.Version`), so there is no variable for ldflags to set. That is why the HIGH
advisories affecting git-lfs 3.7.1 (fixed in 3.8.1) appeared in neither the gate nor the
daily rescan, and future git-lfs advisories will not appear either.

So **git-lfs needs a person to check its GitHub security advisories
(`gh api repos/git-lfs/git-lfs/security-advisories`) directly** — on every rebuild, and when
raising any other bundled tool, do not trust the SBOM alone.

**Suggested review cadence**: whenever the gate reports a blocking CVE for this image
again, and whenever argo-cd's upstream branch for the same line (`release-<SUPPORT_LINE>`
or later) raises the bundled tool versions in `hack/tool-versions.sh` — the versions
upstream ships are the ones whose compatibility it has checked.

**When to stop self-building**: when the official argo-cd image
(`quay.io/argoproj/argocd`), scanned as-is, passes the gate — a newer tag is then a usable
lever again, and that always takes priority over keeping this self-build.

## Building and verifying

```sh
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

Confirm zero effective C/H in `cve-gate.md`. Also check that the coverage self-check
(`CoverageProbe`) reads `ok` — `none` means the zero findings were not a measurement but
an absence of scanner data for that distribution.

What `verify.sh` checks — the argocd version string and pinned commit, the nine upstream
symlinks and argv[0] dispatch (`argocd-repo-server --help` behaves as the repo-server), the
versions of the three bundled tools, and then it makes them do the work repo-server hands
them: `helm template` renders a chart, `kustomize build` applies a generator and a prefix,
and a file committed after `git lfs track` in a git repository is stored as an LFS pointer.
After that: the tini version and that connect-proxy runs, that git/gpg/ssh exist, the LFS
filter in `/etc/gitconfig`, and the `/app/config` directory structure and wrapper
scripts. It also reproduces the `cp --update=none` command the argo-cd chart's
repo-server init container actually runs, directly confirming the GNU coreutils 9.3+
requirement — this check is what catches a base OS change.

**A passing gate does not prove the image works.** Actually starting it needs a Kubernetes
API and is outside the smoke test's scope — deployment verification follows a separate
procedure.

### Handling the next CVE — do not touch the Dockerfile

Neither versions nor the module list are hardcoded in the Dockerfile. When a new blocking
CVE appears, **only `source.build.env`** changes.

```sh
# 1) derive the upgrade values from the gate report (do not hunt for them by hand).
#    A rebuild collects MEDIUM, LOW and unrated findings too (remediation-priority.md)
python3 scripts/build/suggest-go-upgrades.py --reports sbom-out/trivy-reports --image argocd \
  --min-severity UNKNOWN --apply --dry-run

# 2) drop --dry-run to apply. Do not paste the printed GO_MODULE_UPGRADES= line by hand —
#    it holds only the modules this run derived, so existing pins would be lost

# 3) rebuild — this runs through to the gate in one go
IMAGE=argocd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

| New CVE type | Value to change |
|---|---|
| Go `stdlib` | `GO_BUILDER_TAG` |
| A Go module | Add `<module>@<version>` to `GO_MODULE_UPGRADES` |
| An OS package | `RUNTIME_BASE` or `RUNTIME_PACKAGES` |
| A new component release | The relevant `*_VERSION` and `*_COMMIT` (together) |
| argocd itself (`github.com/argoproj/argo-cd/v3`) | `SOURCE_COMMIT` and `APP_VERSION` — `GO_MODULE_UPGRADES` cannot move it |

`GO_MODULE_UPGRADES` is **applied across all four projects** — argocd, helm, kustomize,
and git-lfs. [go-mod-upgrade.sh](go-mod-upgrade.sh) filters it to the modules present in
each project's dependency graph, so one list can be reused as-is — a necessary filter,
because `go get` will otherwise add a module that is not a dependency to `go.mod`.

> A suggestion is the **minimum** the CVEs require. Inter-module constraints may force it
> higher — if the build fails with `requires <module>@vX, not @vY`, raise it to that
> version. When raising a module already in the list, also check what that module's
> `go.mod` requires of the others — raising `x/crypto` can leave the listed `x/text` below
> its requirement.
>
> When a fix is published only as a pseudo-version (`v0.58.1-0.2026…-<commit>`), the script
> skips it as "fixed only in a pre-release". If a **stable release tagged after that
> commit** exists, it fixes it — `gh api repos/<owner>/<repo>/compare/<commit>...<tag>`
> reporting `ahead` with `behind_by: 0` means the tag contains the commit.
