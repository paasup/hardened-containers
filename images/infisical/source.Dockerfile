# syntax=docker/dockerfile:1
# infisical — upstream source (the v0.164.1 tag) compiled directly, reproducing
# upstream's own Dockerfile.standalone-infisical build steps, with three deliberate
# scope cuts and one force-upgrade list. Candidates compared and rationale: "Why we
# build this ourselves" / "Differences from upstream" in README.md, and ADR 0011.
#
# Scope cuts (each confirmed against upstream's own source before cutting — see
# README.md for the evidence):
#   - Oracle Instant Client, the bundled `infisical` CLI (installed upstream via
#     curl|sh — forbidden here regardless), smbclient, and the from-source PQC OpenSSL
#     build are all dropped. Each is reached only through a lazily-spawned child
#     process or an explicitly gated code path (never imported/touched at server
#     bootstrap) — dropping them shrinks the image without changing default behaviour.
#   - The Go "sidecar" binary (backend-go/, the Gateway on-prem relay) is dropped the
#     same way — its own plugin checks `if (!opts.enabled) return` before ever
#     touching the binary path.
#   - unixODBC's *runtime* library is the one thing from that list that is NOT
#     droppable: the dynamic-secret provider registry statically imports the `odbc`
#     npm package at server bootstrap (providers/index.ts -> sap-ase.ts / sap-hana.ts),
#     so the native addon's shared-library dependency must resolve even though no SAP
#     ASE/HANA dynamic secret is configured by default. FreeTDS itself (the actual TDS
#     driver `odbcinst.ini` points at) is not needed until an actual connection is
#     attempted, so it is dropped.
#
# Deliberate difference from upstream — the *backend* builder is SUSE BCI
# (registry.suse.com/bci/bci-base), not the official node image upstream uses. The
# backend's production dependencies include native Node addons (argon2, bcrypt, odbc)
# compiled by `npm ci` — compiling them against Debian's glibc and running them on SUSE
# BCI risks an ABI mismatch at load time. Same principle as the C/Lua rule in
# docs/image-authoring/builder-languages.md ("keep the builder stage and the final
# stage on the same base and link dynamically"), extended to native Node addons. The
# *frontend* build has no native addons in its output (static Vite assets only), so it
# keeps the normal default (the official node image, matching upstream's own pin) with
# no ABI concern.
#
# Vulnerable Node production dependencies are force-upgraded — npm's equivalent of
# GO_MODULE_UPGRADES, split into two build.env lists because npm's `overrides` field
# cannot target a package that is also a direct dependency (`npm error EOVERRIDE`):
# NPM_DIRECT_UPGRADES bumps `dependencies` itself; NPM_OVERRIDES forces the rest
# (transitive-only) via npm's `overrides` mechanism. `npm install`, not `npm ci`, is used
# afterward — `npm ci` refuses to proceed once `npm pkg set` has put package.json out of
# sync with the committed package-lock.json, by design (`npm error EUSAGE`).
#
# @infisical/quic (a Rust-native addon, required for the Gateway/QUIC transport) is
# NOT force-upgraded — it ships as a prebuilt platform binary via npm
# optionalDependencies, is already pinned to its latest published version, and that
# version still carries known CVEs with no newer release available. See
# cve-exceptions.json and README.md "Version management".

ARG NODE_BUILDER_TAG=22.22.0-trixie-slim
# An ARG used in a FROM must be declared before the first FROM (global scope) — see
# docs/image-authoring/README.md.
ARG RUNTIME_BASE=registry.suse.com/bci/bci-base:15.7

# BuildKit's git context — git itself guarantees commit integrity, no separate checksum
# needed. A dedicated scratch stage avoids re-cloning the repo once per downstream stage.
FROM scratch AS src
ARG SOURCE_COMMIT
ADD https://github.com/Infisical/infisical.git#${SOURCE_COMMIT} /src

