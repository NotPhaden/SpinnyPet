import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const API = "https://ps99.biggamesapi.io/api";
const ROBLOX = "https://thumbnails.roblox.com/v1/assets";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("POST only", { status: 405 });

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const db = createClient(supabaseUrl, serviceRole);

  try {
    const [petsRes, rapRes, existsRes] = await Promise.all([
      fetch(`${API}/collection/Pets`),
      fetch(`${API}/rap`),
      fetch(`${API}/exists`)
    ]);
    if (!petsRes.ok) throw new Error(`Pets API ${petsRes.status}`);

    const petsPayload = await petsRes.json();
    const rapPayload = rapRes.ok ? await rapRes.json() : { data: [] };
    const existsPayload = existsRes.ok ? await existsRes.json() : { data: [] };

    const rap = new Map<string, number>();
    for (const item of Array.isArray(rapPayload.data) ? rapPayload.data : []) {
      const id = item?.configData?.id || item?.configName;
      if (id) rap.set(id, Number(item.value || 0));
    }

    const exists = new Map<string, number>();
    for (const item of Array.isArray(existsPayload.data) ? existsPayload.data : []) {
      const id = item?.configData?.id || item?.configName;
      if (id) exists.set(id, Number(item.value || item.exists || 0));
    }

    const raw = Array.isArray(petsPayload.data) ? petsPayload.data : [];
    const base = raw.map((item: any) => {
      const cfg = item.configData || {};
      const id = item.configName || cfg.name || cfg.id;
      return {
        id,
        name: cfg.name || id,
        category: item.category || "Regular",
        thumbnail_asset: cfg.thumbnail || cfg.icon || null,
        golden_thumbnail_asset: cfg.goldenThumbnail || null,
        rap: rap.get(id) || 0,
        exists_count: exists.get(id) || 0,
      };
    }).filter((x: any) => x.id && x.name);

    const ids = [...new Set(base.flatMap((p: any) => [p.thumbnail_asset, p.golden_thumbnail_asset]).map(assetNumber).filter(Boolean))];
    const urls = new Map<string, string>();

    for (let i = 0; i < ids.length; i += 100) {
      const batch = ids.slice(i, i + 100);
      const r = await fetch(`${ROBLOX}?assetIds=${batch.join(",")}&size=420x420&format=Png&isCircular=false`);
      if (!r.ok) continue;
      const payload = await r.json();
      for (const item of payload?.data || []) {
        if (item?.targetId && item?.imageUrl) urls.set(String(item.targetId), item.imageUrl);
      }
    }

    const rows = base.map((p: any) => ({
      ...p,
      thumbnail_url: urls.get(assetNumber(p.thumbnail_asset)) || null,
      golden_thumbnail_url: urls.get(assetNumber(p.golden_thumbnail_asset)) || null,
    }));

    for (let i = 0; i < rows.length; i += 500) {
      const { error } = await db.rpc("upsert_pet_cache", { rows: rows.slice(i, i + 500) });
      if (error) throw error;
    }

    return Response.json({ ok: true, pets: rows.length });
  } catch (error) {
    return Response.json({ ok: false, error: String(error) }, { status: 500 });
  }
});

function assetNumber(value: string | null) {
  const match = String(value || "").match(/(?:rbxassetid:\/\/)?(\d+)/i);
  return match?.[1] || "";
}
