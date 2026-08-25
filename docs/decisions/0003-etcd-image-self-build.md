# 0003. Replace the etcd image with a source-compiled self-build

- Status: Accepted

## Decision

The etcd image is built here. The build definition is
[images/etcd/](../../images/etcd/) — the commit the upstream tag points at is compiled
as-is, with only `golang.org/x/text` force-upgraded via a workspace-wide `replace` in
`go.work` (the version lives in `XTEXT_FIX_VERSION` in `source.build.env`). The final
runtime base is SUSE BCI (`bci-micro`) — the same pattern as
[0002](0002-cloudnative-pg-operator-self-build.md).

**Additionally, this work generalised the `build-image.yml` CI so it is agnostic to
image type** (each image declares its own build variant through
`images/<image>/image.env`) — this was backlog from
[0002](0002-cloudnative-pg-operator-self-build.md). Hardcoding survived two self-built
images; the third one hit the limit for real.

## Context

The upstream image was blocked at the gate on one effective HIGH — an infinite-loop DoS
in `golang.org/x/text`'s `norm.Iter` on malformed UTF-8 input.

The cause was a module version statically linked into the Go binary, so swapping the
base OS does not help, and there was no newer tag (the then-current release was still on
the same version). Worse, unlike [0002](0002-cloudnative-pg-operator-self-build.md),
**the fix was not even backported to the maintenance branch** (branch HEAD was identical
to the tag). Nothing but a self-build could respond immediately.

## Rationale

- **A single workspace-wide `replace` line was measured to flip the gate to PASS** —
  effective C/H went 0/1 → **0/0**. There was no already-backported commit to pick up,
  but since this CVE was the only vulnerable module, a direct force-upgrade sufficed.
- **Functional verification passed** (single-node startup plus an `etcdctl` put/get
  round trip). Because a passing gate does not prove the image works, this is checked by
  `images/etcd/verify.sh`. The first attempt failed because the final base has no `sed`
  (`sh: sed: command not found`) — this was the first time we established that
  `bci-base` has it and `bci-micro` does not. Fixed by switching to a pure shell loop,
  and the constraint was recorded in
  [docs/image-authoring/](../image-authoring/README.md).
- **The CI generalisation was confirmed not to regress existing images** — after adding
  `image.env` to three images, they were verified concurrently as a matrix and the two
  pre-existing images passed identically.
- **The tag substitution logic was validated against copies of the real value files** —
  a diff confirmed that both the single-field and split-field styles were substituted
  exactly, preserving existing comments and formatting.

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.** The same cost as
  [0001](0001-cnpg-postgresql-image.md) and
  [0002](0002-cloudnative-pg-operator-self-build.md).
- **A person updates `SOURCE_COMMIT` and `XTEXT_FIX_VERSION`.** They are not tracked
  automatically.
- **This self-build must be re-evaluated at every patch release** — until upstream
  backports this CVE to the maintenance branch there is no "already-backported safe
  pickup point", so the review burden is higher than in
  [0002](0002-cloudnative-pg-operator-self-build.md).
- **This is a configuration upstream does not test.** A BCI-based etcd build is not in
  etcd's CI matrix.
- **Whether the force-upgrade reached both the server and client binaries was only
  confirmed indirectly, through the SBOM scan** — no direct toolchain comparison was
  done.

## Conditions for revisiting

- **If etcd backports this CVE to the maintenance branch and ships a patch release** —
  moving to a newer tag becomes possible again, which takes priority over self-building.
- **If unexpected runtime problems appear on `bci-micro`** — promote to `bci-base` or
  reconsider another BCI variant (the same condition as
  [0002](0002-cloudnative-pg-operator-self-build.md)).
- **If multi-node (quorum) deployment verification finds a problem with this
  self-built image.**
