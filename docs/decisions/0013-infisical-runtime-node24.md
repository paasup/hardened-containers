# 0013. Run infisical on SUSE BCI's Node 24 while upstream declares Node 26

- Status: Accepted (2026-11-17)
- Refines: [0011](0011-infisical-self-build.md)

## Decision

From `v0.167.11`, the infisical image runs on SLE_BCI's OS package `nodejs24` (with
`nodejs24-devel` and `npm24` for the backend build), even though upstream's
`backend/package.json` declares `engines.node >=26.0.0`.

## Context

- Upstream moved to Node 26 in `v0.166.1`. Only the newest infisical tag is supported, so
  the image cannot stay on a Node 22-era tag and remain on its support line.
- SLE_BCI ships no `nodejs26` on either 15.7 or 16.0. Both stop at `nodejs22`/`nodejs24`
  (measured 2026-11-17).
- The rule in [builder-languages.md](../image-authoring/builder-languages.md) ("Node")
  puts the runtime Node on an OS package, because the runtime is what gets scanned and
  the vendor is what patches it.

## Candidates

| Candidate | Outcome |
| --- | --- |
| **SLE `nodejs24`** | **Chosen.** Keeps the runtime on the vendor-patched OS-package path. The `engines` mismatch is only an `EBADENGINE` warning from npm, not an error. |
| nodejs.org Node 26 tarball on BCI, checksum-verified | Rejected. The runtime would leave the OS-package update path, its pin would have to be raised by hand indefinitely, and the scanner would see it as a loose binary rather than an OS package. |
| Stay on `v0.164.1` (Node 22 era) | Rejected. It is off the support line, and it keeps the three `@infisical/quic` CVEs that needed exceptions (upstream dropped that addon in `v0.165.13`). |

## Evidence that Node 24 is enough

- Upstream's Node 26 upgrade commit (`6409dce`) changes build tooling (tsup → tsdown,
  ts-node → tsx) and typings. No Node-26-only runtime API appears in it. That is a
  reading of the diff, not proof.
- The proof is `verify.sh`. It boots the image against throwaway Postgres and Redis,
  bootstraps an admin (password hashing through the native addons), creates a project,
  then writes a secret and reads it back through the KMS encryption path. This passes
  on Node 24.

## Costs accepted

- The image runs a Node major older than the one upstream tests on. A Node-26-only API
  used on a code path `verify.sh` does not reach would fail at runtime, not at build time.
- Native addons must be compiled with `gcc14-c++` (`BUILDER_GCC_VERSION`): Node 24's
  headers need `-std=gnu++20`, which SLE 15's default GCC 7 rejects.

## Conditions for revisiting

- **SLE_BCI ships `nodejs26`:** move `NODEJS_PKG`, `NODEJS_DEVEL_PKG` and `NPM_PKG` to it.
  This ADR is then superseded.
- **`verify.sh` breaks on a Node 24 / Node 26 difference:** reopen this decision. The
  tarball candidate is the fallback.
