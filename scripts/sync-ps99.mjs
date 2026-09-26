import fs from 'node:fs/promises';

async function loadDotEnv(){
  try{const raw=await fs.readFile(new URL('../.env',import.meta.url),'utf8');for(const line of raw.split(/\r?\n/)){const t=line.trim();if(!t||t.startsWith('#'))continue;const i=t.indexOf('=');if(i<0)continue;const k=t.slice(0,i).trim(),v=t.slice(i+1).trim().replace(/^['"]|['"]$/g,'');if(process.env[k]===undefined)process.env[k]=v;}}catch{}
}
await loadDotEnv();
const SUPABASE_URL=process.env.VITE_SUPABASE_URL;
const SERVICE_KEY=process.env.SUPABASE_SERVICE_ROLE_KEY;
const API='https://ps99.biggamesapi.io/api';
if(!SUPABASE_URL||!SERVICE_KEY) throw new Error('Set VITE_SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in .env');
async function get(path){const r=await fetch(`${API}${path}`,{headers:{accept:'application/json'}});if(!r.ok)throw new Error(`PS99 API ${r.status} for ${path}`);const j=await r.json();if(j.status!=='ok')throw new Error(j.error?.message||`PS99 API error for ${path}`);return j.data;}
const petData=await get('/collection/Pets');
const rapData=await get('/rap').catch(()=>[]);
const rapMap=new Map();
for(const item of Array.isArray(rapData)?rapData:[]){const c=item?.configData||{};const id=c.id||item?.configName||c.name||'';if(id)rapMap.set(String(id),Number(item?.value||0));if(c.name)rapMap.set(String(c.name),Number(item?.value||0));}
const isHigh=x=>{const n=String(x?.configData?.name||x?.configName||'').toLowerCase();const c=String(x?.category||'').toLowerCase();return c==='huge'||c==='titanic'||c==='gargantuan'||n.startsWith('huge ')||n.startsWith('titanic ')||n.startsWith('gargantuan ')};
const asset=v=>{const m=String(v||'').match(/(\d+)/);return m?`https://ps99.biggamesapi.io/image/${m[1]}`:''};
const rows=(Array.isArray(petData)?petData:[]).filter(isHigh).map(x=>{const c=x.configData||{};const id=x.configName||c.name||'';const name=c.name||id;return {id,name,category:x.category||'Regular',thumbnail_asset:c.thumbnail||'',golden_thumbnail_asset:c.goldenThumbnail||'',thumbnail_url:asset(c.thumbnail),golden_thumbnail_url:asset(c.goldenThumbnail),rap:Number(rapMap.get(String(id))??rapMap.get(String(name))??0),exists_count:0};});
console.log(`PS99 catalog: ${rows.length} high-tier pets`);
console.log(`PS99 RAP: ${rows.filter(x=>x.rap>0).length} priced / ${rows.length} total`);
for(let i=0;i<rows.length;i+=300){const chunk=rows.slice(i,i+300);const r=await fetch(`${SUPABASE_URL}/rest/v1/rpc/upsert_pet_cache`,{method:'POST',headers:{apikey:SERVICE_KEY,authorization:`Bearer ${SERVICE_KEY}`,'content-type':'application/json'},body:JSON.stringify({rows:chunk})});if(!r.ok)throw new Error(`Supabase upload failed: ${await r.text()}`);}
await fs.writeFile(new URL('../ps99-catalog.json',import.meta.url),JSON.stringify(rows,null,2));
console.log('PS99 sync finished. Source = BIG Games collection + official RAP only.');
