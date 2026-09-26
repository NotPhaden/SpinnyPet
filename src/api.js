import { supabase, supabaseConfigured } from "./supabase";

const API = "https://ps99.biggamesapi.io/api";
// BIG Games exposes a server-side image proxy that returns the image bytes directly.
// This is preferable to using Roblox's thumbnail JSON API in the browser.
const PS99_IMAGE = "https://ps99.biggamesapi.io/image";
const jsonCache = new Map();
const petCatalogCache = { data: null, time: 0 };

function assetNumber(value) {
  const match = String(value || "").match(/(?:rbxassetid:\/\/)?(\d+)/i);
  return match ? match[1] : null;
}

export function petImageUrl(assetId) {
  const id = assetNumber(assetId);
  return id ? `${PS99_IMAGE}/${id}` : "";
}

export function rbxAssetIdToNumber(value) {
  return assetNumber(value);
}

export function robloxThumbnail(assetId) {
  // Kept as a compatibility export for any old component imports.
  return petImageUrl(assetId);
}

async function getJson(path, ttl = 10 * 60 * 1000) {
  const cached = jsonCache.get(path);
  if (cached && Date.now() - cached.time < ttl) return cached.data;

  const response = await fetch(`${API}${path}`, { headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error(`PS99 API returned ${response.status}`);

  const payload = await response.json();
  if (payload.status !== "ok") throw new Error(payload.error?.message || "PS99 API error");

  jsonCache.set(path, { time: Date.now(), data: payload.data });
  return payload.data;
}

function cleanPet(raw, cached = null) {
  const cfg = raw?.configData || {};
  const id = raw?.configName || cfg.name || cfg.id || cached?.id || "Unknown Pet";
  const thumbnail = cfg.thumbnail || cfg.icon || cached?.thumbnail_asset || "";
  const goldenThumbnail = cfg.goldenThumbnail || cached?.golden_thumbnail_asset || "";

  return {
    id,
    name: cfg.name || cached?.name || id,
    category: raw?.category || cached?.category || "Regular",
    thumbnail,
    goldenThumbnail,
    // Always derive the URL from the asset ID. This repairs old Supabase rows
    // that were populated with the broken Roblox thumbnail JSON endpoint.
    thumbnailUrl: petImageUrl(thumbnail) || cached?.thumbnail_url || "",
    goldenThumbnailUrl: petImageUrl(goldenThumbnail) || cached?.golden_thumbnail_url || "",
    huge: Boolean(cfg.huge || raw?.category === "Huge"),
    secret: Boolean(raw?.category === "Secret"),
    indexObtainable: cfg.indexObtainable !== false,
    rap: Number(cached?.rap || 0),
    exists: Number(cached?.exists_count || 0)
  };
}

function cacheRowsFromPets(pets) {
  return pets.map((pet) => ({
    id: pet.id,
    name: pet.name,
    category: pet.category,
    thumbnail_asset: pet.thumbnail || null,
    golden_thumbnail_asset: pet.goldenThumbnail || null,
    thumbnail_url: petImageUrl(pet.thumbnail) || pet.thumbnailUrl || null,
    golden_thumbnail_url: petImageUrl(pet.goldenThumbnail) || pet.goldenThumbnailUrl || null,
    rap: Number(pet.rap || 0),
    exists_count: Number(pet.exists || 0)
  }));
}

async function readSupabasePetCache() {
  if (!supabaseConfigured || !supabase) return [];
  const { data, error } = await supabase
    .from("pets_cache")
    .select("id,name,category,thumbnail_asset,golden_thumbnail_asset,thumbnail_url,golden_thumbnail_url,rap,exists_count,synced_at")
    .order("name", { ascending: true });
  if (error) throw error;
  return Array.isArray(data) ? data : [];
}

async function writePublicCatalogMetadata(rows) {
  if (!supabaseConfigured || !supabase || !rows.length) return;
  const highTier = rows.filter(isEligibleCatalogPet).map(r => ({
    id:r.id,name:r.name,category:r.category,thumbnail_asset:r.thumbnail || null,
    golden_thumbnail_asset:r.goldenThumbnail || null,
    thumbnail_url:r.thumbnailUrl || petImageUrl(r.thumbnail) || null,
    golden_thumbnail_url:r.goldenThumbnailUrl || petImageUrl(r.goldenThumbnail) || null,
    rap:Number(r.rap||0),exists_count:Number(r.exists||0)
  }));
  if (!highTier.length) return;
  const { error } = await supabase.rpc("upsert_public_catalog", { rows: highTier });
  if (error) throw error;
}

async function writeSupabasePetCache(rows) {
  if (!supabaseConfigured || !supabase || !rows.length) return;
  const chunkSize = 500;
  for (let i = 0; i < rows.length; i += chunkSize) {
    const chunk = rows.slice(i, i + chunkSize);
    const { error } = await supabase.rpc("upsert_pet_cache", { rows: chunk });
    if (error) throw error;
  }
}

function cachedToPet(row) {
  return cleanPet(
    {
      configName: row.id,
      category: row.category,
      configData: {
        name: row.name,
        thumbnail: row.thumbnail_asset,
        goldenThumbnail: row.golden_thumbnail_asset
      }
    },
    row
  );
}

async function fetchRemoteCatalog() {
  const [petData, rapData, existsData] = await Promise.all([
    getJson("/collection/Pets", 30 * 60 * 1000),
    getJson("/rap", 4 * 60 * 60 * 1000).catch(() => []),
    getJson("/exists", 30 * 60 * 1000).catch(() => [])
  ]);

  const rapMap = new Map();
  const addMetric = (map, value, ...keys) => {
    const n = Number(value || 0);
    for (const key of keys) {
      if (key == null) continue;
      const clean = String(key).trim();
      if (!clean) continue;
      map.set(clean, n);
      map.set(clean.toLowerCase(), n);
    }
  };
  for (const item of Array.isArray(rapData) ? rapData : []) {
    const cfg = item?.configData || {};
    addMetric(rapMap, item?.value, item?.configName, cfg.id, cfg.name, item?.name);
  }

  const existsMap = new Map();
  for (const item of Array.isArray(existsData) ? existsData : []) {
    const cfg = item?.configData || {};
    addMetric(existsMap, item?.value ?? item?.exists, item?.configName, cfg.id, cfg.name, item?.name);
  }

  const lookupMetric = (map, ...keys) => {
    for (const key of keys) {
      if (key == null) continue;
      const clean = String(key).trim();
      if (map.has(clean)) return map.get(clean);
      const lower = clean.toLowerCase();
      if (map.has(lower)) return map.get(lower);
    }
    return 0;
  };

  return (Array.isArray(petData) ? petData : []).map((raw) => {
    const pet = cleanPet(raw);
    const cfg = raw?.configData || {};
    return {
      ...pet,
      rap: lookupMetric(rapMap, pet.id, pet.name, raw?.configName, cfg.id, cfg.name),
      exists: lookupMetric(existsMap, pet.id, pet.name, raw?.configName, cfg.id, cfg.name),
      thumbnailUrl: petImageUrl(pet.thumbnail),
      goldenThumbnailUrl: petImageUrl(pet.goldenThumbnail)
    };
  });
}

export function isEligibleCatalogPet(pet) {
  const name = String(pet?.name || pet?.id || "").toLowerCase();
  const category = String(pet?.category || "").toLowerCase();
  return (
    category === "huge" || category === "titanic" || category === "gargantuan" ||
    name.startsWith("huge ") || name.startsWith("titanic ") || name.startsWith("gargantuan ")
  );
}

export function filterEligiblePets(pets) {
  const seen = new Set();
  return (Array.isArray(pets) ? pets : [])
    .filter(isEligibleCatalogPet)
    .filter(p => { const key = String(p?.id || p?.name || ""); if (!key || seen.has(key)) return false; seen.add(key); return true; })
    .sort((a,b) => {
      const rank = p => { const s = `${p?.category||""} ${p?.name||""}`.toLowerCase(); return s.includes("gargantuan") ? 0 : s.includes("titanic") ? 1 : 2; };
      const r = rank(a)-rank(b);
      return r || String(a.name||"").localeCompare(String(b.name||""));
    });
}

export async function fetchPets({ forceRefresh = false } = {}) {
  if (!forceRefresh && petCatalogCache.data && Date.now() - petCatalogCache.time < 60_000) {
    return petCatalogCache.data;
  }

  // Prefer a fresh BIG Games catalog so newly added Titanics/Gargantuans are
  // immediately searchable. Supabase remains the persistent fallback/cache.
  try {
    let remotePets = await fetchRemoteCatalog();
    if (supabaseConfigured) {
      try {
        const cachedRows = await readSupabasePetCache();
        // Union the persisted catalog with the live BIG Games catalog so high-tier pets
        // that are temporarily absent from one source still appear and can be shown locked.
        const remoteIds = new Set(remotePets.map(x => String(x.id)));
        for (const row of cachedRows) {
          if (!isEligibleCatalogPet(row) || remoteIds.has(String(row.id))) continue;
          remotePets.push(cachedToPet(row));
        }
      } catch {}
      await writePublicCatalogMetadata(remotePets).catch(() => {});
      writeSupabasePetCache(cacheRowsFromPets(remotePets)).catch(() => {});
    }
    petCatalogCache.data = remotePets;
    petCatalogCache.time = Date.now();
    return remotePets;
  } catch (remoteError) {
    if (!forceRefresh && supabaseConfigured) {
      try {
        const cachedRows = await readSupabasePetCache();
        if (cachedRows.length) {
          const cachedPets = cachedRows.map(cachedToPet);
          petCatalogCache.data = cachedPets;
          petCatalogCache.time = Date.now();
          return cachedPets;
        }
      } catch {
        // handled below
      }
    }
    throw remoteError;
  }
}

export async function fetchRAP() {
  return getJson("/rap", 4 * 60 * 60 * 1000);
}

export async function fetchExists() {
  return getJson("/exists", 30 * 60 * 1000);
}
