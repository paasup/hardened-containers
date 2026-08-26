# Upstream support lines — what "latest" means

Detail behind [image-authoring/](README.md). This document governs **which upstream
release line an image is entitled to sit on**, and how we find out when it stops being
one.

It is not about CVE exceptions. `cve-exceptions.json` has an `expires` date, but that
time-boxes *one approved CVE waiver on the current build* — a different thing at a
different grain. This document is about the version itself.

## "Latest" is not the newest tag

The newest release on a line upstream **still patches** is what this repository tracks.
Which line that is differs per project, and the difference is large:

| Project | Lines patched at once | Consequence for us |
|---|---|---|
| PostgreSQL | five majors, each for five years | Several lines are legitimately "latest" at the same time |
| etcd, Argo CD | roughly the newest three minors | Some room to sit still |
| Keycloak | the current minor | Move on each minor |
| APISIX | **only the newest minor** | A new minor puts the previous one into EOL the same day, on a roughly two-month cadence |

So "just take the newest tag" and "just stay where we are" are both wrong as a general
rule. The line has to be declared per image, and then checked.

**An end-of-life pin is a defect of the same class as a CVE, but it has a different
remedy.** A CVE is usually fixed by rebuilding — a newer base package or a raised
dependency pin lands and the gate goes green. Nothing about rebuilding moves an image
onto a supported line. Only a person raising `APP_VERSION` does. That asymmetry is why
the check below is kept away from the rebuild path.

## Declaring the line

In `images/<image>/image.env` — the image-level metadata file, which is the right grain
because the support line belongs to the application, not to a base-OS variant.

| Key | Meaning |
|---|---|
| `SUPPORT_SOURCE` | `endoflife.date` or `manual` |
| `SUPPORT_PRODUCT` | endoflife.date product slug (required when the source is `endoflife.date`) |
| `SUPPORT_LINE` | The line we track. Must equal a `releases[].name` upstream, and must be the dotted prefix of `APP_VERSION` — line `18` covers `18.4`, line `3.5` covers `3.5.1` |
| `SUPPORT_REF` | Required when the source is `manual` — the page a person reads instead |
| `SUPPORT_NOTE` | Optional. Where the project's cadence is worth stating in words |

Current declarations:

| Image | Source | Product | Line |
|---|---|---|---|
| `apisix` | endoflife.date | `apache-apisix` | 3.17 |
| `argocd` | endoflife.date | `argo-cd` | 3.5 |
| `cnpg-postgresql` | endoflife.date | `postgresql` | 18 |
| `etcd` | endoflife.date | `etcd` | 3.7 |
| `keycloak` | endoflife.date | `keycloak` | 26.7 |
| `adc` | manual | — | upstream releases page |
| `apisix-ingress-controller` | manual | — | upstream releases page |
| `cloudnative-pg` | manual | — | the operator's own supported-releases page |

**Three of eight are `manual` because endoflife.date has no entry for them.** Those are
reported and never fail the check. A check that cannot measure something must not report
that it passed — the same principle as the gate's `CoverageProbe`, where zero findings
from a scanner with no data is treated as "not measured", never as "clean".

For `cloudnative-pg` the reference is worth following in both directions: the operator's
supported-releases page also declares which PostgreSQL majors *it* supports, which
constrains what `cnpg-postgresql` may sit on.

## How it is checked

Two checks, split by what each can do offline.

**`scripts/lint/repo-checks.sh` check 8 — offline, on every pull request.** That the
declaration exists, is internally complete, and that `SUPPORT_LINE` agrees with
`APP_VERSION`. The mistake it exists to catch is raising `APP_VERSION` and forgetting
`SUPPORT_LINE`, which would leave the live check below silently measuring the wrong line.

**`scripts/build/check-support-line.py` — needs the network, runs daily.** Reads each
`image.env`, queries endoflife.date, and compares. Invoked as a step in `rescan.yml`,
which already has a daily schedule, a per-image matrix, and a Job Summary.

