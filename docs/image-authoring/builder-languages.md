# Builder-stage rules per language

Detail behind [image-authoring/](README.md). The base OS
([base-os-policy.md](base-os-policy.md), rule 2) decides the **final stage**; this
document decides the **builder stage**. The two axes are independent — the same
`bci-micro` final stage sits under a Go builder (`etcd`) or a Node builder.

Builders are out of scope for rule 2 (they do not survive into the final image, so
official language images are used directly). What *is* common to every language is
**lifting versions out into `build.env` as values** — hardcoded in the Dockerfile, every
CVE fix would mean editing the Dockerfile.

## Common — what gets lifted into `build.env`

| Kind | Examples |
| --- | --- |
| Builder image tag | `GO_BUILDER_TAG` · `NODE_BUILDER_TAG` · `BUILDER_BASE` |
| Upstream source point | `SOURCE_COMMIT` (pinned commit) · `APP_VERSION` |
| Forced version of a vulnerable dependency | `GO_MODULE_UPGRADES` · `<LIB>_FIX_VERSION` · `<LIB>_OLD`/`<LIB>_VERSION` pairs |
| Package lists | `BUILDER_PACKAGES` · `RUNTIME_PACKAGES` |

A variable not listed in `BUILD_ARGS` is not passed as `--build-arg` — when adding a
value, update `BUILD_ARGS` too (miss it and the build silently uses the default).

## Go

```dockerfile
ARG GO_BUILDER_TAG=1.26.6-trixie          # global scope — it is used in FROM
FROM --platform=$BUILDPLATFORM golang:${GO_BUILDER_TAG} AS builder
ARG TARGETARCH                             # cross-compile: builder on host arch, output for target
```

- **Use `--platform=$BUILDPLATFORM` with `TARGETARCH`.** Do not run the builder under
  emulation.
- **Inject the version string via `ldflags`.** Upstream usually derives it from
  `git rev-parse HEAD`, but we build without a `.git`, so we pass `SOURCE_COMMIT`
  explicitly — without it the version check in `verify.sh` breaks and the image cannot
  testify to what it was built from.
- **Forced upgrades of vulnerable modules take three forms.** The "Go module CVEs"
  section below covers deriving the values.

  | Form | When | Example |
  | --- | --- | --- |
  | `GO_MODULE_UPGRADES` + `go-mod-upgrade.sh` | One image builds several Go projects | `argocd` |
  | Global `replace` in `go.work` | Upstream uses a workspace | `etcd` |
  | Individual `<LIB>_FIX_VERSION` | A small fixed set of vulnerable modules | `apisix-ingress-controller` |

  Do not create new instances of the third form — whether it is one module or two,
  standardising on `GO_MODULE_UPGRADES` is better because
  `suggest-go-upgrades.py --apply` can handle it automatically.
- **If upstream already backported the fix, use that commit instead of bumping the
  module** — the smaller the divergence the better (`cloudnative-pg` resolved its CVEs
  by compiling the release branch HEAD as-is).

## Node

```dockerfile
FROM ${BUILDER_BASE} AS builder            # node:lts-* or node:${NODE_BUILDER_TAG}
FROM ${RUNTIME_BASE} AS final              # bci-base
RUN zypper -n install -y ${NODE_PKG} && zypper -n clean --all
```

- **The runtime Node is separate from the builder Node.** The builder uses the official
  `node` image; the runtime uses an **OS package** (`nodejs24`) — the runtime is what
  gets scanned, so it belongs on a path the vendor patches.
- Keep the two majors aligned. `NODE_PKG` is a `build.env` value too.
- Copy only the bundled output (`main.cjs` and similar) — never put `node_modules` in
  the final image, **unless the bundler treats `dependencies` as external** (common for
  a real backend app rather than a small CLI — `tsup`/esbuild do this by default for
  Node targets) or the app has native addons (`.node` files can't be bundled at all). In
  that case `node_modules` (production-only, via a separate `npm ci --omit=dev`/
  `npm install --omit=dev` stage) legitimately ships alongside the bundle — matching
  upstream's own build is the test, not a blanket rule (`infisical` keeps it; a small
  Go-equivalent CLI-shaped Node app usually would not need to).
