#!/usr/bin/env node
//
// Renders ceproof's `scan --format json` report into the Markdown that goes to
// $GITHUB_STEP_SUMMARY, and writes the action's key=value outputs.
//
//   node summary.js <report.json> <scan-exit-code> <fail-on> <outputs-file>
//
// Markdown goes to stdout. No dependencies: it runs on the runner's bundled
// node, same as the CLI.
'use strict';
const fs = require('fs');

const [reportPath, exitCodeArg, failOn, outputsPath] = process.argv.slice(2);
if (!reportPath || !outputsPath) {
  console.error('usage: summary.js <report.json> <scan-exit-code> <fail-on> <outputs-file>');
  process.exit(2);
}

const r = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const s = r.summary;
const failed = Number(exitCodeArg) !== 0;
const cfg = r.configStatus || { present: false, valid: null, missingAnswers: [] };

// Only the rows a human has to act on. 21 items today, but cap anyway: the job
// summary has a 1 MiB limit and the citations are long.
const ROW_CAP = 50;
const open = r.gapChecklist.filter((i) => i.status !== 'DERIVED');

const esc = (v) => String(v == null ? '' : v).replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
const clip = (v, n) => {
  const t = esc(v);
  return t.length > n ? `${t.slice(0, n - 1)}…` : t;
};
const out = [];

out.push(`## ${failed ? '❌' : '✅'} CEProof — ${esc(r.projectName)}`);
out.push('');
out.push(
  failed
    ? `Failed on \`--fail-on ${esc(failOn)}\`. ${open.length} of ${s.totalItems} CRA item(s) are still open.`
    : `Passed on \`--fail-on ${esc(failOn)}\`. ${open.length} of ${s.totalItems} CRA item(s) are still open.`,
);
out.push('');
out.push('| | |');
out.push('|---|---|');
out.push(`| Checklist items | ${s.totalItems} (Annex VII + Annex V) |`);
out.push(`| Derived from the repo | ${s.derived} |`);
out.push(`| Partial | ${s.partial} |`);
out.push(`| Needs your input | ${s.needsHumanInput} |`);
out.push(
  `| \`ceproof.config.json\` | ${cfg.present ? (cfg.valid === false ? 'present, **invalid**' : 'present and valid') : 'not found — run `npx ceproof init`'} |`,
);
out.push('');

if (cfg.valid === false && cfg.errors && cfg.errors.length) {
  out.push('### Config errors');
  out.push('');
  for (const e of cfg.errors) out.push(`- ${esc(e)}`);
  out.push('');
}

if (open.length) {
  out.push('### Still open');
  out.push('');
  out.push('| Item | Instrument | Status | Requirement | Evidence so far |');
  out.push('|---|---|---|---|---|');
  for (const i of open.slice(0, ROW_CAP)) {
    const instrument = i.instrument === 'annexVII' ? 'Annex VII' : 'Annex V';
    out.push(
      `| \`${esc(i.id)}\` | ${instrument} | ${esc(i.status)} | ${clip(i.requirementSummary, 160)} | ${clip((i.evidence || []).join('; ') || '—', 120)} |`,
    );
  }
  out.push('');
  if (open.length > ROW_CAP) {
    out.push(`_${open.length - ROW_CAP} more open item(s) omitted from this table — see the uploaded \`report.json\` for all of them._`);
    out.push('');
  }
  out.push('Answer the `NEEDS-HUMAN-INPUT` items in `ceproof.config.json` and they move to `DERIVED`.');
  out.push('');
}

if (r.warnings && r.warnings.length) {
  out.push('### Warnings');
  out.push('');
  for (const w of r.warnings) out.push(`- ${esc(w)}`);
  out.push('');
}

// r.dataVersion is a full sourcing paragraph (the consolidated CRA text plus
// corrigenda), far too long for a footer — clip it and leave the whole string
// in report.json.
out.push(
  `<sub>ceproof ${esc(r.toolVersion)} · scanned ${esc(r.scanTimestamp)} · CRA source: ${clip(r.dataVersion, 120)}</sub>`,
);
out.push('');
out.push('<sub>Compliance-posture information only. Not a conformity assessment, not legal advice, and not a Declaration of Conformity.</sub>');
out.push('');

process.stdout.write(out.join('\n'));

fs.writeFileSync(
  outputsPath,
  [
    `outcome=${failed ? 'fail' : 'pass'}`,
    `total-items=${s.totalItems}`,
    `derived-count=${s.derived}`,
    `partial-count=${s.partial}`,
    `needs-human-input-count=${s.needsHumanInput}`,
    `config-present=${cfg.present ? 'true' : 'false'}`,
    `config-valid=${cfg.valid === null ? 'unknown' : String(cfg.valid)}`,
    '',
  ].join('\n'),
);
