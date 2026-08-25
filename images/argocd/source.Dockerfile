# syntax=docker/dockerfile:1
# argocd — upstream source compiled directly from a pinned commit. Addresses CVEs in
# statically linked Go modules — the bundled tools (helm/kustomize/git-lfs) are recompiled with
# the same toolchain. Values live in source.build.env. Background and the upstream diff:
# images/argocd/README.md. ADR: docs/decisions/0007-argocd-self-build.md

# An ARG used in a FROM must be declared before the first FROM (global scope) — inside a stage
# it becomes local, and later FROM image names resolve to empty
# (docs/image-authoring/README.md).
ARG GO_BUILDER_TAG=1.26.6-trixie
ARG NODE_BUILDER_TAG=24.14.1
ARG RUNTIME_BASE=registry.suse.com/bci/bci-base:15.7

####################################################################################################
# UI — reproduces upstream's argocd-ui stage as-is. The output is embedded into the binary via Go embed.
####################################################################################################
FROM --platform=$BUILDPLATFORM docker.io/library/node:${NODE_BUILDER_TAG} AS argocd-ui

ARG SOURCE_COMMIT
ARG APP_VERSION
ADD https://github.com/argoproj/argo-cd.git#${SOURCE_COMMIT} /src

# Same as upstream: enable pnpm through corepack and install straight from the lockfile.
WORKDIR /src/ui
RUN npm install -g corepack@0.34.6 && corepack enable && pnpm install --frozen-lockfile

# The UI bundle is architecture-independent — as upstream's comment says, TARGETARCH is not used.
ENV ARGO_VERSION=$APP_VERSION
RUN NODE_ENV='production' NODE_ONLINE_ENV='online' NODE_OPTIONS=--max_old_space_size=8192 pnpm build

####################################################################################################
# Bundled Go tools — what upstream downloads as release binaries is recompiled from source here.
#
# Recompiling with a newer toolchain resolves stdlib, but the modules each project pins in its
# go.mod stay old — missing the tools' modules fails the gate. So the same GO_MODULE_UPGRADES
# used for argocd itself is applied to all three tools.
####################################################################################################
FROM --platform=$BUILDPLATFORM golang:${GO_BUILDER_TAG} AS go-tools

ARG TARGETARCH
ARG HELM_VERSION
ARG KUSTOMIZE_VERSION
ARG GIT_LFS_VERSION
ARG GO_MODULE_UPGRADES
ENV CGO_ENABLED=0 GOOS=linux GO_MODULE_UPGRADES=${GO_MODULE_UPGRADES}
COPY go-mod-upgrade.sh /usr/local/bin/go-mod-upgrade
RUN chmod 0755 /usr/local/bin/go-mod-upgrade
WORKDIR /out

# helm — reproduces upstream's Makefile ldflags (version/gitTreeState).
ADD https://github.com/helm/helm.git#v${HELM_VERSION} /src/helm
RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    cd /src/helm && go-mod-upgrade && \
    P=helm.sh/helm/v4/internal/version && \
    GOARCH=${TARGETARCH} go build -trimpath \
      -ldflags "-X ${P}.version=v${HELM_VERSION} -X ${P}.gitTreeState=clean" \
      -o /out/helm ./cmd/helm

# kustomize — the kustomize/ submodule inside the repo is the CLI.
ADD https://github.com/kubernetes-sigs/kustomize.git#kustomize/v${KUSTOMIZE_VERSION} /src/kustomize
RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    cd /src/kustomize/kustomize && go-mod-upgrade && \
    P=sigs.k8s.io/kustomize/api/provenance && \
    GOARCH=${TARGETARCH} go build -trimpath \
      -ldflags "-X ${P}.version=v${KUSTOMIZE_VERSION}" \
      -o /out/kustomize .

# git-lfs — the Makefile bakes the version in via ldflags.
ADD https://github.com/git-lfs/git-lfs.git#v${GIT_LFS_VERSION} /src/git-lfs
RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    cd /src/git-lfs && go-mod-upgrade && \
    GOARCH=${TARGETARCH} go build -trimpath \
      -ldflags "-X github.com/git-lfs/git-lfs/v3/config.GitCommit=v${GIT_LFS_VERSION}" \
      -o /out/git-lfs .

####################################################################################################
# argocd itself — upstream's argocd-build stage plus the forced upgrade of vulnerable modules
####################################################################################################
FROM --platform=$BUILDPLATFORM golang:${GO_BUILDER_TAG} AS argocd-build

ARG TARGETOS
ARG TARGETARCH
ARG SOURCE_COMMIT
ARG APP_VERSION
ARG GO_MODULE_UPGRADES
ENV GO_MODULE_UPGRADES=${GO_MODULE_UPGRADES}
COPY go-mod-upgrade.sh /usr/local/bin/go-mod-upgrade
RUN chmod 0755 /usr/local/bin/go-mod-upgrade

WORKDIR /go/src/github.com/argoproj/argo-cd
ADD https://github.com/argoproj/argo-cd.git#${SOURCE_COMMIT} .

RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    go-mod-upgrade

COPY --from=argocd-ui /src/ui/dist/app ./ui/dist/app

# Calls the Makefile's argocd-all target, exactly as upstream's Dockerfile does
# (a single `go build -o dist/argocd ./cmd`). The Makefile bakes the version symbols in via
# ldflags. BUILD_DATE is fixed for build reproducibility (upstream inserts the current date).
RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    GIT_TAG=v${APP_VERSION} \
    GIT_COMMIT=${SOURCE_COMMIT} \
    GIT_TREE_STATE=clean \
    BUILD_DATE=1970-01-01T00:00:00Z \
    GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    make argocd-all

