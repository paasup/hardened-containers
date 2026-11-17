# apisix — self-built

English · [한국어](README.ko.md)

The whole of apisix (APISIX-Runtime plus the APISIX application), compiled directly from
upstream source on SUSE BCI.

> This image is an **unofficial rebuild** of Apache APISIX. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0005](../../docs/decisions/0005-apisix-self-build.md); image selection rules and the
build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

Upstream `apache/apisix:3.20.0-debian` carries blocking CVEs even while on the latest
upstream tag — so moving to a newer tag does not resolve them. Those CVEs are all in
Debian base OS packages (libc, perl, pcre, and so on), meaning they are fixed by replacing
the base OS wholesale, not by changing application code.

## What differs from upstream — and why this image does not exist for SUSE

Upstream (`apache/apisix:3.20.0-debian`) is not vanilla OpenResty but a custom-compiled
nginx called **"APISIX-Runtime"** — it builds OpenSSL 3.5.9, zlib, and PCRE in directly
and adds `apisix-nginx-module`, `wasm-nginx-module` (WASM, wasmtime),
`lua-var-nginx-module`, `lua-resty-events`, `mod_dubbo`, and
`ngx_multi_upstream_module` **statically at compile time** via `--add-module` (visible in
`openresty -V` output — exact versions in the "Source and version management" table
below). The apiseven pipeline that ships this combination
(`api7/apisix-build-tools`) produces **prebuilt packages only for Debian and RHEL
(UBI9)** — there is none for SUSE.

| Difference | Reason |
| --- | --- |
| Base OS: Debian → SUSE BCI | Consistency across images comes first (`docs/image-authoring/README.md` rule 2). Vanilla OpenResty is not a substitute — openresty.org supports SLES 15.x, but that build contains none of the custom modules above. `--add-module` links statically into the binary at compile time only, so modules cannot be added later to an already-compiled vanilla binary, and nginx's "dynamic module" mechanism does not apply because these modules are not distributed in that form. This deployment must officially support WASM plugins and `http-dubbo` functionality, so rather than compromising on a reduced build, the same module composition as upstream is reproduced. |
| Compile from source rather than reinstalling the Debian/RHEL prebuilt RPM/DEB on SUSE | Mismatched glibc/openssl symbol versions risk breaking the ABI, and there is no equivalent package in SUSE's own repositories, so "reinstall within the same distribution family" does not apply. |
| Rust toolchain installed from SLE_BCI packages (`rust`, `cargo`) | Upstream pipes the rustup bootstrap script into a shell, which executes an unverified remote script on every build — replaced with distribution packages (design rule 7). |
| cpanm bootstrap removed | Upstream installs `IPC::Cmd` (required by OpenSSL's Configure) via cpanm, but SLE_BCI's stock perl already has it (5.26.1 / IPC::Cmd 0.96 — a core module). This removes an unnecessary remote execution. |
| Source tarball integrity verification added | zlib, PCRE, OpenSSL, OpenResty, lua-resty-limit-traffic, and the luarocks install script are verified by SHA256 (the `*_SHA256` values in `source.build.env`). This is the only image that fetches tarballs, so it has no equivalent of a git commit SHA guarantee. |
| Application code and module versions | 100% identical to upstream (the minimal-diff principle) — apiseven's official build scripts (`api7/apisix-build-tools`, tag `apisix-runtime/1.4.2`) are reproduced as-is. |

## Three stages

| Stage | Goal |
| --- | --- |
| `runtime` | Builds OpenSSL 3.5.9, zlib, and PCRE directly into `$OR_PREFIX/{openssl3,zlib,pcre}`, then compiles OpenResty from source with the six custom modules attached via `--add-module`. These paths are filled from source builds because openresty.org has no SLES-specific `-devel` packages. |
| `apisix-app` | Installs the APISIX application (Lua code plus some C-extension rocks) with `luarocks make` on top of the OpenResty/LuaJIT that `runtime` produced. |
| `final` | Moves only the artifacts of those two stages onto a clean SUSE BCI image, adds only the shared libraries needed at runtime (libxml2, libxslt, libyaml, pcre, pcre2), and completes the non-root setup (`apisix`, uid 636). |

## Pitfalls to know when building

- **Build order — zlib before OpenSSL.** OpenSSL's `zlib` config option requires `zlib.h`
  at compile time; the reverse order fails with `zlib.h: No such file`.
- **`lua-resty-saml` (a dependent rock luarocks fetches automatically) does not match the
  `xmlSetStructuredErrorFunc` signature in SUSE's standard `libxml2-devel` (2.12.10),
  where `const` was added to the callback argument, so it fails with
  `-Werror=incompatible-pointer-types`.** The rock's own Makefile hardcodes `-Werror`, so
  the environment's `CFLAGS` cannot turn it off — a `gcc` wrapper used only inside the
  `apisix-app` stage (adding `-Wno-error=incompatible-pointer-types`) downgrades that one
  diagnostic to a warning, and it is restored immediately after `luarocks make` (affecting
  no other build). See the comment on that RUN step in `source.Dockerfile`.
- **`ui/` (the Admin dashboard frontend) does not exist in the `apache/apisix` repository
  itself.** apiseven's packaging pipeline inserts it separately (a Node.js/yarn build), so
  a git clone alone cannot reproduce it — this deployment does not use that UI, so it is
  replaced with an empty directory and skipped.
- **The `/usr/bin/apisix` wrapper script uses `awk` internally.** It parses the OpenResty
  version with it, so without `gawk` installed in the `final` stage even `apisix version`
  fails with "awk: command not found".
- **SUSE shared library package names carry the soname.** There is no plain `libxml2`,
  `libxslt`, or `pcre` — they are `libxml2-2`, `libxslt1`, `libpcre1`, `libpcre2-8-0`, and
  `libyaml-0-2`. (`libxml2-2`, `libpcre2-8-0`, and `libldap-2_4-2` are included in
  `bci-base` by default and need not be listed, but they are spelled out for clarity.)
- **`docker build --pull` invalidates the entire cache when the base image digest
  changes.** `build-hardened-image.sh` always uses `--pull` (scheduled rebuilds depend on
  a fresh base), so even with no Dockerfile change, a SUSE BCI tag refreshed in the
  meantime can trigger a full recompile (roughly 35 minutes) — iterate on the Dockerfile
  with a plain `docker build` without `--pull`, and use `build-hardened-image.sh` only for
  final verification.
- **"LuaRocks 3.12.0 bug ... `fetch.lua:139`: attempt to concatenate local 'name' (a nil
  value)" from `luarocks make` is a network failure, not a luarocks bug.** When a rock
  download from luarocks.org fails, luarocks 3.12.0's failure path crashes concatenating
  `nil`, so the stack trace replaces the real download error. The preceding
  `Installing https://luarocks.org/...` line names the rock that failed — do not mistake it
  for a dependency or version problem and change pins; rebuild. Likewise, when the
  `runtime` stage's `zypper install` fails on a dropped public-dl.suse.com transfer (curl
  error 56), retry rather than change the Dockerfile.

