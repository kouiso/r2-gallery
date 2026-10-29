---
name: fad-invite
description: Use before adding, removing, or changing any tester in Firebase App Distribution (FAD) for this repo — an invite, a change to `ALLOWED_TESTERS` in `tools/app-distribute.sh`, or kouiso's message asking to invite or remove someone. Forces a one-person-at-a-time check of environment, app, OS, and person against kouiso's own message, an independent reviewer subagent, and a multiple-choice question whenever anything is short of 100% certain.
---

# fad-invite — invite testers exactly as kouiso said, one person at a time

## This repo

Repo: r2-gallery. Looked at: `tools/app-distribute.sh`, `tools/app-distribute.test.mjs`, `.agents/skills/fad-distribute/SKILL.md`.

| env | Firebase project | OS | app id | tester |
| --- | --- | --- | --- | --- |
| prod | `r2-gallery-c0ca` (no. 380147062326, the prefix of the app id) | Android only | `1:380147062326:android:5a77ec11925136089c2a97` (`app.r2gallery`) | `ALLOWED_TESTERS` in `tools/app-distribute.sh`: kouiso@ritmo.co.jp only; groups are refused |

`r2-gallery-c0ca` is the production project. Report the env as 本番 / prod, never `single`.

- There is no iOS app in FAD for this repo. Any request for iOS here is a mismatch: ask.
- Any other address is refused by the script on purpose (an incident on 2026-10-07 sent a build to someone else).
  Adding a person means kouiso's explicit message and a change to `ALLOWED_TESTERS` with its test, in a PR.

kouiso states invites precisely. Past failures came from the AI reading them loosely, not from his wording:
a tester was put on the stg (test) group as well as prod, opened the look-alike STG app, and got stuck
on a forced-update screen. Nobody could tell who added her. Do not ask kouiso to change how he writes.
The AI must read exactly.

## Iron rules

- Never add a person to an environment, project, OS, or group that kouiso's message does not name for
  **that person**. Env is YES only when he writes 本番 / prod, or stg / 検証版 / テスト版, for that person;
  otherwise it is `?` (unless "## This repo" lists only one env). stg only when he says stg.
- Never fill a gap by inference, by "the usual groups", by a previous roster, or by what another person
  in the same message got.
- One person = one check = one result line. A batch message is split into people before anything else.
  A sentence that names several people applies to each one named; words about someone else never do.
- "## This repo" (the mapping of env, project, OS, app id, group) is the only source for "which app / group".
  If a value there is `unknown`, ask; never guess it. A dimension with a single entry there (one env, one OS,
  one app) scores YES for that dimension without a question.
- No FAD write (console, API, CLI, workflow dispatch, roster edit) happens before step 4 passes for that person.

## Flow (per person, in order)

### 1. Copy the source

Quote kouiso's message into the work log (file or issue comment) with other people's tester addresses
masked (`t***@example.com`); the unredacted source stays in the chat. Locate it exactly (chat
timestamp / Slack link / issue comment URL). No paraphrase of his wording. If you cannot find his
message, stop and ask.

### 2. Split into one row per person

| # | person (name as he wrote it) | address (as he wrote it; if he pointed to a message, quote that message and its locator) | env: prod / stg | project (app) | OS: iOS / Android | action: add / remove | quote (his exact words for this person) |

Fill each cell **only** from his words for this person. Unknown = write `?`. Never leave a guess in a cell.

### 3. Score each row

For each of the four checks, write YES only if his quote for this person states it directly:

- **Env**: does he say 本番 / prod, or stg / 検証 / テスト版, for this person?
- **Project**: does he name an app listed in "## This repo" for this person (or is only one listed), and does it
  map to exactly one Firebase project + app id?
- **OS**: does he say iOS / iPhone or Android for this person? An app name alone does not decide the OS.
- **Person**: does the address match his text character for character (no two candidates, no address
  mix-up, no family/old address)? Before any write, record this row's pre-write state: whether the
  address is in `ALLOWED_TESTERS` and whether `appdistribution:testers:list` already has it. Write that
  record on the row for every row that reaches step 6, and show it in the step-5 question when step 5 runs.

Any NO or `?` → confidence < 100% → go to step 5 for that row. Do not proceed on "probably".

### 4. Independent review (mandatory, even at 100%)

Spawn a reviewer subagent that did not build the table (fresh context; on Claude use `opus`, on Codex or
another client use the strongest reasoning model available — never the context that built the table).
Give it only:
kouiso's verbatim message, the table, and this skill's Iron rules. Ask it to try to break each row:
"Find any cell not literally supported by the quote for that person. Answer per row: PASS or REJECT + reason."

- Any REJECT → that row goes to step 5. Do not argue the reviewer down; ask kouiso.
- All PASS → step 6.

### 5. Ask kouiso — multiple choice, impossible to misread

Use the client's multiple-choice question tool — AskUserQuestion on Claude Code, the equivalent
structured-choice prompt on Codex (never prose). One question per unclear check, per person (several in
one call is fine, never merged into one question). Offer only options that exist in "## This repo"
(this repo is Android-only — never offer iOS or 両方).
Options must be concrete and mutually exclusive, e.g.:

- "〇〇さん（xxx@example.com）を入れるのは？" → 「r2-gallery 本番 Android 版だけ」/「入れない」
- "「△△さん」はどのアドレス？" → each candidate address as its own option

Show the address so he can see it is the right person. Record his answer verbatim as the new source,
then redo steps 3–4 for that row.

### 6. Apply, then read back

Apply only the PASS rows, through this repo's route. This repo has two gates and no group route:

1. Allow-list: a PR that edits `ALLOWED_TESTERS` in `tools/app-distribute.sh` together with
   `tools/app-distribute.test.mjs` (the test pins the list). Merging is what authorises the address for
   future distributions.
2. FAD tester record: after the PR merges, add or remove the address on the app itself —
   `pnpm dlx firebase-tools appdistribution:testers:add|remove <addr> --app 1:380147062326:android:5a77ec11925136089c2a97`.

Removing an address from `ALLOWED_TESTERS` only stops future uploads reaching them; deleting their FAD
tester record (it drops their access to every release) is a separate action that needs its own question.

Then read the state back — `appdistribution:testers:list --app 1:380147062326:android:5a77ec11925136089c2a97`
shows the registered testers on the app — and report one line per person:

`✅ 名前 — r2-gallery — 本番 — Android — 追加/削除（FAD で確認済み）`

If neither gate could be applied, do not report a row as complete: say which gate is still open.
Rows still waiting on kouiso are listed as `⬜ 名前 — 確認待ち: <the one question>`.
Never say an invite is done or a tester's problem is solved until the read-back (and, for a problem,
the tester's own confirmation) shows it.

## Red flags — stop

- You are about to add someone to stg because "testers usually get both".
- Two people in one message got different treatment and you are copying one person's groups to the other.
- An address in the table does not appear in his message or in the reply he pointed to.
- The reviewer was skipped because the case "looked obvious".
