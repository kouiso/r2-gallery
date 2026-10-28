---
name: fad-invite
description: Use before adding, removing, or changing any tester in Firebase App Distribution (FAD) — inviting someone, adding to or removing from a tester group, editing a tester roster/workflow input, or acting on kouiso's message asking to invite people. Forces a one-person-at-a-time check of environment (prod/stg), project (app), OS (iOS/Android), and person against kouiso's own message, an independent reviewer subagent, and a multiple-choice question whenever anything is short of 100% certain.
---

# fad-invite — invite testers exactly as kouiso said, one person at a time

## This repo

Repo: r2-gallery. Looked at: `tools/app-distribute.sh`, `tools/app-distribute.test.mjs`, `.agents/skills/fad-distribute/SKILL.md`.

| env | Firebase project | OS | app id | tester |
| --- | --- | --- | --- | --- |
| single | `r2-gallery-c0ca` (no. 380147062326, the prefix of the app id) | Android only | `1:380147062326:android:5a77ec11925136089c2a97` (`app.r2gallery`) | `ALLOWED_TESTERS` in `tools/app-distribute.sh`: kouiso@ritmo.co.jp only; groups are refused |

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

Quote kouiso's message verbatim into the work log (file or issue comment). Locate it exactly (chat
timestamp / Slack link / issue comment URL). No paraphrase. If you cannot find his message, stop and ask.

### 2. Split into one row per person

| # | person (name as he wrote it) | address (as he wrote it; if he pointed to a message, quote that message and its locator) | env: prod / stg | project (app) | OS: iOS / Android | action: add / remove | quote (his exact words for this person) |

Fill each cell **only** from his words for this person. Unknown = write `?`. Never leave a guess in a cell.

### 3. Score each row

For each of the four checks, write YES only if his quote for this person states it directly:

- **Env**: does he say 本番 / prod, or stg / 検証 / テスト版, for this person?
- **Project**: does he name an app listed in "## This repo" for this person (or is only one listed), and does it
  map to exactly one Firebase project + app id?
- **OS**: does he say iOS / iPhone or Android for this person? An app name alone does not decide the OS.
- **Person**: does the address match his text character for character (no two candidates, no Android/iOS
  address mix-up, no family/old address)? Before any write, list every FAD group this address is in now and
  show that list in the step-5 question.

Any NO or `?` → confidence < 100% → go to step 5 for that row. Do not proceed on "probably".

### 4. Independent review (mandatory, even at 100%)

Spawn a reviewer subagent that did not build the table (fresh context, model opus). Give it only:
kouiso's verbatim message, the table, and this skill's Iron rules. Ask it to try to break each row:
"Find any cell not literally supported by the quote for that person. Answer per row: PASS or REJECT + reason."

- Any REJECT → that row goes to step 5. Do not argue the reviewer down; ask kouiso.
- All PASS → step 6.

### 5. Ask kouiso — multiple choice, impossible to misread

Use AskUserQuestion (never prose). One question per unclear check, per person (several in one call is fine,
never merged into one question). Offer only options that exist in "## This repo".
Options must be concrete and mutually exclusive, e.g.:

- "〇〇さん（xxx@example.com）を入れるのは？" → 「本番の <アプリ名> iPhone 版だけ」/「検証版の <アプリ名> iPhone 版だけ」/「両方」/「入れない」
- "〇〇さんは iPhone？Android？" → 「iPhone だけ」/「Android だけ」/「両方」
- "「△△さん」はどのアドレス？" → each candidate address as its own option

Show the address so he can see it is the right person. Record his answer verbatim as the new source,
then redo steps 3–4 for that row.

### 6. Apply, then read back

Apply only the PASS rows, through the repo's normal route (roster file + PR / the invite workflow).
"remove" means remove from the named group only; deleting the tester from the whole Firebase project
(it drops every app and group) needs its own question to him.
Then read the actual FAD state back (group membership per app/env, and which apps' releases each of those
groups receives; groups are per project, so a shared group can leak another env) and report one line per person:

`✅ 名前 — アプリ — 本番/検証 — iPhone/Android — 追加/削除（FAD で確認済み）`

Rows still waiting on kouiso are listed as `⬜ 名前 — 確認待ち: <the one question>`.
iOS ad hoc: group membership alone is not done; the device UDID must be in the profile of the build
distributed (otherwise the tester sees it but cannot install). Never say an invite is done or a tester's problem is solved until the read-back (and, for a problem,
the tester's own confirmation) shows it.

## Red flags — stop

- You are about to add someone to stg because "testers usually get both".
- Two people in one message got different treatment and you are copying one person's groups to the other.
- An address in the table does not appear in his message or in the reply he pointed to.
- The reviewer was skipped because the case "looked obvious".
