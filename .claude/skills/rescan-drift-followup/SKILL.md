---
name: rescan-drift-followup
description: Use when the daily rescan reports drift on an already-published image — its autofix branch needs a pull request opened by hand, the autofix verify build went red on a module constraint chain, or the rebuild dispatch needs chasing. Requests like "the rescan found drift", "check the autofix branch", "the autofix build is red", or "the daily scan failed on <image>" belong here.
---

# Following up on rescan drift

Yesterday's PASS becomes today's FAIL with no source change at all — that is the price of
pinning, and `rescan.yml` exists to catch it daily. Most of the response is already
automated; this is the part that is not.

## What the automation already did

`rescan.yml` re-scans every published tag (it does not build), and then either raises Go pins
with `suggest-go-upgrades.py --apply` and routes them to the `autofix/go-cves` branch with a
verify build, or — when no pin changed and the image is merely stale — aggregates one
`build-image.yml` rebuild dispatch. The mechanics are in
[ci.md](../../../docs/image-authoring/ci.md) and the reasoning in
[ADR 0012](../../../docs/decisions/0012-go-cve-autofix-pr.md); neither is repeated here.

Start by reading the run's job summary to see which images drifted and which of those two
paths each took.

## 1. The pull request may not exist

`gh pr create` from Actions fails in this organisation (the org policy that would allow it is
off) and the workflow only records a warning in its summary. Check, and open it yourself if
it is missing:

```sh
gh pr view autofix/go-cves || gh pr create --base main --head autofix/go-cves
```

## 2. A red autofix build is a normal outcome, not a defect

`suggest-go-upgrades.py` derives the **minimum** version that clears each CVE, and minimums
collide with other modules' constraints. ADR 0012 measured this: `x/crypto` forced `x/net`,
which forced `x/text`. So a red build usually means "one more module has to come up", which
takes dependency-graph reasoning and a rebuild to confirm. Hand it over:

```
Agent(subagent_type: "image-author", prompt: "autofix/go-cves is red for <image>: <the build error>. Raise what the constraint chain requires and confirm the gate.")
```

Two things to know before you do:

- **The branch is bot-owned.** The next rescan rebuilds it from the default branch and
  force-pushes. Do not leave a hand-made fix sitting there across a rescan cycle — get it
  reviewed and merged, or move it to your own branch.
- **Read the diff afterwards.** `git diff` plus `bash scripts/lint/repo-checks.sh`; the
  agent's report is what it meant to do, and pins raised beyond the suggested minimum need
  a human to agree with the reason.

## 3. When no pin raise can fix it

If the drifting CVE has no fixed version anywhere, this is no longer a pin problem — go to
[cve-exception-review](../cve-exception-review/SKILL.md), which starts by establishing
whether it is even a real finding. Note that `suggest-go-upgrades.py` does not read
`cve-exceptions.json`, so an already-accepted risk can still show up here as fresh drift.

## 4. Then publish

A merged fix is not a published image. Continue with
[publish-followthrough](../publish-followthrough/SKILL.md) — the rebuild has to be dispatched
with `push=true` from the default branch, and the publication record checked afterwards.

## Scope

This loop is deliberately human-triggered: the automation decides *when* something is wrong,
a person decides whether the fix is right, and `image-author` does the investigation and the
edit. Making the whole loop autonomous (CI dispatching a fix without review) is a separate
question and is not what this skill does.
