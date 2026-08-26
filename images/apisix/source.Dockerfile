# syntax=docker/dockerfile:1
# apisix — a self-build that recompiles upstream apache/apisix:3.18.0-debian (the
# APISIX-Runtime custom nginx plus the APISIX application) from source on SUSE BCI. Three
# stages: runtime (OpenSSL/zlib/pcre plus the custom nginx modules) → apisix-app (installing
# APISIX itself with luarocks) → final (moving only the artifacts onto bci-base). Why we build
# it ourselves and how it differs from upstream: README.md. Rationale for the decision:
# docs/decisions/0005-apisix-self-build.md.

ARG BUILDER_BASE=registry.suse.com/bci/bci-base:15.7
ARG RUNTIME_BASE=registry.suse.com/bci/bci-base:15.7

# =============================================================================
# 1) runtime — OpenSSL/zlib/pcre + OpenResty (the full set of APISIX-Runtime custom modules)
# =============================================================================
FROM ${BUILDER_BASE} AS runtime
ARG OPENRESTY_VERSION=1.29.2.4
ARG OPENSSL_VERSION=3.4.1
ARG APISIX_NGINX_MODULE_VER=1.19.9
ARG WASM_NGINX_MODULE_VER=0.7.0
ARG LUA_VAR_NGINX_MODULE_VER=v0.5.3
ARG LUA_RESTY_EVENTS_VER=0.2.0
ARG NGX_MULTI_UPSTREAM_MODULE_VER=1.3.3
ARG MOD_DUBBO_VER=1.0.2
ARG NGX_HTTP_FFI_CLIENT_VER=v0.1.3
ARG APISIX_RUNTIME_VER=1.3.16

ENV OR_PREFIX=/usr/local/openresty

# rust/cargo come from SLE_BCI packages — upstream pipes the rustup bootstrap script into a
# shell, which executes an unverified remote script on every build.
#
# perl's IPC::Cmd (required by OpenSSL 3.x's Configure) is already in SLE_BCI's stock perl
# (5.26.1 / IPC::Cmd 0.96 — a core module). The cpanm bootstrap upstream uses is unnecessary
# on this base, so it is not carried over.
RUN zypper -n refresh && zypper -n install -y \
      gcc gcc-c++ make patch git wget curl tar gzip xz which findutils perl unzip gawk \
      rust cargo \
 && perl -MIPC::Cmd -e 'exit 0'

WORKDIR /tmp/build

# Source tarballs have their SHA256 verified the moment they are downloaded. The expected
# values are committed in source.build.env, and on a mismatch `sha256sum -c` exits non-zero and
# the build fails on the spot.
# This is the only image that uses tarballs — the others use a git context, where the commit
# SHA plays the same role.

# --- zlib first (a standard source build in place of upstream's openresty-zlib-devel — same
#     output path). OpenSSL's `zlib` config option requires zlib.h at compile time, so zlib
#     must be built before OpenSSL — the reverse order fails with `zlib.h: No such file`.
ARG ZLIB_VERSION=1.3.1
ARG ZLIB_SHA256
RUN wget "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
 && echo "${ZLIB_SHA256}  zlib-${ZLIB_VERSION}.tar.gz" | sha256sum -c - \
 && tar xzf "zlib-${ZLIB_VERSION}.tar.gz" \
 && cd "zlib-${ZLIB_VERSION}" \
 && ./configure --prefix="${OR_PREFIX}/zlib" \
 && make -j"$(nproc)" \
 && make install

# --- pcre (classic PCRE1, a baseline nginx/openresty requirement — installed to the same
#     output path as upstream's openresty-pcre-devel, $OR_PREFIX/pcre) ---
ARG PCRE_VERSION=8.45
ARG PCRE_SHA256
RUN wget "https://sourceforge.net/projects/pcre/files/pcre/${PCRE_VERSION}/pcre-${PCRE_VERSION}.tar.gz/download" -O "pcre-${PCRE_VERSION}.tar.gz" \
 && echo "${PCRE_SHA256}  pcre-${PCRE_VERSION}.tar.gz" | sha256sum -c - \
 && tar xzf "pcre-${PCRE_VERSION}.tar.gz" \
 && cd "pcre-${PCRE_VERSION}" \
 && ./configure --prefix="${OR_PREFIX}/pcre" --enable-jit --enable-utf --enable-unicode-properties \
 && make -j"$(nproc)" \
 && make install

