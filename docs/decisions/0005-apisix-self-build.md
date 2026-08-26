# 0005. Replace the apisix image with a source-compiled self-build

- Status: Accepted

## Decision

The apisix image (APISIX-Runtime plus the APISIX application) is built here. The build
definition is [images/apisix/](../../images/apisix/) — the APISIX-Runtime custom nginx
defined by upstream's build scripts (`api7/apisix-build-tools`, at the
`apisix-runtime/<ver>` tag the APISIX release declares in its own `.requirements`) is
reproduced from source on SUSE BCI (OpenSSL, zlib, PCRE, plus the custom nginx modules
that tag specifies), and the APISIX application is installed on top with `luarocks`. The
final runtime base is SUSE BCI (`bci-base`) — `bci-micro` is not used because of
dynamically linked shared library dependencies (libxml2, libxslt, openldap2).

## Context

Upstream `apache/apisix:3.18.0-debian` carried gate-blocking CVEs even while on the
latest upstream tag (the evidence at the time: Debian base OS packages — libc, perl,
pcre, and others; the gate re-measures current state on every run). Moving to a newer
tag does not resolve them.

Changing only the base OS was not an option either. Upstream is not vanilla OpenResty
but a custom-compiled nginx called "APISIX-Runtime" — it builds OpenSSL, zlib, and PCRE
in directly, and statically adds `apisix-nginx-module`, `wasm-nginx-module` (WASM,
wasmtime), `lua-var-nginx-module`, `lua-resty-events`, `mod_dubbo`, and
`ngx_multi_upstream_module` at compile time via `--add-module`. Because `--add-module`
only takes effect at compile time, modules cannot be added later to an
already-compiled vanilla OpenResty binary, and nginx's "dynamic module" mechanism does
not apply because these modules are not distributed in that form — so vanilla OpenResty
(which openresty.org officially supports on SLES 15.x) could not be substituted. This
deployment must support WASM plugins and `http-dubbo` functionality, so a reduced build
with those modules removed was not an acceptable compromise.

The apiseven pipeline that ships this combination (`api7/apisix-build-tools`) produces
prebuilt packages only for Debian and RHEL (UBI9) — there is none for SUSE. Installing
the Debian/RHEL-only prebuilt RPM/DEB onto SUSE was also not an option: mismatched
glibc/openssl symbol versions risk breaking the ABI.

Nothing but a self-build could respond immediately.

## Rationale

- **Measurement confirmed that upstream's build scripts compile from source in a
  distribution-agnostic way, so they can be moved to SUSE BCI** — the module composition
  in `openresty -V` output and the `APISIX_RUNTIME_VER` value were confirmed to match
  upstream.
- **Functional verification passed** — a standalone configuration starts a real nginx
  worker and serves an HTTP request. Because a passing gate does not prove the image
  works, this is checked by `images/apisix/verify.sh`, which is the only way to actually
  exercise loading of all six custom nginx modules and roughly ninety Lua plugins
  (including C extensions such as `lua-resty-saml`).
- **Application code and module versions were kept 100% identical to upstream to
  minimise the diff.** All that changes is the base OS and, consequently, the package
  manager and the system `-devel` packages.

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.** The same cost as
  [0001](0001-cnpg-postgresql-image.md),
  [0002](0002-cloudnative-pg-operator-self-build.md),
  [0003](0003-etcd-image-self-build.md), and [0004](0004-adc-self-build.md).
- **A person updates the pinned versions** (OpenResty, OpenSSL, zlib, PCRE, the six
  custom modules, `APISIX_RUNTIME_VER`). They are not tracked automatically — when
  upstream ships a new release, or one that already resolves the CVEs above, someone
  editing `source.build.env` and opening a PR is itself the update trigger.
- **`lua-resty-saml`'s xmlsec binding does not match the API signature changes in SUSE's
  standard `libxml2-devel`, so it is worked around with a build-stage-only `gcc`
  wrapper.** This is the cost of not forking the rock's source — details are in
  `images/apisix/README.md`.
- **The `ui/` Admin dashboard frontend is not included.** It does not exist in the
  `apache/apisix` repository itself; apiseven's separate packaging pipeline (a
  Node.js/yarn build) inserts it, so a git clone alone cannot reproduce it. This is an
  accepted gap because the deployment using this image does not use the built-in UI.
- **This is a configuration upstream does not test.** A BCI-based APISIX-Runtime build
  is not in apiseven's CI matrix.

## Conditions for revisiting

- **If `apache/apisix` ships a new release that resolves these CVEs** — moving to a newer
  tag becomes possible again and always takes priority over self-building. This was
  re-measured when the pin moved to 3.18.0 and the upstream image still gated on Debian
  base OS CVEs, so the decision stands; the counts are in that commit message rather than
  frozen here.
- **Every new APISIX minor forces a re-evaluation anyway** — APISIX maintains only its
  newest minor, so the previous one reaches end-of-life the same day the new one ships.
  This image cannot sit still even with a clean gate, which raises the cost of keeping the
  self-build relative to images on longer-lived lines.
- **If SUSE publishes APISIX-Runtime-compatible prebuilt packages** — source compilation
  could be simplified to a package install.
- **If the dynamic-link dependencies (libxml2, libxslt, openldap2) can be removed** —
  reconsider shrinking from `bci-base` to `bci-micro`.
- **If unexpected runtime problems appear on `bci-base`** — reconsider another BCI
  variant.