| Exit | Meaning | Effect |
|---|---|---|
| 0 | On a maintained line at its newest release, or skipped (`manual`) | — |
| 1 | On a maintained line but behind within it | `::notice::` — **does not fail** |
| 2 | The line is end-of-life, or upstream no longer lists it | `::warning::` and **the job fails** |
| 3 | Could not be measured (network, malformed declaration) | `::warning::` |

Being *behind within a maintained line* does not fail, because a fix is still available
upstream and the CVE gate already blocks anything that actually matters. Being *on a dead
line* fails, because there will be no fix at all — and on a repository this size a red
daily run is the only signal that reliably gets noticed.

Why it lives in `scripts/build/` rather than `scripts/gate/`: this is a pin-freshness
tool, a sibling of `suggest-go-upgrades.py`. Putting it under `scripts/gate/` would read
as part of the CVE gate verdict, which design rule 5 keeps intact.

### It must stay out of the rebuild path

`rescan.yml` calls `build-image.yml` when `rescan-published.sh` reports drift. The
support-line step is deliberately **not** wired into that:

- It is a separate step, placed after the rescan step with `if: always()`, so it can
  neither mask nor trigger CVE drift.
- Neither `scripts/gate/rescan-published.sh` nor `scripts/gate/image-gate.py` is touched.
  The first one's exit code *is* the rebuild trigger; the second one's verdict must stay
  "is the CVE state clean".

Wire an EOL finding into the drift path and it rebuilds the same end-of-life pin every
day, forever, without ever fixing it.

## When several lines are maintained at once

Publishing more than one line of the same application is **allowed** — five supported
PostgreSQL majors are five legitimate "latest"s, and a CloudNativePG user on PostgreSQL
17 cannot consume an 18 image, since a major upgrade is a disruptive, planned operation.
Publishing only the newest major serves exactly the users who have already migrated.

Today only PostgreSQL 18 is published. If a second line is wanted, this is the shape:

- **One image directory per line** — `images/cnpg-postgresql-17/` next to the existing
  one. `build-image.yml`'s matrix runs over image directory names, so it needs no change,
  and `published.json` simply gains an entry, letting `rescan.yml` track each line
  independently.
- **`IMAGE_REPO=cnpg-postgresql` in the new `build.env`** keeps the registry repository
  name identical (`build-hardened-image.sh` honours `IMAGE_REPO`, defaulting it to the
  image directory name). Tags already disambiguate the lines: `17.x-…` against `18.x-…`.
- **`BASE_OS` is not the version axis.** It selects the base-OS variant and nothing else;
  overloading it would collide with the real base-OS variants.

Prerequisite before doing this: `cnpg-postgresql`'s major currently appears in three
places that would all have to stay aligned — `APP_VERSION`, the full EVR in `PG_VERSION`,
and the hardcoded `EXTENSIONS="pgaudit_18 pgvector_18"` (even though the Dockerfile
defaults it from `PG_MAJOR`). Collapse that duplication first.

Widening from one published line to two is a deliberate departure from the one-entry-per-
image default, so it wants an ADR — see [decisions/](../decisions/README.md).

## Known limit: second-order EOL

The `SUPPORT_*` fields describe **the application**, not what it bundles. `apisix` pins
around fourteen component versions, and one of them — PCRE 8.45 — is an upstream project
that is itself end-of-life. Nothing here detects that.

Bundled-pin currency stays with the `pin-freshness-check` skill and the
[pin drift](builder-languages.md) section, which are read by a person. Extending the
declaration to cover bundled components is not planned; it would need a support line per
pin, and the component list is exactly where a person is already looking when raising a
CVE fix.

## Related

- [ci.md](ci.md) — `rescan.yml`, and the `published.json` schema the daily check reads
- [builder-languages.md](builder-languages.md) — pin drift, and why fix versions are
  per-branch alternatives rather than "the highest number"
- [decisions/](../decisions/README.md) — when a departure from a default needs an ADR
