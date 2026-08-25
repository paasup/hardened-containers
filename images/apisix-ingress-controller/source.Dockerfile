# syntax=docker/dockerfile:1
# apisix-ingress-controller — upstream source compiled directly from a pinned commit (the
# v2.1.0 tag), with only the vulnerable transitive dependencies force-upgraded (the same
# pattern as the other source-compiled self-builds). Upstream's root Dockerfile only COPYs an
# already-built binary — the compilation itself is done by the Makefile's `build` and
# `build-multi-arch` targets (`CGO_ENABLED=0 go build ...`). That build step is brought inside
# the Dockerfile and reproduced here.
#
# The cause is the versions of statically linked Go modules, so neither a newer tag nor a base
# OS swap resolves it — candidates compared and rationale: "Why we build this ourselves" in
# README.md, and ADR 0006.
#
# Deliberate difference from upstream — force-upgrade the vulnerable modules only (this is a
# single-module project with no go.work, so a workspace-wide replace is unavailable;
# `go get` plus `go mod tidy` is used instead). The application code itself is the v2.1.0 tag
# unchanged (reasoning in README.md).
#
#   gcr.io/distroless/cc-debian12  →  replaced with SUSE BCI (bci-micro). This repository uses
#     SUSE BCI only (docs/image-authoring/README.md rule 2) — the builder stage uses the
#     official golang image as-is. The binary is static (CGO_ENABLED=0), so the cc variant
#     (which bundles glibc) is not needed.
#
# ldflags — reproduces upstream's Makefile GO_LDFLAGS as-is (the four build-time symbols in
# the internal/version package). The full pinned commit hash is baked into the GitSHA slot so
# verify.sh can confirm it from the version string without running git inside the container.

ARG GO_BUILDER_TAG=1.26.5-trixie
# An ARG used in a FROM must be declared before the first FROM (global scope) — see
# docs/image-authoring/README.md.
ARG RUNTIME_BASE=registry.suse.com/bci/bci-micro:15.7

FROM --platform=$BUILDPLATFORM golang:${GO_BUILDER_TAG} AS builder
ARG TARGETARCH
ARG SOURCE_COMMIT
ARG APP_VERSION
ARG MIN_K8S_VERSION
ARG XNET_FIX_VERSION
ARG XTEXT_FIX_VERSION
ARG GRPC_FIX_VERSION
ARG OTEL_FIX_VERSION
WORKDIR /src

# BuildKit's git context support — git itself guarantees commit integrity, with no tarball
# and checksum to manage.
ADD https://github.com/apache/apisix-ingress-controller.git#${SOURCE_COMMIT} /src

# Force-upgrade only the vulnerable transitive dependencies, to their minimum versions (see
# above). otel and otel/sdk must have matching versions, so they are specified together —
# go get settles the remaining compatible versions.
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go get \
      golang.org/x/net@v${XNET_FIX_VERSION} \
      golang.org/x/text@v${XTEXT_FIX_VERSION} \
      google.golang.org/grpc@v${GRPC_FIX_VERSION} \
      go.opentelemetry.io/otel@v${OTEL_FIX_VERSION} \
      go.opentelemetry.io/otel/sdk@v${OTEL_FIX_VERSION} \
 && go mod tidy

# Reproduces upstream's Makefile build target as-is (GOARCH replaced by TARGETARCH, and the
# full pinned commit hash baked into the GitSHA slot — see above).
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    mkdir -p /out; \
    VERSYM="github.com/apache/apisix-ingress-controller/internal/version._buildVersion"; \
    GITSHASYM="github.com/apache/apisix-ingress-controller/internal/version._buildGitRevision"; \
    BUILDOSSYM="github.com/apache/apisix-ingress-controller/internal/version._buildOS"; \
    MINK8SVERSYM="github.com/apache/apisix-ingress-controller/internal/manager._minK8sVersion"; \
    LDFLAGS="-X=${VERSYM}=${APP_VERSION} -X=${GITSHASYM}=${SOURCE_COMMIT} -X=${BUILDOSSYM}=linux/${TARGETARCH} -X=${MINK8SVERSYM}=${MIN_K8S_VERSION}"; \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -trimpath -ldflags="${LDFLAGS}" -o /out/apisix-ingress-controller cmd/main.go

FROM ${RUNTIME_BASE} AS final

# The same path as upstream — not strictly required, since the Helm chart does not hardcode a
# path, but the correspondence with upstream's Dockerfile is kept.
WORKDIR /app
COPY --from=builder /out/apisix-ingress-controller ./apisix-ingress-controller
COPY --from=builder /src/LICENSE /licenses/LICENSE
COPY --from=builder /src/NOTICE  /licenses/NOTICE

# Upstream gets 65532:65532 as the default user from the distroless `:nonroot` tag —
# bci-micro has no such tag variant, so it is set explicitly.
USER 65532:65532

ENTRYPOINT ["/app/apisix-ingress-controller"]
CMD ["-c", "/app/conf/config.yaml"]
