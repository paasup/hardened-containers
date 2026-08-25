# 0001. Build the cnpg-postgresql image ourselves on SUSE BCI

- Status: Accepted

## Decision

The PostgreSQL image CNPG uses is built here, on SUSE BCI 15.7. The build definition is
[images/cnpg-postgresql/](../../images/cnpg-postgresql/) (`suse.Dockerfile` +
`suse.build.env`).

## Context

The upstream candidate `ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie` had two
problems.

1. The `system` tag is a **type deprecated upstream** (in-core barman is being phased
   out).
2. The gate blocked it on numerous CRITICAL/HIGH findings.

Three candidates were compared.

| | A `standard-trixie` | B self-build on ubuntu:24.04 | **C self-build on SUSE BCI 15.7** |
| --- | --- | --- | --- |
| Effective unique C/H | many | 0 | 0 |
| Measurability | full trivy coverage | full trivy coverage | full trivy coverage |
| Signature / attestation | ✅ | ❌ | ❌ |
| Uninvestigated blind spot | none | present | present |
| Deployment verification | — | passed | passed |
| gid | `postgres` | ⚠️ `tape` already holds gid 26 | `postgres` |

## Rationale

- **None of A's blocking findings have a fixed version.** Debian's assessments are split
  across `unimportant` / `no-dsa` / `postponed` / unclassified, so no action resolves
  them. There is no overlap with KEV either.
- **C is at zero, and that zero is a measured zero.** The initial assumption that "trivy
  does not cover SLES 15.7, so we must assess it manually" was wrong — the cause was
  that a genuinely clean image also yields zero findings, making "zero" and "no data"
  indistinguishable. The correct test is a positive control, and this gate performs one
  on every scan via `CoverageProbe` (rescan with injected sentinel packages).
- **C does not have B's gid hygiene problem.** In B, gid 26 is already taken by the
  `tape` group.
- **C passed deployment verification** — CNPG operator integration, rolling switchover,
  data retention, and failover.
- **SUSE's official PostgreSQL chart was not an alternative** — it ships only the
  `plpgsql` extension. C includes `pgaudit`, `pgvector`, and contrib.

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.**
- **We take on the rebuild responsibility.** For every PostgreSQL minor release and
  every base security update. Candidate B already demonstrated this — findings increased
  from a base update less than a day after the build.
- **This is a configuration upstream does not test.** The CNPG bake matrix covers only
  Debian-family images.
- **The `pg-failover-slots` extension is unavailable.** There is no package for it in
  the PGDG zypp repository.
- **There is an uninvestigated blind spot.** SUSE expresses "not evaluated" as the
  absence of a document, so **it is impossible to enumerate what has not been
  evaluated.** This is true regardless of scanner. The basis for "0/0" is incomplete to
  that extent.

## Conditions for revisiting

- **When fixed versions arrive for A's blocking findings** — returning to the upstream
  image becomes preferable. Detectable via `status: fixed` in the gate report.
- **If investigating the blind spot turns out unfavourable to C.**
- **If the rebuild burden becomes a real problem** — needing to rebuild more than once a
  quarter.
- **If SUSE publishes a BCI-based CNPG-compatible image directly** — the self-build
  becomes unnecessary.
