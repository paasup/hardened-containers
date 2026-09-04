# syntax=docker/dockerfile:1
# CloudNativePG operator — upstream source compiled directly from a pinned commit.
# Upstream only COPYs binaries prebuilt by goreleaser (`dist/manager/manager_<arch>`) —
# that compile step is brought inside the Dockerfile and reproduced with `go build`.
#
# Addresses CVEs in statically linked Go modules — rationale:
# docs/decisions/0002-cloudnative-pg-operator-self-build.md
#
# Correspondence with upstream (against the maintenance branch Dockerfile)
#   go build (Makefile build-manager)          →  identical (ldflags included)
#   goreleaser multi-arch (manager_amd64/arm64) →  a single architecture (linux/amd64) COPYed
#     directly. The symlink is replaced by COPYing the same binary to both paths (see below)
#   distroless base (gcr.io/distroless/static-debian13:nonroot) →  replaced with SUSE BCI
#     (bci-micro). This repository uses SUSE BCI only (decisions/0001) — applied to the final
#     runtime image as well. The builder stage (Go compilation) uses the official golang image
#     as-is — it does not affect the compiled output, and what matters for scanning and policy
#     is only what remains in the final image

ARG GO_BUILDER_TAG=1.26.5-trixie
# An ARG used in a FROM must be declared before the first FROM (global scope) — declared
# inside a stage it becomes local to that stage, is not used to resolve the next FROM's image
# name, and the build fails with an empty image name plus a
# "FROM argument 'RUNTIME_BASE' is not declared" warning.
ARG RUNTIME_BASE=registry.suse.com/bci/bci-micro:15.7

# Run the builder on the host's native architecture. Go cross-compilation needs no
# emulation, so pinning --platform=$BUILDPLATFORM avoids the emulation overhead (which matters
# especially when producing linux/amd64 output on a local arm64 Docker Desktop).
FROM --platform=$BUILDPLATFORM golang:${GO_BUILDER_TAG} AS builder
ARG TARGETARCH
ARG SOURCE_COMMIT
ARG APP_VERSION
ARG GO_MODULE_UPGRADES
WORKDIR /src

# BuildKit's git context support — git itself guarantees commit integrity, with no tarball
# and checksum to manage.
ADD https://github.com/cloudnative-pg/cloudnative-pg.git#${SOURCE_COMMIT} /src

# Force-upgrade the vulnerable module(s) to their minimum fixed version (see build.env).
# Normally empty here — this image resolves its CVEs by compiling the maintenance branch
# HEAD, where upstream has already backported them. The lever exists so that a module CVE
# upstream has *not* backported can be fixed without editing this Dockerfile, and so
# suggest-go-upgrades.py --apply can raise the pin on its own.
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    if [ -n "${GO_MODULE_UPGRADES}" ]; then go get ${GO_MODULE_UPGRADES} && go mod tidy; fi

# Reproduces upstream's Makefile LDFLAGS and the build settings in .goreleaser.yml.
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath \
      -ldflags "-s -w \
        -X github.com/cloudnative-pg/cloudnative-pg/pkg/versions.buildVersion=${APP_VERSION} \
        -X github.com/cloudnative-pg/cloudnative-pg/pkg/versions.buildCommit=${SOURCE_COMMIT} \
        -X github.com/cloudnative-pg/cloudnative-pg/pkg/versions.buildDate=$(date -u +%Y-%m-%d)" \
      -o /out/manager ./cmd/manager

FROM ${RUNTIME_BASE} AS final
WORKDIR /

# bci-micro has only root and no 65532 user (unlike distroless's nonroot variant, it does not
# pre-create a nonroot account) — so we create one. bci-micro does have bash and coreutils
# (but no zypper or rpm — "micro" means the package manager is gone, not the shell).
RUN set -eux; \
    echo 'nonroot:x:65532:65532:nonroot:/home/nonroot:/bin/false' >> /etc/passwd; \
    echo 'nonroot:x:65532:' >> /etc/group; \
    mkdir -p /home/nonroot; \
    chown 65532:65532 /home/nonroot

# Required: the operator builds its "available architectures" list from the presence of
# `operator/manager_<GOARCH>` (discovery.go DetectAvailableArchitectures) — if that list is
# empty, Cluster reconciliation fails. Instead of upstream's symlink, the same binary is
# COPYed to both paths — both must be kept.
COPY --from=builder /out/manager /manager
COPY --from=builder /out/manager /operator/manager_amd64
COPY --from=builder /src/licenses /licenses
COPY --from=builder /src/LICENSE /licenses/LICENSE
USER 65532:65532
ENTRYPOINT ["/manager"]
