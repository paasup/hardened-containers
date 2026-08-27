# syntax=docker/dockerfile:1
# kyverno-cli — upstream source compiled directly from a pinned commit (the v1.19.0 tag),
# reproducing kyverno's own Makefile `ko-build-cli`/`ko-publish-cli` targets
# (`CGO_ENABLED=0 go build ./cmd/cli/kubectl-kyverno` with the same ldflags) as a plain
# Dockerfile build instead of `ko`. Note the source directory is nested one level deeper
# than the other six kyverno binaries — `cmd/cli/kubectl-kyverno`, not `cmd/kyverno-cli`.
# The output binary itself is named `kubectl-kyverno` (Makefile's
# `CLI_BIN := $(CLI_DIR)/kubectl-kyverno`) — a kubectl-plugin-style name, not `cli` or
# `kyverno-cli`.
#
# The cause is not this binary's own dependencies but the base image `ko` compiles onto
# (`ghcr.io/wolfi-dev/static:alpine`, a floating tag that tracks Alpine's unscannable
# rolling `edge` branch — trivy has no advisory data for it). Same root cause as
# `images/kyverno/` — see ADR 0009 (covers all seven kyverno images as one decision).
#
# Deliberate differences from upstream:
#   - Base image: `ghcr.io/wolfi-dev/static:alpine` (ko's default) → SUSE BCI (`bci-micro`,
#     this repository's only final base — docs/image-authoring/README.md rule 2). The
#     binary is static (CGO_ENABLED=0 in upstream's own Makefile), so no shell/package
#     manager is required.
#   - Entrypoint path: `ko` bakes the binary to an internal `/ko-app/<name>` path; here it
#     is `/app/kubectl-kyverno`. This is a standalone CLI (not a chart-deployed
#     controller), so no chart `command:`/`args:` compatibility concern applies here.
#   - No `.git` dir kept on the git ADD — same root cause as `images/kyverno/README.md`
#     "Building and verifying" (BuildKit's git context does not fetch tag refs for a
#     pinned-commit checkout, so keeping `.git` makes Go stamp a bogus low pseudo-version
#     and trivy false-flags every historical kyverno CVE against it). `pkg/version.Hash()`/
#     `Time()` fall back to "---"; BuildVersion (ldflags below) is what verify.sh and
#     `kubectl-kyverno version`'s printed version actually use.

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
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go get ${GO_MODULE_UPGRADES} && go mod tidy

# Reproduces upstream Makefile's ko-build-cli target as-is (GOARCH replaced by
# TARGETARCH). LD_FLAGS matches Makefile's LD_FLAGS exactly — pkg/version.BuildVersion is
# the only symbol upstream itself sets via ldflags.
RUN --mount=type=cache,target=/root/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    mkdir -p /out; \
    CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
      go build -trimpath \
        -ldflags="-s -w -X github.com/kyverno/kyverno/pkg/version.BuildVersion=${APP_VERSION}" \
        -o /out/kubectl-kyverno ./cmd/cli/kubectl-kyverno

FROM ${RUNTIME_BASE} AS final

WORKDIR /app
COPY --from=builder /out/kubectl-kyverno ./kubectl-kyverno
COPY --from=builder /src/LICENSE /licenses/LICENSE
COPY --from=builder /src/NOTICE  /licenses/NOTICE

# Upstream gets 65532:65532 from wolfi-dev/static:alpine's baked-in nonroot account.
# bci-micro accepts a purely numeric USER with no /etc/passwd entry required.
USER 65532:65532

ENTRYPOINT ["/app/kubectl-kyverno"]
