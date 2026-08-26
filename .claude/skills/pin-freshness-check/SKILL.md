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

## 2. Enumerate the pins

Pin names differ per image, so do not hardcode them. Read `DEFAULT_BASE_OS` from the
target image's `images/<image>/image.env`, open that variant's `<variant>.build.env`, and
extract every field that looks like a version, commit, or tag — `APP_VERSION`,
`SOURCE_COMMIT`, `GO_BUILDER_TAG`, `NODE_BUILDER_TAG`, `RUNTIME_BASE`, `*_VERSION`, the
`*_FIX_VERSION` family (etcd's `XTEXT_FIX_VERSION`, for instance), and the
`<LIB>_OLD`/`<LIB>_VERSION` pairs in JVM images.

## 3. Re-evaluate the upstream tag

Re-scan the **latest** tag of the official upstream image that was originally vulnerable,
or read its release notes, and see whether the CVE that motivated the self-build is
already resolved (the principle in etcd's README: adopting a new upstream release always
takes priority over keeping the self-build). If it is resolved:

- This skill does not delete the image directory or edit `build.env` itself — **flag it as
  a retirement candidate, report to the user**, and record it under "Open items" in
  [MEMORY.md](../../../MEMORY.md).
- The actual retirement (removing the directory, switching back to referencing the
  upstream image) is separate work — this repository's responsibility ends at the build
  and the `published.json` update.

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
automatic suggestion script. Actually look up the upstream repository's releases, tags,
and advisories (WebFetch/WebSearch) and confirm — again, no guessing, only established
facts:

- Whether any release or commit since the current pin fixes the CVE this image carries.
- If so, whether that change also affects other pins (a minimum Go toolchain version, for
  example) — re-confirming, per "check tool version requirements when raising the base" in
  `docs/image-authoring/base-os-policy.md`, that passing the gate is not the same as a
  successful deployment.

## 6. Summarise the result

Report, per image, "the point the pin refers to versus the current upstream point" plus a
recommendation (leave as-is / a pin-update PR is needed / consider retiring the
self-build). The skill does not edit `build.env` itself — by rule 4 a pin is a value a
person reviews and commits. The one exception is the existing
`suggest-go-upgrades.py --apply`, which may be used as-is for Go pins (that script already
provides `--dry-run` for review).

## Wrapping up

This check does not replace running the gate or registering an exception — after raising a
pin, confirm the CVE is actually resolved by building and gating again with
`build-hardened-image.sh`. If the gate still blocks on CRITICAL/HIGH, move to
[cve-exception-review](../cve-exception-review/SKILL.md).
