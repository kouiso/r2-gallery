import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
function fixture(t) {
  const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'r2-ci-entry-')));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const dir of ['.github/ci', 'bin', 'tools']) mkdirSync(path.join(root, dir), { recursive: true });
  for (const file of ['run.mjs', 'gitleaks.sh']) {
    assert.ok(existsSync(path.join(repository, '.github/ci', file)), `shared ${file} must exist`);
    copyFileSync(path.join(repository, '.github/ci', file), path.join(root, '.github/ci', file));
  }
  const mock = `#!${process.execPath}
const fs=require('node:fs'),path=require('node:path');
const name=path.basename(process.argv[1]),args=process.argv.slice(2);
fs.appendFileSync(process.env.CALLS,JSON.stringify({name,args,cwd:process.cwd(),wordPresent:!!process.env.QN_FORBIDDEN_WORDS})+'\\n');
if(process.env.FAIL_AT && (name+' '+args.join(' ')).includes(process.env.FAIL_AT))process.exit(Number(process.env.FAIL_CODE||37));
`;
  for (const file of ['bin/pnpm', 'bin/gitleaks', 'tools/leak-check.mjs']) writeFileSync(path.join(root, file), file.endsWith('.mjs') ? mock.replace("const fs=require('node:fs'),path=require('node:path');", "import fs from 'node:fs'; import path from 'node:path';") : mock, { mode: 0o755 });
  writeFileSync(path.join(root, 'package.json'), JSON.stringify({ scripts: JSON.parse(readFileSync(path.join(repository, 'package.json'), 'utf8')).scripts }));
  const log = path.join(root, 'calls.jsonl');
  return {
    root,
    run(phase, extra = {}) {
      const env = { ...process.env, PATH: `${root}/bin${path.delimiter}${process.env.PATH}`, CALLS: log };
      for (const key of ['FAIL_AT', 'FAIL_CODE', 'CI_SCAN_BASE', 'CI_SCAN_HEAD', 'QN_FORBIDDEN_WORDS']) delete env[key];
      return spawnSync(process.execPath, [path.join(root, '.github/ci/run.mjs'), phase], { env: { ...env, ...extra }, encoding: 'utf8' });
    },
    calls() { return existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : []; },
  };
}

test('full executes lint, worker typecheck, tests and security checks exactly once', t => {
  const f = fixture(t), result = f.run('full');
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(f.calls().map(x => [x.name, x.args]), [
    ['pnpm', ['lint']], ['pnpm', ['worker:typecheck']],
    ['pnpm', ['test']],
    ['gitleaks', ['detect', '--redact', '-v', '--exit-code=2', '--source', '.', '--log-level=warn']],
    ['leak-check.mjs', []],
  ]);
  assert.ok(f.calls().every(x => x.cwd === f.root));
});

test('fast runs the same command families as full', t => {
  const f = fixture(t);
  assert.equal(f.run('fast').status, 0);
  assert.equal(f.calls().length, 5);
});

test('each command failure propagates its exit code and stops later phases', t => {
  for (const [failure, count] of [['pnpm lint', 1], ['pnpm worker:typecheck', 2], ['pnpm test', 3], ['gitleaks', 4], ['leak-check.mjs', 5]]) {
    const f = fixture(t);
    assert.equal(f.run('full', { FAIL_AT: failure }).status, 37, failure);
    assert.equal(f.calls().length, count, failure);
  }
});

test('incremental secret scan preserves exact original base-parent to head scope', t => {
  const f = fixture(t);
  assert.equal(f.run('secrets', { CI_SCAN_BASE: 'abc123', CI_SCAN_HEAD: 'def456' }).status, 0);
  assert.equal(f.calls()[0].args.at(-1), '--log-opts=--no-merges --first-parent abc123^..def456');
});

test('initial push uses full history and scan findings retain exit 2', t => {
  const f = fixture(t);
  assert.equal(f.run('secrets', { CI_SCAN_BASE: '0000000000000000000000000000000000000000', FAIL_AT: 'gitleaks', FAIL_CODE: '2' }).status, 2);
  assert.equal(f.calls().length, 1);
  assert.equal(f.calls()[0].args.some(x => x.startsWith('--log-opts=')), false);
});

test('hygiene keeps environment input without putting secret values in commands', t => {
  const f = fixture(t), inputs = { QN_FORBIDDEN_WORDS: 'private-fixture-word' };
  const result = f.run('full', inputs);
  assert.equal(result.status, 0);
  assert.equal(f.calls().at(-1).wordPresent, true);
  assert.equal(JSON.stringify(f.calls().map(x => x.args)).includes(inputs.QN_FORBIDDEN_WORDS), false);
  assert.equal((result.stdout + result.stderr).includes(inputs.QN_FORBIDDEN_WORDS), false);
});

test('unknown phase fails closed', t => {
  const f = fixture(t);
  assert.equal(f.run('invalid').status, 2);
  assert.equal(f.calls().length, 0);
});

test('worker typecheck and test failures still stop full checks', t => {
  for (const [failure, count] of [['pnpm worker:typecheck', 2], ['pnpm test', 3]]) {
    const f = fixture(t);
    writeFileSync(path.join(f.root, 'package.json'), '{}');
    assert.equal(f.run('full', { FAIL_AT: failure }).status, 37);
    assert.equal(f.calls().length, count);
  }
});
