import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { describe, expect, it } from "vitest";

const source = readFileSync("flutter/lib/src/ui/browser_surface.dart", "utf8");
const hook = source.match(/const _hookJs = r'''([\s\S]*?)''';/)[1];

function page() {
  const images = [{ currentSrc: "https://fixture.example/first.png" }];
  const timers = [];
  const messages = [];
  let changed;
  const window = {};
  const document = {
    baseURI: "https://fixture.example/",
    documentElement: {},
    querySelectorAll: (kind) => (kind === "img" ? images : []),
  };
  runInNewContext(hook, {
    window,
    document,
    performance: { getEntriesByType: () => [] },
    URL,
    R2Sniff: { postMessage: (value) => messages.push(JSON.parse(value)) },
    setTimeout: (callback) => timers.push(callback),
    MutationObserver: class {
      constructor(callback) {
        changed = callback;
      }
      observe() {}
    },
  });
  return {
    window,
    images,
    messages,
    change: () => changed(),
    flush: () => {
      while (timers.length) timers.shift()();
    },
  };
}

describe("browser manual rescan", () => {
  it("finds late media through the existing scanner without resending known URLs", () => {
    const p = page();
    p.flush();
    expect(p.messages).toEqual([[["p", "https://fixture.example/first.png"]]]);
    p.images.push({ src: "https://fixture.example/manual.png" });
    expect(JSON.parse(p.window.__r2rescan())).toEqual([
      ["p", "https://fixture.example/manual.png"],
    ]);
    expect(JSON.parse(p.window.__r2rescan())).toEqual([]);
    p.flush();
    expect(p.messages).toHaveLength(1);
  });

  it("drains pending automatic detections only once and preserves later automatic scans", () => {
    const p = page();
    expect(JSON.parse(p.window.__r2rescan())).toEqual([["p", "https://fixture.example/first.png"]]);
    p.flush();
    expect(p.messages).toEqual([]);
    p.images.push({ src: "https://fixture.example/automatic.png" });
    p.change();
    p.flush();
    expect(p.messages).toEqual([[["p", "https://fixture.example/automatic.png"]]]);
    expect(JSON.parse(p.window.__r2rescan())).toEqual([]);
  });

  it("distinguishes no results from a native JavaScript failure", () => {
    const p = page();
    p.flush();
    expect(JSON.parse(p.window.__r2rescan())).toEqual([]);
    p.images.forEach = () => {
      throw new Error("fixture failure");
    };
    expect(() => p.window.__r2rescan()).toThrow("media scan failed");
  });
});