# --- OpenSSL (the same version as upstream) — the zlib header path is passed explicitly ---
# This is the crypto library that ends up in the final image. TLS verification is never
# disabled, and the checksum must match.
ARG OPENSSL_SHA256
RUN wget "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
 && echo "${OPENSSL_SHA256}  openssl-${OPENSSL_VERSION}.tar.gz" | sha256sum -c - \
 && tar xzf "openssl-${OPENSSL_VERSION}.tar.gz" \
 && cd "openssl-${OPENSSL_VERSION}" \
 && CFLAGS="-I${OR_PREFIX}/zlib/include" LDFLAGS="-L${OR_PREFIX}/zlib/lib -Wl,-rpath,${OR_PREFIX}/zlib/lib" \
    ./config shared zlib enable-camellia enable-seed enable-rfc3779 \
      enable-cms enable-md2 enable-rc5 enable-weak-ssl-ciphers \
      --prefix="${OR_PREFIX}/openssl3" --libdir=lib \
      --with-zlib-lib="${OR_PREFIX}/zlib/lib" --with-zlib-include="${OR_PREFIX}/zlib/include" \
 && make -j"$(nproc)" \
 && make install_sw install_ssldirs

# --- OpenResty source plus the custom modules (reproducing upstream's build-apisix-runtime.sh) ---
ARG OPENRESTY_SHA256
RUN wget "https://openresty.org/download/openresty-${OPENRESTY_VERSION}.tar.gz" \
 && echo "${OPENRESTY_SHA256}  openresty-${OPENRESTY_VERSION}.tar.gz" | sha256sum -c - \
 && tar zxf "openresty-${OPENRESTY_VERSION}.tar.gz"

RUN git clone --depth=1 -b "${LUA_RESTY_EVENTS_VER}" https://github.com/Kong/lua-resty-events.git "lua-resty-events-${LUA_RESTY_EVENTS_VER}" \
 && git clone --depth=1 -b "${NGX_MULTI_UPSTREAM_MODULE_VER}" https://github.com/api7/ngx_multi_upstream_module.git "ngx_multi_upstream_module-${NGX_MULTI_UPSTREAM_MODULE_VER}" \
 && git clone --depth=1 -b "${MOD_DUBBO_VER}" https://github.com/api7/mod_dubbo.git "mod_dubbo-${MOD_DUBBO_VER}" \
 && git clone --depth=1 -b "${APISIX_NGINX_MODULE_VER}" -- https://github.com/api7/apisix-nginx-module.git "apisix-nginx-module-${APISIX_NGINX_MODULE_VER}" \
 && git clone --depth=1 -b "${WASM_NGINX_MODULE_VER}" https://github.com/api7/wasm-nginx-module.git "wasm-nginx-module-${WASM_NGINX_MODULE_VER}" \
 && git clone --depth=1 -b "${LUA_VAR_NGINX_MODULE_VER}" https://github.com/api7/lua-var-nginx-module "lua-var-nginx-module-${LUA_VAR_NGINX_MODULE_VER}" \
 && git clone --depth=1 -b "${NGX_HTTP_FFI_CLIENT_VER}" https://github.com/api7/ngx_http_ffi_client.git "ngx_http_ffi_client-${NGX_HTTP_FFI_CLIENT_VER}"

RUN cd "ngx_multi_upstream_module-${NGX_MULTI_UPSTREAM_MODULE_VER}" && ./patch.sh "../openresty-${OPENRESTY_VERSION}" && cd .. \
 && cd "apisix-nginx-module-${APISIX_NGINX_MODULE_VER}/patch" && ./patch.sh "../../openresty-${OPENRESTY_VERSION}" && cd ../.. \
 && cd "wasm-nginx-module-${WASM_NGINX_MODULE_VER}" && ./install-wasmtime.sh && cd ..

# Replace OpenResty's bundled lua-resty-limit-traffic with the api7 fork. The bundle directory
# name must stay as-is for the openresty build to find it — hence the separate values for the
# version being replaced (OR_LIMIT_TRAFFIC_VER) and the replacement (LIMIT_TRAFFIC_VER).
ARG OR_LIMIT_TRAFFIC_VER
ARG LIMIT_TRAFFIC_VER
ARG LIMIT_TRAFFIC_SHA256
RUN cd "openresty-${OPENRESTY_VERSION}" \
 && rm -rf "bundle/lua-resty-limit-traffic-${OR_LIMIT_TRAFFIC_VER}" \
 && wget "https://github.com/api7/lua-resty-limit-traffic/archive/refs/tags/v${LIMIT_TRAFFIC_VER}.tar.gz" -O "lua-resty-limit-traffic-${LIMIT_TRAFFIC_VER}.tar.gz" \
 && echo "${LIMIT_TRAFFIC_SHA256}  lua-resty-limit-traffic-${LIMIT_TRAFFIC_VER}.tar.gz" | sha256sum -c - \
 && tar xzf "lua-resty-limit-traffic-${LIMIT_TRAFFIC_VER}.tar.gz" \
 && mv "lua-resty-limit-traffic-${LIMIT_TRAFFIC_VER}" "bundle/lua-resty-limit-traffic-${OR_LIMIT_TRAFFIC_VER}"

