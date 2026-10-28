#!/usr/bin/env node
/**
 * Print an r2g:// pairing string for a worker endpoint + token.
 *
 * Usage:
 *   node tools/pairing-url.mjs <endpoint> <token> [--qr]
 *
 *   <endpoint>  https:// URL of the worker (subpaths allowed, no query,
 *               no embedded credentials)
 *   <token>     pairing token; only ever embedded in the URL fragment
 *   --qr        also print a terminal QR (needs optional qrcode-terminal)
 *
 * Validation mirrors the Flutter client's pairing parser — duplicated on purpose so this
 * stays a dependency-free plain Node script.
 */
import { parseArgs } from "node:util";

const { values, positionals } = parseArgs({
  options: { qr: { type: "boolean", default: false } },
  allowPositionals: true,
});

function fail(msg) {
  console.error(`error: ${msg}`);
  process.exit(1);
}

const [endpoint, token] = positionals;
if (!endpoint || !token) fail("usage: node tools/pairing-url.mjs <endpoint> <token> [--qr]");

let u;
try {
  u = new URL(endpoint.trim());
} catch {
  fail("endpoint is not a valid URL");
}
if (u.protocol !== "https:") fail("endpoint must be https://");
if (!u.hostname) fail("endpoint must have a host");
if (u.username || u.password) fail("endpoint must not embed credentials");
if (u.search || u.hash) fail("endpoint must not have a query or fragment");

const normalized = u.origin + u.pathname.replace(/\/+$/, "");
const pairing = `r2g://setup?e=${encodeURIComponent(normalized)}#${encodeURIComponent(token)}`;
console.log(pairing);

if (values.qr) {
  try {
    const { default: qr } = await import("qrcode-terminal");
    qr.generate(pairing, { small: true });
  } catch {
    console.error("hint: `pnpm add -D qrcode-terminal` enables --qr output (optional)");
  }
}
