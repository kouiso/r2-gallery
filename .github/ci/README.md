# Shared CI entry

Prepare Node 22.12+, pnpm 9.15.9 and the locked dependencies with
`pnpm install --frozen-lockfile`. Then use:

- `task ci:fast`: the cloud `check`, `test` and `secrets-scan` commands.
- `task ci`: those commands plus the KMP debug variant.
- `task ci:kmp`: the KMP native variant.

`node .github/ci/run.mjs <phase>` is the common entry used by the workflows.
The web build uses `pnpm exec vite build`. KMP runs
`:composeApp:testDebugUnitTest :composeApp:assembleDebug` from `kmp/`. A failure
stops local execution and preserves its exit code. Independent cloud jobs retain
their existing conditions, timeouts and cancellation settings.

Native checks need the same Java 21, Android 36 platform and build-tools 36.1.0
as CI. The entry does not install an SDK, change Gradle memory settings or change
`GRADLE_USER_HOME`. KMP keeps the existing `R2_BAKED_ENDPOINT`, `R2_BAKED_TOKEN`
and `R2_DEBUG_KEYSTORE` inputs. For a pinned local key, supply its path through
`R2_DEBUG_KEYSTORE`. CI still performs its existing strict secret decode before
calling the entry. Signing, artifact upload and release/distribution behavior
remain in their existing scripts/workflow steps.

For local security checks, install gitleaks 8.24.3 on PATH. The cloud fallback
still downloads its pinned version into `RUNNER_TEMP` if absent. No absent-tool
case is treated as a passing scan. With no `CI_SCAN_BASE`, gitleaks scans the
full history. Set `CI_SCAN_BASE` and `CI_SCAN_HEAD` to reproduce the workflow's
base-parent-to-head range. Its redaction flags and finding exit code 2 are
preserved. Supply the existing `QN_FORBIDDEN_WORDS` or `QN_FORBIDDEN_WORDS_FILE`
input for the hygiene word scan. The entry does not invent an empty word list
or put those values in command arguments.

`node --test .github/ci/run.test.mjs` runs the actual CLI in temporary fixtures.
It verifies complete command routing and failure propagation. Fixture results
do not prove an actual app build, SDK installation, scan of real history or
production deployment.