RUN cd "openresty-${OPENRESTY_VERSION}" \
 && zlib_prefix="${OR_PREFIX}/zlib" pcre_prefix="${OR_PREFIX}/pcre" openssl_prefix="${OR_PREFIX}/openssl3" ; \
    ./configure --prefix="${OR_PREFIX}" \
      --with-cc-opt="-DAPISIX_RUNTIME_VER=${APISIX_RUNTIME_VER} -DNGX_LUA_ABORT_AT_PANIC -I${zlib_prefix}/include -I${pcre_prefix}/include -I${openssl_prefix}/include" \
      --with-ld-opt="-Wl,-rpath,${OR_PREFIX}/wasmtime-c-api/lib -L${zlib_prefix}/lib -L${pcre_prefix}/lib -L${openssl_prefix}/lib -Wl,-rpath,${zlib_prefix}/lib:${pcre_prefix}/lib:${openssl_prefix}/lib" \
      --add-module="../mod_dubbo-${MOD_DUBBO_VER}" \
      --add-module="../ngx_multi_upstream_module-${NGX_MULTI_UPSTREAM_MODULE_VER}" \
      --add-module="../apisix-nginx-module-${APISIX_NGINX_MODULE_VER}" \
      --add-module="../apisix-nginx-module-${APISIX_NGINX_MODULE_VER}/src/stream" \
      --add-module="../apisix-nginx-module-${APISIX_NGINX_MODULE_VER}/src/meta" \
      --add-module="../wasm-nginx-module-${WASM_NGINX_MODULE_VER}" \
      --add-module="../lua-var-nginx-module-${LUA_VAR_NGINX_MODULE_VER}" \
      --add-module="../lua-resty-events-${LUA_RESTY_EVENTS_VER}" \
      --add-module="../ngx_http_ffi_client-${NGX_HTTP_FFI_CLIENT_VER}" \
      --with-poll_module --with-pcre-jit \
      --without-http_rds_json_module --without-http_rds_csv_module --without-lua_rds_parser \
      --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module \
      --with-http_v2_module --with-http_v3_module \
      --without-mail_pop3_module --without-mail_imap_module --without-mail_smtp_module \
      --with-http_stub_status_module --with-http_realip_module --with-http_addition_module \
      --with-http_auth_request_module --with-http_secure_link_module --with-http_random_index_module \
      --with-http_gzip_static_module --with-http_sub_module --with-http_dav_module \
      --with-http_flv_module --with-http_mp4_module --with-http_gunzip_module \
      --with-threads --with-compat \
      --with-luajit-xcflags="-DLUAJIT_NUMMODE=2 -DLUAJIT_ENABLE_LUA52COMPAT" \
      -j"$(nproc)" \
 && make -j"$(nproc)" \
 && make install

