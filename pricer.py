"""
Repack Ledger Card Ladder pricer.

Leave this running on a computer that stays on. When someone taps Card Ladder in the app, it looks up each
slab's Card Ladder value and saves it to the app.

Setup, once (Windows: in PowerShell):
    pip install playwright
    python pricer.py

The first run asks for your Repack Ledger email and password (the password is not saved) and opens a Chrome
window on Card Ladder. Sign in to Card Ladder in that window. After that it remembers both.
It also watches this week on its own and prices any slab that has no value yet, usually within seconds of the scan,
without anyone asking. Run with --no-auto to only price when someone asks from the app.
Stop it with Ctrl+C. Run with --signout to forget the Repack Ledger sign-in.
"""
import getpass
import json
import os
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# same project as the app's config.js (these two values are public)
SUPA = os.environ.get("REPACK_SUPA", "https://cqzvybrykzuqfqjffzqc.supabase.co")
KEY = "sb_publishable_hX8JScS-XvpaYWPPhnaPSg_oKoBnA-d"
CL_URL = os.environ.get("REPACK_CL", "https://app.cardladder.com/sales-history")
EVERY = float(os.environ.get("REPACK_EVERY", "5"))    # seconds between checks for a request or a new slab
FLAG = 25                                             # flag slabs whose recent sales are this % off the CL value
RETRY_HOURS = 12                                      # a cert Card Ladder did not have is tried again after this long
HOME = Path.home() / ".repack-pricer"
SESSION = HOME / "session.json"
NOTFOUND = HOME / "not-found.json"


def skip_list():
    """certs Card Ladder did not have recently, so automatic checks do not look them up again every few minutes"""
    try:
        d = json.loads(NOTFOUND.read_text())
    except Exception:
        d = {}
    cut = time.time() - RETRY_HOURS * 3600
    return {c: t for c, t in d.items() if t > cut}


def remember_not_found(certs):
    d = skip_list()
    for c in certs:
        d[c] = time.time()
    HOME.mkdir(exist_ok=True)
    NOTFOUND.write_text(json.dumps(d))


def now():
    return datetime.now(timezone.utc).isoformat()


def log(msg):
    print(datetime.now().strftime("%I:%M %p").lstrip("0"), msg, flush=True)


