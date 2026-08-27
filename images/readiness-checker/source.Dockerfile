# syntax=docker/dockerfile:1
# readiness-checker — upstream source compiled directly from a pinned commit (the
# v1.19.0 tag), reproducing kyverno's own Makefile `ko-build-readiness-checker`/
# `ko-publish-readiness-checker` targets (`CGO_ENABLED=0 go build ./cmd/readiness-checker`
# with the same ldflags) as a plain Dockerfile build instead of `ko`.
#
# The cause is not this binary's own dependencies but the base image `ko` compiles onto
# (`ghcr.io/wolfi-dev/static:alpine`, a floating tag that tracks Alpine's unscannable
# rolling `edge` branch — trivy has no advisory data for it). Same root cause as
# images/kyverno/ — see that image's README.md and ADR 0009 (this image is one of the
# seven kyverno self-builds it covers).
#
# Deliberate differences from upstream:
#   - Base image: `ghcr.io/wolfi-dev/static:alpine` (ko's default) → SUSE BCI (`bci-micro`,
#     this repository's only final base — docs/image-authoring/README.md rule 2). The
#     binary is static (CGO_ENABLED=0 in upstream's own Makefile), so no shell/package
#     manager is required.
#   - Entrypoint path: `ko` bakes the binary to an internal `/ko-app/<name>` path; here it
#     is `/app/readiness-checker`. kyverno's Helm chart does not hardcode a `command:`,
#     only `args:`, so this does not change chart behaviour.
#   - No `.git` dir kept on the git ADD — same root cause as images/kyverno/README.md's
#     "Building and verifying" pitfall (do not re-derive it here).

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
ADD https://github.com/kyverno/kyverno.git#${SOURCE_COMMIT} /src

# Force-upgrade the vulnerable module(s) to their minimum fixed version (see build.env).
# GO_MODULE_UPGRADES is empty for this image (see build.env) — unlike the sibling kyverno
# controller binaries, `go get` with no arguments is not a safe no-op here: WORKDIR /src
# is the repository root, which has no .go files of its own (only subdirectories), so a
# bare `go get` fails with "no package to get in current directory". Skip the step
# entirely when there is nothing to upgrade instead of relying on an empty expansion.
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    if [ -n "${GO_MODULE_UPGRADES}" ]; then go get ${GO_MODULE_UPGRADES} && go mod tidy; fi

# Reproduces upstream Makefile's ko-build-readiness-checker target as-is (GOARCH replaced
# by TARGETARCH). LD_FLAGS matches Makefile's LD_FLAGS exactly — pkg/version.BuildVersion
# is the only symbol upstream itself sets via ldflags.
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    mkdir -p /out; \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
      go build -trimpath \
        -ldflags="-s -w -X github.com/kyverno/kyverno/pkg/version.BuildVersion=${APP_VERSION}" \
        -o /out/readiness-checker ./cmd/readiness-checker

FROM ${RUNTIME_BASE} AS final

WORKDIR /app
COPY --from=builder /out/readiness-checker ./readiness-checker
COPY --from=builder /src/LICENSE /licenses/LICENSE
COPY --from=builder /src/NOTICE  /licenses/NOTICE

# Upstream gets 65532:65532 from wolfi-dev/static:alpine's baked-in nonroot account.
# bci-micro accepts a purely numeric USER with no /etc/passwd entry required.
USER 65532:65532

ENTRYPOINT ["/app/readiness-checker"]
