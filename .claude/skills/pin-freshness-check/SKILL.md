---
name: pin-freshness-check
description: Use to check whether a self-built image's committed pins (SOURCE_COMMIT, APP_VERSION, GO_BUILDER_TAG, jar versions, and so on) have fallen behind upstream, or whether a newer upstream tag has already resolved the CVE and the self-build is no longer needed. Requests like "check whether the pins are current", "should we still be self-building this image", or "see whether a new upstream release is out" belong here.
---

# Pin freshness check

The price of design rule 4 — no rolling tags, pins nailed down as committed values — is
that pins fall behind silently over time, with no source change at all (see "Measured
pitfalls" in [self-build-image](../self-build-image/SKILL.md)). This skill removes the
need for a person to remember to check.

## 1. Order of checks — whether to keep self-building comes first

Apply the same order as step 1 of the new-image checklist in
[docs/image-authoring/](../../../docs/image-authoring/README.md), in reverse: before
raising a pin, ask whether **a newer upstream tag or a base OS swap already resolves the
problem**. Each self-built image's `README.md` states why it is self-built — check first
whether that reason still holds.

## 1b. Is the line still supported at all?

Before asking whether a pin is behind, ask whether the line it sits on is still one
upstream patches — a pin can be perfectly current within a line that nobody maintains any
more. Run:

```sh
python3 scripts/build/check-support-line.py --image <image>
```

Exit `2` means the line is end-of-life: **no amount of pin-raising within that line helps,
and neither does rebuilding.** The only remedy is moving to a maintained line, which is
usually a version bump with breaking changes, so treat it as its own piece of work rather
than folding it into a pin refresh. Exit `1` means the line is fine and only the pin is
behind — that is the ordinary case this skill handles.

`SUPPORT_SOURCE=manual` images are skipped by the script; for those, read the
`SUPPORT_REF` URL in `image.env` yourself. Rules and field meanings are in
[docs/image-authoring/support-policy.md](../../../docs/image-authoring/support-policy.md).

## 1c. Checking every image at once

Drop `--image` and the same script checks **all** images in one pass, printing a table
(image · line · our pin · latest in line · maintained · EOL date) and then a note per image
that needs one:

```sh
python3 scripts/build/check-support-line.py
```

That is the whole line-freshness picture for the repository, in seconds — do not loop it per
image, and do not spend an agent on it.

The half it does **not** answer is whether each committed pin still points at the current
upstream point; that needs per-image research across unrelated ecosystems, which the
`pin-freshness-sweep` workflow fans out one agent per image. Pass it the output above so it
does not redo the line check:

```
Workflow({name: 'pin-freshness-sweep', args: {images: [
  {image: '<image>', line_status: 'supported|eol|manual', support_detail: '<what the table and note said>'},
]}})
```

Budget for it: roughly 20 minutes and 65k tokens per image (measured), so a full 17-image
sweep is about an hour. Sweep a subset when that is too much, and bring anything it flags
back here, one image at a time, for the judgement calls and the actual change.

## 2. Enumerate the pins

Pin names differ per image, so do not hardcode them. Read `DEFAULT_BASE_OS` from the
target image's `images/<image>/image.env`, open that variant's `<variant>.build.env`, and
extract every field that looks like a version, commit, or tag — `APP_VERSION`,
`SOURCE_COMMIT`, `GO_BUILDER_TAG`, `NODE_BUILDER_TAG`, `RUNTIME_BASE`, `*_VERSION`, the
`*_FIX_VERSION` family (etcd's `XTEXT_FIX_VERSION`, for instance), and the
`<LIB>_OLD`/`<LIB>_VERSION` pairs in JVM images.

## 3. Re-evaluate the upstream tag

Whether the reason for self-building still holds is a judgement call on upstream evidence,
so hand it to the [`security-investigator`](../../agents/security-investigator.md) agent
(read-only — it reports, it does not change anything):

```
Agent(subagent_type: "security-investigator", prompt: "should we still self-build <image>? <why it was self-built>")
```

It re-scans the latest upstream tag or reads its release notes and establishes whether the
CVE that motivated the self-build is resolved there (the principle in etcd's README:
adopting a new upstream release always takes priority over keeping the self-build). If it
is resolved:

- This skill does not delete the image directory or edit `build.env` itself — **flag it as
  a retirement candidate, report to the user**, and record it under "Open items" in
  [MEMORY.md](../../../MEMORY.md).
- The actual retirement is separate work with its own procedure —
  [retire-self-build](../retire-self-build/SKILL.md).

## 4. Go toolchain and module pins — do not reimplement

There is already a dedicated script for Go pins. Do not build new judgement logic here;
call it and absorb the result:

```sh
python3 scripts/build/suggest-go-upgrades.py --reports <trivy-reports dir> --image <image>
python3 scripts/build/suggest-go-upgrades.py --reports <trivy-reports dir> \
  --image <image> --apply --dry-run
```

## 5. Other manual pins — based on real investigation

Manual pins such as `SOURCE_COMMIT`, JVM jar versions, and `XTEXT_FIX_VERSION` have no
automatic suggestion script, so both the lookup and the raise go to the
[`image-author`](../../agents/image-author.md) agent — it decides the value, writes it into
`build.env`, and rebuilds to confirm the CVE is actually resolved rather than assuming it:

```
Agent(subagent_type: "image-author", prompt: "raise <image>'s manual pins for <CVE>: <pins found in step 2>")
```

Review its diff before anything is committed. What it must establish — no guessing, only
established facts:

- Whether any release or commit since the current pin fixes the CVE this image carries.
- If so, whether that change also affects other pins (a minimum Go toolchain version, for
  example) — re-confirming, per "check tool version requirements when raising the base" in
  `docs/image-authoring/base-os-policy.md`, that passing the gate is not the same as a
  successful deployment.

## 6. Summarise the result

Report, per image, "the point the pin refers to versus the current upstream point" plus a
recommendation (leave as-is / a pin-update PR is needed / consider retiring the
self-build). This skill never edits `build.env` on its own — raising a pin is delegated
(step 4's `suggest-go-upgrades.py --apply` for Go, `image-author` in step 5 for everything
else), and rule 4 still holds either way: **the value is reviewed by a person before it is
committed**, so read the diff rather than trusting a report that says the pin was raised.

## Wrapping up

This check does not replace running the gate or registering an exception — after raising a
pin, confirm the CVE is actually resolved by building and gating again with
`build-hardened-image.sh`. If the gate still blocks on CRITICAL/HIGH, move to
[cve-exception-review](../cve-exception-review/SKILL.md).
