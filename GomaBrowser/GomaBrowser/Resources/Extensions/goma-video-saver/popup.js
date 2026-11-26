// ごま動画セーバー v2 (popup GUI)
// 開いているYouTubeページの動画一覧をコンテンツスクリプトから受け取り、
// チェックした動画をまとめてダウンロードさせる。
"use strict";

var videos = []; // {id, title, current, checked}
var tabId = null;

var listEl = document.getElementById("list");
var countEl = document.getElementById("count");
var goBtn = document.getElementById("go");
var statusEl = document.getElementById("status");
var noteEl = document.getElementById("note");

function render() {
  listEl.innerHTML = "";
  if (!videos.length) {
    listEl.innerHTML = '<div id="empty">このページで動画が見つかりませんでした。下の「URLを貼って追加」からも入れられます。</div>';
  }
  videos.forEach(function (v, i) {
    var label = document.createElement("label");
    label.className = "item";
    var cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = !!v.checked;
    cb.addEventListener("change", function () { v.checked = cb.checked; updateCount(); });
    var t = document.createElement("span");
    t.className = "t";
    t.textContent = v.title;
    if (v.current) {
      var b = document.createElement("span");
      b.className = "badge";
      b.textContent = "再生中";
      t.appendChild(b);
    }
    label.appendChild(cb);
    label.appendChild(t);
    listEl.appendChild(label);
  });
  updateCount();
}

function updateCount() {
  var n = videos.filter(function (v) { return v.checked; }).length;
  countEl.textContent = videos.length + "本中 " + n + "本を選択";
  goBtn.disabled = n === 0 || tabId === null;
  goBtn.textContent = n > 0 ? "選択した" + n + "本をダウンロード" : "選択した動画をダウンロード";
}

function parseId(text) {
  var m = text.match(/(?:[?&]v=|youtu\.be\/|\/shorts\/)([\w-]{11})/);
  if (m) return m[1];
  var bare = text.trim();
  if (/^[\w-]{11}$/.test(bare)) return bare;
  return null;
}

document.getElementById("all").addEventListener("click", function () {
  videos.forEach(function (v) { v.checked = true; }); render();
});
document.getElementById("none").addEventListener("click", function () {
  videos.forEach(function (v) { v.checked = false; }); render();
});
document.getElementById("add-urls").addEventListener("click", function () {
  var lines = document.getElementById("urls").value.split(/\n+/);
  var added = 0;
  lines.forEach(function (line) {
    var id = parseId(line);
    if (!id) return;
    if (videos.some(function (v) { return v.id === id; })) return;
    videos.push({ id: id, title: "（URLから追加）" + id, current: false, checked: true });
    added++;
  });
  document.getElementById("urls").value = "";
  statusEl.textContent = added ? added + "本を追加しました" : "追加できるURLがありませんでした";
  render();
});

goBtn.addEventListener("click", function () {
  var chosen = videos.filter(function (v) { return v.checked; });
  if (!chosen.length || tabId === null) return;
  var titles = {};
  chosen.forEach(function (v) { titles[v.id] = v.title; });
  chrome.tabs.sendMessage(tabId, {
    type: "goma-download-many",
    ids: chosen.map(function (v) { return v.id; }),
    titles: titles
  }, function (resp) {
    if (chrome.runtime.lastError) {
      statusEl.textContent = "ページと通信できませんでした。YouTubeのページを開き直してから、もう一度どうぞ。";
      return;
    }
    if (resp && resp.ok) {
      statusEl.textContent = resp.started + "本のダウンロードを開始しました。進み具合はページ左下のパネルで見られます。この窓は閉じてOKです。";
      goBtn.disabled = true;
    } else {
      statusEl.textContent = "開始できませんでした：" + ((resp && resp.error) || "不明なエラー");
    }
  });
});

// 起動時：アクティブタブのページから一覧をもらう
chrome.tabs.query({ active: true, currentWindow: true }, function (tabs) {
  var tab = tabs && tabs[0];
  if (!tab || !/^https:\/\/www\.youtube\.com\//.test(tab.url || "")) {
    noteEl.style.display = "block";
    noteEl.textContent = "いま開いているタブがYouTubeではありません。YouTubeのページを開いた状態で、このボタンを押してください。";
    render();
    return;
  }
  tabId = tab.id;
  chrome.tabs.sendMessage(tabId, { type: "goma-list-videos" }, function (resp) {
    if (chrome.runtime.lastError || !resp || !resp.ok) {
      noteEl.style.display = "block";
      noteEl.textContent = "ページから一覧を取れませんでした。ページを再読み込みしてから開き直してください。";
      render();
      return;
    }
    videos = (resp.videos || []).map(function (v) {
      return { id: v.id, title: v.title, current: !!v.current, checked: !!v.current };
    });
    render();
  });
});
