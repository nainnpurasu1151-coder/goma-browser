"use strict";
// ごまブラウザ ローカル検証
// 1) JS 構文チェック (node --check 相当: new Function で parse)
// 2) 同梱拡張 manifest の解析と、拡張が使う chrome.* API の shim 対応チェック
// 3) URL パターンマッチのケーステスト (Swift版と同仕様)
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const { matchPattern } = require("./match-pattern");

const root = path.join(__dirname, "..");
const extDir = path.join(root, "GomaBrowser/GomaBrowser/Resources/Extensions/goma-video-saver");
const shimPath = path.join(root, "GomaBrowser/GomaBrowser/Resources/chrome-shim.js");
let pass = 0, fail = 0;
function ok(cond, label) {
  if (cond) { pass++; console.log("  PASS " + label); }
  else { fail++; console.log("  FAIL " + label); }
}

console.log("== 1) JS syntax check ==");
const jsFiles = [
  shimPath,
  path.join(extDir, "background.js"),
  path.join(extDir, "content.js"),
  path.join(extDir, "popup.js"),
  path.join(__dirname, "match-pattern.js"),
];
for (const f of jsFiles) {
  try {
    execFileSync(process.execPath, ["--check", f], { stdio: "pipe" });
    ok(true, path.basename(f));
  } catch (e) {
    ok(false, path.basename(f) + " -> " + String(e.stderr || e.message).slice(0, 200));
  }
}

console.log("== 2) manifest parse & API coverage ==");
const manifest = JSON.parse(fs.readFileSync(path.join(extDir, "manifest.json"), "utf8"));
ok(manifest.manifest_version === 3, "manifest_version === 3");
ok(manifest.background && manifest.background.service_worker === "background.js", "background.service_worker");
ok(manifest.action && manifest.action.default_popup === "popup.html", "action.default_popup");
ok(Array.isArray(manifest.content_scripts) && manifest.content_scripts.length === 1, "content_scripts x1");
const cs = manifest.content_scripts[0];
ok(cs.run_at === "document_idle", "run_at document_idle");
for (const f of [cs.js[0], manifest.background.service_worker, manifest.action.default_popup]) {
  ok(fs.existsSync(path.join(extDir, f)), "file exists: " + f);
}

// 拡張ソースが使う chrome.* を抽出し、shim に定義があるか確認
const shim = fs.readFileSync(shimPath, "utf8");
const sources = ["background.js", "content.js", "popup.js"].map((f) => fs.readFileSync(path.join(extDir, f), "utf8")).join("\n");
const used = new Set();
for (const m of sources.matchAll(/chrome\.([a-zA-Z]+)\.([a-zA-Z]+)/g)) used.add(m[1] + "." + m[2]);
console.log("  used APIs: " + [...used].sort().join(", "));
const shimDefs = {
  "runtime.sendMessage": "chrome.runtime.sendMessage =",
  "runtime.onMessage": "chrome.runtime.onMessage =",
  "runtime.lastError": "chrome.runtime.lastError",
  "runtime.getURL": "chrome.runtime.getURL =",
  "runtime.id": "chrome.runtime.id =",
  "tabs.query": "chrome.tabs.query =",
  "tabs.sendMessage": "chrome.tabs.sendMessage =",
  "tabs.create": "chrome.tabs.create =",
  "downloads.download": "chrome.downloads.download =",
  "downloads.onChanged": "chrome.downloads.onChanged =",
  "downloads.search": "chrome.downloads.search =",
  "storage.local": "chrome.storage.local",
  "scripting.executeScript": "chrome.scripting.executeScript =",
};
for (const api of used) {
  if (api === "runtime.lastError") { ok(shim.includes("lastError"), "shim covers chrome." + api); continue; }
  const marker = shimDefs[api];
  ok(!!marker && shim.includes(marker), "shim covers chrome." + api + (marker ? "" : " (no marker defined)"));
}
// setInterval (background の進捗ポーリング) は通常の WebView JS で動く前提
ok(sources.includes("setInterval"), "background uses setInterval (WebView JS timer)");

console.log("== 3) URL match patterns ==");
const cases = [
  ["https://www.youtube.com/*", "https://www.youtube.com/watch?v=abc", true],
  ["https://www.youtube.com/*", "https://www.youtube.com/", true],
  ["https://www.youtube.com/*", "https://www.youtube.com/@channel/videos", true],
  ["https://www.youtube.com/*", "https://m.youtube.com/watch?v=abc", false],
  ["https://www.youtube.com/*", "http://www.youtube.com/watch?v=abc", false],
  ["https://www.youtube.com/*", "https://www.youtube.com.evil.example/", false],
  ["https://*.googlevideo.com/*", "https://rr1---sn-abc.googlevideo.com/videoplayback?x=1", true],
  ["https://*.googlevideo.com/*", "https://googlevideo.com/videoplayback", true],
  ["https://*.googlevideo.com/*", "https://notgooglevideo.com/", false],
  ["*://*.example.com/*", "http://a.example.com/x", true],
  ["*://*.example.com/*", "ftp://a.example.com/x", false],
  ["<all_urls>", "https://anything.example/path", true],
  ["https://www.youtube.com/watch*", "https://www.youtube.com/watch?v=1", true],
  ["https://www.youtube.com/watch*", "https://www.youtube.com/feed", false],
];
for (const [pat, url, expected] of cases) {
  const got = matchPattern(pat, url);
  ok(got === expected, `${pat}  vs  ${url}  => ${got} (expected ${expected})`);
}

console.log(`\nRESULT: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
