---
name: bilingual-doc-sync
description: Use when a Korean document has been edited and the English counterpart has to catch up, or to find which bilingual pairs have drifted apart. Requests like "carry this into English", "the Korean README changed, update the English one", "which translations are out of date", or "sync the bilingual docs" belong here.
---

# Bilingual document sync

Korean is the source of truth for every bilingual pair in this repository: `README.ko.md`
alongside `README.md` at the root and in each image directory, plus
[docs/architecture.ko.md](../../../docs/architecture.ko.md) — the one `docs/**` document
meant to be read end to end. The Korean side is edited first and the change is then carried
into English, so drift always points the same way: the English document is the one that is
behind.

## 1. Find what has drifted

```sh
bash scripts/lint/repo-checks.sh 2>&1 | grep -A20 'bilingual translation freshness'
```

That check compares each pair's last commit time and **warns** rather than fails — a
translation that has not caught up yet is a legitimate intermediate state, so nothing is
blocked. It is also why drift can sit unnoticed: read the warnings deliberately, they will
not stop a build.

For a pair the check flags, look at exactly what changed on the Korean side:

```sh
git log --oneline -- <path>.ko.md | head
git diff <the commit before the Korean change>..HEAD -- <path>.ko.md
```

## 2. Carry the change across

Do the translation in this session — this is ordinary document editing, not a job for a
subagent. Two rules:

- **Translate the change, not the file.** The English document has its own history and
  wording; port what actually changed rather than regenerating the whole page, or unrelated
  paragraphs will churn and the diff stops being reviewable.
- **Keep the structure aligned.** Same headings in the same order, same links, same code
  blocks. Where the pair diverges structurally the next person cannot tell what is a
  deliberate difference and what is a missed update.

Code, commands, file paths, field names and CVE identifiers stay verbatim — only prose gets
translated.

## 3. Commit both sides together

Commit the Korean and English edits in one commit whenever they are ready at the same time.
That keeps the freshness check silent for the right reason, rather than because nobody
looked. If the translation genuinely has to land later, say so in the Korean commit so the
warning is expected.

## What this is not

If the *content* is wrong in both languages, that is not a sync problem — fix the Korean
first, then carry it across. And a new bilingual pair (a new image README) must be created
as a pair: `repo-checks.sh`'s "bilingual READMEs" check fails on a missing counterpart or a
missing cross-link at the top, which is the harder failure and the earlier one.