- **If the app has native addons** (`argon2`, `bcrypt`, `odbc`, and similar — anything
  needing `node-gyp`), compile them on the **same base as the final image**, not the
  official `node` image, even though rule 2's builder exemption would otherwise allow
  it — the same principle as the C/Lua rule below, extended to native Node addons
  (measured: `infisical`). SLE_BCI's `python3` (3.6.15) is too old for `node-gyp`
  (`SyntaxError` on the walrus operator) — install `python313`+`nodejs*-devel` and
  symlink `python3` to it (SLE_BCI has no `update-alternatives` to do this
  automatically).

## JVM (jar replacement)

Unpack the tarball upstream ships and **swap out only the vulnerable jars.** Do not
recompile.

```dockerfile
ARG NETTY_OLD                              # the version currently present
ARG NETTY_VERSION                          # the version to swap in
```

- **Take an `OLD`/`VERSION` pair.** `OLD` is specified so the build **fails when the
  replacement target is not found** — when upstream bumps the version, the build should
  break rather than silently doing nothing.
- **A jar pinned by a BOM cannot be fixed by changing tags or base OS** — which is
  exactly why the image is built here.
- `tzdata-java` does not exist in SLE_BCI (the JDK's bundled tzdb is used). See the SLE
  package-name table in [base-os-policy.md](base-os-policy.md).

## C and Lua (compiled from source)

- **Do not attempt static linking.** SLE_BCI has no static glibc. Keep the builder stage
  and the final stage on the **same base** and link dynamically (`argocd`'s `tini` and
  `connect-proxy`).
- When there are many component versions, lift each into its own `ARG` (`apisix` has
  more than ten).
- For a tool built from source because SLE_BCI lacks it, record **why it is absent and
  what it substitutes for** in a comment — that must be distinguishable from dropping a
  feature.

## Go module CVEs — do not hand-pick upgrade versions

A blocking CVE in a module statically linked into a Go binary is resolved by writing
`<module>@<version>` into `GO_MODULE_UPGRADES` in `build.env`. That version is already
present in the gate report's `FixedVersion`, so a script extracts it — nobody should be
reading through CVEs picking maxima by hand.

```sh
python3 scripts/build/suggest-go-upgrades.py --reports <trivy-reports dir> [--image <filter>]
python3 scripts/build/suggest-go-upgrades.py --reports <trivy-reports dir> \
  --image <image> --apply --dry-run     # see what it would write
python3 scripts/build/suggest-go-upgrades.py --reports <trivy-reports dir> \
  --image <image> --apply                # write it into build.env
```

It emits a paste-ready `GO_MODULE_UPGRADES="..."` line plus per-module rationale as
comments (installed version → target version, the CVEs involved). `stdlib` is a
toolchain problem rather than a module, so a `GO_BUILDER_TAG` candidate is computed and
reported separately.

**Why we do not pull the latest at build time** — `go get -u` on every build means the
same source produces different images. It is the same reason this repository does not
use rolling tags. A version pin is **a record of what we verified**, and `git diff`
shows what moved and why. Run without `--apply` to get suggestions only; a person
reviews them and commits with `--apply`.

Two traps show up in practice.

- **Multiple `FixedVersion` values are per-branch alternatives, not "a higher
  version".** For stdlib, `1.25.13, 1.26.6, 1.27.0-rc.3` are the fix points on three
  separate branches. Taking the overall maximum misreads a pre-release as a stable
  release. The script handles this rule.
- **A suggestion is the minimum the CVE requires.** Inter-module constraints may force
  it higher — a module may require a specific minimum of another module, so the
  suggested value fails the build with `requires <module>@vX, not vY`. Raise it to the
  version that message names.

When one image builds several Go projects (`argocd` builds argocd, helm, kustomize, and
git-lfs together), **reuse a single list across all of them** — add a helper like
`images/argocd/go-mod-upgrade.sh` that applies only the modules present in that
project's dependency graph. `go get` will happily add a module that is not a dependency
to `go.mod`, so the list cannot simply be passed through.

## Node module CVEs — npm's `overrides`, and where it differs from Go

npm's analogue of `GO_MODULE_UPGRADES` is the `overrides` field, applied via `npm pkg
set overrides[<pkg>]=<version>` (bracket syntax for scoped names) before `npm
install`/`npm ci --omit=dev`, values taken from trivy's `FixedVersion` the same way —
minimum version on the currently-installed major line, never hand-picked (measured:
`infisical`, 26 packages). Two mechanics have no Go equivalent, both found by an actual
build failing rather than anticipated in advance:

- **npm refuses to `overrides` a package that is also a direct dependency**
  (`npm error EOVERRIDE`). Split the list in two: a direct-upgrade list that does `npm
  pkg set dependencies[<pkg>]=<version>` instead, and the `overrides` list for
  everything transitive-only. To also dedupe *nested* copies of a direct-upgraded
  package (other dependencies pulling in an old version of the same package), add a
  self-referencing `overrides[<pkg>]["."]` entry alongside the `dependencies` bump —
  but the two values must match **character-for-character**, `^` included; the
  EOVERRIDE check is a textual comparison against `dependencies`, not a semver
  satisfaction check, so `dependencies[<pkg>]=^1.2.3` paired with
  `overrides[<pkg>]["."]=1.2.3` (no caret) still conflicts.
- **`npm ci` refuses to run once `npm pkg set` has put `package.json` out of sync with
  the committed `package-lock.json`** (`npm error EUSAGE`, worded as if the lockfile
  were simply missing — it is present and valid). Use `npm install` (which reconciles
  the lockfile) instead of `npm ci` in any stage that runs `npm pkg set` first.
- **Forcing a nested dependency can break a *different* package that pins it on
  purpose.** A dependency may hard-depend on an old API shape of the very package being
  force-upgraded (measured: `oci-common` pinning `uuid@3.3.3` for its legacy `uuid/v1`
  subpath import, removed from uuid's `package.json` `exports` map starting with uuid
  9 — forcing `uuid` up without also upgrading `oci-common` crashed the app at runtime
  with `ERR_PACKAGE_PATH_NOT_EXPORTED`, not caught by `npm install` succeeding, only by
  actually running the app). If the offending package has since migrated to the newer
  API itself, force-upgrading *it* too (even though nothing scanned it directly)
  resolves both the breakage and the nested CVE at once. This is exactly why
  `verify.sh` actually running the app (not just a successful build) matters as much
  for Node force-upgrades as for Go ones.

### Pins fall behind while sitting still

The cost of pinning versions is that **a newly disclosed CVE puts that pin out of
compliance without the source changing at all.** A separate workflow, `rescan.yml`,
checks for this drift daily: it re-scans published images and, for any that now fail the
gate, calls `build-image.yml` to rebuild and push that image (see [ci.md](ci.md)). When
something needs to land immediately, a person can still run `build-image.yml` directly
via `workflow_dispatch`.

There are three cases where a rebuild fixes a blocking CVE — the response is the same in
all of them (rebuild).

| Case | Why a rebuild fixes it |
| --- | --- |
| The pin is behind | Raise the pin and build |
| The pin is right but nothing has been built with it yet | This is the state right after a commit that only changed the pin |
| A base OS package is behind | A rebuild makes zypper install the current one — unrelated to any pin |

- **A blocking CVE with no fixed version is not resolved by rebuilding** — consider
  moving to a newer upstream tag, or an approved exception.
- **Approved exceptions (`cve-exceptions.json`) apply.** Expired exceptions do not
  count.
- The verdict uses the same criteria as the gate (`max(vendor, NVD)`, HIGH by default).
