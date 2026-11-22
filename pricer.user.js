// ==UserScript==
// @name         Repack Ledger Card Ladder pricer
// @namespace    repack-ledger
// @version      1.1
// @description  Fills in Card Ladder values in Repack Ledger: new slabs on its own within seconds, and everything when someone asks from the app. Keep Card Ladder open in its own Chrome window.
// @match        https://app.cardladder.com/*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_deleteValue
// @grant        GM_xmlhttpRequest
// @connect      cqzvybrykzuqfqjffzqc.supabase.co
// @run-at       document-idle
// @noframes
// @updateURL    https://milakuang.github.io/Izea-Ozone/pricer.user.js
// @downloadURL  https://milakuang.github.io/Izea-Ozone/pricer.user.js
// ==/UserScript==

(function () {
  "use strict";

  // same project as the app's config.js (these two values are public)
  const SUPA = "https://cqzvybrykzuqfqjffzqc.supabase.co";
  const KEY = "sb_publishable_hX8JScS-XvpaYWPPhnaPSg_oKoBnA-d";
  const EVERY = 5000;           // how often to check for a request or a new slab with no value
  const RETRY_H = 12;           // a cert Card Ladder did not have is tried again after this many hours
  const FLAG = 0.25;            // flag a slab when recent sales are this far off the CL value
  const wait = ms => new Promise(r => setTimeout(r, ms));

  // ---------- panel ----------
  const box = document.createElement("div");
  box.style.cssText = "position:fixed;right:14px;bottom:14px;z-index:2147483647;background:#0f172a;color:#fff;font:13px/1.4 system-ui,sans-serif;padding:10px 12px;border-radius:12px;box-shadow:0 6px 24px rgba(0,0,0,.3);max-width:280px";
  document.body.appendChild(box);
  let line = "Starting...";
  const paint = () => {
    const s = GM_getValue("session", null);
    box.innerHTML = '<b style="display:block;margin-bottom:4px">Repack pricer</b>' +
      (s ? '<div id="rp-line"></div><div style="margin-top:6px;opacity:.7">Signed in as ' + esc(s.email) + ' | <a href="#" id="rp-out" style="color:#5eead4">Sign out</a></div>'
         : '<form id="rp-in"><div style="margin-bottom:6px;opacity:.8">Sign in with your Repack Ledger account. Your password is not saved.</div>' +
           '<input name="e" type="email" placeholder="Email" style="width:100%;margin-bottom:4px;padding:5px;border-radius:6px;border:0;color:#000">' +
           '<input name="p" type="password" placeholder="Password" style="width:100%;margin-bottom:6px;padding:5px;border-radius:6px;border:0;color:#000">' +
           '<input name="n" placeholder="Name for this computer" value="' + esc(GM_getValue("worker", "Card Ladder PC")) + '" style="width:100%;margin-bottom:6px;padding:5px;border-radius:6px;border:0;color:#000">' +
           '<button style="padding:5px 10px;border:0;border-radius:6px;background:#14b8a6;color:#fff;font-weight:600">Sign in</button> <span id="rp-err" style="color:#fca5a5"></span></form>');
    const l = box.querySelector("#rp-line"); if (l) l.textContent = line;
    const out = box.querySelector("#rp-out");
    if (out) out.onclick = e => { e.preventDefault(); GM_deleteValue("session"); paint(); };
    const f = box.querySelector("#rp-in");
    if (f) f.onsubmit = async e => {
      e.preventDefault();
      try {
        GM_setValue("worker", f.n.value.trim() || "Card Ladder PC");
        await signIn(f.e.value.trim(), f.p.value);
        paint(); tick();
      } catch (x) { f.querySelector("#rp-err").textContent = String(x.message || x); }
    };
  };
  const say = t => { line = t; const l = box.querySelector("#rp-line"); if (l) l.textContent = t; };
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]); }

  // ---------- Supabase (through GM_xmlhttpRequest, so Card Ladder's page rules do not get in the way) ----------
  function http(method, url, body, headers) {
    return new Promise((res, rej) => GM_xmlhttpRequest({
      method, url, data: body == null ? undefined : JSON.stringify(body),
      headers: Object.assign({ apikey: KEY, "Content-Type": "application/json" }, headers || {}),
      timeout: 20000,
      onload: r => { let j = null; try { j = r.responseText ? JSON.parse(r.responseText) : null; } catch (e) {} res({ status: r.status, json: j }); },
      onerror: () => rej(new Error("No connection")), ontimeout: () => rej(new Error("Timed out"))
    }));
  }
  async function signIn(email, password) {
    const r = await http("POST", SUPA + "/auth/v1/token?grant_type=password", { email, password });
    if (r.status !== 200) throw new Error((r.json && (r.json.error_description || r.json.msg)) || "Sign in failed");
    save(r.json);
  }
  function save(j) { GM_setValue("session", { access: j.access_token, refresh: j.refresh_token, exp: Date.now() + (j.expires_in || 3600) * 1000, email: (j.user && j.user.email) || (GM_getValue("session", {}) || {}).email }); }
  async function token() {
    const s = GM_getValue("session", null); if (!s) return null;
    if (Date.now() < s.exp - 120000) return s.access;
    const r = await http("POST", SUPA + "/auth/v1/token?grant_type=refresh_token", { refresh_token: s.refresh });
    if (r.status !== 200) { GM_deleteValue("session"); paint(); return null; }
    save(r.json); return r.json.access_token;
  }
  async function rest(method, path, body, prefer) {
    const t = await token(); if (!t) throw new Error("signed out");
    const r = await http(method, SUPA + "/rest/v1/" + path, body, Object.assign({ Authorization: "Bearer " + t }, prefer ? { Prefer: prefer } : {}));
    if (r.status >= 300) throw new Error("Database said " + r.status + ": " + ((r.json && r.json.message) || ""));
    return r.json;
  }
  const setPricer = (patch, where) => rest("PATCH", "pricer?id=eq.1" + (where || ""), patch, "return=representation");

  // ---------- Card Ladder lookups (same steps as the psa-cardladder-pricer skill) ----------
  const q = s => [...document.querySelectorAll(s)];
  const main = () => (document.querySelector("main") || document.body).innerText;
  const sig = () => q(".stat-item").filter(e => /^\s*Price/.test(e.innerText)).slice(0, 5).map(e => e.innerText.replace(/\s+/g, "")).join("|") + "#" + (main().match(/Profile: [^\n]*/) || [""])[0];
  const tagBtn = () => q("button").find(b => b.innerText.trim() === "tag");
  async function clear() {
    const chip = q("button,i,span").find(e => e.innerText && e.innerText.trim() === "close" && /Profile:/.test((e.parentElement && e.parentElement.innerText) || ""));
    if (chip) { chip.click(); await wait(2500); }
  }
  function dialog(needButton) {
    const h = q("h1,h2,h3,h4,h5,h6").find(h => /Search Sales by Cert/i.test(h.textContent));
    let d = h; while (d && !(needButton ? [...d.querySelectorAll("button")].some(b => b.innerText.trim() === "Submit") : d.querySelector("input"))) d = d.parentElement;
    return d;
  }
  async function lookup(cert) {
    await clear(); await wait(500);
    const pre = sig();
    const b = tagBtn(); if (!b) throw new Error("Card Ladder is not showing Sales History. Is it signed in?");
    b.click(); await wait(700);
    const d = dialog(false); if (!d) throw new Error("Could not open the cert search on Card Ladder");
    const i = d.querySelector("input"); i.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(i, String(cert));
    i.dispatchEvent(new Event("input", { bubbles: true })); i.dispatchEvent(new Event("change", { bubbles: true }));
    await wait(400);
    const d2 = dialog(true); [...d2.querySelectorAll("button")].find(x => x.innerText.trim() === "Submit").click();
    let ok = false;
    for (let k = 0; k < 30; k++) {
      await wait(500);
      const v = document.querySelector(".estimate .value");
      if (v && /\$/.test(v.textContent) && sig() !== pre) { ok = true; break; }
      if (k > 2 && /No results|There are no/i.test(main())) return null;
    }
    let last = sig(); for (let k = 0; k < 6; k++) { await wait(500); const now = sig(); if (now === last && k >= 2) break; last = now; }
    if (!ok) return null;
    const v = document.querySelector(".estimate .value"), t = main();
    const cl = v ? parseFloat(v.textContent.replace(/[^\d.]/g, "")) : NaN;
    if (!(cl > 0)) return null;
    const grade = (t.match(/Grade: (\w+)/) || [])[1] || "", profile = ((t.match(/Profile: ([^\n]*)/) || [])[1] || "").replace(/\s*\(Pop \d+\).*$/, "").replace(/\s*close\s*$/, "").trim();
    // average of the 3 most recent same-grade sales, skipping sales far from the usual price
    const all = q(".stat-item").filter(e => /^\s*Price/.test(e.innerText)).map(e => parseFloat(e.innerText.replace(/[^\d.]/g, ""))).filter(n => !isNaN(n));
    let avg3 = null;
    if (all.length) {
      const ref = all.slice(0, 10).sort((a, b) => a - b), m = ref.length % 2 ? ref[(ref.length - 1) / 2] : (ref[ref.length / 2 - 1] + ref[ref.length / 2]) / 2;
      const keep = []; for (const p of all) { if (keep.length >= 3) break; if (p >= m * 0.5 && p <= m * 1.5) keep.push(p); }
      const nums = keep.length ? keep : all.slice(0, 3); avg3 = Math.round(nums.reduce((a, b) => a + b, 0) / nums.length * 100) / 100;
    }
    return { cl: Math.round(cl * 100) / 100, grade, profile, avg3 };
  }

  // certs Card Ladder did not have recently, so the automatic check does not keep looking them up
  const skipList = () => { const d = GM_getValue("notFound", {}), cut = Date.now() - RETRY_H * 3600000, o = {}; Object.keys(d).forEach(c => { if (d[c] > cut) o[c] = d[c]; }); return o; };
  const rememberNotFound = certs => { const d = skipList(); certs.forEach(c => d[c] = Date.now()); GM_setValue("notFound", d); };
  async function weekCards(scope, skip) {
    const wk = await rest("GET", "weeks?closed=eq.false&select=id");
    if (!wk || !wk.length) throw new Error("No open week");
    const cards = await rest("GET", "cards?week_id=eq." + wk[0].id + "&sold=eq.false&cert=not.is.null&select=id,cert,description,market_value&order=seq.asc");
    return cards.filter(c => String(c.cert).trim() !== "" && !(skip && skip[String(c.cert)]) && (scope === "all" || !(+c.market_value > 0)));
  }

  // ---------- the job ----------
  let working = false;
  async function run(job, skip) {
    working = true;
    const out = { updated: 0, same: 0, names: 0, notFound: [], flagged: [] };
    try {
      if (location.pathname !== "/sales-history") { GM_setValue("resume", 1); location.href = "https://app.cardladder.com/sales-history"; return; }
      for (let k = 0; k < 20 && !tagBtn(); k++) await wait(500);
      if (!tagBtn()) throw new Error("Card Ladder is signed out or not loading on the pricer computer.");
      const cards = await weekCards(job.scope, skip);
      await setPricer({ total: cards.length, progress: 0 });
      for (let n = 0; n < cards.length; n++) {
        const c = cards[n];
        // stop if someone pressed Stop or sent a new request
        const now = await rest("GET", "pricer?id=eq.1&select=status,requested_at");
        if (!now[0] || now[0].status !== "working" || now[0].requested_at !== job.requested_at) { say("Stopped"); return; }
        say("Pricing " + (n + 1) + " of " + cards.length + ": " + (c.description || c.cert));
        await setPricer({ progress: n, current_card: c.description || "Cert " + c.cert, last_seen: new Date().toISOString() });
        let r = await lookup(c.cert); if (!r) r = await lookup(c.cert);
        if (!r) { out.notFound.push(String(c.cert)); continue; }
        const patch = {};
        if (Math.round((+c.market_value || 0) * 100) !== Math.round(r.cl * 100)) patch.market_value = r.cl;
        if (!String(c.description || "").trim() && r.profile) { patch.description = r.profile + (r.grade ? " PSA " + r.grade : ""); out.names++; }
        if (Object.keys(patch).length) { await rest("PATCH", "cards?id=eq." + c.id, patch); out.updated++; } else out.same++;
        if (r.avg3 != null) { const off = Math.round((r.avg3 - r.cl) / r.cl * 100); if (Math.abs(off) >= FLAG * 100) out.flagged.push({ cert: String(c.cert), name: c.description || patch.description || "", cl: r.cl, avg3: r.avg3, off }); }
      }
      rememberNotFound(out.notFound);
      await setPricer({ status: "done", progress: cards.length, current_card: null, finished_at: new Date().toISOString(), result: out, message: null }, "&status=eq.working");
      say("Done: " + out.updated + " updated" + (out.notFound.length ? ", " + out.notFound.length + " not found" : ""));
    } catch (e) {
      say("Problem: " + (e.message || e));
      try { await setPricer({ status: "error", message: String(e.message || e), finished_at: new Date().toISOString(), current_card: null, result: out }, "&status=eq.working"); } catch (x) {}
    } finally { working = false; }
  }

  async function tick() {
    if (working) return;
    if (!GM_getValue("session", null)) { paint(); return; }
    try {
      const me = GM_getValue("worker", "Card Ladder PC");
      const row = (await setPricer({ last_seen: new Date().toISOString(), worker: me + " | prices new slabs automatically" }))[0];
      if (!row) throw new Error("This account cannot see the pricer. Run upgrade-7.sql and sign in with a member account.");
      // picked up again after the page moved to Sales History in the middle of a request
      const resume = GM_getValue("resume", 0) && row.status === "working" && String(row.worker || "").startsWith(me);
      GM_deleteValue("resume");
      if (row.status === "pending" || resume) {
        const claimed = resume ? [row] : await setPricer({ status: "working", started_at: new Date().toISOString(), progress: 0, total: 0, message: null, result: null }, "&status=eq.pending");
        if (claimed && claimed[0]) { await run(claimed[0]); return; }
      } else if (row.status !== "working") {
        // automatic: price slabs with no value without anyone asking
        const skip = skipList();
        if ((await weekCards("missing", skip)).length) {
          const claimed = await setPricer({ status: "working", scope: "missing", requested_by: "Automatic (" + me + ")", requested_at: new Date().toISOString(), started_at: new Date().toISOString(), finished_at: null, progress: 0, total: 0, message: null, result: null }, "&status=not.in.(pending,working)");
          if (claimed && claimed[0]) { await run(claimed[0], skip); return; }
        }
      }
      say("Waiting for a request (checked " + new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) + ")");
    } catch (e) { say(e.message === "signed out" ? "Signed out" : "Problem: " + (e.message || e)); }
  }

  paint();
  tick();
  setInterval(tick, EVERY);
})();
