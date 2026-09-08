# What gets fixed, in what order

Detail behind [image-authoring/](README.md).

The gate's contract is narrow on purpose: zero effective CRITICAL/HIGH at publication, and
nothing more (see [SECURITY.md](../../SECURITY.md)). That leaves everything below the
threshold without a rule, and "no rule" has been resolving itself as "never" — MEDIUM and
LOW findings kept sliding, and findings that arrive with **no severity at all** were not even
visible. This document sets the rule. It does not widen the guarantee in `SECURITY.md`.

## Every finding gets a disposition — not necessarily a fix

"Fix everything" is not achievable: some CVEs have no fixed version, some are the scanner
mis-attributing a file, some sit in code the image never executes. So the requirement is not
that every finding is fixed but that **every finding has one of these four dispositions**:

| Disposition | When | Where it is recorded |
| --- | --- | --- |
| **Fixed** | a fixed version exists and was adopted | the commit, and the image `README.md` |
| **Not applicable** | established as not real for this image (scanner mis-decomposition, component absent) | `cve-exceptions.json` `reason`, or the image README |
| **Accepted** | real, unfixable now, risk accepted for a bounded time | `cve-exceptions.json` with `expires` |
| **Deferred** | fixable, but not on its own rebuild — see the next section | nothing new: the next rebuild collects it |

A finding with no disposition is the only forbidden state. That is exactly what happened with
the unrated `golang.org/x/crypto` advisories: not accepted, not deferred, just invisible.

The evidence bar is the one `cve-exceptions.json`'s `_readme` already sets — **facts
established by investigation, not guesses** — and it applies to all four, not just to
exceptions.

## The unit of cost is a rebuild, not a CVE

Rebuilding, republishing, a new tag, and consumers adopting that tag are where the cost is.
Adding one more fix to a rebuild that is happening anyway is almost free. So:

- **When a CRITICAL/HIGH forces a rebuild, that rebuild takes every fixable finding in the
  image** — MEDIUM, LOW, and unrated-with-a-fix included. Not just the blocking one.
- **A MEDIUM, LOW or unrated finding does not earn a rebuild of its own.** Two things can
  override that: a blast radius large enough to be worth it on its own (see below), or a
  person deciding it is, with the reason written into the commit. The second is deliberately
  a human call and not a rule — there is no measurement here that could make it one.
- This is what makes **Deferred** a bounded state rather than a synonym for "ignored": it
  lasts until the next blocking fix, and that rebuild collects it automatically.

For Go images the second, wider pass is
`suggest-go-upgrades.py --min-severity UNKNOWN` (the default `HIGH` answers the narrower
question of whether a rebuild is needed at all). Apply it with `--apply`, which merges into
the existing `GO_MODULE_UPGRADES` value; **do not copy the printed `GO_MODULE_UPGRADES=` line
by hand** — it lists only the modules this run derived, so pasting it drops the pins that are
there to hold a version above what upstream declares even with no CVE outstanding.

**The blocking fix is never held hostage.** If the combined set fails to build — forced
module upgrades collide with other constraints, as measured in
[ADR 0012](../decisions/0012-go-cve-autofix-pr.md) — fall back to the blocking-only set,
publish that, and defer the rest again. Batching also raises behavioural risk (forcing an npm
dependency once broke an unrelated package), so `verify.sh` passing is not negotiable: a
batch that breaks the app is not a cheaper rebuild, it is a broken image.

## Ordering inputs — measurable ones only

When more than one thing could be done, rank by these, in this order:

1. **Is there a fixed version?** Without one there is no remediation to perform; it goes to
   Accepted or Deferred, never to the top of a list.
2. **Blast radius.** Several images share one pin string, so one edit can clear a finding
   across all of them — the kyverno family carries an identical `GO_MODULE_UPGRADES` value in
   six images, and `google.golang.org/grpc` is pinned in nearly every Go image. A fix that
   covers six images outranks one that covers one.
3. **Is a rating pending?** An unrated CVE is *undetermined*, not low. When NVD scores it, the
   gate starts blocking on it — across every image carrying that pin, on the same day. Raising
   one value now versus handling several images at once later is a legitimate ordering
   argument.

Severity is deliberately not first. Above the threshold the gate has already decided; below
it, severity says less than the three inputs above.

**Reachability is deliberately not an input.** Whether the vulnerable symbol is actually
called would be the ideal discriminator, and it was considered. It is left out because
measuring it needs a per-language tool (`govulncheck` for Go, nothing equivalent for the JVM,
Node and C images here), because extracting a binary from each image to scan it is a
procedure in its own right, and above all because it would not change the disposition of a
single finding on the current list: a fixable finding rides along on the next rebuild whether
or not it is reachable. The consequence is a rule rather than a gap: **nobody here claims a
finding is or is not reachable**, because nothing in this repository measures it. An
unmeasured reachability claim is a guess, and the evidence bar above does not allow one.

## Findings with no severity

The gate's blocking threshold stays where it is — CRITICAL/HIGH. Lowering it to UNKNOWN would
let a single unrated advisory stop the pipeline. Instead:

- **Unrated with a fixed version must be dispositioned.** `image-gate.py` reports these in
  their own section so they cannot go unseen, and per the rule above they ride along on the
  next rebuild.
- **Unrated with no fixed version** is Deferred with a re-review date, or Accepted if it needs
  to be visible in the published record.

This is a different case from the one in
[scanner-caveats.md](scanner-caveats.md): there, "unevaluated by vendor" means the scanner
does not report the CVE **at all**, and cross-checking for those is still out of scope. Here
the CVE *is* reported, with a package, an installed version and often a fixed version — only
the rating is missing. Reported-but-unrated is in scope; never-reported is not.

## Where MEDIUM and LOW sit

Non-blocking does not mean out of scope. They carry no obligation to be patched on their own,
their default path is the next rebuild, and they still need a disposition. A MEDIUM that has
sat for months with no disposition is a process failure even though the gate is green.

## Producing the inventory

Deciding needs the whole picture at once, across images. Build it from the committed SBOMs —
mechanical, no agent:

```sh
mkdir -p /tmp/triage
for s in sboms/*.cdx.json; do
  img="$(basename "$s" .cdx.json)"
  ref="$(python3 -c "import json,sys; print(json.load(open('published.json'))['images']['$img']['ref'])")"
  trivy sbom "$s" --scanners vuln --format json -o "/tmp/triage/$img.trivy.json"
  python3 scripts/gate/image-gate.py --report "/tmp/triage/$img.trivy.json" \
    --image-ref "$ref" --exceptions cve-exceptions.json --sbom "$s" \
    --json-out "/tmp/triage/$img.json" --summary-md "/tmp/triage/$img.md" || true
done
```

Two things in that loop are easy to get wrong and both silently corrupt the result:

- **Pass the published `ref`, not the image name.** Exceptions match on a substring of
  `--image-ref` (`exception_applies`), and the entries are written as `/keycloak:` — hand it
  `keycloak` and no exception applies, so an accepted risk reappears as a blocker.
- **Write the trivy report to a file.** `image-gate.py` checks `os.path.isfile`, so a process
  substitution (`--report <(trivy …)`) is rejected as "report not found".

`|| true` is there because the gate exits non-zero on FAIL, which is a normal outcome when
surveying rather than gating.

Hand the resulting JSON files to the [`cve-triage`](../../.claude/agents/cve-triage.md) agent
together with this document; it proposes a disposition per finding with the evidence for it,
and a person applies them. The agent never edits files — an accepted risk gets published in
`cve-exceptions.json`, and that entry is the repository's credibility.
