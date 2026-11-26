"use strict";
// Swift版 MatchPattern.swift と同じ仕様の JS 実装（ローカル検証用）
function globMatch(pattern, value) {
  const p = pattern, v = value;
  const dp = Array.from({ length: p.length + 1 }, () => new Array(v.length + 1).fill(false));
  dp[0][0] = true;
  for (let i = 1; i <= p.length; i++) if (p[i - 1] === "*") dp[i][0] = dp[i - 1][0];
  for (let i = 1; i <= p.length; i++) {
    for (let j = 1; j <= v.length; j++) {
      if (p[i - 1] === "*") dp[i][j] = dp[i - 1][j] || dp[i][j - 1];
      else if (p[i - 1] === v[j - 1]) dp[i][j] = dp[i - 1][j - 1];
    }
  }
  return dp[p.length][v.length];
}

function parsePattern(pattern) {
  if (pattern === "<all_urls>") return { scheme: "*", host: "*", path: "/*", all: true };
  const sep = pattern.indexOf("://");
  if (sep < 0) return null;
  const scheme = pattern.slice(0, sep);
  const rest = pattern.slice(sep + 3);
  const slash = rest.indexOf("/");
  if (slash < 0) return null;
  const host = rest.slice(0, slash);
  const path = rest.slice(slash);
  if (!scheme || !host || !path) return null;
  return { scheme, host, path, all: false };
}

function matchPattern(pattern, urlString) {
  const mp = parsePattern(pattern);
  if (!mp) return false;
  let u;
  try { u = new URL(urlString); } catch (e) { return false; }
  const scheme = u.protocol.replace(/:$/, "");
  const host = u.hostname.toLowerCase();
  if (mp.all) return ["http", "https", "file", "ftp"].includes(scheme);
  if (mp.scheme === "*") { if (scheme !== "http" && scheme !== "https") return false; }
  else if (mp.scheme !== scheme) return false;
  if (mp.host !== "*") {
    if (mp.host.startsWith("*.")) {
      const d = mp.host.slice(2);
      if (!(host === d || host.endsWith("." + d))) return false;
    } else if (host !== mp.host) return false;
  }
  let target = u.pathname || "/";
  if (u.search) target += u.search;
  return globMatch(mp.path, target);
}

module.exports = { matchPattern, parsePattern, globMatch };
