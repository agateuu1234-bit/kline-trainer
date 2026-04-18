#!/usr/bin/env node
// verify-codex-tree.mjs
// Usage: node verify-codex-tree.mjs <pin.json> <plugin-root>
// Verifies files listed in pin.json.codex_plugin_cc.file_tree match sha256 under plugin-root.
// Supports legacy flat pin.file_tree for backward compat.
import { readFileSync } from 'fs';
import { createHash } from 'crypto';
import { resolve } from 'path';

const [, , pinPath, pkgRoot] = process.argv;
if (!pinPath || !pkgRoot) {
  console.error('Usage: node verify-codex-tree.mjs <pin.json> <plugin-root>');
  process.exit(2);
}

const pin = JSON.parse(readFileSync(pinPath, 'utf-8'));
const tree = (pin.codex_plugin_cc && pin.codex_plugin_cc.file_tree) || pin.file_tree || {};
if (Object.keys(tree).length === 0) {
  console.error('FAIL: no file_tree found in pin (checked codex_plugin_cc.file_tree and legacy file_tree)');
  process.exit(1);
}

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
