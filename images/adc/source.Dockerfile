# syntax=docker/dockerfile:1
# adc — a self-build replacing upstream ghcr.io/api7/adc:0.29.0. The builder stage is reused
# from upstream unchanged; only the final stage's base becomes SUSE BCI. Background and
# rationale: README.md and ADR 0004.
#
# Upstream (libs/tools/src/docker/Dockerfile, tag v0.29.0) has two stages:
#   FROM node:lts-bookworm-slim AS builder   (bundles to a single main.cjs with pnpm + nx)
#   FROM gcr.io/distroless/nodejs24-debian13:nonroot
#   COPY --from=builder main.cjs .
# The builder stage is out of policy scope (image-authoring/README.md rule 2), so it is
# reproduced as-is — all that changes is one line of base in the final stage.
#
# Deliberate difference from upstream — the final stage base only
#   gcr.io/distroless/nodejs24-debian13:nonroot  →  registry.suse.com/bci/bci-base:15.7
#     + zypper install nodejs24 (staying on the same Node major, 24)
#   /nodejs/bin/node  →  /usr/bin/node (the actual path zypper installs to)

ARG BUILDER_BASE=node:lts-bookworm-slim
ARG RUNTIME_BASE=registry.suse.com/bci/bci-base:15.7

FROM ${BUILDER_BASE} AS builder
ARG SOURCE_COMMIT

ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME/bin:$PATH"
ENV NX_DAEMON="false"
RUN corepack enable

WORKDIR /build

# BuildKit's git context support — git itself guarantees commit integrity, with no tarball
# and checksum to manage.
ADD https://github.com/api7/adc.git#${SOURCE_COMMIT} /build

RUN pnpm install nx -g \
 && pnpm install \
 && NODE_ENV=production nx build cli

FROM ${RUNTIME_BASE} AS final
ARG NODE_PKG=nodejs24

RUN zypper -n install -y ${NODE_PKG} \
 && zypper -n clean --all

COPY --from=builder /build/dist/apps/cli/main.cjs /adc/main.cjs

# Upstream's final stage gets non-root by default from the distroless ":nonroot" tag —
# bci-base has no such tag variant, so the user is created explicitly.
RUN groupadd --system --gid 1000 adc \
 && useradd --system --gid adc --no-create-home --shell /usr/sbin/nologin --uid 1000 adc \
 && chown -R adc:adc /adc

WORKDIR /adc
USER adc
ENTRYPOINT ["/usr/bin/node", "main.cjs"]