## Source and version management

| Item | Value |
| --- | --- |
| APISIX source | `https://github.com/apache/apisix.git` (tag `3.20.0`, commit `bc1e687f`) |
| OpenResty | `1.31.8.1` |
| OpenSSL | `3.5.9` |
| zlib / PCRE | `1.3.1` / `8.45` |
| Custom modules | `apisix-nginx-module 1.20.3`, `wasm-nginx-module 0.7.0`, `lua-var-nginx-module v0.5.3`, `lua-resty-events 0.2.0`, `ngx_multi_upstream_module 1.4.1`, `mod_dubbo 1.0.2`, `ngx_http_ffi_client v0.1.3` |
| APISIX_RUNTIME_VER | `1.4.2` (the apiseven build script version tag) |
| Final base | `registry.suse.com/bci/bci-base:15.7` |

The module set is not ours to choose. APISIX declares the runtime it needs in
`.requirements` (`APISIX_RUNTIME=1.4.2` at tag `3.20.0`), and `api7/apisix-build-tools`
at that tag fixes the module versions — read both when raising `APISIX_VERSION`.
`ngx_http_ffi_client` is not optional: 3.18 makes the FFI HTTP client the default, and it
lives in that module.

This image moved from 3.18 straight to 3.20 (3.19 went EOL on 2026-11-11, the day 3.20.0
shipped). 3.20.0 (commit `bc1e687f`) raises the runtime to `1.4.2`, and the values that moved
with it are OpenResty (`1.29.2.4` → `1.31.8.1`, nginx 1.31.8), OpenSSL (`3.4.1` → `3.5.9`),
`apisix-nginx-module` (`1.19.9` → `1.20.3`) and `ngx_multi_upstream_module` (`1.3.3` →
`1.4.1`); the two module bumps from 3.19's runtime `1.3.18` are subsumed by these. zlib,
PCRE, the other modules and lua-resty-limit-traffic are unchanged, and the OpenResty
1.31.8.1 bundle still carries `lua-resty-limit-traffic-0.09` and a single `ngx_lua-*`
directory, so the Dockerfile's bundle replacement and lookup steps are unchanged. The
luarocks install script changed in 3.20.0 (it points `lrexlib-pcre` at the runtime's bundled
PCRE through `PCRE_DIR`), so its checksum was re-pinned. The new tarball checksums were
cross-checked outside the download host: OpenSSL against the `.sha256` on openssl.org and on
the GitHub release, OpenResty by verifying its `.asc` signature against the release key
openresty.org publishes (A0E98066).