####################################################################################################
# C tools — built from source because SLE_BCI has no packages for them
####################################################################################################
FROM ${RUNTIME_BASE} AS c-builder

ARG TINI_VERSION
ARG SSH_CONNECT_VERSION
ARG BUILDER_PACKAGES
# The SLE_BCI mirror drops intermittently (e.g. curl error 56, SSL unexpected eof). Retry.
RUN for i in 1 2 3 4 5; do \
      zypper --non-interactive --gpg-auto-import-keys refresh && break; \
      echo "zypper refresh failed — retry $i"; sleep 10; \
    done && \
    zypper --non-interactive install -y --no-recommends ${BUILDER_PACKAGES} && \
    zypper --non-interactive clean --all

# tini — upstream argocd's ENTRYPOINT (["/usr/bin/tini", "--"]).
# SLE_BCI has no static glibc, so it is built dynamically linked (this stage and final share a base).
ADD https://github.com/krallin/tini.git#v${TINI_VERSION} /src/tini
RUN cd /src/tini && \
    cmake -DCMAKE_BUILD_TYPE=Release . && \
    make tini && \
    install -m 0755 tini /out-tini

# connect-proxy — the upstream of Debian's connect-proxy package (connect.c from gotoh/ssh-connect).
# git uses it in SSH-over-proxy environments. Built rather than dropping the functionality.
ADD https://github.com/gotoh/ssh-connect.git#${SSH_CONNECT_VERSION} /src/connect
RUN cd /src/connect && \
    gcc -O2 -o /out-connect connect.c

####################################################################################################
# Final image — reproduces upstream's argocd-base plus final, on SUSE BCI
####################################################################################################
FROM ${RUNTIME_BASE} AS final

LABEL org.opencontainers.image.source="https://github.com/argoproj/argo-cd"

ARG RUNTIME_PACKAGES
ENV ARGOCD_USER_ID=999

# RUNTIME_PACKAGES is upstream's apt list translated to SLE names. The ones that differ:
#   git → git-core   tzdata → timezone   gpg/gpg-agent → gpg2   openssh-client → openssh-clients
# tini and connect-proxy are absent from SLE_BCI, so they are built in c-builder and COPYed in.
# The SLE_BCI mirror drops intermittently. Retry.
RUN for i in 1 2 3 4 5; do \
      zypper --non-interactive --gpg-auto-import-keys refresh && break; \
      echo "zypper refresh failed — retry $i"; sleep 10; \
    done && \
    zypper --non-interactive update -y && \
    zypper --non-interactive install -y --no-recommends ${RUNTIME_PACKAGES} && \
    zypper --non-interactive clean --all && \
    rm -rf /var/log/zypp /usr/share/doc/packages/*

RUN groupadd -g $ARGOCD_USER_ID argocd && \
    useradd -r -u $ARGOCD_USER_ID -g argocd argocd && \
    mkdir -p /home/argocd && \
    chown argocd:0 /home/argocd && \
    chmod g=u /home/argocd

COPY --from=c-builder /out-tini    /usr/bin/tini
COPY --from=c-builder /out-connect /usr/bin/connect-proxy
COPY --from=go-tools  /out/helm      /usr/local/bin/helm
COPY --from=go-tools  /out/kustomize /usr/local/bin/kustomize
COPY --from=go-tools  /out/git-lfs   /usr/local/bin/git-lfs

# The wrapper scripts upstream installs from source — argocd uses them for gpg verification
# and as its entrypoint.
COPY --from=argocd-build \
    /go/src/github.com/argoproj/argo-cd/hack/gpg-wrapper.sh \
    /go/src/github.com/argoproj/argo-cd/hack/git-verify-wrapper.sh \
    /go/src/github.com/argoproj/argo-cd/entrypoint.sh \
    /usr/local/bin/
RUN chmod 0755 /usr/local/bin/gpg-wrapper.sh /usr/local/bin/git-verify-wrapper.sh /usr/local/bin/entrypoint.sh

# Creates the git-lfs system configuration (/etc/gitconfig) to enable the LFS filter — same as upstream.
RUN git lfs install --system

# A backwards-compatibility symlink — same as upstream.
RUN ln -s /usr/local/bin/entrypoint.sh /usr/local/bin/uid_entrypoint.sh

# Supports configmap mounts — the same paths and permissions as upstream.
WORKDIR /app/config/ssh
RUN touch ssh_known_hosts && \
    ln -s /app/config/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts

WORKDIR /app/config
RUN mkdir -p tls && \
    mkdir -p gpg/source && \
    mkdir -p gpg/keys && \
    chown argocd gpg/keys && \
    chmod 0700 gpg/keys

ENV USER=argocd

# Avoids the _grpc_config DNS TXT lookup causing timeouts in dual-stack environments — same as
# upstream. It can be overridden through argocd-cmd-params-cm.
ENV GRPC_ENABLE_TXT_SERVICE_CONFIG=false

COPY --from=argocd-build /go/src/github.com/argoproj/argo-cd/dist/argocd /usr/local/bin/argocd

# The same nine symlinks as upstream — the chart specifies container commands by these names.
RUN ln -s /usr/local/bin/argocd /usr/local/bin/argocd-server && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-repo-server && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-cmp-server && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-application-controller && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-dex && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-notifications && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-applicationset-controller && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-k8s-auth && \
    ln -s /usr/local/bin/argocd /usr/local/bin/argocd-commit-server

ENTRYPOINT ["/usr/bin/tini", "--"]

USER $ARGOCD_USER_ID
WORKDIR /home/argocd
