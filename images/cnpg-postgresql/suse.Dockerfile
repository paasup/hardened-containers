# CloudNativePG PostgreSQL — self-build on SUSE BCI
#
# A port of the upstream CNPG Dockerfile (Debian / apt / PGDG-deb) to SUSE
# (zypper / PGDG-rpm). This is more than changing ARG BASE — the package manager, repository
# setup, package names, and paths all differ.
#
# Correspondence with upstream
#   postgresql-common + apt.postgresql.org.sh  →  rpm --import + zypper addrepo (PGDG zypp)
#   postgresql-18                              →  postgresql18-server
#   postgresql-18-pgaudit / -pgvector          →  pgaudit_18 / pgvector_18
#   locales-all                                →  glibc-locale
#   usermod -u 26 postgres                     →  unnecessary (the PGDG RPM creates it as uid 26)
#   /usr/lib/postgresql/18/bin                 →  /usr/pgsql-18/bin

ARG BASE=registry.suse.com/bci/bci-base:15.7
FROM $BASE AS minimal

ARG PG_MAJOR=18
ARG PG_VERSION=18.4-4200001PGDG.sles15.7
ARG SLE_REPO=sles-15.7-x86_64
ARG PGDG_KEY=PGDG-RPM-GPG-KEY-SLES15

ENV PATH=$PATH:/usr/pgsql-${PG_MAJOR}/bin

# The PGDG repository requires importing the GPG key first. With addrepo alone, the
# repository is skipped with "Signature verification failed for repomd.xml".
RUN set -eux; \
    rpm --import "https://download.postgresql.org/pub/repos/zypp/keys/${PGDG_KEY}"; \
    zypper --non-interactive addrepo --refresh \
      "https://download.postgresql.org/pub/repos/zypp/${PG_MAJOR}/suse/${SLE_REPO}/" pgdg; \
    zypper --non-interactive refresh; \
    zypper --non-interactive install -y --no-recommends \
      "postgresql${PG_MAJOR}-server=${PG_VERSION}"; \
    zypper clean --all; \
    rm -rf /var/log/zypp /var/cache/zypp

# CNPG finds binaries via PATH, but this guards against code that assumes the Debian layout.
RUN set -eux; \
    mkdir -p /usr/lib/postgresql; \
    ln -sfn "/usr/pgsql-${PG_MAJOR}" "/usr/lib/postgresql/${PG_MAJOR}"; \
    # The PGDG RPM creates it as uid 26 — the same as upstream
    id postgres | grep -q 'uid=26(' || { echo "postgres uid is not 26"; exit 1; }

USER 26


# pg_textsearch (Timescale, BM25 full-text index) — compiled from source.
# Why: the PGDG zypp repository has no package for it. It is added on top of upstream's
# standard extension set for databases that need BM25 keyword search; other databases are
# unaffected unless they CREATE EXTENSION / preload it.
# The builder stays on the same BCI base as the final image (dynamic linking, no static glibc).
# `with_llvm=no` skips JIT bitcode — this image does not install the llvmjit package either.
# For the same reason postgresql-devel is installed with --nodeps: its only unmet requirement on
# BCI is clang/llvm (for that bitcode), which BCI's repositories do not carry. The devel EVR is
# pinned to PG_VERSION so the headers match the server in the final image. Builder stage only.
FROM minimal AS pg-textsearch-build
ARG PG_MAJOR=18
ARG PG_VERSION=18.4-4200001PGDG.sles15.7
ARG PG_TEXTSEARCH_VERSION
ARG PG_TEXTSEARCH_SHA256
USER 0
RUN set -eux; \
    zypper --non-interactive install -y --no-recommends gcc make tar gzip gawk; \
    zypper --non-interactive --pkg-cache-dir /tmp/rpms download "postgresql${PG_MAJOR}-devel=${PG_VERSION}"; \
    rpm -i --nodeps $(find /tmp/rpms -name "postgresql${PG_MAJOR}-devel-*.rpm"); \
    curl -fsSL -o /tmp/pg_textsearch.tar.gz \
      "https://github.com/timescale/pg_textsearch/archive/refs/tags/v${PG_TEXTSEARCH_VERSION}.tar.gz"; \
    echo "${PG_TEXTSEARCH_SHA256}  /tmp/pg_textsearch.tar.gz" | sha256sum -c -; \
    mkdir /tmp/src; \
    tar -xzf /tmp/pg_textsearch.tar.gz -C /tmp/src --strip-components=1; \
    cd /tmp/src; \
    # The Makefile reads the version with awk inside $(shell ...), which fails silently and
    # compiles an empty version string; the extension then refuses to install. Fail here instead.
    test "$(awk -F"'" '/default_version/ {print $2}' pg_textsearch.control)" = "${PG_TEXTSEARCH_VERSION}"; \
    make with_llvm=no; \
    make with_llvm=no install DESTDIR=/out


FROM minimal AS standard
ARG PG_MAJOR=18
# Equivalent to upstream's standard: pgaudit, pgvector, contrib (pg_stat_statements), all locales,
# plus pg_textsearch built above (not in upstream).
# pg-failover-slots is excluded because the PGDG zypp repository has no package for it
# (a difference from upstream's Debian standard).
ARG EXTENSIONS="pgaudit_${PG_MAJOR} pgvector_${PG_MAJOR}"
USER 0
RUN set -eux; \
    zypper --non-interactive install -y --no-recommends \
      glibc-locale \
      "postgresql${PG_MAJOR}-contrib" \
      ${EXTENSIONS}; \
    zypper clean --all; \
    rm -rf /var/log/zypp /var/cache/zypp
# Only the compiled extension files — no toolchain reaches the final image.
COPY --from=pg-textsearch-build /out/usr/pgsql-${PG_MAJOR}/ /usr/pgsql-${PG_MAJOR}/
USER 26


# Bring the stale packages left in the base image up to date with security updates.
# This corresponds to the `apt-get upgrade` step in the Debian version — base images are only
# rebuilt periodically, so they lag the distribution archive. Without this step, the unpatched
# vulnerabilities of that moment simply remain.
FROM standard AS patched
USER 0
RUN set -eux; \
    zypper --non-interactive refresh; \
    zypper --non-interactive update -y --no-recommends; \
    zypper clean --all; \
    rm -rf /var/log/zypp /var/cache/zypp
USER 26
