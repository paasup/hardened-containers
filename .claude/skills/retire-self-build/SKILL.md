---
name: retire-self-build
description: Use when a self-built image is being retired because upstream now fixes what it was built for — removing images/<image>/, dropping it from the publication record, marking its ADR superseded. Requests like "retire this self-build", "we do not need to build this ourselves any more", "remove this image", or "switch back to the upstream image" belong here. Whether retiring is safe is decided in pin-freshness-check; this is the execution afterwards.
---

# Retiring a self-build

The counterpart to [self-build-image](../self-build-image/SKILL.md). Adding an image is well
documented; removing one was not, and
[pin-freshness-check](../pin-freshness-check/SKILL.md) deliberately stops at "flag it as a
retirement candidate" — this is what happens next.

## 0. The decision must already exist

Do not retire on the strength of "upstream looks newer". There has to be a recorded finding
that the CVE the image was built for is resolved in a specific upstream tag or commit —
that is what `pin-freshness-check` (via the
[`security-investigator`](../../agents/security-investigator.md) agent) produces. If no such
finding exists, go there first.

## 1. Say that the rebuilds are stopping

Retiring deletes nothing that was already published: the last tag stays in the registry and
keeps working. What ends is the security rebuild — from that point the tag ages while still
looking exactly as maintained as any other, and nothing in the tag itself says otherwise.
So the end of rebuilds has to be stated where whoever pulls it will see it, before the
definition is removed.

## 2. Remove the build definition

```sh
git rm -r images/<image>/
```

`build-image.yml` and `rescan.yml` are parameterised by the `images/` directory, so nothing
in `.github/workflows/` needs editing — the image simply stops being a target.

## 3. Drop the publication record, keep the SBOM

Remove this image's entry from `published.json`. That is what stops the root README's table
advertising an image nobody rebuilds any more (the table is generated from that file).

Leave `sboms/<image>.cdx.json` in place. It is committed precisely so that "what was inside
the image we published" outlives the build that made it — deleting it would erase the answer
for a tag that may still be running somewhere. Say in the commit message that the SBOM is
kept deliberately, so the next person does not read it as an oversight.

## 4. Regenerate the README tables

```sh
python3 scripts/build/render-published-images-table.py
```

CI does this on publish, but a retirement is not a publish, so do it here — otherwise the
freshness check in `repo-checks.sh` fails on the next pull request.

## 5. Mark the ADR superseded — never delete it

If an ADR argued for building this image here, change its status to `Superseded → NNNN`
(pointing at whatever decision replaced it) and leave the document in place. A reversed
decision is still the record of why it was once right — the rule is in
[docs/decisions/README.md](../../../docs/decisions/README.md).

## 6. Catch the prose that still claims we build it

The image name appears in more than its own directory: the root README's narrative, the
architecture document, `docs/image-authoring/` examples, `cve-exceptions.json` entries scoped
to that image.

```sh
grep -rn '<image>' --exclude-dir=.git .
```

`repo-checks.sh`'s "internal path references" check catches dead `images/<image>/...` links
automatically; prose that is merely now untrue is on you. An exception in
`cve-exceptions.json` that only ever applied to this image should go with it.

## 7. Record it, then clear it

Note in [MEMORY.md](../../../MEMORY.md) that the image was retired and on what evidence,
then follow that file's maintenance rules: once the retirement is merged, the durable record
is the commit message and the superseded ADR, so the item comes back out of MEMORY.md.
