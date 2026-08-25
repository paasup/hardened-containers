# Keycloak — self-build on SUSE BCI (plus the vulnerable jar overlay)
#
# Upstream: https://github.com/keycloak/keycloak/blob/main/quarkus/container/Dockerfile
#
# Repackages the upstream distribution onto a SUSE BCI rootfs and replaces the vulnerable jars
# shipped inside it with fixed versions. The rationale for self-building, for the BCI version
# choice, and for the rootfs assembly method is in ADR 0008; the differences from upstream are
# in README.md.
#
# Correspondence with upstream
#   registry.access.redhat.com/ubi9 (builder)      →  registry.suse.com/bci/bci-base:15.7
#   ubi-null.sh (build rootfs, then rpm erase the rest) →  bci-micro filesystem seed + zypper --installroot
#   registry.access.redhat.com/ubi9-micro (final)  →  FROM scratch + the rootfs above
#   ADD $KEYCLOAK_DIST → tar → /opt/keycloak       →  identical
#   keycloak:x:0:root / uid 1000 / ENTRYPOINT      →  identical
#   (none)                                         →  vulnerable jar overlay + kc.sh build re-augmentation
#
# ARGs must be declared before the first FROM (global scope). Inside a stage they become local
# and are not used to resolve later FROM image names (checklist step 3 in
# docs/image-authoring/README.md).
ARG BUILDER_BASE=registry.suse.com/bci/bci-base:15.7
ARG MICRO_BASE=registry.suse.com/bci/bci-micro:15.7

# The seed for the final runtime rootfs. Nothing is built here; only the filesystem is taken.
FROM ${MICRO_BASE} AS micro


FROM ${BUILDER_BASE} AS builder

ARG KEYCLOAK_VERSION
ARG RUNTIME_PACKAGES
ARG NETTY_OLD
ARG NETTY_VERSION
ARG JACKSON_OLD
ARG JACKSON_VERSION
ARG PGJDBC_OLD
ARG PGJDBC_VERSION
ARG MICROMETER_OLD
ARG MICROMETER_VERSION

# (a) Build the runtime rootfs. The rootfs uses the seed method (see "Adding packages on top
# of bci-micro" in docs/image-authoring/base-os-policy.md) — creating a separate installroot
# and laying it over micro causes rpmdb masking, so it is not used.
#
# rpm --import comes first. Without it the installroot's rpmdb has no SUSE keys, and every
# installed package skips per-package signature verification with
# "Header V3 RSA/SHA256 Signature, key ID ...: NOKEY" (zypper still checks the repository
# metadata signature, but per-package verification is separate).
COPY --from=micro / /rootfs
RUN set -eux; \
    rpm --root /rootfs --import /usr/lib/rpm/gnupg/keys/*.asc; \
    zypper --non-interactive --installroot /rootfs --gpg-auto-import-keys refresh; \
    zypper --non-interactive --installroot /rootfs install -y --no-recommends \
      ${RUNTIME_PACKAGES}; \
    zypper --non-interactive --installroot /rootfs clean --all; \
    rm -rf /rootfs/var/log/zypp /rootfs/var/cache/zypp /rootfs/var/cache/zypper

# (b) Unpack the upstream distribution — identical to upstream's ADD $KEYCLOAK_DIST + tar step.
ADD https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VERSION}/keycloak-${KEYCLOAK_VERSION}.tar.gz /tmp/keycloak/
RUN set -eux; \
    cd /tmp/keycloak; \
    tar -xf keycloak-*.tar.gz; \
    rm keycloak-*.tar.gz; \
    mv keycloak-* /opt/keycloak; \
    mkdir -p /opt/keycloak/data; \
    chmod -R g+rwX /opt/keycloak

# (c) The vulnerable jar overlay. Filenames stay the same; only the contents become the fixed
#     versions — details in the overlay-jars.sh comments. If no target file is found, the
#     script fails.
COPY overlay-jars.sh /tmp/
RUN bash /tmp/overlay-jars.sh /opt/keycloak


FROM scratch AS final

COPY --from=builder /rootfs/ /
COPY --from=builder --chown=1000:0 /opt/keycloak /opt/keycloak

ENV LANG=en_US.UTF-8
# Identical to upstream — the flag used to detect running inside a container
ENV KC_RUN_IN_CONTAINER=true

RUN echo "keycloak:x:0:root" >> /etc/group && \
    echo "keycloak:x:1000:0:keycloak user:/opt/keycloak:/sbin/nologin" >> /etc/passwd

# SUSE exposes java through an update-alternatives symlink. Because this is a chroot install
# the link may not be created, so it is asserted at build time — failing here is better than
# dying at runtime with "java: not found".
RUN java -version 2>&1 | head -1

# Confirms at build time that augmentation actually passes with the overlaid jars.
# With no options, build reproduces the pre-augmentation state of the release tar, so runtime
# behaviour matches the upstream image (this is not about producing an optimised image).
RUN /opt/keycloak/bin/kc.sh build && chown -R 1000:0 /opt/keycloak

USER 1000

EXPOSE 8080
EXPOSE 8443
EXPOSE 9000

ENTRYPOINT [ "/opt/keycloak/bin/kc.sh" ]
