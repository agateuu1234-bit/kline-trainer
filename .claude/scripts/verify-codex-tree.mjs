#!/usr/bin/env node
// verify-codex-tree.mjs
// Usage: node verify-codex-tree.mjs <pin.json> <package-root>
// Verifies every file listed in pin.json.file_tree matches sha256 under package-root.
import { readFileSync } from 'fs';
import { createHash } from 'crypto';
import { resolve } from 'path';

const [, , pinPath, pkgRoot] = process.argv;
if (!pinPath || !pkgRoot) {
  console.error('Usage: node verify-codex-tree.mjs <pin.json> <package-root>');
  process.exit(2);
}

const pin = JSON.parse(readFileSync(pinPath, 'utf-8'));
const tree = pin.file_tree || {};
let failed = 0;

for (const [rel, expected] of Object.entries(tree)) {
  const abs = resolve(pkgRoot, rel);
  try {
    const buf = readFileSync(abs);
    const actual = 'sha256:' + createHash('sha256').update(buf).digest('hex');
    if (actual !== expected) {
      console.error(`MISMATCH ${rel}: expected ${expected}, actual ${actual}`);
      failed++;
    }
  } catch (e) {
    console.error(`MISSING ${rel}: ${e.message}`);
    failed++;
  }
}

if (failed > 0) {
  console.error(`FAIL: ${failed} file(s) did not match pin`);
  process.exit(1);
}
console.log(`PASS: ${Object.keys(tree).length} file(s) match pin`);
process.exit(0);
