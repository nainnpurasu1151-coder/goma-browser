// ごま動画セーバー v2 (background)
// コンテントスクリプトから受け取ったURLをダウンロードする。複数同時OK。
// ダウンロードの状態変化を YouTube タブへ知らせて、ページ内のパネルに表示させる。
"use strict";

var titles = {}; // downloadId -> title

function broadcast(msg) {
  chrome.tabs.query({ url: "https://www.youtube.com/*" }, function (tabs) {
    (tabs || []).forEach(function (t) {
      try {
        chrome.tabs.sendMessage(t.id, msg, function () { void chrome.runtime.lastError; });
      } catch (e) {}
    });
  });
}

chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
  if (!msg || msg.type !== "goma-download") return;
  var filename = (msg.filename || "video.mp4").replace(/[\\/:*?"<>|]/g, "_").slice(0, 120);
  chrome.downloads.download(
    { url: msg.url, filename: filename, saveAs: false, conflictAction: "uniquify" },
    function (downloadId) {
      if (chrome.runtime.lastError) {
        sendResponse({ ok: false, error: chrome.runtime.lastError.message });
      } else {
        titles[downloadId] = msg.title || filename;
        broadcast({ type: "goma-dl-state", downloadId: downloadId, title: titles[downloadId], state: "started" });
        sendResponse({ ok: true, downloadId: downloadId });
      }
    }
  );
  return true;
});

chrome.downloads.onChanged.addListener(function (delta) {
  if (!delta || !delta.state || !delta.state.current) return;
  var st = delta.state.current; // complete / interrupted
  if (st !== "complete" && st !== "interrupted") return;
  var title = titles[delta.id];
  if (!title) {
    chrome.downloads.search({ id: delta.id }, function (items) {
      var it = items && items[0];
      var t = it ? (it.filename || "").split(/[\\/]/).pop() : "動画";
      broadcast({ type: "goma-dl-state", downloadId: delta.id, title: t, state: st, error: delta.error ? delta.error.current : null });
    });
  } else {
    broadcast({ type: "goma-dl-state", downloadId: delta.id, title: title, state: st, error: delta.error ? delta.error.current : null });
  }
  if (st === "complete") delete titles[delta.id];
});

// 進行中ダウンロードの％を定期的にパネルへ送る
setInterval(function () {
  chrome.downloads.search({ state: "in_progress" }, function (items) {
    (items || []).forEach(function (it) {
      if (it.totalBytes > 0) {
        broadcast({
          type: "goma-dl-state",
          downloadId: it.id,
          title: titles[it.id] || (it.filename || "").split(/[\\/]/).pop() || "動画",
          state: "progress",
          percent: Math.floor((it.bytesReceived / it.totalBytes) * 100)
        });
      }
    });
  });
}, 2500);
