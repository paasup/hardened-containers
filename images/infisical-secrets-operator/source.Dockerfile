# syntax=docker/dockerfile:1
# infisical-secrets-operator — upstream source compiled directly from a pinned commit
# (the infisical-k8-operator/v0.11.8 tag), reproducing upstream's own Dockerfile build
# step (`CGO_ENABLED=0 go build -ldflags=... cmd/main.go`) as-is, with only the
# vulnerable transitive dependencies force-upgraded (the same pattern as this
# repository's other source-compiled self-builds — closest precedent:
# apisix-ingress-controller, ADR 0006).
#
# The cause is the versions of statically linked Go modules, so neither a newer tag
# (already latest) nor a base OS swap (upstream's own final base is already
# distroless-family, almost no OS packages) resolves it — candidates compared and
# rationale: "Why we build this ourselves" in README.md, and ADR 0010.
#
# Deliberate differences from upstream:
#   - Force-upgrade the vulnerable modules only (this is a single-module project with no
#     go.work, so a workspace-wide replace is unavailable; `go get` plus `go mod tidy` is
#     used instead, same as apisix-ingress-controller). Application code is the pinned
#     tag unchanged.
#   - gcr.io/distroless/static:nonroot → replaced with SUSE BCI (bci-micro). This
#     repository uses SUSE BCI only (docs/image-authoring/README.md rule 2) — the builder
#     stage uses the official golang image as-is. The binary is static
#     (CGO_ENABLED=0, same as upstream), so no glibc-bearing variant is needed.
#
# ldflags reproduces upstream's own -X .../internal/util.Version injection as-is — the
# only build-time symbol upstream itself sets (used solely for the operator's outbound
# HTTP User-Agent header — upstream internal/util/version.go).

ARG GO_BUILDER_TAG=1.26.7-trixie
# An ARG used in a FROM must be declared before the first FROM (global scope) — see
# docs/image-authoring/README.md.
ARG RUNTIME_BASE=registry.suse.com/bci/bci-micro:15.7

FROM --platform=$BUILDPLATFORM golang:${GO_BUILDER_TAG} AS builder
ARG TARGETARCH
ARG SOURCE_COMMIT
ARG APP_VERSION
ARG GO_MODULE_UPGRADES
WORKDIR /src

# BuildKit's git context — git itself guarantees commit integrity, no separate checksum needed.
ADD https://github.com/Infisical/kubernetes-operator.git#${SOURCE_COMMIT} /src

# Force-upgrade the vulnerable modules to their minimum fixed version (see build.env).
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go get ${GO_MODULE_UPGRADES} && go mod tidy

# Reproduces upstream's own build step as-is (GOARCH replaced by TARGETARCH — the final
# base is linux-only; VERSION injected the same symbol upstream's own CI does).
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    mkdir -p /out; \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
      go build -ldflags="-X github.com/Infisical/infisical/k8-operator/internal/util.Version=${APP_VERSION}" \
        -a -o /out/manager cmd/main.go

FROM ${RUNTIME_BASE} AS final

# Same layout as upstream — binary at /manager, WORKDIR /.
WORKDIR /
COPY --from=builder /out/manager /manager
COPY --from=builder /src/LICENSE /licenses/LICENSE

# Upstream gets 65532:65532 as the default user from the distroless `:nonroot` tag —
# bci-micro has no such tag variant, so it is set explicitly.
USER 65532:65532

ENTRYPOINT ["/manager"]
