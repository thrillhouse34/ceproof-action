#!/usr/bin/env node
//
// Renders ceproof's `scan --format json` report into the Markdown that goes to
// $GITHUB_STEP_SUMMARY, and writes the action's key=value outputs.
//
//   node summary.js <report.json> <scan-exit-code> <fail-on> <outputs-file> [has-key]
//
// <has-key> is the string "true" when a license-key input was supplied. It only
// suppresses the upsell block — no key material is ever passed to, or touched
// by, this script.
//
// Markdown goes to stdout. No dependencies: it runs on the runner's bundled
// node, same as the CLI.
'use strict';
const fs = require('fs');

const [reportPath, exitCodeArg, failOn, outputsPath, hasKeyArg] = process.argv.slice(2);
const hasKey = hasKeyArg === 'true';
if (!reportPath || !outputsPath) {
  console.error('usage: summary.js <report.json> <scan-exit-code> <fail-on> <outputs-file>');
  process.exit(2);
}

const r = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
const s = r.summary;
const failed = Number(exitCodeArg) !== 0;

// The FDA profile's JSON is a DIFFERENT document, not the CRA one with a flag
// on it: `items` instead of `gapChecklist`, `device` instead of `projectName`,
// `structureVersion` instead of `dataVersion`, `generatedAt` instead of
// `scanTimestamp`, no `configStatus`, and no per-item `instrument`. Normalised
// once, here, so everything below stays ONE renderer. Two near-identical
// renderers is how two surfaces drift apart, and the disclaimer and the open-item
// table are exactly what must not drift.
const fda = r.profile === 'fda';

// configStatus is absent on the FDA profile. ceproof.config.json IS still read
// there (fda.componentSupport), it is just not reported on — so this stays null
// and the config-present output says "unknown" rather than a confident false.
const cfg = r.configStatus || { present: fda ? null : false, valid: null, missingAnswers: [] };

const title = fda
  ? [r.device && r.device.name, r.device && r.device.version].filter(Boolean).join(' ') || 'FDA premarket SBOM'
  : r.projectName;
const itemWord = fda ? 'FDA' : 'CRA';
const itemsLabel = fda ? '13 FDA content items' : s.totalItems + ' (Annex VII + Annex V)';
const sourceLabel = fda ? 'FDA guidance' : 'CRA source';
const sourceVersion = fda ? r.structureVersion : r.dataVersion;
const runAt = fda ? r.generatedAt : r.scanTimestamp;

// Only the rows a human has to act on. 21 CRA items / 13 FDA items today, but
// cap anyway: the job summary has a 1 MiB limit and the citations are long.
const ROW_CAP = 50;
const open = (fda ? r.items : r.gapChecklist).filter((i) => i.status !== 'DERIVED');

const esc = (v) => String(v == null ? '' : v).replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
const clip = (v, n) => {
  const t = esc(v);
  return t.length > n ? `${t.slice(0, n - 1)}…` : t;
};
const out = [];

out.push(`## ${failed ? '❌' : '✅'} CEProof${fda ? ' (FDA premarket SBOM)' : ''} — ${esc(title)}`);
out.push('');
out.push(
  `${failed ? 'Failed' : 'Passed'} on \`--fail-on ${esc(failOn)}\`. ${open.length} of ${s.totalItems} ${itemWord} item(s) are still open.`,
);
if (fda && !failed && failOn === 'never') {
  // Say WHY a green run has open items under it, in the one place the person
  // looking at a tick above five NEEDS-HUMAN-INPUT rows will actually read.
  out.push('');
  out.push(
    '<sub>The FDA profile is report-only by default: three of its items can only ever be answered by a human, ' +
      'so it never fails the job unless you ask it to with `fail-on`.</sub>',
  );
}
out.push('');
out.push('| | |');
out.push('|---|---|');
out.push(`| Checklist items | ${itemsLabel} |`);
out.push(`| Derived from the repo | ${s.derived} |`);
out.push(`| Partial | ${s.partial} |`);
out.push(`| Needs your input | ${s.needsHumanInput} |`);
if (fda) {
  const c = r.counts || {};
  out.push(`| Components | ${c.components == null ? '—' : c.components} |`);
  out.push(`| Imported SBOMs | ${((r.inputs && r.inputs.sboms) || []).length} |`);
} else {
  out.push(
    `| \`ceproof.config.json\` | ${cfg.present ? (cfg.valid === false ? 'present, **invalid**' : 'present and valid') : 'not found — run `npx ceproof init`'} |`,
  );
}
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
  // No Instrument column on the FDA profile: its thirteen items all come from
  // one guidance document, so a column reading "FDA" thirteen times is noise.
  out.push(fda ? '| Item | Status | Requirement | Evidence so far |' : '| Item | Instrument | Status | Requirement | Evidence so far |');
  out.push(fda ? '|---|---|---|---|' : '|---|---|---|---|---|');
  for (const i of open.slice(0, ROW_CAP)) {
    const instrument = fda ? '' : `${i.instrument === 'annexVII' ? 'Annex VII' : 'Annex V'} | `;
    out.push(
      `| \`${esc(i.id)}\` | ${instrument}${esc(i.status)} | ${clip(i.requirementSummary, 160)} | ${clip((i.evidence || []).join('; ') || '—', 120)} |`,
    );
  }
  out.push('');
  if (open.length > ROW_CAP) {
    out.push(`_${open.length - ROW_CAP} more open item(s) omitted from this table — see the uploaded \`report.json\` for all of them._`);
    out.push('');
  }
  out.push(
    fda
      ? 'Some of these move to `DERIVED` once you declare them in `ceproof.config.json` (the `fda.*` keys). Three never can: the safety and security risk assessment, the risk controls and the cyber-device determination are yours to make.'
      : 'Answer the `NEEDS-HUMAN-INPUT` items in `ceproof.config.json` and they move to `DERIVED`.',
  );
  out.push('');
}

