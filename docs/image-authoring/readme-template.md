# Per-image README template

This is what step 3 of the new-image checklist in [image-authoring/](README.md) points
at. It is the common skeleton distilled from reviewing the eight existing image READMEs.
Follow this order when writing or revising one — if the shape differs per image, working
out something like "is this pin updated automatically?" means going to the code every
time.

**Language**: write **both** `README.md` (English) and `README.ko.md` (Korean). Korean
is the source of truth — when content changes, edit `README.ko.md` first and carry it
into English. Put a link to the other version on the first line of each file. To reduce
drift, **do not list volatile figures such as CVE numbers or counts as a snapshot in
either version** — the gate re-measures them on every run.

1. **Title and one-line summary** — what this image is and where it is used.
2. **Non-affiliation notice** — one blockquote. Do not leave this only in the top-level
   README; people evaluate a single image on its own page:
   ```md
   > This image is an **unofficial rebuild** of <upstream project>. It is not affiliated
   > with, endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE)
   > for trademark and licensing notices.
   ```
3. **Links to the ADR and image-authoring/** — one paragraph: "The decision, the
   candidates compared, and the costs accepted are in ADR …; image selection rules and
   the build framework are owned by image-authoring/." Do not duplicate their content
   here. The escalation order for self-building (newer tag → base OS swap → self-build →
   approved exception) already lives in `image-authoring/README.md` and the
   `self-build-image` skill — the fact that all eight images are here already means they
   passed that ordering, so do not repeat the policy as a blockquote in every README.
4. **`## Why we build this ourselves`** — exactly checklist step 1: a table breaking the
   blocking CVEs down by nature (layer / count / representative CVE / does a higher-level
   lever fix it), plus measured evidence for why a newer tag or a base OS swap does not
   work (version comparisons, `pom.xml`/`go.mod` cross-checks, SBOM file paths).
   No speculation — the same standard as `cve-exceptions.json`'s `_readme`.
5. **`## Differences from upstream`** — a table (item / upstream / this image / reason).
   It must not contradict the actual Dockerfile and build.env values — re-check against
   the code every time the table changes.
6. **`## Version management`** — never omit. Cover all of the following:
   - **List every pin that is not tracked automatically** (`SOURCE_COMMIT`, manually
     raised library or jar versions, exact EVR strings) and state that "these are not
     tracked automatically — a person editing `*.build.env` and opening a PR is itself
     the update trigger". Pins whose values come from a semi-automatic script
     (`GO_BUILDER_TAG` via `suggest-go-upgrades.py`) are listed separately — they are not
     fully manual.
   - **If any `cve-exceptions.json` entry targets this image, cross-reference it here.**
     If part of the CVE tally in "Why we build this ourselves" is actually resolved by an
     **approved exception (accepted risk)** rather than an overlay, recompile, or version
     bump, say so and name the CVEs — a reader must not conclude "self-building fixed
     everything".
   - **Re-add the tally.** Whenever the counts in "Why we build this ourselves" change
     (e.g. "12 bundled jars: netty×6, jackson×3, …"), re-add the list and confirm it
     matches the actual remediation record (overlay table, exception list, version-bump
     rationale). Blocking one more CVE without updating the tally breaks this check.
   - **State the condition for switching away, not just a review cadence.** Do not write
     merely "bump the version when a new release appears". If upstream (or a maintenance
     branch) has already shipped a release that resolves the CVE, moving to that release
     always beats continuing to self-build. This section should contain the evidence
     needed to decide whether to raise the pin or stop self-building entirely.
7. **`## Building and verifying`** — the local build command, what `verify.sh` does and
   does not check (out of smoke-test scope — real deployment verification is a separate
   procedure), and what to check after a build (zero effective C/H in `cve-gate.md`,
   `CoverageProbe` reading `ok`, rpmdb masking where relevant).
8. **`### File layout`** — a table.
9. **`### Tags`** — the format with an example (build date included, never a rolling tag).
10. **(If applicable) `## Not done yet — deployment verification`** — if real deployment
    verification has not happened, say what remains.
