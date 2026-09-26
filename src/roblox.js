const userCache = new Map();
const avatarCache = new Map();

function extractUserId(input) {
  const raw = String(input || '').trim();
  const urlMatch = raw.match(/roblox\.com\/users\/(\d+)/i);
  if (urlMatch) return urlMatch[1];
  if (/^\d+$/.test(raw)) return raw;
  return null;
}

async function fetchJson(url, options = {}) {
  const res = await fetch(url, { ...options, headers: { Accept: 'application/json', ...(options.headers || {}) } });
  if (!res.ok) throw new Error(`Roblox API ${res.status}`);
  return res.json();
}

async function fetchUserById(id) {
  const clean = String(id || '').trim();
  if (!/^\d+$/.test(clean)) return null;
  const key = `id:${clean}`;
  if (userCache.has(key)) return userCache.get(key);
  try {
    const user = await fetchJson(`https://users.roblox.com/v1/users/${clean}`);
    if (user?.id) userCache.set(key, user);
    return user?.id ? user : null;
  } catch { return null; }
}

async function fetchUserByUsername(username) {
  const clean = String(username || '').trim();
  if (!clean) return null;
  const key = `name:${clean.toLowerCase()}`;
  if (userCache.has(key)) return userCache.get(key);
  try {
    const json = await fetchJson('https://users.roblox.com/v1/usernames/users', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ usernames: [clean], excludeBannedUsers: false })
    });
    const user = json?.data?.[0] || null;
    if (user?.id) userCache.set(key, user);
    return user;
  } catch { return null; }
}

export async function resolveRobloxUser(input) {
  const clean = String(input || '').trim().replace(/^@/, '');
  if (!clean) return null;
  const id = extractUserId(clean);
  if (id) return fetchUserById(id);
  return fetchUserByUsername(clean);
}

export async function resolveRobloxAvatar(input) {
  const user = await resolveRobloxUser(input);
  if (!user?.id) return null;
  if (avatarCache.has(String(user.id))) return { user, url: avatarCache.get(String(user.id)) };
  try {
    const json = await fetchJson(`https://thumbnails.roblox.com/v1/users/avatar-headshot?userIds=${user.id}&size=150x150&format=Png&isCircular=false`);
    const image = json?.data?.[0]?.imageUrl || null;
    if (image) avatarCache.set(String(user.id), image);
    return { user, url: image };
  } catch { return { user, url: null }; }
}