if (r.warnings && r.warnings.length) {
  out.push('### Warnings');
  out.push('');
  for (const w of r.warnings) out.push(`- ${esc(w)}`);
  out.push('');
}

// The upsell, shown only to people who have not already bought. Nobody wants to
// be sold the thing they are currently using, and a paid customer seeing "get
// the full report" in every run would read as a billing bug.
if (!hasKey) {
  out.push('---');
  out.push('');
  if (fda) {
    // NO PRICE here, deliberately, and it is the same call ceproof's own
    // FDA_UNLICENSED_MESSAGE makes: the FDA tiers are annual and a price
    // hardcoded into an action someone pinned eight months ago is worse than a
    // link to the page that is current. The CRA upsell below can quote $99
    // because that one is perpetual and has not moved.
    out.push(
      '**Get the FDA evidence pack** — `ceproof report --format fda-pack` writes seven files: ' +
        'the enriched CycloneDX SBOM, the support and end-of-support table, the known-exploited ' +
        'vulnerability table with the two columns you fill in, a summary, the open-items list, ' +
        'a provenance record and a disclaimer. Annual, sold per company and per consultant — ' +
        '[ceproof.dev/fda](https://ceproof.dev/fda)',
    );
    out.push('');
    out.push('<sub>This view, above, is free and always will be. It needs no key.</sub>');
  } else {
    // The prices and the sample URL are the ones on ceproof.dev ($99 Individual,
    // $299 Agency, /report-sample). They are quoted in README.md too — change both
    // together.
    out.push(
      '**Get the full report** — the Annex VII technical documentation pack and the Annex V ' +
        'Declaration of Conformity draft, as HTML and PDF, regenerated on every release. ' +
        'From **$99 one-time** (agency $299), perpetual license, no subscription — ' +
        '[look at a finished pack](https://ceproof.dev/report-sample) · ' +
        '[ceproof.dev](https://ceproof.dev)',
    );
  }
  out.push('');
  out.push(
    '<sub>Already have a key? Put it in a repository secret and pass it to this action as ' +
      '`license-key: ${{ secrets.CEPROOF_LICENSE_KEY }}`.</sub>',
  );
  out.push('');
}

// r.dataVersion / r.structureVersion is a full sourcing paragraph (the
// consolidated CRA text plus corrigenda; the FDA guidance with its docket
// number and sections), far too long for a footer — clip it and leave the whole
// string in report.json.
out.push(
  `<sub>ceproof ${esc(r.toolVersion)} · scanned ${esc(runAt)} · ${sourceLabel}: ${clip(sourceVersion, 120)}</sub>`,
);
out.push('');
// The FDA profile needs its own disclaimer, not the CRA one with a word swapped:
// "not a Declaration of Conformity" is meaningless to a device manufacturer, and
// the two things that have to be said in a premarket context — not an FDA
// submission, and not endorsed by FDA or CISA — are not said by the CRA line at
// all. Kept in step with FDA_DISCLAIMER in ceproof's src/branding.ts.
out.push(
  fda
    ? '<sub>Informational — not legal advice. Generated from the component data you supplied and your own declarations. Not an FDA submission, not regulatory advice, and not reviewed or endorsed by FDA or by CISA. It supports your own review of your premarket submission; it does not replace it.</sub>'
    : '<sub>Compliance-posture information only. Not a conformity assessment, not legal advice, and not a Declaration of Conformity.</sub>',
);
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
    `config-present=${cfg.present === null ? 'unknown' : cfg.present ? 'true' : 'false'}`,
    `config-valid=${cfg.valid === null ? 'unknown' : String(cfg.valid)}`,
    '',
  ].join('\n'),
);
