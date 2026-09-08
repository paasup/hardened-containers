// Parallel, read-only freshness sweep across the self-built images.
//
// Answers one question for every image at once: is its upstream line still patched, and do
// its committed pins still point at the current upstream point? Doing this one image at a
// time is what the pin-freshness-check skill is for; this is the sweep that tells you which
// images to take there.
//
// Read-only by construction: no image is built and no file is edited. The image-author agent
// is deliberately NOT used here — every call of it runs local docker builds, which must stay
// sequential and human-triggered.
//
// WHAT NEEDS A MODEL AND WHAT DOES NOT
//   Line support needs no model at all: `python3 scripts/build/check-support-line.py` with no
//   --image checks every image in ONE call and prints the whole table (line, our pin, latest
//   in line, maintained, EOL date). It costs seconds and no tokens, rescan.yml already runs it
//   daily, and there is nothing to interpret. So the caller runs it and passes the result in
//   through `args` — see the pin-freshness-check skill for the exact command. Only when it is
//   absent does one agent run that same single command, purely because a workflow script has
//   no shell of its own; that is an agent used as a shell, not as a judgement.
//
//   What nothing here automates is "does this pin still point at the current upstream point",
//   because answering it means reading releases, changelogs and advisories across a dozen
//   unrelated ecosystems and judging what the version strings mean (kyverno tags with a
//   leading "v" where endoflife.date never does; PGDG needs a whole EVR string matched; a Go
//   patch release may carry no security content while an OSV advisory sits on a module pin).
//   That is the part worth fanning out, one agent per image.
//
// SCALE — measured, not estimated
//   Concurrent agents are capped at min(16, CPUs - 2), so on a 10-core machine 8 run at once
//   and 17 images arrive in three waves. A two-image run took 23 minutes and 133k subagent
//   tokens, i.e. roughly 20 minutes and 65k tokens per image, because establishing whether a
//   gap is security-relevant means reading advisories per pin. Budget about an hour and on the
//   order of a million tokens for all 17, and sweep a subset with args when that is too much.
//   This is a periodic review, not something to run casually.
//
// Usage — prefer the first form: it spends no agent on the line check
//   Workflow({name: 'pin-freshness-sweep', args: {images: [
//     {image: 'etcd', line_status: 'supported', support_detail: 'line 3.7, pin 3.7.1 is the latest in line'},
//   ]}})
//   Workflow({name: 'pin-freshness-sweep', args: ['etcd','adc']})  // these images, agent runs the line check
//   Workflow({name: 'pin-freshness-sweep'})                        // every image, agent runs the line check

export const meta = {
  name: 'pin-freshness-sweep',
  description: 'Read-only sweep: which self-built images sit on an EOL line or have pins behind upstream',
  whenToUse: 'Periodically, or before planning a round of pin updates — one verdict per image, in parallel',
  phases: [
    { title: 'Line check', detail: 'one command over every image — skipped entirely when the caller passes it in' },
    { title: 'Sweep', detail: 'one read-only research agent per image — pins versus upstream' },
  ],
}

const ROSTER_SCHEMA = {
  type: 'object',
  properties: {
    images: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          image: { type: 'string' },
          line_status: {
            type: 'string',
            description: 'supported | eol | manual | unknown — from the exit code',
          },
          support_detail: { type: 'string', description: 'the line it tracks and what the check said' },
        },
        required: ['image', 'line_status', 'support_detail'],
      },
    },
  },
  required: ['images'],
}

const VERDICT_SCHEMA = {
  type: 'object',
  properties: {
    image: { type: 'string' },
    pins: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          committed: { type: 'string' },
          latest: { type: 'string', description: 'current upstream point, or "unknown" if it could not be established' },
          behind: { type: 'boolean' },
        },
        required: ['name', 'committed', 'latest', 'behind'],
      },
    },
    verdict: {
      type: 'string',
      description: 'current | pins_behind | needs_judgement',
    },
    note: { type: 'string', description: 'one or two sentences: what a person should do about it' },
  },
  required: ['image', 'pins', 'verdict', 'note'],
}

// Only used when the caller did not pass the line check in. One command, one turn — this
// agent exists because a workflow script has no shell, not because the work needs judgement.
const rosterPrompt = (subset) => `In this repository (hardened-containers), run exactly one command and report its contents. READ-ONLY: do not edit, build or commit anything, and do not run anything else.

  python3 scripts/build/check-support-line.py

With no --image it checks EVERY image in one pass and prints a table (image, line, our pin, latest in line, maintained, EOL date) followed by per-image notes. Do not call it once per image.

Turn that output into one entry per image${subset ? `, restricted to exactly these images: ${subset.join(', ')}` : ''}:
- line_status "eol" if the table or notes say the line is no longer maintained (an EOL date in the past, maintained=no); "manual" if the notes say the image is not on endoflife.date and is judged by a person — carry that reference URL into support_detail; otherwise "supported", including when the note says the line is maintained but our pin is behind inside it. "unknown" only if the output does not say.
- support_detail: the line it tracks, our pin, the latest in that line, and whatever the note said about it, quoted from the output rather than paraphrased.

Field meanings are in docs/image-authoring/support-policy.md if the output needs interpreting.`

