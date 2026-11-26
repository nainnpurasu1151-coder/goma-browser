// ごま動画セーバー v2.1 (content script)
// ・ページ内から player API を叩く（拡張オリジンだと Google にブロックされるため）
// ・チャンネル動画一覧などのページで「動画を選ぶ」モード：カードにチェックを付けて一括保存
// ・ポップアップ(GUI)からの「一覧取得」「まとめてダウンロード」にも応える
// ・ページ左下パネルに保存状況を表示する
(function () {
  "use strict";

  var CLIENTS = [
    {
      name: "ANDROID",
      key: "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w",
      body: function (id) {
        return {
          context: { client: { clientName: "ANDROID", clientVersion: "20.10.38", androidSdkVersion: 30, hl: "en", gl: "US" } },
          videoId: id,
          playbackContext: { contentPlaybackContext: { vis: 0, splay: false, signatureTimestamp: 20000 } },
          racyCheckOk: true,
          contentCheckOk: true
        };
      }
    },
    {
      name: "IOS",
      key: "AIzaSyB-1vPrdLhSz5YKrVqEaBzTrjoGVUsaXuI",
      body: function (id) {
        return {
          context: { client: { clientName: "IOS", clientVersion: "20.10.4", deviceMake: "Apple", deviceModel: "iPhone16,2", hl: "en", gl: "US", osName: "iPhone", osVersion: "18.3.2.22D82", utcOffsetMinutes: 540 } },
          videoId: id,
          playbackContext: { contentPlaybackContext: { vis: 0, splay: false, signatureTimestamp: 20000 } },
          racyCheckOk: true,
          contentCheckOk: true
        };
      }
    }
  ];

  var CARD_SELECTOR = "ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ytd-playlist-video-renderer, ytd-grid-video-renderer, ytd-radio-renderer, ytd-compact-radio-renderer, ytd-reel-item-renderer, yt-lockup-view-model";

  // ---------- 小物 ----------
  function toast(text) {
    var el = document.getElementById("goma-saver-toast");
    if (!el) {
      el = document.createElement("div");
      el.id = "goma-saver-toast";
      el.style.cssText = "position:fixed;left:50%;bottom:96px;transform:translateX(-50%);background:rgba(20,20,20,.94);color:#fff;padding:12px 18px;border-radius:10px;font-size:14px;z-index:2147483647;max-width:86vw;text-align:center;box-shadow:0 4px 18px rgba(0,0,0,.4);";
      document.documentElement.appendChild(el);
    }
    el.textContent = text;
    el.style.display = "block";
    clearTimeout(el._gomaTimer);
    el._gomaTimer = setTimeout(function () { el.style.display = "none"; }, 6000);
  }

  function videoIdFromUrl() {
    try {
      var u = new URL(location.href);
      if (u.pathname === "/watch") return u.searchParams.get("v");
      if (u.pathname.indexOf("/shorts/") === 0) return u.pathname.split("/")[2];
    } catch (e) {}
    return null;
  }

  function idFromHref(href) {
    if (!href) return null;
    var m = href.match(/[?&]v=([\w-]{11})/) || href.match(/\/shorts\/([\w-]{11})/);
    return m ? m[1] : null;
  }

  function cardOf(anchor) {
    var card = anchor.closest(CARD_SELECTOR);
    if (card) return card;
    // フォールバック：サムネイル画像を含むリンクなら、そのリンク自体をカード扱いにする
    if (anchor.querySelector("img")) return anchor;
    return null;
  }

  function titleOfCard(card, fallbackAnchor) {
    var t = card.querySelector("#video-title");
    if (t) {
      var s = (t.getAttribute("title") || t.textContent || "").trim().replace(/\s+/g, " ");
      if (s) return s.slice(0, 100);
    }
    var h = card.querySelector("h3");
    if (h) {
      var s2 = (h.getAttribute("aria-label") || h.textContent || "").trim().replace(/\s+/g, " ");
      if (s2) return s2.slice(0, 100);
    }
    if (fallbackAnchor) {
      var s3 = (fallbackAnchor.getAttribute("title") || "").trim();
      if (s3) return s3.slice(0, 100);
    }
    return "";
  }

  // ページ内の動画カードを {id, title, card} で集める（リンク起点で拾うので新UIにも追随しやすい）
  function scanCards() {
    var seen = {};
    var out = [];
    var anchors = document.querySelectorAll('a[href*="/watch?v="], a[href*="/shorts/"]');
    anchors.forEach(function (a) {
      var id = idFromHref(a.getAttribute("href") || "");
      if (!id || seen[id]) return;
      var card = cardOf(a);
      if (!card) return;
      seen[id] = true;
      out.push({ id: id, title: titleOfCard(card, a) || id, card: card });
    });
    return out;
  }

  // ---------- 状況パネル ----------
  var panelEntries = {};
  var panelOrder = [];

  function ensurePanel() {
    var p = document.getElementById("goma-panel");
    if (p) return p;
    p = document.createElement("div");
    p.id = "goma-panel";
    p.style.cssText = "position:fixed;left:12px;bottom:12px;width:308px;max-height:46vh;overflow:auto;background:rgba(18,18,18,.96);color:#eee;border:1px solid #c8a415;border-radius:12px;z-index:2147483646;font-size:12.5px;box-shadow:0 6px 22px rgba(0,0,0,.5);display:none;";
    p.innerHTML = '<div style="display:flex;justify-content:space-between;align-items:center;padding:8px 12px;border-bottom:1px solid #333;">' +
      '<span style="color:#e9c33c;font-weight:700;">⬇ ごま動画セーバー 保存状況</span>' +
      '<span id="goma-panel-close" style="cursor:pointer;color:#aaa;padding:0 4px;">✕</span></div>' +
      '<div id="goma-panel-list" style="padding:6px 12px;"></div>';
    document.documentElement.appendChild(p);
    p.querySelector("#goma-panel-close").addEventListener("click", function () { p.style.display = "none"; });
    return p;
  }

  function panelSet(key, title, status) {
    if (!(key in panelEntries)) panelOrder.unshift(key);
    panelEntries[key] = { title: title || (panelEntries[key] && panelEntries[key].title) || "動画", status: status };
    while (panelOrder.length > 10) { var k = panelOrder.pop(); delete panelEntries[k]; }
    var p = ensurePanel();
    p.style.display = "block";
    var list = p.querySelector("#goma-panel-list");
    list.innerHTML = "";
    panelOrder.forEach(function (k) {
      var e = panelEntries[k];
      var row = document.createElement("div");
      row.style.cssText = "padding:5px 0;border-bottom:1px solid #2a2a2a;";
      var t = document.createElement("div");
      t.style.cssText = "white-space:nowrap;overflow:hidden;text-overflow:ellipsis;";
      t.textContent = e.title;
      var s = document.createElement("div");
      s.style.cssText = "color:#9fd08a;font-size:11.5px;";
      if (/失敗|エラー|できなかった/.test(e.status)) s.style.color = "#e88";
      s.textContent = e.status;
      row.appendChild(t); row.appendChild(s);
      list.appendChild(row);
    });
  }

  // ---------- 取得とダウンロード ----------
  function fetchPlayer(client, id) {
    return fetch("https://www.youtube.com/youtubei/v1/player?key=" + client.key + "&prettyPrint=false", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(client.body(id)),
      credentials: "omit"
    }).then(function (r) { return r.json(); });
  }

  function pickProgressive(data) {
    var fmts = (data.streamingData || {}).formats || [];
    for (var i = 0; i < fmts.length; i++) {
      if (fmts[i].url && (fmts[i].mimeType || "").indexOf("video/mp4") === 0) return fmts[i];
    }
    return null;
  }

  function fetchInfo(id) {
    var chain = Promise.reject(new Error("start"));
    CLIENTS.forEach(function (client) {
      chain = chain.catch(function () {
        return fetchPlayer(client, id).then(function (data) {
          var fmt = pickProgressive(data);
          if (!fmt) throw new Error("MP4一本の形式が見つからなかった");
          var title = ((data.videoDetails || {}).title || id).replace(/[\\/:*?"<>|]/g, "_").trim().slice(0, 80);
          return { url: fmt.url, title: title, height: fmt.height || 360 };
        });
      });
    });
    return chain;
  }

  var tempSeq = 0;
  function saveOne(id, titleHint) {
    var key = "tmp" + (++tempSeq);
    panelSet(key, titleHint || id, "情報を取得中…");
    return fetchInfo(id).then(function (info) {
      panelSet(key, info.title, "ダウンロード開始中…（" + info.height + "p）");
      return new Promise(function (resolve) {
        chrome.runtime.sendMessage(
          { type: "goma-download", url: info.url, filename: info.title + ".mp4", title: info.title },
          function (resp) {
            if (resp && resp.ok) {
              panelSet("dl" + resp.downloadId, info.title, "ダウンロード中…");
              delete panelEntries[key];
              panelOrder = panelOrder.filter(function (k) { return k !== key; });
              resolve(true);
            } else {
              panelSet(key, info.title, "開始できなかった：" + ((resp && resp.error) || "不明なエラー"));
              resolve(false);
            }
          }
        );
      });
    }).catch(function (err) {
      panelSet(key, titleHint || id, "保存できなかった：" + err.message);
      return false;
    });
  }

  function saveMany(ids, titles) {
    var delay = 0;
    ids.forEach(function (id) {
      setTimeout(function () { saveOne(id, titles && titles[id]); }, delay);
      delay += 900; // 取得リクエストが一斉に飛ばないよう少しずらす（ダウンロード自体は並行）
    });
    toast(ids.length + "本の保存を開始します。進み具合は左下のパネルで");
  }

  // ---------- 選択モード（チャンネル動画一覧など） ----------
  var selecting = false;
  var selected = {}; // id -> {title, card, box}
  var scanTimer = null;

  function ensureSelectUI() {
    var btn = document.getElementById("goma-select-btn");
    if (!btn) {
      btn = document.createElement("button");
      btn.id = "goma-select-btn";
      btn.textContent = "☑ 動画を選ぶ";
      btn.style.cssText = "position:fixed;right:16px;bottom:150px;z-index:2147483645;background:#222;color:#e9c33c;border:2px solid #c8a415;border-radius:999px;padding:11px 16px;font-size:14px;font-weight:700;cursor:pointer;box-shadow:0 4px 14px rgba(0,0,0,.45);";
      btn.addEventListener("click", function () { selecting ? exitSelectMode() : enterSelectMode(); });
      document.documentElement.appendChild(btn);
    }
    var bar = document.getElementById("goma-select-bar");
    if (!bar) {
      bar = document.createElement("div");
      bar.id = "goma-select-bar";
      bar.style.cssText = "position:fixed;left:50%;bottom:18px;transform:translateX(-50%);z-index:2147483646;background:rgba(18,18,18,.97);border:2px solid #c8a415;border-radius:999px;padding:8px 10px 8px 18px;display:none;align-items:center;gap:10px;box-shadow:0 6px 22px rgba(0,0,0,.55);font-size:14px;color:#eee;white-space:nowrap;";
      bar.innerHTML =
        '<span id="goma-sel-count" style="font-weight:700;">0本 選択中</span>' +
        '<button id="goma-sel-all" style="background:#2b2b2b;color:#ddd;border:1px solid #555;border-radius:999px;padding:7px 12px;cursor:pointer;">表示分を全選択</button>' +
        '<button id="goma-sel-go" style="background:#c8a415;color:#111;border:none;border-radius:999px;padding:8px 16px;font-weight:700;cursor:pointer;">⬇ ダウンロード</button>' +
        '<button id="goma-sel-cancel" style="background:none;color:#aaa;border:none;padding:8px 6px;cursor:pointer;">やめる</button>';
      document.documentElement.appendChild(bar);
      bar.querySelector("#goma-sel-cancel").addEventListener("click", exitSelectMode);
      bar.querySelector("#goma-sel-all").addEventListener("click", function () {
        scanCards().forEach(function (c) { setSelected(c, true); });
        refreshBar();
      });
      bar.querySelector("#goma-sel-go").addEventListener("click", function () {
        var ids = Object.keys(selected);
        if (!ids.length) { toast("動画が選ばれていません"); return; }
        var titles = {};
        ids.forEach(function (id) { titles[id] = selected[id].title; });
        exitSelectMode();
        saveMany(ids, titles);
      });
    }
    return { btn: btn, bar: bar };
  }

  function refreshBar() {
    var n = Object.keys(selected).length;
    var c = document.getElementById("goma-sel-count");
    if (c) c.textContent = n + "本 選択中";
    var go = document.getElementById("goma-sel-go");
    if (go) go.style.opacity = n ? "1" : ".45";
  }

  function setSelected(item, on) {
    var entry = selected[item.id];
    if (on) {
      if (!entry) {
        selected[item.id] = { title: item.title, card: item.card };
        entry = selected[item.id];
      }
      item.card.style.boxShadow = "inset 0 0 0 3px #c8a415";
      item.card.style.borderRadius = "12px";
      var box = item.card.querySelector(".goma-check input");
      if (box) box.checked = true;
    } else {
      delete selected[item.id];
      item.card.style.boxShadow = "";
      var box2 = item.card.querySelector(".goma-check input");
      if (box2) box2.checked = false;
    }
  }

  function injectCheckboxes() {
    scanCards().forEach(function (item) {
      var card = item.card;
      if (card.querySelector(".goma-check")) return;
      if (getComputedStyle(card).position === "static") card.style.position = "relative";
      var label = document.createElement("label");
      label.className = "goma-check";
      label.style.cssText = "position:absolute;top:8px;left:8px;z-index:60;background:rgba(10,10,10,.82);border:2px solid #c8a415;border-radius:8px;padding:5px 7px;cursor:pointer;display:flex;align-items:center;";
      var cb = document.createElement("input");
      cb.type = "checkbox";
      cb.style.cssText = "width:20px;height:20px;accent-color:#c8a415;cursor:pointer;margin:0;";
      cb.checked = !!selected[item.id];
      if (cb.checked) { card.style.boxShadow = "inset 0 0 0 3px #c8a415"; card.style.borderRadius = "12px"; }
      cb.addEventListener("click", function (e) { e.stopPropagation(); });
      cb.addEventListener("change", function () { setSelected(item, cb.checked); refreshBar(); });
      label.appendChild(cb);
      label.addEventListener("click", function (e) { e.stopPropagation(); });
      card.appendChild(label);
    });
  }

  function enterSelectMode() {
    selecting = true;
    var ui = ensureSelectUI();
    ui.btn.textContent = "☑ 選択モード中（押すと終了）";
    ui.bar.style.display = "flex";
    injectCheckboxes();
    refreshBar();
    // スクロールで後から読み込まれるカードにもチェックを付ける
    scanTimer = setInterval(function () { if (selecting) injectCheckboxes(); }, 1500);
    toast("保存したい動画にチェックを付けて、下の「ダウンロード」を押してね");
  }

  function exitSelectMode() {
    selecting = false;
    if (scanTimer) { clearInterval(scanTimer); scanTimer = null; }
    document.querySelectorAll(".goma-check").forEach(function (el) { el.remove(); });
    Object.keys(selected).forEach(function (id) {
      if (selected[id].card) selected[id].card.style.boxShadow = "";
    });
    selected = {};
    var ui = ensureSelectUI();
    ui.btn.textContent = "☑ 動画を選ぶ";
    ui.bar.style.display = "none";
  }

  // ---------- ポップアップ・背景との通信 ----------
  chrome.runtime.onMessage.addListener(function (msg, sender, sendResponse) {
    if (!msg) return;
    if (msg.type === "goma-list-videos") {
      var cur = videoIdFromUrl();
      var videos = scanCards().slice(0, 120).map(function (c) {
        return { id: c.id, title: c.title, current: c.id === cur };
      });
      if (cur && !videos.some(function (v) { return v.id === cur; })) {
        var t = document.title.replace(/ - YouTube$/, "");
        videos.unshift({ id: cur, title: t.slice(0, 100), current: true });
      }
      sendResponse({ ok: true, videos: videos, pageTitle: document.title });
      return;
    }
    if (msg.type === "goma-download-many") {
      var ids = (msg.ids || []).filter(Boolean);
      if (!ids.length) { sendResponse({ ok: false, error: "動画が選ばれていません" }); return; }
      saveMany(ids, msg.titles || {});
      sendResponse({ ok: true, started: ids.length });
      return;
    }
    if (msg.type === "goma-dl-state") {
      var key = "dl" + msg.downloadId;
      if (msg.state === "started") panelSet(key, msg.title, "ダウンロード中…");
      else if (msg.state === "progress") panelSet(key, msg.title, "ダウンロード中… " + msg.percent + "%");
      else if (msg.state === "complete") panelSet(key, msg.title, "完了 ✔ ダウンロードフォルダに保存");
      else if (msg.state === "interrupted") panelSet(key, msg.title, "失敗：" + (msg.error || "中断されました"));
      return;
    }
  });

  // ---------- 動画ページの単体ボタン（v1から継続） ----------
  function addButton() {
    if (document.getElementById("goma-saver-btn")) return;
    if (!videoIdFromUrl()) return;
    var btn = document.createElement("button");
    btn.id = "goma-saver-btn";
    btn.textContent = "⬇ MP4で保存";
    btn.style.cssText = "position:fixed;right:16px;bottom:84px;z-index:2147483647;background:#c8a415;color:#111;border:none;border-radius:999px;padding:12px 18px;font-size:15px;font-weight:700;cursor:pointer;box-shadow:0 4px 14px rgba(0,0,0,.45);";
    btn.addEventListener("click", function () {
      var id = videoIdFromUrl();
      if (id) saveOne(id);
    });
    document.documentElement.appendChild(btn);
  }

  // 選択ボタンは「カードが2枚以上あるページ」で出す（チャンネル動画一覧・検索・ホーム等）
  function refreshSelectButton() {
    if (selecting) return;
    var ui = ensureSelectUI();
    var has = scanCards().length >= 2;
    ui.btn.style.display = has ? "block" : "none";
  }

  addButton();
  refreshSelectButton();
  var last = location.href;
  setInterval(function () {
    if (location.href !== last) {
      last = location.href;
      if (selecting) exitSelectMode();
      var old = document.getElementById("goma-saver-btn");
      if (old) old.remove();
      addButton();
      refreshSelectButton();
    }
  }, 1200);
})();
