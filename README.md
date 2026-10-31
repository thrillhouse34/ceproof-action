# CEProof Action

Derive an EU Cyber Resilience Act compliance posture from your repo — offline, and
honest about what it cannot know.

This action runs the [`ceproof`](https://www.npmjs.com/package/ceproof) CLI against your
checked-out repository, writes the Annex VII / Annex V gap checklist to the job summary,
uploads it as a build artifact, and fails the job while items are still unanswered.

It is a **composite** action: `ceproof` is already published to npm, so the action is a
thin wrapper that `npx`-runs a pinned version (`0.3.4`). No bundled `node_modules` to
keep in sync, and the thing the action runs is byte-for-byte the release you can run
locally yourself.

CEProof is **source-available** under the [Elastic License 2.0](LICENSE).

> **What this is not.** CEProof produces compliance-posture *information*. It is not a
> conformity assessment, not legal advice, and not a Declaration of Conformity. It tells
> you which Annex VII and Annex V items your repo can evidence and which ones still need
> a human.

## Usage

```yaml
name: cra

on: [push, pull_request]

permissions:
  contents: read

jobs:
  cra:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: thrillhouse34/ceproof-action@v1
        with:
          fail-on: never     # start here: report, don't block
```

Start with `fail-on: never`. A fresh repo with no `ceproof.config.json` has every
human-required item open, so the default `human-required` would fail on day one. Answer
the items, then tighten the threshold.

### Generate the config first

The human-required items are answered in `ceproof.config.json`, which lives in your
repo. Create it once, locally:

```sh
npx ceproof@0.3.4 init
```

Fill it in, commit it, and those items move from `NEEDS-HUMAN-INPUT` to `DERIVED` on the
next run.

### Block merges once you are answering the items

```yaml
      - uses: thrillhouse34/ceproof-action@v1
        with:
          fail-on: human-required   # the default: fail while anything needs an answer
```

### Strictest: fail on partial evidence too

```yaml
      - uses: thrillhouse34/ceproof-action@v1
        with:
          fail-on: partial
```

### Also generate the Annex VII pack

If you have a ceproof key, put it in a repository secret and pass it in. The
free posture scan runs exactly as before; the Annex VII pack and Annex V DoC
draft are generated on top and uploaded as their own artifact.

```yaml
      - uses: thrillhouse34/ceproof-action@v1
        with:
          license-key: ${{ secrets.CEPROOF_LICENSE_KEY }}
          fail-on: never
```

Never paste the key in as a literal — always a secret. See
[The paid report](#the-paid-report) below for what you get and how it fails.

### Scan a subdirectory with its own config, and use the outputs

```yaml
      - id: cra
        uses: thrillhouse34/ceproof-action@v1
        with:
          path: products/gateway
          config: products/gateway/ceproof.config.json
          fail-on: never
      - run: echo "${{ steps.cra.outputs.needs-human-input-count }} CRA items still need an answer"
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Project path to scan, relative to the workspace. |
| `fail-on` | `human-required` | When to fail the job: `human-required`, `partial`, or `never`. Any other value is rejected with exit 2 rather than silently defaulted. |
| `config` | _(empty)_ | Path to `ceproof.config.json`, relative to the workspace. Defaults to `<path>/ceproof.config.json`. A path that does not exist is an error, not a silent fallback — see [Notes](#notes). |
| `include-dev` | `false` | `true` to include `devDependencies` in the dependency facts. |
| `project-license` | _(empty)_ | SPDX id or expression for your own project, overriding `package.json`. |
| `version` | `0.3.4` | Version of the `ceproof` npm package to run. Pinned; override only to try a newer release. |
| `out` | _(empty)_ | Directory for `report.json` and `summary.md`. Defaults to a directory under the runner temp dir, so your checkout stays clean. |
| `summary` | `true` | `false` to skip writing to the job summary. |
| `upload-artifact` | `true` | `false` to skip the artifact upload. |
| `artifact-name` | `ceproof-report` | Name of the uploaded artifact. Give each job a distinct name if you run the action more than once in one workflow. |
| `artifact-retention-days` | `0` | Days before the uploaded artifact expires. `0` uses the repository default. |
| `license-key` | _(empty)_ | Your paid ceproof key, which also generates the Annex VII pack and Annex V DoC draft. Pass it from a secret, never as a literal. Empty means free scan only — which is the supported, normal configuration, not a degraded one. |
| `report-formats` | `annex7,annex7-pdf,doc,doc-pdf,sbom-cyclonedx,sbom-spdx` | Paid report formats to generate, comma-separated. Only read when `license-key` is set. |
| `report-out` | _(empty)_ | Directory for the paid report artifacts. Defaults to a directory under the runner temp dir. |
| `report-artifact-name` | `ceproof-full-report` | Name of the uploaded paid-report artifact. Separate from `artifact-name` so the free report and the paid pack download independently. |

## Outputs

| Output | Description |
|---|---|
| `outcome` | `pass` or `fail` — whether the scan tripped the `fail-on` threshold. Written before the action exits, so pair the step with `continue-on-error: true` if you want to read it on a failing scan. |
| `total-items` | CRA checklist items evaluated (Annex VII and Annex V together). |
| `derived-count` | Items fully derived from evidence in the repo. |
| `partial-count` | Items with some evidence, but not enough to stand alone. |
| `needs-human-input-count` | Items that need an answer from you — no repo evidence can supply them. |
| `config-present` | `true` when a `ceproof.config.json` was found. |
| `config-valid` | `true`, `false`, or `unknown` when there is no config to validate. |
| `report-path` | Absolute path to the machine-readable `report.json`. |
| `summary-path` | Absolute path to the Markdown summary. |
| `report-generated` | `true` when the paid report was generated. Empty when no `license-key` was supplied. |
| `report-dir` | Absolute path to the directory holding the paid report artifacts. Empty when no `license-key` was supplied. |

## What the report looks like

The job summary gets a verdict line, a posture table, and a row per item that is not yet
fully derived:

> ## ❌ CEProof — acme-sample-device
>
> Failed on `--fail-on human-required`. 19 of 21 CRA item(s) are still open.
>
> | | |
> |---|---|
> | Checklist items | 21 (Annex VII + Annex V) |
> | Derived from the repo | 2 |
> | Partial | 2 |
> | Needs your input | 17 |
> | `ceproof.config.json` | not found — run `npx ceproof init` |
>
> ### Still open
>
> | Item | Instrument | Status | Requirement | Evidence so far |
> |---|---|---|---|---|
> | `annex7.1.a` | Annex VII | NEEDS-HUMAN-INPUT | General description of the product with digital elements, including its intended purpose. | — |
> | `annex7.1.b` | Annex VII | PARTIAL | General description must state versions of software affecting compliance with essential cybersecurity requirements. | vcs.isGitRepo: true; vcs.tag: not detected |
>
> Answer the `NEEDS-HUMAN-INPUT` items in `ceproof.config.json` and they move to `DERIVED`.

Long requirement text and evidence lists are clipped in the table; nothing is clipped in
`report.json`. More than 50 open items gets the first 50 and a line saying how many were
left out. An invalid config gets its validation errors listed above the table.

The uploaded artifact holds both files:

- `report.json` — the full `ceproof scan --format json` report (`schemaVersion: 1`): every
  checklist item with its status, requirement summary, the exact CRA citation, and the
  evidence behind it, plus the detected repo facts (security policy, project license,
  ecosystems, runtimes, VCS, update mechanism), the config status with the list of
  unanswered item ids, and any warnings.
- `summary.md` — the Markdown above, for pasting into a ticket.

## The paid report

The free scan tells you where you stand. The paid report is the paperwork: the
Annex VII technical documentation pack and the Annex V Declaration of Conformity
draft, as HTML and PDF, plus both SBOM formats — compiled from the same scan,
stamped with the release they describe, regenerated on every run. It needs a
ceproof key — one perpetual purchase, no subscription, from
[ceproof.dev](https://ceproof.dev).

```yaml
      - uses: thrillhouse34/ceproof-action@v1
        with:
          license-key: ${{ secrets.CEPROOF_LICENSE_KEY }}
          config: ceproof.config.json
          fail-on: never
          report-formats: annex7-pdf,doc-pdf   # narrow it if you only want the PDFs
```

The obvious thing to do with it is tag a release and keep the pack that matches
it:

```yaml
on:
  release:
    types: [published]
```

It is **one extra input on the same action**, not a second action. That is a
deliberate choice: the pack is rendered from the same gap checklist the free
step already computed, so a separate action would have to redo that work and
could then disagree with the step above it about your posture — two documents,
two answers, for one release. One `uses:` line, one checklist, one source of
truth.

### How it behaves

- **No key is the normal case.** Leave `license-key` empty, or point it at a
  secret that isn't set, and the action is exactly the free scan — no paid step,
  no warning, no failure. The job summary gets a one-line pointer to the paid
  report, which disappears as soon as a key is configured.
- **A rejected key fails the job**, with a message naming the likely causes and
  nothing written. It does not silently fall back to the free scan: a release
  going out without the Annex VII pack you thought you had generated is worse
  than a red build. Put `continue-on-error: true` on the step if you would
  rather it were advisory.
- **A `config` path that does not exist is refused here too**, before any key
  work. A compliance document missing the answers it is supposed to carry is
  worse than no document at all.
- **The free verdict is never affected.** The scan runs first and publishes its
  outputs and job summary before the report step is reached, so a key problem
  can't change, hide, or invalidate the free result.
- **The report runs even when the scan failed the build.** With the default
  `fail-on: human-required`, a repo with open items fails — and that is most
  repos, most of the time. Without this, the pack would never be generated for
  exactly the people who most need it.

The output is still informational. It is not a conformity assessment, not legal
advice, and not a Declaration of Conformity until a responsible person reviews,
completes and signs it.

### What happens to your key

- It is passed to the action in an `env:` block, which the runner does not log,
  and it is read from `$CEPROOF_KEY` — never put on a command line, where any
  process on the runner could read it out of `ps`.
- `::add-mask::` is emitted before any other output, so the runner redacts the
  value from the log even if something later were to print it.
- It is never written to the job summary, to any action output, or to any
  uploaded artifact. The generated artifacts are searched for the key, and the
  upload is refused outright if it is found — a check, not an assumption.
- Keys live in repository secrets. A secret is not readable by workflows from
  forked pull requests, which is the behaviour you want here.

## Exit codes

The action exits with the CLI's own code, so the job status follows it:

| Code | Meaning |
|---|---|
| 0 | Nothing crossed the `fail-on` threshold. |
| 1 | Something did. `outcome` is `fail`; the report is still written and uploaded. |
| 2 | Usage or tool error — no project found at `path`, a bad `fail-on` value, a `config` path that does not exist. The message is on stderr. |
| 3 | A `license-key` was supplied and rejected. No paid artifacts were written. The free scan's result still stands. |

A failing scan still produces the artifact. That's the run you want it for.

## Not on GitHub Actions?

This action is only a thin wrapper around the published CLI, so the same checks
run anywhere Node 22 runs — no action needed.

### GitLab CI

```yaml
ceproof:
  image: node:22
  stage: test
  script:
    - npm ci
    - npx --yes ceproof@0.3.5 scan . --fail-on never
    - npx --yes ceproof@0.3.5 report . --format sbom-cyclonedx,sbom-spdx --out ceproof-reports
  artifacts:
    paths: [ceproof-reports/]
# Paid packs: add a masked CI/CD variable CEPROOF_KEY and append annex7,doc to --format.
```

### Plain CLI

```bash
npx ceproof scan                                  # gap checklist; exit 1 while human-required items remain (default --fail-on human-required)
npx ceproof init                                  # answer the items a scan can't infer
npx ceproof report --format sbom-cyclonedx,sbom-spdx --out sbom   # free SBOMs
CEPROOF_KEY=... npx ceproof report --format annex7,annex7-pdf,doc,doc-pdf --out cra   # paid
```

The exit codes are the same ones in the table above, so any runner can gate on
them the way this action does.

## Notes

- Scanning is fully offline. The only network call is `npx` fetching the pinned `ceproof`
  package from npm.
- This action checks the `config` path itself and exits 2 before running the CLI at all.
  Older `ceproof` releases treated an explicitly-given but missing `--config` path as "no
  config present", with no warning, so a typo silently discarded every answer you wrote
  and then failed your build on the items that config was answering. The CLI refuses
  properly now too; the check here is belt and braces, and stays whichever version you
  pin. (Deliberately written without a version number — `scripts/bump.sh` rewrites every
  version string in this file, and a sentence about an old release's behaviour must not
  be re-pointed at a new one.)
- `ceproof scan` needs no license key. The paid `report` command (the Annex VII pack and
  the Annex V Declaration of Conformity draft, as HTML and PDF) is wrapped too, but only
  runs when you supply one — see [The paid report](#the-paid-report).
- The derived/partial split moves with your repo's git state — a real release tag, for
  instance, is evidence for `annex7.1.b`. Expect the counts to shift between a shallow CI
  checkout and your local clone.
- Pin the action by tag (`@v1`) or by commit SHA, and pin the CLI with `version:` if you
  want the checklist frozen across releases.

## Testing this action

`./scripts/simulate.sh` runs the action's real `scripts/run.sh` against
`fixtures/sample-repo` with a faked runner environment and asserts on the exit codes, the
job summary, and every output. It also drives `scripts/report.sh` with a deliberately
invalid key, asserting that the refusal is clean, that nothing is written, and that the
key reaches no output other than the `::add-mask::` line that exists to redact it. If
[`act`](https://github.com/nektos/act) is installed it also runs
`.github/workflows/test.yml` for real. CI runs the same script plus the action itself
four ways: passing, failing, with a bad key, and with no key.

## Maintainer notes

Not for users of the action — for whoever maintains it.

### Bumping the pinned CLI version

The npm version is pinned in six places: `action.yml`'s `version` input
default, `scripts/run.sh`'s fallback, `scripts/report.sh`'s fallback, and this
README (three times). Don't edit them by hand:

```sh
./scripts/bump.sh 0.3.4
```

It reads the current version out of `action.yml` (the single source of truth),
refuses to proceed unless `ceproof@<new>` is actually published to npm, rewrites
every pin, warns about any stale one it didn't know about, and then prints the
commit, release and tag commands. It never pushes, tags or publishes anything
itself.

### If the Marketplace name is taken

An action's `name:` has to be unique across the whole GitHub Marketplace, and
must not collide with an existing GitHub user or organisation. GitHub only tells
you at release time. If `CEProof` is rejected, the fallback is one line in
`action.yml`:

```yaml
name: 'CEProof CRA Posture Scan'
```

Nothing else changes — the name is a display label, not the `uses:` path, which
comes from the repository name. The README's usage examples stay correct.

## License

Source-available under the Elastic License 2.0 (SPDX: `Elastic-2.0`). See [LICENSE](LICENSE).
