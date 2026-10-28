#!/usr/bin/env node
// Generates per-AI entry points from the canonical sources:
//   AGENTS.md            -> CLAUDE.md, GEMINI.md, .github/copilot-instructions.md,
//                         .cursor/rules/r2-gallery.mdc
//   .agents/skills/*     -> .claude/skills/<name>/SKILL.md stubs (canonical stays in .agents)
// Usage:
//   node tools/sync-ai-rules.mjs          write generated files (idempotent)
//   node tools/sync-ai-rules.mjs --check  exit 1 if any generated file is stale
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const CHECK = process.argv.includes("--check");
const PROLOG =
  "<!-- AUTO-GENERATED from AGENTS.md / .agents/skills by tools/sync-ai-rules.mjs — DO NOT EDIT DIRECTLY -->";

const agents = readFileSync(join(ROOT, "AGENTS.md"), "utf8");

const targets = [
  ["CLAUDE.md", `${PROLOG}\n\n${agents}`],
  ["GEMINI.md", `${PROLOG}\n\n${agents}`],
  [".github/copilot-instructions.md", `${PROLOG}\n\n${agents}`],
  [
    ".cursor/rules/r2-gallery.mdc",
    `---\ndescription: r2-gallery workspace rules (canonical: AGENTS.md)\nalwaysApply: true\n---\n\n${PROLOG}\n\n${agents}`,
  ],
];

// .claude/skills/<name>/SKILL.md stubs point at the canonical skill.
const skillsDir = join(ROOT, ".agents/skills");
if (existsSync(skillsDir)) {
  for (const name of readdirSync(skillsDir)) {
    const canonical = join(skillsDir, name, "SKILL.md");
    if (!existsSync(canonical)) continue;
    const text = readFileSync(canonical, "utf8");
    const description = text.match(/^description:\s*(.+)$/m)?.[1]?.trim() ?? "";
    targets.push([
      `.claude/skills/${name}/SKILL.md`,
      `---\nname: ${name}\ndescription: ${description}\n---\n\n${PROLOG}\n\nCanonical source: \`.agents/skills/${name}/SKILL.md\` — read that file and follow it.\n`,
    ]);
  }
}

let stale = 0;
for (const [rel, content] of targets) {
  const path = join(ROOT, rel);
  if (existsSync(path) && readFileSync(path, "utf8") === content) continue;
  stale += 1;
  if (CHECK) {
    console.log(`stale: ${rel}`);
    continue;
  }
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
  console.log(`wrote: ${rel}`);
}
if (CHECK && stale > 0) {
  console.error(`\n${stale} generated file(s) out of date — run tools/sync-ai-rules.mjs`);
  process.exit(1);
}
if (!stale) console.log("AI rule files already in sync");
