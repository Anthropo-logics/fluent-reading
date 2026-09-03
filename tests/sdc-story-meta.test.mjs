import assert from 'node:assert/strict';
import { afterEach, test } from 'node:test';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const {
  extractQaEvidence,
  normalizeStatus,
  resolveQaEvidence,
} = require('../.aiox-core/core/sdc/story-meta');
const { verifyPhase } = require('../.aiox-core/core/sdc/phase-verify');

const temporaryRoots = [];

afterEach(() => {
  for (const root of temporaryRoots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function temporaryRoot() {
  const root = mkdtempSync(join(tmpdir(), 'lectura-sdc-'));
  temporaryRoots.push(root);
  return root;
}

function write(root, relativePath, contents) {
  const target = join(root, relativePath);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, contents);
  return target;
}

function incompleteStoryMeta(storyId, verdict) {
  return {
    storyId,
    qaVerdict: verdict,
    qaReviewer: null,
    qaReviewedRevision: null,
    qaWaiver: { active: false, reason: '', approver: '', valid: false },
    qaWaiverValid: verdict !== 'WAIVED',
    qaEvidenceComplete: false,
  };
}

test('uses top-level gate evidence instead of nested history', () => {
  const root = temporaryRoot();
  write(
    root,
    'docs/qa/gates/4.2.yml',
    `story: '4.2'
gate: PASS
reviewer: Quinn
reviewed_revision: commit:current
history:
  - gate: CONCERNS
    reviewed_revision: commit:old
`,
  );

  const evidence = resolveQaEvidence(incompleteStoryMeta('4.2', 'PASS'), { cwd: root });
  assert.equal(evidence.verdict, 'PASS');
  assert.equal(evidence.reviewedRevision, 'commit:current');
  assert.equal(evidence.complete, true);
  assert.equal(evidence.error, null);
});

test('accepts approved_by as waiver provenance', () => {
  const root = temporaryRoot();
  write(
    root,
    'docs/qa/gates/4.7.yml',
    `story: '4.7'
gate: WAIVED
reviewer: Quinn
reviewed_revision: commit:waived
waiver:
  active: true
  reason: Owner-approved exclusion
  approved_by: Project owner
`,
  );

  const evidence = resolveQaEvidence(incompleteStoryMeta('4.7', 'WAIVED'), { cwd: root });
  assert.equal(evidence.verdict, 'WAIVED');
  assert.equal(evidence.waiver.approver, 'Project owner');
  assert.equal(evidence.complete, true);
  assert.equal(evidence.error, null);
});

test('recognizes Spanish QA markers and revision provenance', () => {
  const evidence = extractQaEvidence(`## QA Results

### Revisión final

**Veredicto: PASS.**
**Revisor:** Quinn
**Revisión revisada:** \`commit:abc123\`
`);

  assert.equal(evidence.verdict, 'PASS');
  assert.equal(evidence.reviewer, 'Quinn');
  assert.equal(evidence.reviewedRevision, 'commit:abc123');
  assert.equal(evidence.complete, true);
});

test('recognizes a plain verdict beneath Gate Status', () => {
  const evidence = extractQaEvidence(`## QA Results

### Reviewed By: Quinn

### Reviewed Revision: commit:plain

### Gate Status

PASS — all criteria covered.
`);

  assert.equal(evidence.verdict, 'PASS');
  assert.equal(evidence.complete, true);
});

test('ignores noncanonical duplicate gate filenames', () => {
  const root = temporaryRoot();
  const gate = `story: '1.8'
gate: PASS
reviewer: Quinn
reviewed_revision: commit:current
`;
  write(root, 'docs/qa/gates/1.8-canonical.yml', gate);
  write(root, 'docs/qa/gates/1.8-canonical (1).yml', gate.replace('PASS', 'CONCERNS'));

  const evidence = resolveQaEvidence(incompleteStoryMeta('1.8', 'PASS'), { cwd: root });
  assert.equal(evidence.verdict, 'PASS');
  assert.equal(evidence.complete, true);
  assert.equal(evidence.error, null);
});

test('treats Superseded as an explicit closed lifecycle status', () => {
  const root = temporaryRoot();
  const story = write(
    root,
    'docs/stories/6.12.superseded.md',
    `# Story 6.12: Superseded example

## Status

**Superseded** (closed before implementation)

## File List

- \`docs/stories/6.12.superseded.md\`

## QA Results

**Veredicto: PASS.**
**Revisor:** Quinn
**Revisión revisada:** \`commit:successor\`
`,
  );

  assert.equal(normalizeStatus('Superseded (closed before implementation)'), 'Superseded');
  assert.equal(verifyPhase(story, 'close', { cwd: root }).ok, true);
});

test('fails closed when story and gate verdicts differ', () => {
  const root = temporaryRoot();
  write(
    root,
    'docs/qa/gates/5.7.yml',
    `story: '5.7'
gate: PASS
reviewer: Quinn
reviewed_revision: commit:current
`,
  );

  const evidence = resolveQaEvidence(incompleteStoryMeta('5.7', 'CONCERNS'), { cwd: root });
  assert.equal(evidence.complete, false);
  assert.match(evidence.error, /does not match story verdict/);
});

test('fails closed when reviewed revision is absent', () => {
  const root = temporaryRoot();
  write(
    root,
    'docs/qa/gates/4.2.yml',
    `story: '4.2'
gate: PASS
reviewer: Quinn
`,
  );

  const evidence = resolveQaEvidence(incompleteStoryMeta('4.2', 'PASS'), { cwd: root });
  assert.equal(evidence.complete, false);
  assert.match(evidence.error, /lacks reviewer or reviewed_revision/);
});

test('ignores verdict provenance outside QA Results', () => {
  const evidence = extractQaEvidence(`## Dev Notes

Gate: PASS
Reviewed By: Quinn
Reviewed Revision: commit:not-qa

## QA Results

Pending review.
`);

  assert.equal(evidence.verdict, null);
  assert.equal(evidence.complete, false);
});

test('recognizes an architectural gate inside QA Results', () => {
  const evidence = extractQaEvidence(`## QA Results

Gate arquitectónico: **PASS**
Reviewed By: Aria
Reviewed Revision: commit:architecture
`);

  assert.equal(evidence.verdict, 'PASS');
  assert.equal(evidence.complete, true);
});

test('keeps provenance when gate syntax matches overlapping verdict patterns', () => {
  const evidence = extractQaEvidence(`## QA Results

### Review Date: 2026-09-03

### Reviewed By: Quinn

### Reviewed Revision: commit:overlap

### Gate Status

Gate: PASS
`);

  assert.equal(evidence.verdict, 'PASS');
  assert.equal(evidence.reviewer, 'Quinn');
  assert.equal(evidence.reviewedRevision, 'commit:overlap');
  assert.equal(evidence.complete, true);
});
