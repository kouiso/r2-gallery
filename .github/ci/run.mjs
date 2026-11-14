import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const check = [['pnpm', ['lint']], ['pnpm', ['worker:typecheck']]];
const tests = [['pnpm', ['test']]];
const scan = [['bash', ['.github/ci/gitleaks.sh']]];
const hygiene = [[process.execPath, ['tools/leak-check.mjs']]];
const fast = [...check, ...tests, ...scan, ...hygiene];
// Flutter クライアントのビルド検証は署名鍵を持つ別の運用リポジトリの r2-flutter-build レーンが受け持つ。
const phases = { check, test: tests, gitleaks: scan, hygiene, secrets: [...scan, ...hygiene], fast, full: fast };
const phase = process.argv[2] ?? 'fast';
if (!Object.hasOwn(phases, phase)) {
  console.error(`Unknown CI phase: ${phase}`);
  process.exit(2);
}
for (const [command, args, relative = '.'] of phases[phase]) {
  const result = spawnSync(command, args, { cwd: path.join(root, relative), stdio: 'inherit', shell: process.platform === 'win32' });
  if (result.error) console.error(result.error.message);
  if (result.status !== 0) process.exit(result.status ?? 1);
}
