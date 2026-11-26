// chrome-shim.js — ごまブラウザ Chrome拡張互換レイヤー (v1)
// 注入前にネイティブ側が先頭へ以下を差し込む:
//   window.__GOMA_EXT_ID__ = "<extId>";
//   window.__GOMA_CONTEXT__ = "content" | "background" | "popup";
//   window.__GOMA_TAB_ID__ = <number|null>;
// ワールド: content script は WKContentWorld.page（ページ本体）で実行する。
// 理由: ごま動画セーバーは YouTube の player API を「ページ内スクリプト」から
// 叩く設計が必須だった（拡張オリジンから叩くと Google にブロックされる）。
(function () {
  "use strict";
  if (window.__gomaShimInstalled) return;
  window.__gomaShimInstalled = true;

  var EXT_ID = window.__GOMA_EXT_ID__ || "unknown";
  var CONTEXT = window.__GOMA_CONTEXT__ || "content";
  var TAB_ID = (typeof window.__GOMA_TAB_ID__ === "number") ? window.__GOMA_TAB_ID__ : null;

  var callbackSeq = 0;
  var pending = {}; // callbackId -> function(result, errorMessage)
  var runtimeListeners = [];
  var downloadChangedListeners = [];
  var messageSenders = {}; // not used externally

  function bridge() {
    return window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.gomaBridge;
  }

  // ネイティブへ非同期リクエストを送り、Promise を返す
  function callNative(api, method, args) {
    return new Promise(function (resolve, reject) {
      var b = bridge();
      if (!b) { reject(new Error("goma bridge unavailable")); return; }
      var callbackId = "cb" + (++callbackSeq) + "_" + Date.now();
      pending[callbackId] = function (result, errorMessage) {
        if (errorMessage) {
          chrome.runtime.lastError = { message: errorMessage };
          reject(new Error(errorMessage));
        } else {
          chrome.runtime.lastError = null;
          resolve(result);
        }
        // lastError はコールバック実行直後にクリアされる Chrome の挙動に寄せる
        setTimeout(function () { chrome.runtime.lastError = null; }, 0);
      };
      b.postMessage({
        extId: EXT_ID, context: CONTEXT, tabId: TAB_ID,
        api: api, method: method, args: args || {}, callbackId: callbackId
      });
    });
  }

  // Chrome 形式: callback があれば callback 方式、なければ Promise を返す (MV3)
  function withCallback(promise, callback) {
    if (typeof callback === "function") {
      promise.then(function (r) { callback(r); }, function () { callback(undefined); });
      return undefined;
    }
    return promise;
  }

  // ネイティブからの応答 (Swift が evaluateJavaScript で呼ぶ)
  window.__gomaResolve = function (callbackId, result, errorMessage) {
    var fn = pending[callbackId];
    if (!fn) return;
    delete pending[callbackId];
    fn(result, errorMessage || null);
  };

  // ネイティブからのメッセージ配送 (runtime.onMessage / tabs.sendMessage の着信)
  // message, sender を渡し、sendResponse / return true (非同期) に対応する
  window.__gomaDeliverMessage = function (message, sender, responseCallbackId) {
    var responded = false;
    function sendResponse(value) {
      if (responded) return;
      responded = true;
      var b = bridge();
      if (b && responseCallbackId) {
        b.postMessage({
          extId: EXT_ID, context: CONTEXT, tabId: TAB_ID,
          api: "runtime", method: "__messageResponse",
          args: { value: value === undefined ? null : value },
          callbackId: responseCallbackId
        });
      }
    }
    var keepOpen = false;
    runtimeListeners.slice().forEach(function (fn) {
      try {
        var ret = fn(message, sender || { id: EXT_ID }, sendResponse);
        if (ret === true) keepOpen = true;
        if (ret && typeof ret.then === "function") {
          keepOpen = true;
          ret.then(sendResponse, function () { sendResponse(undefined); });
        }
      } catch (e) { /* listener error is swallowed like Chrome */ }
    });
    if (!keepOpen && !responded && responseCallbackId) {
      // 誰も応答しない場合は undefined で即時クローズ
      sendResponse(undefined);
    }
  };

  // ネイティブからの downloads.onChanged 配送
  window.__gomaDownloadsChanged = function (delta) {
    downloadChangedListeners.slice().forEach(function (fn) {
      try { fn(delta); } catch (e) {}
    });
  };

  var chrome = window.chrome || {};
  window.chrome = chrome;

  chrome.runtime = chrome.runtime || {};
  chrome.runtime.id = EXT_ID;
  chrome.runtime.lastError = null;
  chrome.runtime.getURL = function (path) {
    // 拡張内リソースはカスタムスキーム goma-ext://<extId>/<path> で表す。
    // ネイティブ側 WKURLSchemeHandler が実ファイルを返す。
    return "goma-ext://" + EXT_ID + "/" + String(path || "").replace(/^\//, "");
  };
  chrome.runtime.getManifest = function () { return window.__GOMA_MANIFEST__ || {}; };
  chrome.runtime.sendMessage = function (message, callback) {
    // content/popup -> background へ。background 自身からの送信は他文脈へブロードキャスト。
    var p = callNative("runtime", "sendMessage", { message: message });
    return withCallback(p.then(function (r) { return r ? r.value : undefined; }), callback);
  };
  chrome.runtime.onMessage = {
    addListener: function (fn) { if (runtimeListeners.indexOf(fn) < 0) runtimeListeners.push(fn); },
    removeListener: function (fn) {
      var i = runtimeListeners.indexOf(fn); if (i >= 0) runtimeListeners.splice(i, 1);
    },
    hasListener: function (fn) { return runtimeListeners.indexOf(fn) >= 0; }
  };
  chrome.runtime.onInstalled = { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } };
  chrome.runtime.getBackgroundPage = function (cb) { if (cb) cb(null); };

  chrome.tabs = chrome.tabs || {};
  chrome.tabs.query = function (queryInfo, callback) {
    var p = callNative("tabs", "query", { query: queryInfo || {} });
    return withCallback(p.then(function (r) { return (r && r.tabs) || []; }), callback);
  };
  chrome.tabs.sendMessage = function (tabId, message, callback) {
    if (typeof callback === "undefined" && typeof arguments[2] === "function") callback = arguments[2];
    var p = callNative("tabs", "sendMessage", { targetTabId: tabId, message: message });
    return withCallback(p.then(function (r) { return r ? r.value : undefined; }), callback);
  };
  chrome.tabs.create = function (createProperties, callback) {
    var p = callNative("tabs", "create", { properties: createProperties || {} });
    return withCallback(p.then(function (r) { return r ? r.tab : undefined; }), callback);
  };
  chrome.tabs.get = function (tabId, callback) {
    var p = callNative("tabs", "get", { targetTabId: tabId });
    return withCallback(p.then(function (r) { return r ? r.tab : undefined; }), callback);
  };
  chrome.tabs.update = function (tabId, updateProperties, callback) {
    if (typeof updateProperties === "function") { callback = updateProperties; updateProperties = {}; }
    var p = callNative("tabs", "update", { targetTabId: tabId, properties: updateProperties || {} });
    return withCallback(p.then(function (r) { return r ? r.tab : undefined; }), callback);
  };

  chrome.downloads = chrome.downloads || {};
  chrome.downloads.download = function (options, callback) {
    var p = callNative("downloads", "download", { options: options || {} });
    return withCallback(p.then(function (r) {
      if (r && typeof r.downloadId === "number") return r.downloadId;
      throw new Error((r && r.error) || "download failed");
    }), callback);
  };
  chrome.downloads.search = function (query, callback) {
    var p = callNative("downloads", "search", { query: query || {} });
    return withCallback(p.then(function (r) { return (r && r.items) || []; }), callback);
  };
  chrome.downloads.onChanged = {
    addListener: function (fn) { if (downloadChangedListeners.indexOf(fn) < 0) downloadChangedListeners.push(fn); },
    removeListener: function (fn) {
      var i = downloadChangedListeners.indexOf(fn); if (i >= 0) downloadChangedListeners.splice(i, 1);
    },
    hasListener: function (fn) { return downloadChangedListeners.indexOf(fn) >= 0; }
  };
  // v1 未対応スタブ（呼ばれても例外にしない）
  chrome.downloads.pause = function (id, cb) { if (cb) cb(); };
  chrome.downloads.resume = function (id, cb) { if (cb) cb(); };
  chrome.downloads.cancel = function (id, cb) { if (cb) cb(); };
  chrome.downloads.erase = function (q, cb) { if (cb) cb([]); };

  function storageArea() {
    return {
      get: function (keys, callback) {
        var p = callNative("storage", "get", { keys: keys === undefined ? null : keys });
        return withCallback(p.then(function (r) { return (r && r.values) || {}; }), callback);
      },
      set: function (items, callback) {
        var p = callNative("storage", "set", { items: items || {} });
        return withCallback(p.then(function () { return undefined; }), callback);
      },
      remove: function (keys, callback) {
        var p = callNative("storage", "remove", { keys: keys });
        return withCallback(p.then(function () { return undefined; }), callback);
      },
      clear: function (callback) {
        var p = callNative("storage", "clear", {});
        return withCallback(p.then(function () { return undefined; }), callback);
      }
    };
  }
  chrome.storage = chrome.storage || {};
  chrome.storage.local = storageArea();
  chrome.storage.sync = storageArea(); // v1: sync は local と同一扱い
  chrome.storage.onChanged = { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } };

  chrome.scripting = chrome.scripting || {};
  chrome.scripting.executeScript = function (injection, callback) {
    var p = callNative("scripting", "executeScript", { injection: injection || {} });
    return withCallback(p.then(function (r) { return (r && r.results) || []; }), callback);
  };

  chrome.action = chrome.action || {};
  chrome.action.setBadgeText = function (details, cb) { if (cb) cb(); };
  chrome.action.setTitle = function (details, cb) { if (cb) cb(); };
  chrome.action.onClicked = { addListener: function () {}, removeListener: function () {}, hasListener: function () { return false; } };

  // 未対応 API は存在だけさせず、undefined のままにする（拡張側の feature detection を壊さないため）
  // webRequest / declarativeNetRequest は v1 未対応（README 参照）。
})();