# ---------- Supabase ----------
def http(method, path, body=None, token=None, prefer=None):
    req = urllib.request.Request(SUPA + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("apikey", KEY)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if prefer:
        req.add_header("Prefer", prefer)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            txt = r.read().decode()
            return r.status, (json.loads(txt) if txt else None)
    except urllib.error.HTTPError as e:
        txt = e.read().decode()
        try:
            return e.code, json.loads(txt)
        except ValueError:
            return e.code, {"message": txt}


class Auth:
    def __init__(self):
        self.s = json.loads(SESSION.read_text()) if SESSION.exists() else None

    def save(self, j):
        self.s = {"access": j["access_token"], "refresh": j["refresh_token"],
                  "exp": time.time() + j.get("expires_in", 3600),
                  "email": (j.get("user") or {}).get("email") or (self.s or {}).get("email"),
                  "name": (self.s or {}).get("name", "Card Ladder PC")}
        HOME.mkdir(exist_ok=True)
        SESSION.write_text(json.dumps(self.s))

    def sign_in(self):
        print("Sign in with your Repack Ledger account. The password is not saved.")
        while True:
            email = input("Email: ").strip()
            pw = getpass.getpass("Password: ")
            code, j = http("POST", "/auth/v1/token?grant_type=password", {"email": email, "password": pw})
            if code == 200:
                name = input("Name for this computer [Card Ladder PC]: ").strip() or "Card Ladder PC"
                self.s = {"name": name}
                self.save(j)
                return
            print("Could not sign in:", (j or {}).get("error_description") or (j or {}).get("msg") or code)

    def token(self):
        if not self.s:
            self.sign_in()
        if time.time() > self.s["exp"] - 120:
            code, j = http("POST", "/auth/v1/token?grant_type=refresh_token", {"refresh_token": self.s["refresh"]})
            if code != 200:
                log("The Repack Ledger sign-in expired.")
                self.s = None
                self.sign_in()
            else:
                self.save(j)
        return self.s["access"]


auth = None


def rest(method, path, body=None, prefer=None):
    code, j = http(method, "/rest/v1/" + path, body, auth.token(), prefer)
    if code == 401:
        auth.s["exp"] = 0
        code, j = http(method, "/rest/v1/" + path, body, auth.token(), prefer)
    if code >= 300:
        raise RuntimeError("Database said %s: %s" % (code, (j or {}).get("message", "")))
    return j


def set_pricer(patch, where=""):
    return rest("PATCH", "pricer?id=eq.1" + where, patch, "return=representation")


# ---------- Card Ladder (same steps as the psa-cardladder-pricer skill, run inside the page) ----------
LOOKUP_JS = r"""
async (cert) => {
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const q = s => [...document.querySelectorAll(s)];
  const main = () => (document.querySelector("main") || document.body).innerText;
  const sig = () => q(".stat-item").filter(e => /^\s*Price/.test(e.innerText)).slice(0, 5).map(e => e.innerText.replace(/\s+/g, "")).join("|") + "#" + (main().match(/Profile: [^\n]*/) || [""])[0];
  const tag = () => q("button").find(b => b.innerText.trim() === "tag");
  const chip = q("button,i,span").find(e => e.innerText && e.innerText.trim() === "close" && /Profile:/.test((e.parentElement && e.parentElement.innerText) || ""));
  if (chip) { chip.click(); await wait(2500); }
  await wait(500);
  const pre = sig();
  if (!tag()) return { error: "signedout" };
  tag().click(); await wait(700);
  const h = q("h1,h2,h3,h4,h5,h6").find(h => /Search Sales by Cert/i.test(h.textContent));
  let d = h; while (d && !d.querySelector("input")) d = d.parentElement;
  if (!d) return { error: "nodialog" };
  const i = d.querySelector("input"); i.focus();
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(i, String(cert));
  i.dispatchEvent(new Event("input", { bubbles: true })); i.dispatchEvent(new Event("change", { bubbles: true }));
  await wait(400);
  let d2 = h; while (d2 && ![...d2.querySelectorAll("button")].some(b => b.innerText.trim() === "Submit")) d2 = d2.parentElement;
  [...d2.querySelectorAll("button")].find(b => b.innerText.trim() === "Submit").click();
  let ok = false;
  for (let k = 0; k < 30; k++) {
    await wait(500);
    const v = document.querySelector(".estimate .value");
    if (v && /\$/.test(v.textContent) && sig() !== pre) { ok = true; break; }
    if (k > 2 && /No results|There are no/i.test(main())) return null;
  }
  let last = sig(); for (let k = 0; k < 6; k++) { await wait(500); const n = sig(); if (n === last && k >= 2) break; last = n; }
  if (!ok) return null;
  const v = document.querySelector(".estimate .value"), t = main();
  const cl = v ? parseFloat(v.textContent.replace(/[^\d.]/g, "")) : NaN;
  if (!(cl > 0)) return null;
  const grade = (t.match(/Grade: (\w+)/) || [])[1] || "";
  const profile = ((t.match(/Profile: ([^\n]*)/) || [])[1] || "").replace(/\s*\(Pop \d+\).*$/, "").replace(/\s*close\s*$/, "").trim();
  const all = q(".stat-item").filter(e => /^\s*Price/.test(e.innerText)).map(e => parseFloat(e.innerText.replace(/[^\d.]/g, ""))).filter(n => !isNaN(n));
  return { cl: Math.round(cl * 100) / 100, grade, profile, prices: all.slice(0, 40) };
}
"""


def avg3(prices):
    """average of the 3 most recent sales, skipping ones far from the usual price"""
    if not prices:
        return None
    ref = sorted(prices[:10])
    m = ref[len(ref) // 2] if len(ref) % 2 else (ref[len(ref) // 2 - 1] + ref[len(ref) // 2]) / 2
    keep = []
    for p in prices:
        if len(keep) >= 3:
            break
        if m * 0.5 <= p <= m * 1.5:
            keep.append(p)
    nums = keep or prices[:3]
    return round(sum(nums) / len(nums), 2)


class CardLadder:
    def __init__(self, pw):
        HOME.mkdir(exist_ok=True)
        opts = dict(user_data_dir=str(HOME / "browser"), headless=os.environ.get("REPACK_HEADLESS") == "1",
                    viewport={"width": 1300, "height": 900})
        if os.environ.get("REPACK_CHROME"):
            opts["executable_path"] = os.environ["REPACK_CHROME"]
        try:
            self.ctx = pw.chromium.launch_persistent_context(channel="chrome", **opts)
        except Exception:
            try:
                self.ctx = pw.chromium.launch_persistent_context(**opts)
            except Exception:
                sys.exit("Could not start Chrome. Install Google Chrome, or run:  python -m playwright install chromium")
        self.page = self.ctx.pages[0] if self.ctx.pages else self.ctx.new_page()

    def ready(self, wait_s=15):
        try:
            if not self.page.url.startswith(CL_URL):
                self.page.goto(CL_URL, wait_until="domcontentloaded", timeout=60000)
            self.page.wait_for_function("[...document.querySelectorAll('button')].some(b=>b.innerText.trim()==='tag')", timeout=wait_s * 1000)
            return True
        except Exception:
            return False

    def lookup(self, cert):
        for attempt in range(2):
            try:
                r = self.page.evaluate(LOOKUP_JS, str(cert))
            except Exception:
                r = {"error": "page"}
            if r and r.get("error"):
                if not self.ready():
                    raise RuntimeError("Card Ladder is signed out or not loading on the pricer computer.")
                continue
            if r:
                return r
        return None


# ---------- the job ----------
def week_cards(scope, skip=()):
    wk = rest("GET", "weeks?closed=eq.false&select=id")
    if not wk:
        raise RuntimeError("No open week")
    cards = rest("GET", "cards?week_id=eq.%s&sold=eq.false&cert=not.is.null&select=id,cert,description,market_value&order=seq.asc" % wk[0]["id"])
    return [c for c in cards if str(c["cert"]).strip() and str(c["cert"]) not in skip and (scope == "all" or not (float(c["market_value"] or 0) > 0))]


def run(cl, job, skip=()):
    out = {"updated": 0, "same": 0, "names": 0, "notFound": [], "flagged": []}
    try:
        if not cl.ready():
            raise RuntimeError("Card Ladder is signed out or not loading on the pricer computer.")
        cards = week_cards(job["scope"], skip)
        set_pricer({"total": len(cards), "progress": 0})
        log("Request from %s: %d slab%s" % (job.get("requested_by") or "someone", len(cards), "" if len(cards) == 1 else "s"))
        for n, c in enumerate(cards):
            cur = rest("GET", "pricer?id=eq.1&select=status,requested_at")
            if not cur or cur[0]["status"] != "working" or cur[0]["requested_at"] != job["requested_at"]:
                log("Stopped")
                return
            name = c["description"] or "Cert %s" % c["cert"]
            set_pricer({"progress": n, "current_card": name, "last_seen": now()})
            r = cl.lookup(c["cert"])
            if not r:
                out["notFound"].append(str(c["cert"]))
                log("  %s: not on Card Ladder" % c["cert"])
                continue
            patch = {}
            if round(float(c["market_value"] or 0) * 100) != round(r["cl"] * 100):
                patch["market_value"] = r["cl"]
            if not str(c["description"] or "").strip() and r["profile"]:
                patch["description"] = r["profile"] + (" PSA " + r["grade"] if r["grade"] else "")
                out["names"] += 1
            if patch:
                rest("PATCH", "cards?id=eq." + c["id"], patch)
                out["updated"] += 1
            else:
                out["same"] += 1
            a = avg3(r["prices"])
            log("  %s: $%.2f%s" % (name, r["cl"], "" if a is None else " (last 3 avg $%.2f)" % a))
            if a is not None:
                off = round((a - r["cl"]) / r["cl"] * 100)
                if abs(off) >= FLAG:
                    out["flagged"].append({"cert": str(c["cert"]), "name": c["description"] or patch.get("description", ""), "cl": r["cl"], "avg3": a, "off": off})
        remember_not_found(out["notFound"])
        set_pricer({"status": "done", "progress": len(cards), "current_card": None, "finished_at": now(), "result": out, "message": None}, "&status=eq.working")
        log("Done: %d updated, %d unchanged%s" % (out["updated"], out["same"], ", %d not found" % len(out["notFound"]) if out["notFound"] else ""))
    except Exception as e:
        log("Problem: %s" % e)
        try:
            set_pricer({"status": "error", "message": str(e), "finished_at": now(), "current_card": None, "result": out}, "&status=eq.working")
        except Exception:
            pass


def main():
    global auth
    if "--signout" in sys.argv:
        SESSION.unlink(missing_ok=True)
        print("Signed out of Repack Ledger on this computer.")
        return
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        sys.exit("Playwright is not installed. Run:  pip install playwright")
    auto = "--no-auto" not in sys.argv
    auth = Auth()
    auth.token()
    me = auth.s.get("name", "Card Ladder PC")
    with sync_playwright() as pw:
        cl = CardLadder(pw)
        if not cl.ready():
            print("\nSign in to Card Ladder in the Chrome window that just opened, then come back here and press Enter.")
            input()
            while not cl.ready(30):
                input("Card Ladder still is not showing Sales History. Sign in there, then press Enter.")
        log("Ready as \"%s\". %s Press Ctrl+C to stop." % (me, "Pricing new slabs as they come in and when asked from the app." if auto else "Waiting for requests from the app."))
        while True:
            try:
                rows = set_pricer({"last_seen": now(), "worker": me + (" | prices new slabs automatically" if auto else "")})
                if not rows:
                    sys.exit("This account cannot see the pricer. Run upgrade-7.sql and sign in with a member account.")
                if rows[0]["status"] == "pending":
                    claimed = set_pricer({"status": "working", "started_at": now(), "progress": 0, "total": 0, "message": None, "result": None}, "&status=eq.pending")
                    if claimed:
                        run(cl, claimed[0])
                        continue
                # automatic: price slabs with no value, without anyone asking
                elif auto and rows[0]["status"] != "working":
                    skip = skip_list()
                    if week_cards("missing", skip):
                        claimed = set_pricer({"status": "working", "scope": "missing", "requested_by": "Automatic (%s)" % me, "requested_at": now(),
                                              "started_at": now(), "finished_at": None, "progress": 0, "total": 0, "message": None, "result": None},
                                             "&status=not.in.(pending,working)")
                        if claimed:
                            run(cl, claimed[0], skip)
                            continue
            except KeyboardInterrupt:
                raise
            except SystemExit:
                raise
            except Exception as e:
                log("Problem: %s" % e)
            time.sleep(EVERY)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped.")
