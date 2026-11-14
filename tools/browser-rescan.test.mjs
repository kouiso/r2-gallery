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

// 動画1本につき v と d の2件を積むので、101本以上で受信側の上限（200件）を超える。
// 超えた分は seen に記録済みのため二度と届かない。何本でも全件が上限以下の通知に分かれて届くこと
function videoPage(count) {
  const videos = Array.from({ length: count }, (_, i) => ({
    readyState: 1,
    duration: 60 + i,
    poster: "",
    currentSrc: `https://fixture.example/v${i}.mp4`,
    getAttribute: () => "",
    querySelectorAll: () => [],
    addEventListener() {},
  }));
  const timers = [];
  const messages = [];
  const window = {};
  runInNewContext(hook, {
    window,
    document: {
      baseURI: "https://fixture.example/",
      documentElement: {},
      querySelectorAll: (kind) => (kind === "video" ? videos : []),
    },
    performance: { getEntriesByType: () => [] },
    URL,
    R2Sniff: { postMessage: (value) => messages.push(JSON.parse(value)) },
    setTimeout: (callback) => timers.push(callback),
    MutationObserver: class {
      observe() {}
    },
  });
  return {
    window,
    messages,
    flush: () => {
      while (timers.length) timers.shift()();
    },
  };
}

describe("browser hook message size", () => {
  for (const count of [100, 120, 150, 450]) {
    it(`delivers every candidate of ${count} videos in slices the receiver reads fully`, () => {
      const p = videoPage(count);
      p.flush();
      expect(p.messages.every((m) => m.length <= 200)).toBe(true);
      const urls = new Set(
        p.messages
          .flat()
          .filter((e) => e[0] === "v")
          .map((e) => e[1]),
      );
      expect(urls.size).toBe(count);
      const durs = new Set(
        p.messages
          .flat()
          .filter((e) => e[0] === "d")
          .map((e) => e[1]),
      );
      expect(durs.size).toBe(count);
    });
  }

  it("keeps manual rescan results whole so the receiver can slice them", () => {
    const p = videoPage(150);
    const all = JSON.parse(p.window.__r2rescan());
    expect(all).toHaveLength(300);
  });
});
