// PSA cert lookup for Repack Ledger.
// Keeps your PSA token secret on Supabase, checks the caller is on the members list,
// caches results so repeat lookups do not use your daily PSA calls, and returns the slab photos.
import { createClient } from "npm:@supabase/supabase-js@2";

function encodeBase64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown) =>
  new Response(JSON.stringify(body), { headers: { ...cors, "Content-Type": "application/json" } });

const API = "https://api.psacard.com/publicapi/cert/";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: member } = await sb.rpc("is_member");
    if (member !== true) return reply({ error: "Not allowed. Sign in with an account on the members list." });

    const token = Deno.env.get("PSA_TOKEN");
    if (!token) return reply({ error: "PSA_TOKEN secret is not set in Supabase Edge Function secrets." });

    const body = await req.json().catch(() => ({}));
    const cert = String(body.cert ?? "").replace(/\D/g, "");
    const wantImages = body.images !== false;
    if (!cert) return reply({ error: "No cert number" });

    const headers = { Authorization: "bearer " + token };
    const { data: cached } = await sb.from("psa_cache").select("*").eq("cert", cert).maybeSingle();
    let info = cached?.info ?? null;
    let imgs: { front: boolean; url: string }[] | null = cached?.images ?? null;

    if (!info) {
      const r = await fetch(API + "GetByCertNumber/" + cert, { headers });
      const text = await r.text();
      if (r.status === 429 || /limit/i.test(text) && r.status >= 400) return reply({ error: "PSA daily lookup limit reached. Try again tomorrow." });
      if (r.status === 401 || r.status === 403 || r.status === 500 && /auth|token|credential/i.test(text))
        return reply({ error: "PSA rejected the token. Generate a new one and update PSA_TOKEN." });
      let j: any;
      try { j = JSON.parse(text); } catch { return reply({ error: "PSA error: " + text.slice(0, 140) }); }
      if (j?.IsValidRequest === false || !j?.PSACert) return reply({ error: j?.ServerMessage || "No PSA data for cert " + cert });
      info = j.PSACert;
    }

    if (wantImages && imgs === null) {
      imgs = [];
      const r = await fetch(API + "GetImagesByCertNumber/" + cert, { headers });
      if (r.ok) {
        const j = await r.json().catch(() => []);
        imgs = (Array.isArray(j) ? j : [])
          .map((x: any) => ({ front: !!x.IsFrontImage, url: String(x.ImageURL || "") }))
          .filter((x) => x.url.startsWith("https://"));
      }
    }

    await sb.from("psa_cache").upsert({ cert, info, images: imgs, fetched_at: new Date().toISOString() });

    const images: { front: boolean; type: string; data: string }[] = [];
    if (wantImages && imgs) {
      for (const im of [...imgs].sort((a, b) => Number(b.front) - Number(a.front)).slice(0, 2)) {
        try {
          const r = await fetch(im.url);
          if (!r.ok) continue;
          const buf = new Uint8Array(await r.arrayBuffer());
          if (buf.length > 6_000_000) continue;
          images.push({ front: im.front, type: r.headers.get("content-type") || "image/jpeg", data: encodeBase64(buf) });
        } catch { /* skip this image */ }
      }
    }
    return reply({ cert, info, images, cached: !!cached });
  } catch (e) {
    return reply({ error: "Lookup failed: " + String((e as Error)?.message ?? e) });
  }
});
