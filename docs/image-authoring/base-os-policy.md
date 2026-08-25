# Base OS policy — the runtime is SUSE BCI

Detail behind rule 2 in [image-authoring/](README.md). Read this when choosing the final
stage's base for a new image, or when raising an existing image's BCI version.

Consistency across images comes first: every image is BCI, and trivy's SLES coverage is
confirmed by a positive control on every scan (the gate's `CoverageProbe`).

- When this policy conflicts with "stay as close to upstream as possible", **record
  which one won and why in that image's README.** Having a policy is not a reason to
  skip the record.
- Builder stages (used to compile, not present in the final image) are out of scope —
  official language images (`golang`, …) are fine there. The policy applies only to the
  **final stage, which is what gets scanned and shipped**.

## Pick the BCI variant from what the runtime actually needs

The eight images here use only three combinations. A new image should pick one of
them — before inventing a fourth, write down why these three do not work.

| Final base | When to pick it | Cost | Images using it |
| --- | --- | --- | --- |
| `bci-base` | The runtime uses OS packages or a shell (installs the app with `zypper`, entrypoint is a shell script) | Largest attack surface | `adc` · `apisix` · `argocd` · `cnpg-postgresql` |
| `bci-micro` | Runs a single statically linked binary | No package manager. No `sed`, `grep`, or `find` either. You must create the nonroot account yourself | `apisix-ingress-controller` · `cloudnative-pg` · `etcd` |
| `scratch` + micro rootfs | The whole runtime is assembled in the builder (JVM + application tree) | You own the rootfs assembly (the "seed" approach below is mandatory) | `keycloak` |

Choosing `bci-micro` or `scratch` means **building yourself what upstream got for free
from a distroless `:nonroot` tag.**

```dockerfile
# bci-micro has only root — there is no tag equivalent to distroless's nonroot variant
RUN echo 'nonroot:x:65532:65532:nonroot:/home/nonroot:/bin/false' >> /etc/passwd; \
    echo 'nonroot:x:65532:' >> /etc/group; \
    mkdir -p /home/nonroot; chown 65532:65532 /home/nonroot
USER 65532:65532
```

`bci-base` has `groupadd`/`useradd`, so use those instead (see `images/adc`).
**Keep upstream's uid and gid values** — changing them arbitrarily breaks volume
permissions.

## Pick the BCI version by measuring, per image

**There is no "always use the newest BCI" rule.** A new SLE major's SLE_BCI repository
can lag behind an older one for a particular package, in which case the newer base
leaves *more* CVEs behind. **Measure the version of the packages this image actually
needs, for each candidate tag, and record the result in a `build.env` comment.**

```sh
docker run --rm registry.suse.com/bci/bci-base:<tag> \
  sh -c 'zypper -n refresh >/dev/null 2>&1; zypper -n info <package>'
```

When moving to a new version, re-confirm trivy's coverage for that SLE version too — if
`CoverageProbe` reads `none`, zero findings is not really zero, and the gate blocks it.

**Choosing on CVE counts alone will kill you in production.** The base OS also changes
the **version** of the tools the runtime depends on. For example, a chart's init
container may use `cp --update=none`, a form that only exists in GNU coreutils 9.3+.
Built on an older BCI, that image **passes the gate and passes `verify.sh`**, then dies
at deployment with `Init:CrashLoopBackOff`. The scanner only asks "do the installed
packages have known CVEs"; it has no idea what the chart using this image requires.

→ **Reproduce in `verify.sh` the commands the chart actually runs against this image.**
Then a base change fails at build time. See the "commands the chart actually runs"
section of `images/argocd/verify.sh` for an example.

## Adding packages on top of `bci-micro` — always use the "seed" approach

`bci-micro` has no package manager but **does have an rpmdb**
(`/usr/lib/sysimage/rpm`). If you install into an empty installroot and then lay that
rootfs over micro, **micro's rpmdb is shadowed and micro's own packages disappear from
the SBOM entirely** — that is not fewer CVEs, it is a scanning blind spot.

Lay micro's filesystem down as a seed and install on top of it:

```dockerfile
FROM registry.suse.com/bci/bci-micro:15.7 AS micro
FROM registry.suse.com/bci/bci-base:15.7 AS builder
COPY --from=micro / /rootfs
RUN rpm --root /rootfs --import /usr/lib/rpm/gnupg/keys/*.asc && \
    zypper --non-interactive --installroot /rootfs --gpg-auto-import-keys refresh && \
    zypper --non-interactive --installroot /rootfs install -y --no-recommends <packages>
FROM scratch AS final
COPY --from=builder /rootfs/ /
```

Omitting `rpm --import` makes every installed package emit a `NOKEY` warning, skipping
per-package signature verification. After the build, always check the OS package count
in the SBOM — if it dropped to single digits, masking happened. A worked example is
`images/keycloak/suse.Dockerfile`.

## Common tools missing from `bci-micro`

`sed`, `grep`, and `find` are **all three absent**. `bash`, `coreutils`, `readlink`,
`dirname`, `uname`, and `locale` are present.

- If the application in the final image uses these (Keycloak's `bin/kc.sh` uses `sed`
  and `grep`, for instance), they must be **listed explicitly** in the runtime package
  list.
- **Guest** scripts inside `verify.sh` must not depend on them — write pure shell loops
  (`while IFS= read -r line; do ...; done`) instead, since availability differs per
  image.

## SLE package names that differ from RHEL/Debian

| Other distributions | SLE_BCI 15.7 |
| --- | --- |
| `tzdata` | `timezone` |
| `tzdata-java` | **none** (the JDK's bundled tzdb is used) |
| `glibc-langpack-en` | `glibc-locale-base` |
| `coreutils-single` | `coreutils` |

Copying an upstream Dockerfile's package list verbatim fails the build with
`No provider of '...' found`. Check first with
`zypper -n search -t package '<pattern>'`.