const sweepPrompt = (image, line) => `You are doing a READ-ONLY pin freshness check on the self-built container image "${image}" in this repository (hardened-containers). Do not edit any file, do not build anything, do not commit. Report only.

Its upstream line has already been checked, so do NOT run check-support-line.py: line status is "${line.line_status}" — ${line.support_detail}. Take that as given and, if it says the line is end-of-life, say in your note that a pin raise inside that line cannot help and the real work is a migration to a maintained line.

Your job is the part nothing here automates — whether the committed pins still point at the current upstream point.

1. Enumerate the committed pins — do not assume the names.
   Read DEFAULT_BASE_OS from images/${image}/image.env, open that variant's images/${image}/<variant>.build.env, and take every field that is a version, commit or tag: APP_VERSION, SOURCE_COMMIT, GO_BUILDER_TAG, NODE_BUILDER_TAG, RUNTIME_BASE, *_VERSION, the *_FIX_VERSION family, and any <LIB>_OLD/<LIB>_VERSION pairs.

2. Establish the current upstream point for each pin (WebFetch/WebSearch on the upstream repository's releases, tags or advisories; for Go module pins you may also read scripts/build/suggest-go-upgrades.py output if trivy reports are already present under /tmp/out — do not run a build to produce them).
   Only facts: if you cannot establish a pin's current upstream point, set latest to "unknown" and behind to false rather than guessing.
   Watch the known trap: some projects tag with a leading "v" (kyverno's v1.19.0) while endoflife.date release names never carry it. Compare like with like.
   Say in the note which gaps are security-relevant and which are merely newer — a patch release with no security content is not the same finding as a pin sitting on a CVE.

3. Read images/${image}/README.md for why this image is self-built at all, and say in your note if that reason looks like it may no longer hold — flag it, do not conclude it. Deciding to retire a self-build needs its own investigation.

Set verdict to: "pins_behind" if any pin is behind; else "needs_judgement" if you could not establish enough to say; else "current".`

const RANK = { line_eol: 0, pins_behind: 1, needs_judgement: 2, current: 3 }

// Stage 1 is not a stage at all in the preferred form: the caller already ran
// check-support-line.py and passes its result as args.images, so no agent and no tokens go
// into it. The agent below is the fallback for a standalone invocation only.
const provided = args && !Array.isArray(args) && Array.isArray(args.images) ? args.images : null
const subset = Array.isArray(args) && args.length ? args : null

const roster = (
  provided ||
  (
    await agent(rosterPrompt(subset), {
      label: subset ? `line check (${subset.length} images)` : 'line check (all images)',
      phase: 'Line check',
      schema: ROSTER_SCHEMA,
    })
  ).images
).map((r) => ({
  image: r.image,
  line_status: r.line_status || 'unknown',
  support_detail: r.support_detail || 'not established',
}))

log(
  provided
    ? `${roster.length} image(s); line status supplied by the caller, so no agent was spent on it`
    : `${roster.length} image(s); line status established by one agent call`,
)
// An empty roster must not fall through to "everything is current" — that reads as a clean
// bill of health for a sweep that examined nothing.
if (roster.length === 0) {
  log('no images to sweep — nothing was examined')
  return { table: '', swept: 0, no_verdict: 0, details: [], next_step: 'Nothing was swept: the image list was empty. Check the args passed in.' }
}

log('concurrency is capped at min(16, CPUs-2), and each image takes roughly 20 minutes')

const eol = roster.filter((r) => r.line_status === 'eol')
if (eol.length) log(`line end-of-life: ${eol.map((r) => r.image).join(', ')} — migration, not a pin raise`)

// Stage 2 — the research half, one agent per image.
const byImage = new Map(roster.map((r) => [r.image, r]))
const results = (
  await parallel(
    roster.map((line) => () =>
      agent(sweepPrompt(line.image, line), {
        label: `sweep:${line.image}`,
        phase: 'Sweep',
        schema: VERDICT_SCHEMA,
      }),
    ),
  )
).filter(Boolean)

const failed = roster.length - results.length
if (failed > 0) log(`${failed} image(s) returned no verdict — they are absent from the table, not "current"`)

// An end-of-life line outranks everything: no pin raise inside it helps, so it is the finding
// that has to be read first even when the pins themselves look fine.
const rank = (r) => (byImage.get(r.image)?.line_status === 'eol' ? RANK.line_eol : RANK[r.verdict] ?? 9)
results.sort((a, b) => rank(a) - rank(b) || a.image.localeCompare(b.image))

// The table stays scannable: one line per image, no prose. A markdown cell cannot hold a
// real line break and an HTML <br> does not survive every renderer, so several behind pins
// are separated with "; " and the reasoning goes in `details` below the table instead.
const rows = results.map((r) => {
  const behind = r.pins.filter((p) => p.behind)
  const pinCell = behind.length
    ? behind.map((p) => `${p.name} ${p.committed} → ${p.latest}`).join('; ')
    : '—'
  const line = byImage.get(r.image)?.line_status ?? 'unknown'
  return `| ${r.image} | ${line === 'eol' ? '**line_eol**' : r.verdict} | ${line} | ${behind.length} | ${pinCell} |`
})

const table = [
  '| Image | Verdict | Line | # behind | Pins behind |',
  '|---|---|---|---|---|',
  ...rows,
].join('\n')

const attention = results.filter(
  (r) => r.verdict !== 'current' || byImage.get(r.image)?.line_status === 'eol',
)

return {
  table,
  swept: results.length,
  no_verdict: failed,
  details: attention.map((r) => ({
    image: r.image,
    verdict: r.verdict,
    line: byImage.get(r.image)?.line_status ?? 'unknown',
    line_detail: byImage.get(r.image)?.support_detail ?? '',
    note: r.note,
  })),
  next_step:
    attention.length === 0
      ? 'Nothing to do — every swept image is current and on a supported line.'
      : 'Take each flagged image to the pin-freshness-check skill individually; that is where the judgement calls and any actual pin change happen. An end-of-life line is a migration, handled through self-build-image, not a pin raise.',
}