##
## FRONTEND — official node image (no native addons in the output, no ABI concern)
##
FROM --platform=$BUILDPLATFORM node:${NODE_BUILDER_TAG} AS frontend-deps
WORKDIR /app
COPY --from=src /src/frontend/package.json /src/frontend/package-lock.json ./
RUN npm ci --ignore-scripts

FROM --platform=$BUILDPLATFORM node:${NODE_BUILDER_TAG} AS frontend-builder
WORKDIR /app
COPY --from=frontend-deps /app/node_modules ./node_modules
COPY --from=src /src/frontend .
ENV NODE_ENV=production
ENV NODE_OPTIONS="--max-old-space-size=8192"
ARG APP_VERSION
ENV INFISICAL_PLATFORM_VERSION=${APP_VERSION}
ENV VITE_INFISICAL_PLATFORM_VERSION=${APP_VERSION}
RUN npm run build

##
## BACKEND builder toolchain — SUSE BCI, same base as the final stage (see header).
##
FROM ${RUNTIME_BASE} AS backend-toolchain
ARG NODEJS_PKG
ARG NODEJS_DEVEL_PKG
ARG NPM_PKG
# node-gyp (compiling odbc/argon2/bcrypt's native addons) requires Python 3.8+ — SLE_BCI's
# `python3` package is 3.6.15, which node-gyp's bundled gyp fails on (SyntaxError on the
# walrus operator). python313 has no /usr/bin/python3 alternative wired up by default (no
# update-alternatives in this image), so the symlink is created explicitly.
RUN zypper -n install -y --no-recommends \
      ${NODEJS_PKG} ${NODEJS_DEVEL_PKG} ${NPM_PKG} \
      gcc-c++ make python313 unixODBC-devel \
    && ln -sf /usr/bin/python3.13 /usr/bin/python3 \
    && zypper -n clean --all
WORKDIR /app

FROM backend-toolchain AS backend-build
ARG SOURCE_COMMIT
ARG APP_VERSION
ARG NPM_DIRECT_UPGRADES
ARG NPM_OVERRIDES
COPY --from=src /src/backend .
COPY --from=src /src/standalone-entrypoint.sh standalone-entrypoint.sh
# Force-upgrade vulnerable dependencies before resolving the tree (see build.env and the
# header comment above for why this is split in two). Bracket syntax is required for
# `npm pkg set` on scoped package names (@scope/name). NPM_DIRECT_UPGRADES sets both
# `dependencies` and a self-referencing `overrides[pkg]["."]` to the *same* range —
# npm's EOVERRIDE check is a textual comparison against `dependencies`, not a semver
# satisfaction check, so a bare version here (no "^") would conflict even though it's
# compatible. Only the `dependencies` bump forces the top-level resolution; the
# matching override on top of it is what dedupes every *nested* copy other packages
# pull in (measured: without it, e.g. uuid@3.3.3/8.3.2/9.0.1/10.0.0/11.1.0 all kept
# coexisting alongside the fixed top-level uuid@11.1.1).
RUN for spec in ${NPM_DIRECT_UPGRADES}; do \
      pkg="${spec%@*}"; ver="${spec##*@}"; \
      npm pkg set "dependencies[${pkg}]=^${ver}"; \
      npm pkg set "overrides[${pkg}][.]=^${ver}"; \
    done
RUN for spec in ${NPM_OVERRIDES}; do \
      pkg="${spec%@*}"; ver="${spec##*@}"; \
      npm pkg set "overrides[${pkg}]=${ver}"; \
    done
RUN npm install
RUN npm i -g tsconfig-paths
ENV NODE_OPTIONS="--max-old-space-size=8192"
RUN npm run build
# No Contentful secrets are supplied by this build (self-hosted/air-gapped path) — the
# same no-op upstream itself documents for cloud/dev builds without those secrets.
RUN --mount=type=secret,id=contentful_space_id,required=false \
    --mount=type=secret,id=contentful_delivery_token,required=false \
    --mount=type=secret,id=contentful_environment,required=false \
    npm run bake:announcements

