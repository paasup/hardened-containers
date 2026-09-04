# syntax=docker/dockerfile:1
# etcd — upstream source compiled directly from a pinned commit.
#
# Upstream's root Dockerfile (https://github.com/etcd-io/etcd) only ADDs already-built
# binaries (`etcd`/`etcdctl`/`etcdutl`) — compilation happens outside the Dockerfile.
# Every scripts/ path mentioned below refers to the upstream etcd repository, not this one:
# upstream scripts/build.sh → `etcd_build()` in scripts/build_lib.sh does that work.
# We bring that build step inside the Dockerfile and reproduce it with `go build`
# (the same pattern as the cloudnative-pg self-build).
#
# Why we build it ourselves — the cause is the version of golang.org/x/text statically
# linked into the binary, so a base OS swap does not fix it. Rationale:
# docs/decisions/0003-etcd-image-self-build.md
#
# Correspondence with upstream (tag v3.7.1, against etcd-io/etcd's scripts/build_lib.sh → etcd_build())
#   cd server && go build ...    →  identical (ldflags injects the pinned commit rather than GitSHA — see below)
#   cd etcdutl && go build ...   →  identical
#   cd etcdctl && go build ...   →  identical
#   distroless/static-debian12   →  replaced with SUSE BCI (bci-micro). The images in this
#     repository use SUSE BCI only (docs/image-authoring/README.md rule 2) — the builder stage
#     (Go compilation) uses the official golang image as-is
#
# Deliberate difference from upstream — forcing the x/text upgrade
#   etcd manages the server, etcdctl, and etcdutl modules together as a Go workspace (go.work).
#   Instead of editing each go.mod individually, a single workspace-wide replace line is added
#   to go.work to force-upgrade golang.org/x/text — keeping the divergence from upstream
#   minimal (docs/image-authoring/README.md — keep the divergence from upstream minimal).
#
# ldflags — why the pinned commit is injected instead of GitSHA
#   Upstream bakes the value from `git rev-parse --short HEAD` into the version string. We
#   check out through BuildKit's git context (`ADD ...#${SOURCE_COMMIT}`), so the commit is
#   already known — the full commit hash is baked in as-is so the host-side verify.sh can
#   confirm the version string reflects the pinned commit without running git inside the
#   container (the same reasoning as cloudnative-pg/source.Dockerfile).

ARG GO_BUILDER_TAG=1.26.5-trixie
# An ARG used in a FROM must be declared before the first FROM (global scope) — checklist
# step 3 in docs/image-authoring/README.md. Declared inside a stage it becomes local to that
# stage, is not used to resolve later FROM image names, and the build fails with an empty
# image name.
ARG RUNTIME_BASE=registry.suse.com/bci/bci-micro:15.7

# Run the builder on the host's native architecture. Go cross-compilation needs no emulation.
FROM --platform=$BUILDPLATFORM golang:${GO_BUILDER_TAG} AS builder
ARG TARGETARCH
ARG SOURCE_COMMIT
ARG APP_VERSION
ARG GO_MODULE_UPGRADES
WORKDIR /src

# BuildKit's git context support — git itself guarantees commit integrity, with no tarball
# and checksum to manage.
ADD https://github.com/etcd-io/etcd.git#${SOURCE_COMMIT} /src

# Force-upgrade the vulnerable module(s) workspace-wide (the list lives in build.env).
#
# Upstream is a Go workspace, so `go get` is not the lever the single-module images use —
# it would touch only the module it is run in, leaving the sibling modules (server, etcdctl,
# etcdutl) on the vulnerable version. A `replace` in go.work applies to all of them at once,
# and `go work sync` propagates it into each module's go.sum.
#
# The *values* still come from GO_MODULE_UPGRADES rather than a per-module ARG, so this
# image is covered by suggest-go-upgrades.py --apply like every other Go image. The
# `<mod>@<version>` spec splits cleanly into a replace directive: ${spec#*@} keeps the "v"
# prefix that replace requires.
RUN for spec in ${GO_MODULE_UPGRADES}; do \
      echo "replace ${spec%@*} => ${spec%@*} ${spec#*@}" >> go.work; \
    done \
 && go work sync

# Reproduces etcd_build() from upstream (etcd-io/etcd) scripts/build_lib.sh as-is.
# (GOARCH is replaced by TARGETARCH, and the full pinned commit hash is baked in instead of
# GitSHA — see the explanation above)
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    mkdir -p /out; \
    LDFLAGS="-X=go.etcd.io/etcd/api/v3/version.GitSHA=${SOURCE_COMMIT}"; \
    ( cd server  && CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -installsuffix=cgo -ldflags="${LDFLAGS}" -o /out/etcd    . ); \
    ( cd etcdutl && CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -installsuffix=cgo -ldflags="${LDFLAGS}" -o /out/etcdutl . ); \
    ( cd etcdctl && CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -installsuffix=cgo -ldflags="${LDFLAGS}" -o /out/etcdctl . )

FROM ${RUNTIME_BASE} AS final

# The same paths and structure as upstream's root Dockerfile — the chart's
# (groundhog2k/etcd) startup, liveness, and readiness probes hardcode
# `/usr/local/bin/etcdctl`, so these paths must not change.
COPY --from=builder /out/etcd    /usr/local/bin/etcd
COPY --from=builder /out/etcdctl /usr/local/bin/etcdctl
COPY --from=builder /out/etcdutl /usr/local/bin/etcdutl
COPY --from=builder /src/LICENSE /licenses/LICENSE

WORKDIR /var/etcd/
WORKDIR /var/lib/etcd/

EXPOSE 2379 2380

CMD ["/usr/local/bin/etcd"]