Every backward-incompatible change in 3.19.0 and 3.20.0 (`:warning:`) is on the
configuration and plugin-behaviour side, and none touches the image build contract — for
example upstream `tls.verify` is now honoured for https/grpcs (3.19); the `mcp-bridge`
plugin is removed, `oas-validator` defaults `ssl_verify` to `true`, `wolf-rbac` moves
`header_prefix` to the Route or Service, `forward-auth` switches to the FFI client, and the
Prometheus stream metrics gain labels (3.20). `apisix start` now returns once openresty has
daemonized, but this image's entrypoint, like upstream `apache/apisix-docker`, runs
openresty in the foreground with `daemon off;`, so it is unaffected.
Deployment configuration must be checked against the 3.19.0 and 3.20.0 entries in upstream `CHANGELOG.md`.

All of these live in `source.build.env` and are **not tracked automatically.** As with the
other self-built images, someone reading a new upstream release (or a version that already
resolves the CVE set above) and editing `source.build.env` to open a PR is itself the
update trigger.

The tarball SHA256 pins are managed the same way — when a version changes, its checksum
must change with it. How they are derived and cross-checked is documented in the comments
in `source.build.env`.

**Suggested review cadence**: whenever the gate reports a blocking CVE for this image
again, or `apache/apisix` ships a new minor — if that release already resolves the
CVEs above, moving to it always takes priority over keeping this self-build.

**This image has the shortest support window of any here.** APISIX maintains only its
newest minor, so a new minor puts the previous one into end-of-life **the same day**, on a
roughly two-month cadence — 3.17 went EOL on 2026-08-20, the day 3.18.0 shipped, 3.18 on
2026-09-28, the day 3.19.0 shipped, and 3.19 on 2026-11-11, the day 3.20.0 shipped. So a
blocking CVE is not the only trigger to move: when the line goes EOL the pin has to move
even with a clean gate, and the daily rescan's support-line check makes that call
automatically (see
[support-policy.md](../../docs/image-authoring/support-policy.md)). An EOL line is not
resolved by rebuilding. endoflife.date can also list a new minor days after it ships, so
right after moving to a new line `check-support-line.py` may exit 2 with "upstream lists
no line". That clears on its own once the line is listed, and is not worked around.

## Building and verifying

```sh
# local build (no push)
IMAGE=apisix BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# through to a registry push
IMAGE=apisix BASE_OS=source REGISTRY=<your-registry> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is **build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.** Beyond `apisix version` output and the nginx config syntax check
(`nginx -t`), `verify.sh` **starts a real nginx worker** with a standalone YAML
configuration and confirms that the APISIX router responds to an HTTP request (no route →
404), that a configured route matches, and that two plugins in different phases
(`mocking` and `response-rewrite`) actually run — the only way to actually exercise loading of the 15 custom modules and roughly 90
Lua plugins, including C extensions such as lua-resty-saml.

After the build, check:

1. The last line of `verify.log` is `VERIFY-OK`
2. The blocking findings in `cve-gate.md` — nothing beyond what is registered in this
   repository's `cve-exceptions.json`
3. **The coverage self-check (`CoverageProbe`) reads `ok`** — `none` means the zero
   findings were not a measurement but an absence of scanner data for that distribution,
   and the gate blocks

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — three stages (runtime / apisix-app / final) |
| `source.build.env` | All pinned versions and tarball checksums (only names listed in `BUILD_ARGS` are passed as `--build-arg`) |
| `verify.sh` | Functional verification — starts a real nginx and issues an HTTP request |
| `docker-entrypoint.sh` | Identical to upstream `apache/apisix-docker` (`utils/docker-entrypoint.sh`) |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/apisix:3.20.0-security-hardened-20261116
                   └ app  ┘└ slug ┘└hardened┘└ build date ┘
```
