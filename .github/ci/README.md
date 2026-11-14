# Shared CI entry

Prepare Node 22.12+, pnpm 9.15.9 and the locked dependencies with
`pnpm install --frozen-lockfile`. Then use:

- `task ci:fast`: runs `node --test .github/ci/run.test.mjs` and then every phase below
  (`check`, `test`, `gitleaks`, `hygiene`).

`node .github/ci/run.mjs <phase>` is the common entry used by the workflows. The phases are:

| Phase | Runs | Workflow job |
|---|---|---|
| `check` | `pnpm lint` and `pnpm worker:typecheck` | `check` |
| `test` | `pnpm test` (vitest for tools, then the worker under miniflare) | `test` |
| `gitleaks` | `.github/ci/gitleaks.sh` | `secrets-scan` |
| `hygiene` | `tools/leak-check.mjs` | `secrets-scan` |
| `secrets` | `gitleaks` then `hygiene` | - |
| `fast` | `check`, `test`, `gitleaks`, `hygiene` | - |
| `full` | same as `fast` (kept as an alias) | - |

A failure stops local execution and preserves its exit code. Independent cloud jobs retain
their existing conditions, timeouts and cancellation settings.

This entry does not build the Flutter client. `flutter pub get`, `flutter test`,
`flutter build apk --release` and `flutter build web` run in the operator-managed
`r2-flutter-build` lane (a separate build repository that holds the signing key). See the repository
`CLAUDE.md` for the app commands.

For local security checks, install gitleaks 8.24.3 on PATH. The cloud fallback
still downloads its pinned version into `RUNNER_TEMP` if absent. No absent-tool
case is treated as a passing scan: without gitleaks and `RUNNER_TEMP`, the entry stops at the
`gitleaks` phase. With no `CI_SCAN_BASE`, gitleaks scans all local refs (not only the current branch)
with their full history. Set `CI_SCAN_BASE` and `CI_SCAN_HEAD` to reproduce the workflow's
base-parent-to-head range. Its redaction flags and finding exit code 2 are
preserved. Supply the existing `QN_FORBIDDEN_WORDS` or `QN_FORBIDDEN_WORDS_FILE`
input for the hygiene word scan. The entry does not invent an empty word list
or put those values in command arguments.

`node --test .github/ci/run.test.mjs` runs the actual CLI in temporary fixtures.
It verifies complete command routing and failure propagation. Fixture results
do not prove an actual app build, scan of real history or production deployment.
