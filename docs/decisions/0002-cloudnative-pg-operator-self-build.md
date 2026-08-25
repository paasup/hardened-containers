# 0002. Replace the cloudnative-pg operator with a source-compiled self-build, and unify self-build orchestration

- Status: Accepted

## Decision

The cloudnative-pg operator image is built here. The build definition is
[images/cloudnative-pg/](../../images/cloudnative-pg/) — a pinned commit from the
upstream maintenance branch compiled directly with `go build`, on a SUSE BCI
(`bci-micro`) runtime base.

**Additionally, this work generalised `scripts/build/build-hardened-image.sh` so that
the OS-package-reinstall shape (`cnpg-postgresql`) and the source-compile shape
(`cloudnative-pg`) share a single orchestration script.** The point is to stop the
methodology from diverging every time another self-built image is added. The contract is
owned by [docs/image-authoring/](../image-authoring/README.md).

## Context

The upstream operator image was blocked at the gate on effective HIGH findings — one in
stdlib, one in `golang.org/x/text`, one in grpc.

All three came from **module versions statically linked into the Go binary**, so neither
of the two higher-level levers applied.

- Move to a newer tag — there was none (the then-current release was still on the same
  version).
- Swap the base OS — the published image's base is distroless, so it has effectively
  zero OS packages.

Only a self-build was a viable response. All three CVEs were already backported to the
upstream maintenance branch, so compiling that commit as-is was enough — no need to bump
Go dependencies directly.

## Rationale

- **The maintenance branch HEAD is a measured, safe pickup point.** Comparing `go.mod`
  confirmed that the fixed versions of all three CVEs were included, and a rescan
  confirmed effective C/H of 0/0.
- **The principle that a passing gate does not prove the image works proved itself
  here.** The first build passed the gate at 0/0, but deployment verification failed with
  `Cluster` reconciliation reporting `invalid architecture: amd64`. The operator
  determines its available architectures from the **presence of a binary file** at a
  specific path, and upstream's multi-arch symlink had been mistaken for incidental
  scaffolding and removed. Fixed by COPYing the same binary to both paths.
- **The decision to unify on BCI ([0001](0001-cnpg-postgresql-image.md)) applies to this
  image too.** The initial design followed "stay as close to upstream as possible" and
  kept distroless, but that conflicted with the base OS policy, so it was replaced with
  `bci-micro`; the gate and deployment verification were confirmed still passing
  afterwards.
- **Unifying the orchestration was confirmed not to cause a regression** — immediately
  after generalising the script, `cnpg-postgresql` was rebuilt and produced an identical
  tag and gate result.

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.** The same cost as
  ADR [0001](0001-cnpg-postgresql-image.md).
- **A person updates `SOURCE_COMMIT`.** It is not tracked automatically — at the next
  CVE, someone picks the then-current maintenance branch commit and edits `build.env`,
  and that act is itself the trigger.
- **A maintenance branch is not a pure patch backport.** Small feature commits can be
  mixed in — the whole diff was not audited line by line; regressions were only checked
  at deployment smoke-test level.
- **This is a configuration upstream does not test.** A BCI-based operator build is not
  in the operator's CI matrix.
- **Unlike `bci-base`, `bci-micro` has no nonroot account, so one must be created** —
  other self-built images on BCI micro/minimal need the same work.

## Conditions for revisiting

- **If upstream ships a formal patch release containing these fixes** — moving to a
  newer tag becomes possible again, which takes priority over self-building.
- **If a feature commit on the maintenance branch causes a real regression** — roll back
  to a different pinned commit, such as one before that feature commit.
- **If SUSE publishes a compatible official operator image** — the self-build becomes
  unnecessary.
- **If unexpected runtime problems appear on `bci-micro`** (CA trust chain, TLS, …) —
  promote to `bci-base` or reconsider another BCI variant.
