---
name: publish-followthrough
description: Use after an image's gate passes locally and it still has to reach the registry — the steps from commit through pull request, merge, publish dispatch, and confirming the publication record really landed. Requests like "the gate passes, what is left to publish", "publish this image", "did published.json get updated", "run the publish dispatch", or "finish this image off" belong here.
---

# Publish follow-through

A gate that passed on your machine has published nothing. This is the sequence from there to
a real tag in the registry, and it is written down because it was repeated from memory once
per image and the same steps kept getting missed.

## 1. Re-confirm the gate result — do not trust a report

Read `/tmp/out/cve-gate.json` (or wherever the build wrote it) rather than a summary that
says it passed:

- no blocking CRITICAL/HIGH findings, and
- `CoverageProbe` reads `ok`. `none` means the zero findings were an absence of scanner data
  for that distribution, not a measurement — that is a fail, not a pass.

If an `image-author` run produced the change, also read `git diff` before going further: its
write scope is prompt-level, not enforced.

## 2. What goes into the commit

`images/<image>/` — the Dockerfile, `<variant>.build.env`, `image.env`, `verify.sh`,
`README.md` and `README.ko.md` — plus `docs/decisions/NNNN-*.md` if candidates were compared
and rejected. Do **not** hand-edit `published.json` or `sboms/`: CI writes those (step 5).

Run `bash scripts/lint/repo-checks.sh` before opening anything. It is what `pr-checks.yml`
runs, and it is the check that catches a build made to pass by weakening supply-chain
verification.

## 3. Open the pull request yourself

`gh pr create` **from Actions fails** in this organisation — "Allow GitHub Actions to create
and approve pull requests" is off, and the workflow only leaves a warning in its job summary.
So a person opens it:

```sh
gh pr create --base main --head <branch>
```

(If an org admin ever enables that setting, this step becomes automatic and this section
should be deleted rather than left as folklore.)

## 4. Merging is the review

Merge only once the PR's checks are green. There is no separate approval gate — the merge
*is* the decision that this pin, this base, this rationale are acceptable.

## 5. Dispatch the publish, from the default branch

Building on `push` never pushes to a registry. An actual push and the `published.json`
update happen only through `workflow_dispatch`, and `push=true` is honoured only from the
default branch:

```sh
gh workflow run self-build-image --repo paasup/hardened-containers \
  -f image=<image> -f push=true
```

`image` takes several space-separated names, or `all`. Several images in one dispatch run as
one matrix inside a single run — prefer that over separate dispatches, which contend for the
concurrency slot.

## 6. Confirm the record landed

The workflow commits `published.json`, `sboms/<image>.cdx.json`, and the regenerated
`README.md`/`README.ko.md` tables itself, in its own commit, and only when the gate passed
**and** the push actually happened. So verify rather than assume:

```sh
git pull
python3 scripts/build/render-published-images-table.py --check   # expect: already matches
```

Check `published.json` carries the new tag *and* digest for this image, and that
`sboms/<image>.cdx.json` changed. If `--check` reports the README is stale, the workflow's
commit did not include the regeneration — investigate that rather than quietly fixing it
here, because the next PR's `repo-checks.sh` will fail on it.

## 7. Clear the MEMORY.md entry

Once the image is published and verified, its `MEMORY.md` item is no longer "what to do
next". Move what is worth keeping to its real home — the image `README.md`, an ADR, or
`docs/image-authoring/` if the lesson is a pitfall — and delete the item, per that file's
own maintenance rules.

## 8. Say what publishing did not prove

This repository's responsibility ends at the push and the publication record. One thing is
therefore still open, and it should be stated rather than silently dropped: **a passing gate
does not prove the image works.** A CVE scanner cannot see runtime requirements at all, so
behaviour in a real deployment is a separate check, and it has not happened just because the
tag exists.
