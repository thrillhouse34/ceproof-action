# CEProof Action

Derive an EU Cyber Resilience Act compliance posture from your repo — offline, and
honest about what it cannot know.

This action runs the [`ceproof`](https://www.npmjs.com/package/ceproof) CLI against your
checked-out repository, writes the Annex VII / Annex V gap checklist to the job summary,
uploads it as a build artifact, and fails the job while items are still unanswered.

It is a **composite** action: `ceproof` is already published to npm, so the action is a
thin wrapper that `npx`-runs a pinned version (`0.3.3`). No bundled `node_modules` to
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
npx ceproof@0.3.3 init
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
| `version` | `0.3.3` | Version of the `ceproof` npm package to run. Pinned; override only to try a newer release. |
| `out` | _(empty)_ | Directory for `report.json` and `summary.md`. Defaults to a directory under the runner temp dir, so your checkout stays clean. |
| `summary` | `true` | `false` to skip writing to the job summary. |
| `upload-artifact` | `true` | `false` to skip the artifact upload. |
| `artifact-name` | `ceproof-report` | Name of the uploaded artifact. Give each job a distinct name if you run the action more than once in one workflow. |
| `artifact-retention-days` | `0` | Days before the uploaded artifact expires. `0` uses the repository default. |

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

## Exit codes

The action exits with the CLI's own code, so the job status follows it:

| Code | Meaning |
|---|---|
| 0 | Nothing crossed the `fail-on` threshold. |
| 1 | Something did. `outcome` is `fail`; the report is still written and uploaded. |
| 2 | Usage or tool error — no project found at `path`, a bad `fail-on` value, a `config` path that does not exist. The message is on stderr. |

A failing scan still produces the artifact. That's the run you want it for.

## Notes

- Scanning is fully offline. The only network call is `npx` fetching the pinned `ceproof`
  package from npm.
- `ceproof` itself treats an explicitly-given but missing `--config` path as "no config
  present", with no warning — a typo would silently discard every answer you wrote. This
  action checks the path first and exits 2 instead.
- `ceproof scan` needs no license key. The paid `report` command (the Annex VII pack and
  the Annex V Declaration of Conformity draft, as HTML and PDF) is not wrapped by this
  action.
- The derived/partial split moves with your repo's git state — a real release tag, for
  instance, is evidence for `annex7.1.b`. Expect the counts to shift between a shallow CI
  checkout and your local clone.
- Pin the action by tag (`@v1`) or by commit SHA, and pin the CLI with `version:` if you
  want the checklist frozen across releases.

## Testing this action

`./scripts/simulate.sh` runs the action's real `scripts/run.sh` against
`fixtures/sample-repo` with a faked runner environment and asserts on the exit codes, the
job summary, and every output. If [`act`](https://github.com/nektos/act) is installed it
also runs `.github/workflows/test.yml` for real. CI runs the same script plus the action
itself, both the passing and the failing path.

## License

Elastic License 2.0 — see [LICENSE](LICENSE). Source-available, not open source.
