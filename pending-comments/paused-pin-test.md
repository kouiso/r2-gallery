head fd15d686ee0bdc627e9528a4388fd151d8873665 (pushed fix/pin-test-isolate-timing; compute injectable via PinLock.computeImpl, test uses pending fake compute; mutant with sync hash fails the test)
root cause: test bug not product — wall-clock gap assertion; under load even a no-hash 2s delay shows 236-311ms gaps (OS starvation of UI thread); old test failed 4/11 under load
next: 30x run of new test under load, analyze/flutter test/pnpm/ci fast/sync-rules checks, write PR + LOCAL-CHECK drafts (not yet written)