RUN cd "lua-resty-events-${LUA_RESTY_EVENTS_VER}" \
 && install -d "${OR_PREFIX}/lualib/resty/events/" \
 && install -m 664 lualib/resty/events/*.lua "${OR_PREFIX}/lualib/resty/events/" \
 && install -d "${OR_PREFIX}/lualib/resty/events/compat/" \
 && install -m 644 lualib/resty/events/compat/*.lua "${OR_PREFIX}/lualib/resty/events/compat/"

RUN cd "apisix-nginx-module-${APISIX_NGINX_MODULE_VER}" && OPENRESTY_PREFIX="${OR_PREFIX}" make install \
 && cd "../wasm-nginx-module-${WASM_NGINX_MODULE_VER}" && OPENRESTY_PREFIX="${OR_PREFIX}" make install

# =============================================================================
# 2) apisix — install APISIX itself (the Lua application)
# =============================================================================
FROM runtime AS apisix-app
ARG APISIX_VERSION=3.18.0

ENV PATH=$PATH:${OR_PREFIX}/luajit/bin:${OR_PREFIX}/nginx/sbin:${OR_PREFIX}/bin

# The -devel packages needed to compile rocks such as lua-resty-saml and lyaml. sudo is
# invoked inside linux-install-luarocks.sh, so it is provided as a package rather than by
# editing the script.
RUN zypper -n install -y \
      pcre-devel pcre2-devel openldap2-devel \
      libxml2-devel libxslt-devel zlib-devel libyaml-devel \
      diffutils cmake automake autoconf libtool gawk readline-devel sudo

# Use the upstream repository's install script as-is, but verify it before executing —
# tags can move, and without verification a change on the remote silently installs something
# else.
ARG LUAROCKS_INSTALLER_SHA256
RUN wget https://raw.githubusercontent.com/apache/apisix/${APISIX_VERSION}/utils/linux-install-luarocks.sh \
 && echo "${LUAROCKS_INSTALLER_SHA256}  linux-install-luarocks.sh" | sha256sum -c - \
 && chmod +x linux-install-luarocks.sh \
 && ./linux-install-luarocks.sh

WORKDIR /apisix
RUN git clone --depth=1 -b "${APISIX_VERSION}" https://github.com/apache/apisix.git .

# apisix-master-0.rockspec sits at the repository root (re-confirmed at tag 3.18.0).
# `luarocks make` does not use the rockspec's source.url (a remote tarball); it builds the
# current directory — so a git clone is sufficient, and there is no need to sed-patch
# source.url to a local path the way the apiseven build does.
#
# lua-resty-saml's xmlsec binding does not match the API signature change in libxml2 2.12 and
# fails the build under -Werror (the rock's Makefile hardcodes -Werror, so CFLAGS cannot turn
# it off) — a gcc wrapper scoped to this stage downgrades only that diagnostic to a warning.
# Background: "Pitfalls to know when building" in README.md.
RUN mv /usr/bin/gcc /usr/bin/gcc.real \
 && printf '#!/bin/sh\nexec /usr/bin/gcc.real -Wno-error=incompatible-pointer-types "$@"\n' > /usr/bin/gcc \
 && chmod +x /usr/bin/gcc

RUN luarocks make ./apisix-master-0.rockspec --tree=/usr/local/apisix/deps --local

# Restored so later steps are unaffected — the gcc wrapper above is only for the
# lua-resty-saml build.
RUN mv /usr/bin/gcc.real /usr/bin/gcc

# Rearrange the bin/apisix wrapper luarocks installed, and the apisix Lua package in the deps
# tree, into the /usr/local/apisix layout (reproducing apisix-build-tools install_apisix()).
#
# ui/ does not exist in the upstream source repository — when absent, an empty directory is
# substituted and the step is skipped. Background: README.md.
RUN mkdir -p /usr/local/apisix \
 && cp -r conf /usr/local/apisix/conf \
 && { cp -r ui /usr/local/apisix/ui 2>/dev/null || mkdir -p /usr/local/apisix/ui; } \
 && install -m 755 bin/apisix /usr/local/apisix/apisix-cli-bin \
 && mv /usr/local/apisix/deps/share/lua/5.1/apisix /usr/local/apisix/apisix \
 && sed -i '1i package.path = "/usr/local/apisix/deps/share/lua/5.1/?/init.lua;" .. package.path' \
      /usr/local/apisix/apisix/cli/apisix.lua

# =============================================================================
# 3) final
# =============================================================================
FROM ${RUNTIME_BASE} AS final

# SUSE shared library package names carry the soname (libxml2-2, libpcre1, libxslt1,
# libpcre2-8-0, libyaml-0-2). gawk is used by the /usr/bin/apisix wrapper script to parse the
# version — without it, it fails with "awk: command not found".
RUN zypper -n install -y libpcre1 libxslt1 libyaml-0-2 libxml2-2 libpcre2-8-0 gawk \
 && zypper -n clean --all

COPY --from=apisix-app /usr/local/openresty /usr/local/openresty
COPY --from=apisix-app /usr/local/apisix /usr/local/apisix
COPY --from=apisix-app /usr/local/apisix/apisix-cli-bin /usr/bin/apisix

ENV PATH=$PATH:/usr/local/openresty/luajit/bin:/usr/local/openresty/nginx/sbin:/usr/local/openresty/bin

RUN chmod 755 /usr/bin/apisix \
 && rm -f /usr/local/apisix/apisix-cli-bin \
 && mkdir -p /usr/local/apisix/logs /usr/local/apisix/conf/cert \
 && groupadd --system --gid 636 apisix \
 && useradd --system --gid apisix --no-create-home --shell /usr/sbin/nologin --uid 636 apisix \
 && chown -R apisix:0 /usr/local/apisix \
 && chmod -R g=u /usr/local/apisix \
 && ln -sf /dev/stdout /usr/local/apisix/logs/access.log \
 && ln -sf /dev/stderr /usr/local/apisix/logs/error.log

COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod 755 /docker-entrypoint.sh

WORKDIR /usr/local/apisix
USER apisix

EXPOSE 9080 9443

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["docker-start"]
