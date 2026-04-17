#!/usr/bin/env node
// Task 8 test: verify-codex-tree.mjs
import { execSync } from 'child_process';
import { writeFileSync, mkdtempSync, mkdirSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import { createHash } from 'crypto';

const tmp = mkdtempSync(join(tmpdir(), 'vct-'));
const pkgDir = join(tmp, 'pkg');
mkdirSync(pkgDir, { recursive: true });
writeFileSync(join(pkgDir, 'a.js'), 'content A');
writeFileSync(join(pkgDir, 'b.js'), 'content B');

const sha = (f) => 'sha256:' + createHash('sha256').update(execSync(`cat ${f}`)).digest('hex');

const pin = {
  package_name: 'test',
  version: '1.0.0',
  file_tree: {
    'a.js': sha(join(pkgDir, 'a.js')),
    'b.js': sha(join(pkgDir, 'b.js'))
  }
};
const pinFile = join(tmp, 'pin.json');
writeFileSync(pinFile, JSON.stringify(pin));

// Scenario 1: matching pin -> exit 0
try {
  execSync(`node .claude/scripts/verify-codex-tree.mjs ${pinFile} ${pkgDir}`, { stdio: 'pipe' });
  console.log('Test 1 PASS: matching pin -> exit 0');
} catch (e) {
  console.error('Test 1 FAIL: expected exit 0, got', e.status); process.exit(1);
}

// Scenario 2: tampered -> non-zero exit
writeFileSync(join(pkgDir, 'a.js'), 'TAMPERED');
let tamperedExitCode = null;
try {
  execSync(`node .claude/scripts/verify-codex-tree.mjs ${pinFile} ${pkgDir}`, { stdio: 'pipe' });
  tamperedExitCode = 0;
} catch (e) {
  tamperedExitCode = e.status;
}
if (tamperedExitCode === 0) {
  console.error('Test 2 FAIL: should have failed on tampered file');
  process.exit(1);
}
console.log('Test 2 PASS: tampered -> exit', tamperedExitCode);

console.log('ALL PASS');