FROM backend-toolchain AS backend-prod-deps
ARG NPM_DIRECT_UPGRADES
ARG NPM_OVERRIDES
COPY --from=src /src/backend/package.json /src/backend/package-lock.json ./
RUN for spec in ${NPM_DIRECT_UPGRADES}; do \
      pkg="${spec%@*}"; ver="${spec##*@}"; \
      npm pkg set "dependencies[${pkg}]=^${ver}"; \
      npm pkg set "overrides[${pkg}][.]=^${ver}"; \
    done
RUN for spec in ${NPM_OVERRIDES}; do \
      pkg="${spec%@*}"; ver="${spec##*@}"; \
      npm pkg set "overrides[${pkg}]=${ver}"; \
    done
RUN npm install --omit=dev

##
## FINAL — SUSE BCI, runtime packages only (no compiler, no dev headers).
##
FROM ${RUNTIME_BASE} AS final
ARG NODEJS_PKG
RUN zypper -n install -y --no-recommends ${NODEJS_PKG} libodbc2 \
    && zypper -n clean --all

ENV ChrystokiConfigurationPath=/usr/safenet/lunaclient/

RUN printf "[FreeTDS]\nDescription = FreeTDS Driver\nDriver = /usr/lib64/libtdsodbc.so\nSetup = /usr/lib64/libtdsS.so\nFileUsage = 1\n" > /etc/odbcinst.ini

RUN groupadd --system --gid 1001 nodejs \
    && useradd --system --uid 1001 --gid nodejs non-root-user

WORKDIR /backend
COPY --from=backend-build --chown=1001:1001 /app/dist ./dist
COPY --from=backend-build --chown=1001:1001 /app/package.json ./package.json
COPY --from=backend-build --chown=1001:1001 /app/scripts ./scripts
COPY --from=backend-build --chown=1001:1001 /app/standalone-entrypoint.sh ./standalone-entrypoint.sh
COPY --from=backend-prod-deps --chown=1001:1001 /app/node_modules ./node_modules
COPY --from=frontend-builder --chown=1001:1001 /app/dist ./frontend-build
COPY --from=src /src/LICENSE /licenses/LICENSE
RUN chmod +x ./scripts/export-assets.sh ./standalone-entrypoint.sh  # upstream's own CDN asset-extraction script, copied in above  
# upstream's own CDN asset-extraction script, copied in above

# Give non-root-user permission to update SSL certs, same as upstream.
RUN chown -R non-root-user /etc/ssl/certs \
    && chmod -R u+rwx /etc/ssl/certs \
    && chown non-root-user /usr/sbin/update-ca-certificates \
    && chmod u+rx /usr/sbin/update-ca-certificates

ARG APP_VERSION
ENV INFISICAL_PLATFORM_VERSION=${APP_VERSION}
ARG SOURCE_COMMIT
ENV DD_GIT_COMMIT_SHA=${SOURCE_COMMIT}

LABEL org.opencontainers.image.title="Infisical"
LABEL org.opencontainers.image.description="Open-source secret management platform (unofficial hardened rebuild)"
LABEL org.opencontainers.image.url="https://infisical.com"
LABEL org.opencontainers.image.source="https://github.com/Infisical/infisical"
LABEL org.opencontainers.image.vendor="Infisical"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${APP_VERSION}"
LABEL org.opencontainers.image.revision="${SOURCE_COMMIT}"

ENV PORT=8080
ENV HOST=0.0.0.0
ENV HTTPS_ENABLED=false
ENV NODE_ENV=production
ENV STANDALONE_BUILD=true
ENV STANDALONE_MODE=true
ENV NODE_OPTIONS="--max-old-space-size=2048"
ENV TELEMETRY_ENABLED=true

EXPOSE 8080

USER 1001

CMD ["./standalone-entrypoint.sh"]
