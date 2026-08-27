# Architecture decision records (ADRs)

Only the image choices **that re-measurement cannot reconstruct** belong here.

Figures such as CVE counts, coverage, and package versions are re-measured by the gate
on every run, so they are not recorded in documents. What is never regenerated anywhere
is "why this candidate was chosen and what was accepted as the cost" — that is what an
ADR is for.

| # | Decision | Status |
|---|---|---|
| [0001](0001-cnpg-postgresql-image.md) | Build the cnpg-postgresql image ourselves on SUSE BCI | Accepted |
| [0002](0002-cloudnative-pg-operator-self-build.md) | Replace the cloudnative-pg operator with a source-compiled self-build | Accepted |
| [0003](0003-etcd-image-self-build.md) | Replace the etcd image with a source-compiled self-build | Accepted |
| [0004](0004-adc-self-build.md) | Replace the adc image with a self-build | Accepted |
| [0005](0005-apisix-self-build.md) | Replace the apisix image with a source-compiled self-build | Accepted |
| [0006](0006-apisix-ingress-controller-self-build.md) | Replace the apisix-ingress-controller image with a source-compiled self-build | Accepted |
| [0007](0007-argocd-self-build.md) | Replace the argocd image with a source-compiled self-build | Accepted |
| [0008](0008-keycloak-self-build.md) | Build the Keycloak image ourselves | Accepted |
| [0009](0009-kyverno-self-build.md) | Replace the kyverno image family (7 images) with source-compiled self-builds | Accepted |

## When to write a new ADR

- Image candidates were compared and one was chosen, and **there were rejected
  candidates**
- Moving to a self-build meant **accepting the loss of upstream signatures and
  provenance**
- A default was deliberately violated

Conversely, an action with only one option — "the gate blocked us, so we raised the
tag" — is not an ADR. The commit message is the record (see "Where work gets recorded"
in [CLAUDE.md](../../CLAUDE.md)).

Filenames are `NNNN-<topic>.md`, numbered consecutively. When a decision is reversed,
do not delete the document — change its status to `Superseded → NNNN`.
