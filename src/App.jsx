import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ArrowUp, CircleUserRound, Dice5, Gift, Hash, Heart, LogIn, MessageCircle, Package, RefreshCw, ShieldCheck, Trophy, WalletCards, X, Crown, Users, Sparkles, Send, Plus, Clock3, History, TrendingUp, TrendingDown, Box, Zap, Tag, Upload, Calculator, Minus, Medal, BarChart3, UserPlus, UserMinus, Settings2, Swords, Bomb, CircleDot, Rocket } from "lucide-react";
import { supabase, supabaseConfigured } from "./supabase";
import { fetchPets, filterEligiblePets } from "./api";
import { betaClaimBonus, betaClaimDailyCase, betaCreateGiveaway, betaCreateLobby, betaCreateDiceLobby, betaJoinDiceLobby, betaDrawGiveaway, betaEnterGiveaway, betaGetGiveaways, betaGetHistory, betaGetLiveBets, betaGetInventory, betaSellPet, betaSellAllPets, betaGetStats, betaSendChat, betaSession, betaSignIn, betaSignOut, betaSignUp, betaUpdateRobloxProfile, betaRunUpgrade, betaGetRole, betaAdminGetUsers, betaAdminGetInventory, betaAdminClearInventory, betaAdminRemovePet, betaAdminSetBalance, betaAdminGiveAll, betaAdminModerate, betaAdminSetRole, betaAdminSetEvent, betaAdminTriggerChaos, betaGetActiveEvent, betaJoinEvent, betaPlayEvent, betaOpenCase, betaRedeemPromo, betaAdminCreatePromo, betaFinalizeGiveaways, betaGetJoinedGiveaways, betaUpdateCustomAvatar, betaListLobbies, betaCancelLobby, betaGetCoinflipResult, betaGetLobbyResult, betaJoinLobby, betaCreateCaseBattle, betaJoinCaseBattle, betaGetCaseBattle, betaListCaseBattles, betaGetTimeRewards, betaClaimTimeReward, betaOpenCaseTicket, betaGetTimeTickets, betaGetLeaderboard, betaGetClan, betaGetTopClans, betaGetPublicClan, betaCreateClan, betaInviteToClan, betaRespondClanInvite, betaKickClanMember, betaUpgradeClan, betaClaimClanTopReward, betaDepositClan, betaAdminDeleteClan, betaGetClanBattleTimer, betaAdminResetClanBattleTimer, betaAdminResetLeaderboard, betaMinesStart, betaMinesReveal, betaMinesCashout, betaPlinkoPlay, betaCrashStart, betaCrashCashout } from "./betaAuth";
import { displayPetValue, formatCompact, formatNumber, parseCompactAmount, rankForWagered } from "./format";
import { Modal, PetCard, PetIcon, PoolCard, SearchBox, tierOf } from "./components";
import { resolveRobloxAvatar } from "./roblox";
import { CASES, CASE_POOL_CONFIG, CASE_TIER_CONFIG } from "./cases";
import { WAGERED_SEED, PROFIT_SEED } from "./leaderboardData";

const SITE_NAME = "SpinnyPet";
const DISCORD_URL = "https://discord.gg/zPGvFynKG";
const ROUTES = { "/":"home","/coinflip":"coinflip","/dice":"dice","/inventory":"inventory","/profile":"profile","/daily-cases":"time-rewards","/cases":"cases","/case-battle":"case-battle","/leaderboard":"leaderboard","/mines":"mines","/plinko":"plinko","/crash":"crash","/clans":"clans","/giveaways":"giveaways","/promo":"promo","/admin":"admin" };
const PATHS = Object.fromEntries(Object.entries(ROUTES).map(([path,page])=>[page,path]));
const GAME_CARDS = [
  { name:"Coinflip", route:"coinflip", asset:"/assets/coinflip.png", desc:"50/50 Heads or Tails duels" },
  { name:"Color Dice", route:"dice", asset:"/assets/dice.png", desc:"Pick colors and create your own room" },
  { name:"Case Battle", route:"case-battle", asset:"/assets/case-cosmic.png", desc:"Battle with the same SpinnyPet cases" },
  { name:"Pet Mines", route:"mines", asset:"/assets/galaxycase.png", desc:"Reveal gems, avoid the mines" },
  { name:"Pet Plinko", route:"plinko", asset:"/assets/dicebackground.png", desc:"Drop a chip through multiplier gates" },
  { name:"Pet Crash", route:"crash", asset:"/assets/globalbackground.png", desc:"Cash out before the rocket crashes" }
];

function currentRoute(){
  const path=window.location.pathname.replace(/\/+$/,"")||"/";
  if(path==="/cases" || path.startsWith("/cases/")) return "cases";
  return ROUTES[path] || "home";
}
function caseImage(c){ const src=String(c?.image||""); return src.startsWith("/") ? src : `/assets/${src}`; }
function petStakeLabel(items){
  const arr=Array.isArray(items)?items:[];
  if(!arr.length) return "";
  return arr.map((p)=>{
    const name=p?.name||p?.pet_name||p?.petId||p?.pet_id||"Pet";
    const q=Number(p?.quantity||p?.count||1);
    return q>1?`${name} ×${q}`:name;
  }).join(" · ");
}
function PetStakeInline({items}){
  const label=petStakeLabel(items);
  return label?<div className="pet-stake-inline"><span>🐾</span><b>{label}</b></div>:null;
}


function caseFromPath(){
  const m=window.location.pathname.match(/^\/cases\/([^/]+)$/);
  return m ? decodeURIComponent(m[1]) : null;
}
function petValue(p){ return Math.max(0,Number(p?.rap||0)); }
function formatPetValue(p){ const v=petValue(p); return v>0 ? formatCompact(v) : 'NOT PRICED'; }
function normalizeUsername(v){ return String(v||'').trim().toLowerCase(); }
function inventoryPetShape(i){ return { id:i.pet_id, name:i.name, thumbnail:i.thumbnail_asset, thumbnailUrl:i.thumbnail_url, goldenThumbnail:i.golden_thumbnail_asset, goldenThumbnailUrl:i.golden_thumbnail_url, rap:Number(i.rap||0), category:i.category||"Owned" }; }
function isHighTierName(name){ const n=String(name||"").toLowerCase(); return n.startsWith("huge ")||n.startsWith("titanic ")||n.startsWith("gargantuan "); }
function playWinSound(){ try{ const a=new Audio("/assets/win.ogg"); a.volume=1; a.play().catch(()=>{}); }catch{} }
function playLoseSound(){ try{ const a=new Audio("/assets/lose.wav"); a.volume=1; a.play().catch(()=>{}); }catch{} }
function playCaseOpenSound(){ try{ const a=new Audio("/assets/case-open.wav"); a.volume=1; a.play().catch(()=>{}); }catch{} }
function playMatchSound(kind="click"){ try{ const C=window.AudioContext||window.webkitAudioContext; if(!C)return; const ctx=new C(); const o=ctx.createOscillator(), g=ctx.createGain(); const cfg={click:[520,.045,"square"],tick:[680,.07,"square"],roll:[190,.16,"sawtooth"],reveal:[880,.16,"triangle"],open:[330,.09,"triangle"],case:[260,.12,"sawtooth"]}[kind]||[520,.05,"square"]; o.type=cfg[2];o.frequency.value=cfg[0];g.gain.setValueAtTime(.0001,ctx.currentTime);g.gain.exponentialRampToValueAtTime(.24,ctx.currentTime+.008);g.gain.exponentialRampToValueAtTime(.0001,ctx.currentTime+cfg[1]);o.connect(g);g.connect(ctx.destination);o.start();o.stop(ctx.currentTime+cfg[1]+.02);setTimeout(()=>ctx.close().catch(()=>{}),Math.ceil((cfg[1]+.1)*1000)); }catch{} }
function caseTierName(p){ const n=String(p?.name||'').toLowerCase(); const c=String(p?.category||'').toLowerCase(); if(n.startsWith('gargantuan ')||c==='gargantuan')return 'GARGANTUAN'; if(n.startsWith('titanic ')||c==='titanic')return 'TITANIC'; return 'HUGE'; }
function caseDisplayRewards(pets, selected){
  const allowed=new Set(CASE_TIER_CONFIG[selected?.id]||['HUGE']);
  const grouped={HUGE:[],TITANIC:[],GARGANTUAN:[]};
  (pets||[]).filter(p=>allowed.has(caseTierName(p)) && petValue(p)>0).forEach(p=>grouped[caseTierName(p)].push(p));
  Object.values(grouped).forEach(arr=>arr.sort((x,y)=>petValue(y)-petValue(x)));
  const out=[];
  for(const tier of ['GARGANTUAN','TITANIC','HUGE']){ if(!allowed.has(tier))continue; out.push(...grouped[tier].slice(0, tier==='HUGE'?8:4)); }
  return out.slice(0,16);
}


export default function App(){
  const [page,setPage]=useState(currentRoute()); const [caseId,setCaseId]=useState(caseFromPath()); const [pets,setPets]=useState([]); const [loadingPets,setLoadingPets]=useState(true); const [petError,setPetError]=useState("");
  const [session,setSession]=useState(null); const [profile,setProfile]=useState(null); const [authOpen,setAuthOpen]=useState(false); const [authMode,setAuthMode]=useState("login");
  const [inventory,setInventory]=useState([]); const [search,setSearch]=useState(""); const [toast,setToast]=useState("");
  const [chat,setChat]=useState([]); const [chatText,setChatText]=useState(""); const [history,setHistory]=useState([]); const [stats,setStats]=useState({});
  const [giveaways,setGiveaways]=useState([]); const [joinedGiveawayIds,setJoinedGiveawayIds]=useState([]);
  const [role,setRole]=useState("user");
  const [event,setEvent]=useState(null);
  const [adminEffect,setAdminEffect]=useState(null);

  useEffect(()=>{
    document.title=`${SITE_NAME} · Beta`; document.querySelector('link[rel="icon"]')?.setAttribute("href","/assets/favicon.png");
    const onPop=()=>{ setPage(currentRoute()); setCaseId(caseFromPath()); }; window.addEventListener("popstate",onPop);
    loadPets(); loadChat(); loadGiveaways(); loadEvent();
    const giveawayTimer=setInterval(()=>{ betaFinalizeGiveaways().then(loadGiveaways).catch(()=>{}); },2000);
    const cached=betaSession(); cached.then(async s=>{ if(s){ setSession(s); setProfile(s); await refreshPrivate(); } });
    let channel=null;
    let adminChannel=null;
    if(supabase){
      adminChannel=supabase.channel("spinnypet-admin-effects")
        .on("postgres_changes",{event:"INSERT",schema:"public",table:"beta_admin_effects"},(p)=>{
          const fx=p.new||{};
          const target=String(fx.target_page||"all");
          if(target!=="all" && target!==currentRoute()) return;
          setAdminEffect({...fx,_nonce:Date.now()});
          if(Number(fx.reward_amount||0)>0){
            refreshPrivate();
            setToast(`ADMIN DROP · +💎 ${formatCompact(Number(fx.reward_amount))}`);
          }
          setTimeout(()=>setAdminEffect(null),6500);
        }).subscribe();
      channel=supabase.channel("petflip-live")
        .on("postgres_changes",{event:"INSERT",schema:"public",table:"beta_chat_messages"},(p)=>{
          setChat(v=>{
            if(v.some(x=>x.id===p.new.id)) return v;
            return [...v,p.new].slice(-100);
          });
        })
        .subscribe();
    }
    return ()=>{ window.removeEventListener("popstate",onPop); if(channel) supabase.removeChannel(channel); if(adminChannel) supabase.removeChannel(adminChannel); clearInterval(giveawayTimer); };
  },[]);

  useEffect(()=>{ loadGiveaways(); },[session?.user_id]);

  useEffect(()=>{
    const refreshHandler=()=>refreshPrivate();
    window.addEventListener("petflip:refresh-private",refreshHandler);
    return ()=>window.removeEventListener("petflip:refresh-private",refreshHandler);
  },[session]);

  useEffect(()=>{
    const labels={home:"Home",coinflip:"Coinflip",dice:"Color Dice",inventory:"Inventory",profile:"Profile","daily-cases":"Time Rewards",cases:"Cases","case-battle":"Case Battle",mines:"Pet Mines",plinko:"Pet Plinko",crash:"Pet Crash",leaderboard:"Leaderboard",clans:"Clans",giveaways:"Giveaways",promo:"Promo Code",admin:"Admin Panel"};
    document.title=`${SITE_NAME} · ${labels[page]||"Beta"}`;
  },[page]);

  async function refreshPrivate(){
    try{ setInventory(await betaGetInventory()); }catch{}
    try{ const st=await betaGetStats(); setStats(st); if(st?.balance!==undefined){setSession(v=>v?({...v,balance:Number(st.balance)}):v);setProfile(v=>v?({...v,balance:Number(st.balance)}):v);} }catch{}
    try{ setHistory(await betaGetHistory()); }catch{}
    try{ setRole(await betaGetRole()); }catch{ setRole("user"); }
    try{ setEvent(await betaGetActiveEvent()); }catch{}
  }
  async function loadEvent(){ try{setEvent(await betaGetActiveEvent());}catch{} }
  function navigate(next){
    const raw=String(next);
    const isCase=raw.startsWith("/cases/");
    const path=isCase?raw:(PATHS[raw]||"/");
    if(window.location.pathname!==path) window.history.pushState({page:isCase?"cases":raw,caseId:isCase?caseFromPath():null},"",path);
    setCaseId(isCase ? decodeURIComponent(raw.replace(/^\/cases\//,"")) : null);
    setPage(isCase ? "cases" : raw);
    setAdminEffect(null);
    window.scrollTo({top:0,behavior:"smooth"});
  }
  async function loadPets(force=false){ setLoadingPets(true); setPetError(""); try{ setPets(await fetchPets({forceRefresh:force})); }catch(e){setPetError(e.message||"Could not load the pet catalog.");}finally{setLoadingPets(false);} }
  async function loadChat(){ if(!supabase)return; const {data}=await supabase.from("beta_chat_messages").select("id,user_id,username,message,created_at,role,rank_name,custom_avatar_url").order("created_at",{ascending:false}).limit(100); setChat((data||[]).reverse()); }
  async function loadGiveaways(){
    if(!supabase)return;
    try{await betaFinalizeGiveaways();}catch{}
    try{setGiveaways(await betaGetGiveaways());}catch{}
    if(!session)return;
    const key=`spinnypet:joined-giveaways:${session.user_id}`;
    let local=[];
    try{local=JSON.parse(localStorage.getItem(key)||"[]");if(!Array.isArray(local))local=[];}catch{local=[]}
    // Never clear an optimistic/local JOINED state just because an older database patch
    // does not expose beta_get_joined_giveaways yet. Server state is merged into local state.
    try{
      const server=await betaGetJoinedGiveaways();
      const merged=[...new Set([...(local||[]),...(Array.isArray(server)?server:[])])];
      setJoinedGiveawayIds(merged);
      localStorage.setItem(key,JSON.stringify(merged));
    }catch{
      setJoinedGiveawayIds(local);
    }
  }
  async function claimBonus(){ if(!session){setAuthMode("signup");setAuthOpen(true);return;} try{await loadPets();const d=await betaClaimBonus();setProfile(p=>({...p,balance:Number(d.balance)}));setSession(p=>({...p,balance:Number(d.balance)}));await refreshPrivate();setToast(d.pet_name?`50B + ${d.pet_name} received.`:(d.cooldown_seconds?`Next beta reward in ${Math.ceil(d.cooldown_seconds/60)} min.`:"Beta reward unavailable."));}catch(e){setToast(e.message||"Could not claim bonus.");} }
  async function claimDaily(){ if(!session){setAuthMode("login");setAuthOpen(true);return;} try{await loadPets();const d=await betaClaimDailyCase();setProfile(p=>({...p,balance:Number(d.balance)}));setSession(p=>({...p,balance:Number(d.balance)}));await refreshPrivate();setToast(d.message||"Daily case claimed.");}catch(e){setToast(e.message||"Daily case unavailable.");} }
  async function signOut(){try{await betaSignOut();}finally{setSession(null);setProfile(null);setInventory([]);setHistory([]);setStats({});setRole("user");setEvent(null);navigate("home");}}
  async function sendChat(){ if(!chatText.trim())return; if(!session){setAuthMode("login");setAuthOpen(true);return;} try{const row=await betaSendChat(chatText);setChat(v=>v.some(x=>x.id===row.id)?v:[...v,row].slice(-100));setChatText("");}catch(e){setToast(e.message||"Could not send message.");} }
  async function authSuccess(data){setSession(data);setProfile(data);setAuthOpen(false);await refreshPrivate();}
  async function syncRoblox(input){
    if(!session){setAuthMode("login");setAuthOpen(true);return;}
    const clean=String(input||stats?.roblox_user_id||stats?.roblox_username||"").trim();
    if(!clean){setToast("Enter your Roblox username or numeric User ID first.");return;}
    const result=await resolveRobloxAvatar(clean);
    if(!result?.user?.id){setToast("Roblox profile not found. Use the exact Roblox username, numeric User ID, or roblox.com/users/ID/profile URL.");return;}
    try{
      const saved=await betaUpdateRobloxProfile(result.user.id,result.user.name,result.url||"");
      setStats(v=>({...v,roblox_user_id:result.user.id,roblox_username:result.user.name,avatar_url:result.url||""}));
      setProfile(v=>({...v,roblox_user_id:result.user.id,roblox_username:result.user.name,avatar_url:result.url||""}));
      setToast(`Roblox avatar linked: @${result.user.name}${saved?.avatar_url?"":" (avatar image unavailable)"}`);
    }catch(e){setToast(e.message||"Could not save Roblox profile.");}
  }

  const eligible=useMemo(()=>filterEligiblePets(pets),[pets]);
  const balance=Number(session?.balance ?? profile?.balance ?? stats?.balance ?? 0);
  const totalPetValue=useMemo(()=>inventory.reduce((sum,i)=>sum+petValue(i)*Number(i.quantity||0),0),[inventory]);
  const totalVirtualValue=balance+totalPetValue;
  const currentAvatar=stats?.custom_avatar_url||stats?.avatar_url;
  const q=search.trim().toLowerCase();
  const filtered=useMemo(()=>!q?eligible:eligible.filter(p=>p.name.toLowerCase().includes(q)||String(p.category||"").toLowerCase().includes(q)),[eligible,q]);
  window.__SPINNYPET_INVENTORY__=inventory;
  const rank=rankForWagered(stats?.wagered||0);
  const giveawaysWithAssets=useMemo(()=>giveaways.map(g=>({...g, reward_pet_thumbnail_url:g.reward_pet_thumbnail_url||pets.find(p=>p.id===g.reward_pet_id)?.thumbnailUrl||"", reward_pet_golden_thumbnail_url:g.reward_pet_golden_thumbnail_url||pets.find(p=>p.id===g.reward_pet_id)?.goldenThumbnailUrl||""})),[giveaways,pets]);

  return <div className="app-shell">
    <header className="topbar">
      <button className="brand brand-banner" onClick={()=>navigate("home")}><img src="/assets/banner.png" alt="SpinnyPet"/><em>BETA</em></button>
      <div className="top-actions">
        {session&&<WalletSummary balance={balance} totalVirtualValue={totalVirtualValue}/>} {session?<button className="user-pill" onClick={()=>navigate("profile")}>{currentAvatar?<img src={currentAvatar} alt=""/>:<CircleUserRound size={17}/>}<span>{session.username}</span></button>:<button className="wallet-btn" onClick={()=>{setAuthMode("login");setAuthOpen(true)}}><LogIn size={16}/> Sign in</button>}
      </div>
    </header>
    <div className="main-layout">
      <aside className="sidebar">
        <button className="menu-button" title="SpinnyPet"><img src="/assets/banner.png" alt="SpinnyPet"/></button>
        <NavGroup title="GAMES">
          <SideLink active={page==="home"} icon={<HouseIcon/>} label="Home" onClick={()=>navigate("home")}/>
          <SideLink active={page==="coinflip"} icon={<Hash size={18}/>} label="Coinflip" onClick={()=>navigate("coinflip")}/>
          <SideLink active={page==="dice"} icon={<Dice5 size={18}/>} label="Color Dice" onClick={()=>navigate("dice")}/>
          <SideLink active={page==="cases"} icon={<Box size={18}/>} label="Cases" onClick={()=>navigate("cases")}/>
          <SideLink active={page==="case-battle"} icon={<Trophy size={18}/>} label="Case Battle" onClick={()=>navigate("case-battle")}/>
          <SideLink active={page==="mines"} icon={<Bomb size={18}/>} label="Pet Mines" onClick={()=>navigate("mines")}/>
          <SideLink active={page==="plinko"} icon={<CircleDot size={18}/>} label="Pet Plinko" onClick={()=>navigate("plinko")}/>
          <SideLink active={page==="crash"} icon={<Rocket size={18}/>} label="Pet Crash" onClick={()=>navigate("crash")}/>
          <SideLink active={page==="leaderboard"} icon={<BarChart3 size={18}/>} label="Leaderboard" onClick={()=>navigate("leaderboard")}/>
        </NavGroup>
        <NavGroup title="MORE">
          <SideLink active={page==="profile"} icon={<CircleUserRound size={18}/>} label="Profile" onClick={()=>navigate("profile")}/>
          <SideLink active={page==="inventory"} icon={<Package size={18}/>} label="Inventory" onClick={()=>navigate("inventory")}/>
          <SideLink active={page==="clans"} icon={<Swords size={18}/>} label="Clans" onClick={()=>navigate("clans")}/>
          <SideLink active={page==="daily-cases"} icon={<Gift size={18}/>} label="Time Rewards" onClick={()=>navigate("daily-cases")}/>
          <SideLink active={page==="giveaways"} icon={<Crown size={18}/>} label="Giveaways" onClick={()=>navigate("giveaways")}/>
          <SideLink active={page==="promo"} icon={<Tag size={18}/>} label="Promo Code" onClick={()=>navigate("promo")}/>
          {role!=="user"&&<SideLink active={page==="admin"} icon={<ShieldCheck size={18}/>} label="Admin Panel" onClick={()=>navigate("admin")}/>} 
          <SideLink icon={<MessageCircle size={18}/>} label="Discord" onClick={()=>window.open(DISCORD_URL,"_blank","noopener,noreferrer")}/>
        </NavGroup>
        <div className="sidebar-bottom"><button className="beta-bonus" onClick={claimBonus}><Gift size={19}/><span><b>50B + Random Titanic</b><small>Every 30 minutes</small></span></button>{session&&<button className="signout" onClick={signOut}><LogIn size={15}/><span>Sign out</span></button>}</div>
      </aside>
      <main className="content">
        <PageAtmosphere page={page} adminEffect={adminEffect} />
        {page==="home"&&<Home pets={eligible} filtered={filtered} loading={loadingPets} error={petError} search={search} setSearch={setSearch} refresh={()=>loadPets(true)} navigate={navigate} rank={rank} balance={balance}/>} 
        {page==="coinflip"&&<CoinflipPage inventory={inventory} balance={balance} session={session} setAuthOpen={setAuthOpen} toast={setToast}/>}
        {page==="dice"&&<ColorDicePage pets={eligible} inventory={inventory} balance={balance} session={session} setAuthOpen={setAuthOpen} toast={setToast}/>} 
        {page==="inventory"&&<InventoryPage pets={eligible} inventory={inventory} search={search} setSearch={setSearch} setToast={setToast} onRefresh={refreshPrivate}/>} 
        {page==="profile"&&<ProfilePage session={session} stats={stats} history={history} rank={rank} onSignIn={()=>{setAuthMode("login");setAuthOpen(true)}} onClaim={claimBonus} onSignOut={signOut} onCustomAvatar={async(url)=>{try{const saved=await betaUpdateCustomAvatar(url);const avatar=saved?.custom_avatar_url||url||"";setStats(v=>({...v,custom_avatar_url:avatar}));setChat(v=>v.map(m=>m.user_id===session?.user_id?({...m,custom_avatar_url:avatar}):m));await refreshPrivate();setStats(v=>({...v,custom_avatar_url:avatar}));setToast("Profile picture updated.")}catch(e){setToast(e.message||"Could not update picture.")}}}/>} 
        {(page==="time-rewards"||page==="daily-cases")&&<TimeRewardsPage session={session} pets={eligible} balance={balance} setAuthOpen={setAuthOpen} setToast={setToast}/>}
        {page==="cases"&&<CasesPage session={session} pets={eligible} balance={balance} setAuthOpen={setAuthOpen} setToast={setToast} navigate={navigate} caseId={caseId}/>}
        {page==="case-battle"&&<CaseBattlePage session={session} pets={eligible} balance={balance} setAuthOpen={setAuthOpen} setToast={setToast}/>}
        {page==="mines"&&<MinesPage session={session} balance={balance} setAuthOpen={setAuthOpen} setToast={setToast} onRefresh={refreshPrivate}/>}
        {page==="plinko"&&<PlinkoPage session={session} balance={balance} setAuthOpen={setAuthOpen} setToast={setToast} onRefresh={refreshPrivate}/>}
        {page==="crash"&&<CrashPage session={session} balance={balance} setAuthOpen={setAuthOpen} setToast={setToast} onRefresh={refreshPrivate}/>}
        {page==="leaderboard"&&<LeaderboardPage role={role} setToast={setToast}/>}
        {page==="clans"&&<ClanPage session={session} balance={balance} setAuthOpen={setAuthOpen} setToast={setToast} onRefresh={refreshPrivate}/>}
        {page==="giveaways"&&<GiveawaysPage session={session} giveaways={giveawaysWithAssets} joinedGiveawayIds={joinedGiveawayIds} setJoinedGiveawayIds={setJoinedGiveawayIds} reload={loadGiveaways} setToast={setToast}/>}
        {page==="promo"&&<PromoCodePage session={session} setAuthOpen={setAuthOpen} setToast={setToast} onRedeemed={refreshPrivate}/>}
        {page==="admin"&&<AdminPage session={session} role={role} setToast={setToast}/>}
      </main>
      <Chat messages={chat} text={chatText} setText={setChatText} onSend={sendChat} username={session?.username} giveaways={giveawaysWithAssets} joinedGiveawayIds={joinedGiveawayIds} onEnterGiveaway={async(g)=>{if(g.host_username && normalizeUsername(g.host_username)===normalizeUsername(session?.username)){setToast("You cannot join your own giveaway.");return;}const key=`spinnypet:joined-giveaways:${session?.user_id}`;setJoinedGiveawayIds(v=>{const next=[...new Set([...(v||[]),g.id])];try{localStorage.setItem(key,JSON.stringify(next))}catch{}return next});try{await betaEnterGiveaway(g.id);setToast("Entered giveaway — ✓ JOINED");await loadGiveaways();}catch(e){try{const saved=JSON.parse(localStorage.getItem(key)||"[]");setJoinedGiveawayIds(Array.isArray(saved)?saved:[])}catch{}setToast(e.message||"Could not enter giveaway.")}}}/>
    </div>
    {authOpen&&<AuthModal mode={authMode} setMode={setAuthMode} onClose={()=>setAuthOpen(false)} onSuccess={authSuccess}/>} 
    {toast&&<div className="toast"><span>{toast}</span><button onClick={()=>setToast("")}><X size={15}/></button></div>}
  </div>;
}

function PageAtmosphere({page,adminEffect}){
  const pageMeta={
    home:{label:"SPINNYVERSE",icon:"✦",items:["💎","🐾","✦","◆","✧"]},
    coinflip:{label:"COIN RUSH",icon:"◉",items:["H","T","💎","◉","T"]},
    dice:{label:"DICE STORM",icon:"🎲",items:["🔴","🟣","🟡","🔵","🟢"]},
    inventory:{label:"PET VAULT",icon:"🐾",items:["🐾","✨","💎","◈","🐾"]},
    profile:{label:"PLAYER AURA",icon:"◈",items:["✦","◈","✧","💎"]},
    "time-rewards":{label:"REWARD RUSH",icon:"⏱",items:["🎁","💎","✨","🎁"]},
    cases:{label:"CASE RAIN",icon:"▣",items:["📦","💎","✨","📦"]},
    "case-battle":{label:"BATTLE ARENA",icon:"⚔",items:["⚔","📦","💎","🏆"]},
    leaderboard:{label:"CHAMPION MODE",icon:"🏆",items:["🏆","✦","💎","1","2","3"]},
    clans:{label:"CLAN ENERGY",icon:"⚔",items:["⚔","✦","◆","🏆"]},
    giveaways:{label:"GIVEAWAY RAIN",icon:"🎁",items:["🎁","💎","✨","🎁"]},
    promo:{label:"PROMO BOOST",icon:"#",items:["#","💎","✦","⚡"]},
    admin:{label:"ADMIN OVERRIDE",icon:"⚡",items:["⚡","💎","☢","✦","⚡"]}
  };
  const meta=pageMeta[page]||pageMeta.home;
  const fx=adminEffect;
  const fxType=fx?.effect_type||"";
  const fxClass=fx?` admin-fx-${fxType}`:"";
  return <div className={`page-atmosphere-layer page-atmosphere-${page}${fxClass}`} aria-hidden="true">
    <div className="page-atmosphere-badge"><i>{meta.icon}</i><span>{fx?String(fx.message||"ADMIN ABUSE").toUpperCase():meta.label}</span>{fx?.reward_amount>0&&<b>+💎 {formatCompact(Number(fx.reward_amount))}</b>}</div>
    <div className="page-atmosphere-particles">{Array.from({length:18},(_,i)=>{const left=(i*19+7)%96;const top=(i*31+11)%92;return <span key={i} style={{"--i":i,"--delay":`${(i%7)*.35}s`,left:`${left}%`,top:`${top}%`}}>{meta.items[i%meta.items.length]}</span>})}</div>
    {fx&&<div className="admin-fx-sweep"><strong>⚡ ADMIN ABUSE ⚡</strong><small>{String(fx.message||fx.effect_type||"EVENT").toUpperCase()}</small></div>}
  </div>;
}

function WalletSummary({balance,totalVirtualValue}){
  const [open,setOpen]=useState(false);
  const [mode,setMode]=useState("diamonds");
  const main=mode==="diamonds"?balance:totalVirtualValue;
  return <div className="wallet-summary-wrap"><button className="wallet-summary" onClick={()=>setOpen(v=>!v)}><span className="wallet-summary-icon">💎</span><div><b>{formatCompact(main)}</b><small>{mode==="diamonds"?"DIAMONDS":"TOTAL VALUE"}</small></div><span className="wallet-caret">⌄</span></button>{open&&<div className="wallet-summary-pop"><button className={mode==="diamonds"?"active":""} onClick={()=>setMode("diamonds")}><span>💎</span><div><b>{formatCompact(balance)}</b><small>Diamonds</small></div></button><button className={mode==="total"?"active":""} onClick={()=>setMode("total")}><span>◈</span><div><b>{formatCompact(totalVirtualValue)}</b><small>Total virtual value</small></div></button></div>}</div>}

function NavGroup({title,children}){return <div className="nav-group"><div className="nav-title">{title}</div>{children}</div>}
function HouseIcon(){return <span style={{fontSize:17,lineHeight:1}}>⌂</span>}
function SideLink({icon,label,image,active,onClick}){return <button className={`side-link ${active?"active":""}`} title={label} onClick={onClick}><span className="side-icon">{image?<img src={image} alt=""/>:icon}</span><span className="side-label">{label}</span></button>}
function Stat({value,label,icon}){return <div className="stat"><div className="stat-icon">{icon}</div><div><strong>{value}</strong><span>{label}</span></div></div>}

function LiveBets(){
  const [bets,setBets]=useState([]);
  async function load(){try{setBets((await betaGetLiveBets()).slice(0,14));}catch{setBets([])}}
  useEffect(()=>{load();const t=setInterval(load,1800);return()=>clearInterval(t)},[]);
  return <section className="section live-bets-section"><div className="section-head"><div><h2>Live Bets</h2><span>Coinflip, Color Dice and Case Battle · real-time beta activity</span></div><button className="ghost-btn" onClick={load}><RefreshCw size={14}/> Refresh</button></div><div className="live-bets-table"><div className="live-bets-head"><span>Game</span><span>Player</span><span>Bet</span><span>Multiplier</span><span>Payout</span></div>{bets.length?bets.map(b=>{const lost=b.status_label==='LOST'||Number(b.payout)<0;const payout=Number(b.payout||0);return <div className="live-bets-row" key={`${b.game_type}:${b.id}`}><div className="live-game"><span className={`live-game-icon live-icon-${b.game_type}`}>{b.game_type==='dice'?'🎲':b.game_type==='upgrader'?'↗':'↯'}</span><b>{b.game_label}</b></div><div><b>{b.username}</b><small>{b.choice||b.status_label||'Live'}</small></div><div><b>💎 {formatCompact(Math.abs(Number(b.bet||0)))}</b></div><div><span className="multiplier-pill">{Number(b.multiplier||0).toFixed(2)}x</span></div><div className={lost?'live-payout-loss':'live-payout-win'}><b>{lost?'−':'+'}💎 {formatCompact(Math.abs(payout))}</b><span>{lost?'LOST':b.status_label||'LIVE'}</span></div></div>}):<div className="live-bets-empty"><Users size={22}/><span>No live bets right now.</span></div>}</div></section>
}

function Home({pets,filtered,loading,error,search,setSearch,refresh,navigate,rank,balance}){
  const featured=pets.slice(0,5);
  return <>
    <section className="home-banner"><div className="home-banner-copy"><div className="eyebrow">PRIVATE BETA · PET & DIAMOND DUELS</div><h1>Open, duel and collect<br/><span>your rarest pets.</span></h1><p>Huge, Titanic and Gargantuan pets only. Every lobby is player-created — nothing starts without you.</p><div className="hero-buttons"><button className="primary-btn" onClick={()=>navigate("cases")}>Open Cases <Box size={16}/></button><button className="ghost-btn" onClick={()=>navigate("coinflip")}>Open a game</button></div></div><div className="home-banner-art"><img src="/assets/case-cosmic.png" alt=""/><div className="banner-float float-one">💎 {formatCompact(balance)}</div><div className="banner-float float-two">{rank.name}</div></div></section>
    <div className="stats-row"><Stat icon={<WalletCards size={18}/>} value={formatCompact(balance)} label="YOUR BALANCE"/><Stat icon={<Sparkles size={18}/>} value={pets.length.toLocaleString()} label="HIGH-TIER PETS"/><Stat icon={<Crown size={18}/>} value={rank.name} label="YOUR RANK"/></div>
    <section className="section"><div className="section-head"><div><h2>Games</h2><span>Pick a game and create your own lobby.</span></div></div><div className="game-grid">{GAME_CARDS.map(g=><button className="game-card" key={g.route} onClick={()=>navigate(g.route)}><div className="game-art"><img src={g.asset} alt=""/></div><div className="game-card-copy"><b>{g.name}</b><small>{g.desc}</small></div><span className="game-arrow">→</span></button>)}</div></section>
    <LiveBets />

  </>;
}

function StakePicker({inventory,balance,selected,setSelected,joinMode=false,requiredValue=0,minDiamond=0,petFilter=null,selectAllLabel="Select Top",allowDiamondJoin=false}){
  const [tab,setTab]=useState(joinMode&&!allowDiamondJoin?"pets":"diamonds");
  const [input,setInput]=useState("");
  const [petSearch,setPetSearch]=useState("");
  const [sort,setSort]=useState("value");
  const selectedPets=selected?.type==="pet"?(selected.pets||[]):[];
  const allowed=useMemo(()=>{
    const q=petSearch.trim().toLowerCase();
    return inventory.filter(i=>(petFilter?petFilter(i):isHighTierName(i.name))&&(!q||i.name.toLowerCase().includes(q)))
      .sort((a,b)=>sort==="name"?a.name.localeCompare(b.name):petValue(b)-petValue(a));
  },[inventory,petSearch,sort]);
  function setDiamond(v){
    setInput(v);
    const n=parseCompactAmount(v);
    setSelected(Number.isFinite(n)&&n>0&&n<=balance&&n>=minDiamond?{type:"diamonds",amount:n,pet:null,pets:[]}:null);
  }
  function togglePet(i){
    const current=selectedPets;
    const key=x=>`${x.pet_id||x.id}:${x.variant||"normal"}`;
    const exists=current.some(x=>key(x)===key(i));
    const next=exists?current.filter(x=>key(x)!==key(i)):[...current,i];
    setSelected(next.length?{type:"pet",amount:next.reduce((s,x)=>s+petValue(x),0),pet:next[0],pets:next}:null);
  }
  function clear(){setSelected(null);setInput("");}
  const petTotal=selectedPets.reduce((s,x)=>s+petValue(x),0);
  const shortfall=Math.max(0,requiredValue-petTotal);
  return <div className="stake-picker">
    <div className="stake-tabs">
      {(!joinMode||allowDiamondJoin)&&<button className={tab==="diamonds"?"active":""} onClick={()=>setTab("diamonds")}>💎 Diamonds</button>}
      <button className={tab==="pets"?"active":""} onClick={()=>setTab("pets")}>🐾 {joinMode?"Your pets":"My pets"}</button>
    </div>
    {tab==="diamonds"&&(!joinMode||allowDiamondJoin)?<div className="diamond-stake">
      <label>Amount to use{minDiamond?` · minimum ${formatCompact(minDiamond)}`:""}</label><div className="diamond-input"><span>💎</span><input value={input} onChange={e=>setDiamond(e.target.value)} placeholder="1b, 5b, 10b..."/><small>{selected?.type==="diamonds"?formatNumber(selected.amount):""}</small></div>
      <div className="quick-stakes">{[10000000,100000000,1000000000,5000000000,10000000000,100000000000,1000000000000].map(v=><button key={v} onClick={()=>setDiamond(String(formatCompact(v).toLowerCase()))} disabled={v>balance||v<minDiamond}>{formatCompact(v)}</button>)}</div>
    </div>:<div className="owned-stake-wrap">
      <div className="owned-stake-tools"><SearchBox value={petSearch} onChange={setPetSearch} placeholder="Search pets..."/><select value={sort} onChange={e=>setSort(e.target.value)}><option value="value">Sort: Value</option><option value="name">Sort: Name</option></select><button onClick={()=>{if(selectAllLabel==="Select All"){const next=allowed.map(i=>i);setSelected(next.length?{type:"pet",amount:next.reduce((s,x)=>s+petValue(x),0),pet:next[0],pets:next}:null)}else if(allowed[0])togglePet(allowed[0])}}>{selectAllLabel}</button><button onClick={clear}>Clear</button></div>
      <div className="owned-stake-grid">{allowed.length?allowed.map(i=><button key={`${i.id}:${i.variant||"normal"}`} className={`owned-stake ${selectedPets.some(x=>x.id===i.id)?"active":""}`} onClick={()=>togglePet(i)}>
        <PetIcon pet={inventoryPetShape(i)} size="small" variant={i.variant}/><span>{i.name}</span><b>{i.quantity}×</b><small>{i.variant||"normal"} · 💎 {displayPetValue(petValue(i))}</small>
      </button>):<div className="empty-owned">No Huge, Titanic or Gargantuan pets in your inventory yet.</div>}</div>
      {joinMode&&<div className={`join-value-hint ${shortfall>0?"short":"ok"}`}>{petTotal?`Your bundle: 💎 ${formatCompact(petTotal)}`:"Select one or more pets"}{requiredValue?` · Match value: 💎 ${formatCompact(requiredValue)}${shortfall?` · Need ${formatCompact(shortfall)} more`:" · Ready to join"}`:""}</div>}
    </div>}
    <div className="selected-stake-line">Selected: <b>{selected?.type==="pet"?`${selectedPets.length} pet${selectedPets.length===1?"":"s"} · 💎 ${formatCompact(petTotal)}`:selected?.amount?`💎 ${formatCompact(selected.amount)}`:"Nothing"}</b></div>
  </div>;
}

function CoinflipPage({inventory,balance,session,setAuthOpen,toast}){
  const [side,setSide]=useState("Heads");
  const [stake,setStake]=useState(null);
  const [lobbies,setLobbies]=useState([]);
  const [created,setCreated]=useState(null);
  const [joinLobby,setJoinLobby]=useState(null);
  const [joinStake,setJoinStake]=useState(null);
  const [busy,setBusy]=useState(false);
  const [result,setResult]=useState(null);
  const [resultOpen,setResultOpen]=useState(false); const [diceReveal,setDiceReveal]=useState(false); const [diceCountdown,setDiceCountdown]=useState(3);
  const [resultSource,setResultSource]=useState("");
  const [resultTimer,setResultTimer]=useState(null);const [resultRevealed,setResultRevealed]=useState(false);
  const MIN=10000000;
  const petAllowed=i=>{const n=String(i?.name||"").toLowerCase();const c=String(i?.category||"").toLowerCase();return n.startsWith("titanic ")||n.startsWith("gargantuan ")||c==="titanic"||c==="gargantuan";};
  const load=async()=>{try{setLobbies(await betaListLobbies("coinflip"));}catch{setLobbies([])}};
  useEffect(()=>{load();const t=setInterval(async()=>{
    await load();
    if(created?.id){try{const r=await betaGetCoinflipResult(created.id);if(r?.status==="finished"&&!result)showResult(r,"host");}catch{}}
  },1200);return()=>clearInterval(t)},[created?.id,result]);
  function showResult(r,source){
    if(!r||result)return;
    setResult({...r,__pendingReveal:true});setResultSource(source);setResultOpen(true);setResultRevealed(false);if(source==="host")setCreated(null);
    playMatchSound("roll");
    window.dispatchEvent(new Event("petflip:refresh-private"));
    [1,2].forEach(n=>setTimeout(()=>playMatchSound("tick"),n*1000));
    setTimeout(()=>{setResult({...r,__pendingReveal:false});setResultRevealed(true);playMatchSound("reveal");window.dispatchEvent(new Event("petflip:refresh-private"));},3000);
    if(r?.winner_id && String(r.winner_id)===String(session?.user_id)) setTimeout(playWinSound,3000);
    if(r?.winner_id && String(r.winner_id)!==String(session?.user_id)) setTimeout(playLoseSound,3000);
    const timer=setTimeout(()=>{setResultOpen(false);setResult(null);setResultRevealed(false);setCreated(null);setResultSource("")},5500);setResultTimer(timer);
  }
  function resetResult(){if(resultTimer)clearTimeout(resultTimer);setResult(null);setResultOpen(false);setResultSource("");setResultRevealed(false);setCreated(null);}
  async function create(){
    if(!session){setAuthOpen(true);return;}
    if(!stake){toast("Choose diamonds or one or more Titanic / Gargantuan pets.");return;}
    if(stake.type==="diamonds"&&Number(stake.amount)<MIN){toast("Coinflip minimum wager is 10M gems.");return;}
    setBusy(true);resetResult();
    try{const d=await betaCreateLobby("coinflip",{...stake,choice:side});setCreated({id:d.id,stake,choice:side});setStake(null);await load();window.dispatchEvent(new Event("petflip:refresh-private"));toast("Coinflip game created. Waiting for an opponent.");}
    catch(e){toast(e.message||"Could not create coinflip.");}finally{setBusy(false)}
  }
  async function join(){
    if(!session){setAuthOpen(true);return;}
    if(!joinLobby||!joinStake){toast("Choose your wager first.");return;}
    if(joinStake.type==="diamonds"&&Number(joinStake.amount)<MIN){toast("Coinflip minimum wager is 10M gems.");return;}
    if(joinLobby.stake_type!==joinStake.type){toast("Use the same wager type as the host.");return;}
    if(joinStake.type==="pet"&&Number(joinStake.amount)<Number(joinLobby.stake_amount||0)){toast(`Your pet bundle must be worth at least ${formatCompact(joinLobby.stake_amount)} gems.`);return;}
    if(joinStake.type==="diamonds"&&Number(joinStake.amount)!==Number(joinLobby.stake_amount||0)){toast(`This coinflip requires exactly ${formatCompact(joinLobby.stake_amount)} gems.`);return;}
    setBusy(true);
    try{const d=await import("./betaAuth").then(m=>m.betaJoinLobby(joinLobby.id,joinStake));setJoinLobby(null);setJoinStake(null);await load();showResult({...d,status:"finished"},"join");}
    catch(e){toast(e.message||"Could not join coinflip.");}finally{setBusy(false)}
  }
  async function cancel(){if(!created?.id)return;setBusy(true);try{await betaCancelLobby(created.id);setCreated(null);await load();window.dispatchEvent(new Event("petflip:refresh-private"));toast("Coinflip cancelled and your stake was returned.");}catch(e){toast(e.message||"Could not cancel coinflip.")}finally{setBusy(false)}}
  return <section className="coinflip-page">
    <div className="page-header"><div><span>50 / 50 DUEL</span><h1>Coinflip</h1><small>Minimum wager: 10M gems · Titanic + Gargantuan pets or gems only.</small></div><div className="case-balance">💎 {formatCompact(balance)}</div></div>
    <div className="coinflip-create-card">
      <div className="coinflip-head"><div><span className="eyebrow">CREATE COINFLIP GAME</span><h2>Choose your side</h2><small>Pick Heads or Tails, then build your wager.</small></div><div className="coinflip-badge">50 / 50</div></div>
      <div className="coinflip-side-grid"><button className={side==="Heads"?"selected":""} onClick={()=>setSide("Heads")}><span className="coin-side heads">◉</span><b>Heads</b>{side==="Heads"&&<span>✓</span>}</button><button className={side==="Tails"?"selected":""} onClick={()=>setSide("Tails")}><span className="coin-side tails">●</span><b>Tails</b>{side==="Tails"&&<span>✓</span>}</button></div>
      <StakePicker inventory={inventory} balance={balance} selected={stake} setSelected={setStake} minDiamond={MIN} petFilter={petAllowed} selectAllLabel="Select All" allowDiamondJoin/>
      <div className="coinflip-summary"><div><span>SELECTED</span><b>{stake?.type==="pet"?`${stake.pets.length} pets`:(stake?"💎":"0")}</b></div><div><span>TOTAL VALUE</span><b>💎 {formatCompact(stake?.amount||0)}</b></div><div><span>YOUR SIDE</span><b>{side}</b></div><button className="primary-btn" disabled={busy||!stake||Number(stake.amount||0)<MIN} onClick={create}>{busy?"Creating…":"Create Game"}</button></div>
      <div className="coinflip-restriction"><span className="restriction-check">✓</span><div><b>Gargantuan + Titanic + Gems Only</b><small>Only Gargantuans, Titanics, or gems can join this game.</small></div></div>
    </div>
    <div className="coinflip-list-card"><div className="section-head"><div><h2>Live Coinflips</h2><span>Join an open game with your own wager.</span></div><button className="ghost-btn" onClick={load}><RefreshCw size={14}/> Refresh</button></div>{created&&<div className="coinflip-created"><div><span className="online-dot"/><b>Your game is live</b><small>{created?.choice} · 💎 {formatCompact(created?.stake?.amount||0)}</small></div><button className="ghost-btn" disabled={busy} onClick={cancel}>Cancel</button></div>}<div className="coinflip-games">{lobbies.filter(x=>x.id!==created?.id).map(l=><div className="coinflip-game-row" key={l.id}><div className="cf-player"><span className="cf-avatar">{l.creator_avatar_url?<img src={l.creator_avatar_url} alt=""/>:String(l.creator_username||"?")[0].toUpperCase()}</span><div><b>{l.creator_username}</b><small>OPEN GAME</small></div></div><div className="cf-side-badge"><span className={String(l.choice||"Heads")==="Heads"?"heads":"tails"}>{String(l.choice||"Heads")==="Heads"?"H":"T"}</span><div><b>{l.choice||"Heads"}</b><small>their side</small></div></div><div><b>💎 {formatCompact(l.stake_amount)}</b><small>{l.stake_type==="pet"?`${l.pet_count||1} pets`:"Gems"}</small>{l.stake_type==="pet"&&<PetStakeInline items={l.stake_pet_items}/>}</div><button className="primary-btn" onClick={()=>{setJoinLobby(l);setJoinStake(null)}}>Join</button></div>)}{!lobbies.filter(x=>x.id!==created?.id).length&&<div className="empty-state"><Hash size={30}/><b>No open coinflips</b><span>Create the first game and wait for another beta player.</span></div>}</div></div>
    {joinLobby&&<Modal onClose={()=>{setJoinLobby(null);setJoinStake(null)}}><button className="modal-close" onClick={()=>{setJoinLobby(null);setJoinStake(null)}}><X size={18}/></button><div className="coinflip-join-modal"><span className="eyebrow">JOIN COINFLIP</span><h2>{joinLobby.creator_username}'s game</h2><p>Host chose <b>{joinLobby.choice||"Heads"}</b> · stake <b>💎 {formatCompact(joinLobby.stake_amount)}</b>.</p><StakePicker inventory={inventory} balance={balance} selected={joinStake} setSelected={setJoinStake} joinMode requiredValue={joinLobby.stake_type==="pet"?Number(joinLobby.stake_amount):0} minDiamond={MIN} petFilter={petAllowed} selectAllLabel="Select All" allowDiamondJoin/><button className="primary-btn wide" disabled={busy||!joinStake||joinStake.type!==joinLobby.stake_type||(joinStake.type==="diamonds"&&Number(joinStake.amount)!==Number(joinLobby.stake_amount))||(joinStake.type==="pet"&&Number(joinStake.amount)<Number(joinLobby.stake_amount))} onClick={join}>{busy?"Flipping…":"Join & Flip"}</button></div></Modal>}
    {resultOpen&&result&&<Modal className="coinflip-result-shell" onClose={resetResult}><button className="modal-close" onClick={resetResult}><X size={18}/></button><div className={`coinflip-result-modal ${resultRevealed?"revealed":"spinning"}`}><div className={`coinflip-result-coin ${resultRevealed&&String(result.winner_side||result.result_side||"").toLowerCase()==="tails"?"tails":"heads"}`}>{resultRevealed?(String(result.winner_side||result.result_side||"Heads")==="Heads"?"H":"T"):"?"}</div><span className="eyebrow">COINFLIP RESULT</span>{resultRevealed?<><h2>{result.winner_username||"Winner"} wins!</h2><p><b>{result.winner_side||result.result_side||"Heads"}</b> landed · {resultSource==="join"?"Your game is settled":"The game is settled"}.</p><div className="coinflip-result-payout"><span>WINNER PAYOUT</span><b>💎 {formatCompact(Number(result.payout||result.stake_value||0))}</b></div><small>Result revealed after the 3 second match animation.</small></>:<><h2>Coin is flipping…</h2><p>The match is settled server-side. Watch the coin animation while the result is revealed.</p><div className="coinflip-result-payout pending"><span>RESULT</span><b>WAITING FOR REVEAL</b></div><small>3 second reveal animation</small></>}</div></Modal>}
  </section>
}

function PromoCodePage({session,setAuthOpen,setToast,onRedeemed}){
  const [code,setCode]=useState("");const [busy,setBusy]=useState(false);
  async function redeem(e){e.preventDefault();if(!session){setAuthOpen(true);return;}if(!code.trim()){setToast("Enter a promo code.");return;}setBusy(true);try{const d=await betaRedeemPromo(code);setCode("");await onRedeemed();setToast(`Promo redeemed: ${formatCompact(d.reward_amount||0)} diamonds`);}catch(e){setToast(e.message||"Promo code could not be redeemed.");}finally{setBusy(false)}}
  return <section className="promo-page"><div className="page-header"><div><span>REWARDS</span><h1>Promo Code</h1><small>Enter a valid SpinnyPet beta code to receive diamonds.</small></div><Tag size={28}/></div><div className="promo-card"><div className="promo-icon"><Tag size={24}/></div><h2>Redeem a promo code</h2><p>Codes are case-insensitive. Each account can use a code once.</p><form onSubmit={redeem}><input value={code} onChange={e=>setCode(e.target.value.toUpperCase())} placeholder="ENTER CODE" autoComplete="off"/><button className="primary-btn" disabled={busy}>{busy?"Redeeming…":"Redeem Code"}</button></form></div></section>
}


function GameShell({eyebrow,title,subtitle,icon,children,right}){
  return <section className="v23-game-page"><div className="v23-game-hero"><div><span className="eyebrow">{eyebrow}</span><h1>{icon} {title}</h1><p>{subtitle}</p></div>{right}</div>{children}</section>;
}
function DiamondStake({value,setValue,balance,min=1000000}){
  return <div className="v23-stake"><label>BET</label><input value={value} onChange={e=>setValue(e.target.value)} placeholder="10m"/><div className="v23-stake-presets">{['10m','50m','100m','1b'].map(v=><button key={v} onClick={()=>setValue(v)}>{v}</button>)}<span>Balance {formatCompact(balance||0)} · Min {formatCompact(min)}</span></div></div>;
}
function MinesPage({session,balance,setAuthOpen,setToast,onRefresh}){
  const [bet,setBet]=useState('10m'),[sessionId,setSessionId]=useState(null),[board,setBoard]=useState(Array(25).fill(null)),[revealed,setRevealed]=useState([]),[busy,setBusy]=useState(false),[state,setState]=useState('idle'),[mult,setMult]=useState(1),[message,setMessage]=useState('Pick a tile to start the run.');
  const start=async()=>{if(!session){setAuthOpen(true);return}setBusy(true);try{const d=await betaMinesStart(parseCompactAmount(bet));setSessionId(d.id);setBoard(Array(25).fill(null));setRevealed([]);setMult(1);setState('playing');setMessage('Minefield armed. Find gems and cash out before the mine.');}catch(e){setToast(e.message||'Could not start Mines.')}finally{setBusy(false)}};
  const reveal=async i=>{if(state!=='playing'||busy||revealed.includes(i))return;setBusy(true);try{const d=await betaMinesReveal(sessionId,i);setBoard(b=>{const n=[...b];n[i]=d.hit?'mine':'gem';if(d.hit){(d.mines||[]).forEach(x=>n[x]='mine')}return n});setRevealed(r=>[...r,i]);if(d.hit){setState('lost');setMessage('BOOM. The mine got you.');setMult(1)}else{setMult(Number(d.multiplier||1));setMessage(`Safe tile. Cash out at ${formatCompact(Number(d.payout||0))} diamonds.`)}}catch(e){setToast(e.message||'Could not reveal tile.')}finally{setBusy(false)}};
  const cash=async()=>{if(!sessionId||state!=='playing')return;setBusy(true);try{const d=await betaMinesCashout(sessionId);setState('won');setMessage(`Cashed out ${formatCompact(Number(d.payout||0))} diamonds.`);setToast(`MINES · +💎 ${formatCompact(Number(d.payout||0))}`);onRefresh();}catch(e){setToast(e.message||'Cash out failed.')}finally{setBusy(false)}};
  return <GameShell eyebrow="V23 ORIGINAL" title="Pet Mines" subtitle="Reveal safe tiles, build your multiplier, then cash out. The mine layout is generated and settled server-side." icon="💣" right={<div className="v23-game-badge">25 TILES · 3 MINES</div>}><div className="v23-game-grid"><div className="v23-game-panel"><DiamondStake value={bet} setValue={setBet} balance={balance}/><div className="v23-mines-top"><div><small>MULTIPLIER</small><strong>{mult.toFixed(2)}×</strong></div><div><small>STATUS</small><strong>{state==='playing'?'LIVE':state.toUpperCase()}</strong></div><button className="primary-btn" disabled={busy||state==='playing'} onClick={start}>{state==='idle'||state==='lost'||state==='won'?'Start Round':'Running'}</button><button className="ghost-btn" disabled={busy||state!=='playing'||!revealed.length} onClick={cash}>Cash Out</button></div><div className="mines-board">{board.map((v,i)=><button key={i} className={`mine-tile ${v||''}`} disabled={state!=='playing'||busy||Boolean(v)} onClick={()=>reveal(i)}>{v==='mine'?'💣':v==='gem'?'💎':'?'}</button>)}</div><div className="v23-game-note">{message}</div></div><div className="v23-game-side"><h3>How it works</h3><p>Each safe reveal increases your multiplier. Hit a mine and the round ends. Cash out whenever you want.</p><div className="v23-rule"><b>Server settled</b><span>Mine positions and payouts never come from the browser.</span></div><div className="v23-rule"><b>Fast rounds</b><span>Start a fresh 25-tile board after every result.</span></div></div></div></GameShell>;
}
function PlinkoPage({session,balance,setAuthOpen,setToast,onRefresh}){
  const [bet,setBet]=useState(1000000),[busy,setBusy]=useState(false),[result,setResult]=useState(null),[history,setHistory]=useState([]),[pathIndex,setPathIndex]=useState(-1);
  const play=async()=>{if(!session){setAuthOpen(true);return}setBusy(true);setResult(null);setPathIndex(-1);try{const d=await betaPlinkoPlay(parseCompactAmount(bet));const path=String(d?.path||'');path.split('').forEach((_,i)=>setTimeout(()=>setPathIndex(i),180*(i+1)));setTimeout(()=>{setResult(d);setHistory(h=>[d,...h].slice(0,8));setToast(`PLINKO · ${formatCompact(Number(d.payout||0))} diamonds`);onRefresh?.()},180*(path.length+1));}catch(e){setToast(e.message||'Could not play Plinko.')}finally{setBusy(false)}};
  const gates=[0.2,0.5,1,1.5,2,3,5,10,5,3,2,1.5,1,.5,.2];
  const path=String(result?.path||'');
  return <GameShell eyebrow="V24 FIX" title="Pet Plinko" subtitle="The server decides the path. The chip now visibly follows every left/right bounce before landing." icon="🟣" right={<div className="v23-game-badge">×0.20 → ×10.00</div>}><div className="v23-game-grid"><div className="v23-game-panel"><DiamondStake value={bet} setValue={setBet} balance={balance}/><div className="plinko-stage"><div className={`plinko-chip ${pathIndex>=0?'is-dropping':''}`} style={{'--plinko-step':Math.max(0,pathIndex)}}>{result?'🐾':'●'}</div>{Array.from({length:7},(_,r)=><div className="plinko-row" key={r}>{Array.from({length:r+4},(_,i)=><i key={i}>•</i>)}</div>)}<div className="plinko-gates">{gates.map((x,i)=><span key={`${x}-${i}`} className={Number(result?.multiplier)===x?'landed':''}>×{x}</span>)}</div></div><button className="primary-btn wide" disabled={busy} onClick={play}>{busy?'Dropping…':'Drop Pet Chip'}</button>{result&&<div className="plinko-result"><span>LANDED ON</span><strong>×{Number(result.multiplier).toFixed(2)}</strong><b>💎 {formatCompact(Number(result.payout||0))}</b><small>Path: {path.split('').join(' → ')||'—'}</small></div>}</div><div className="v23-game-side"><h3>Recent drops</h3>{history.length?history.map((r,i)=><div className="v23-history" key={i}><span>×{Number(r.multiplier).toFixed(2)}</span><b>+{formatCompact(Number(r.payout||0))}</b></div>):<div className="empty-state">No drops yet.</div>}</div></div></GameShell>;
}
function CrashPage({session,balance,setAuthOpen,setToast,onRefresh}){
  const [bet,setBet]=useState(1000000),[busy,setBusy]=useState(false),[run,setRun]=useState(null),[mult,setMult]=useState(1),[status,setStatus]=useState('ready');
  useEffect(()=>{if(status!=='playing'||!run?.started_at)return;const started=Date.parse(run.started_at);const tick=()=>setMult(Math.max(1,Math.exp(Math.max(0,Date.now()-started)/1000/9)));tick();const iv=setInterval(tick,100);return()=>clearInterval(iv)},[status,run]);
  const start=async()=>{if(!session){setAuthOpen(true);return}setBusy(true);try{const d=await betaCrashStart(parseCompactAmount(bet));setRun(d);setMult(1);setStatus('playing');}catch(e){setToast(e.message||'Could not start Crash.')}finally{setBusy(false)}};
  const cash=async()=>{if(status!=='playing'||!run?.id)return;setBusy(true);try{const d=await betaCrashCashout(run.id);if(d?.status==='crashed'){setStatus('crashed');setMult(Number(d.multiplier||mult));setToast(`CRASHED at ${Number(d.multiplier||mult).toFixed(2)}×`);}else{setStatus('won');setMult(Number(d.multiplier||mult));setToast(`CRASH · +💎 ${formatCompact(Number(d.payout||0))}`)}onRefresh?.();}catch(e){setToast(e.message||'Could not settle Crash.')}finally{setBusy(false)}};
  return <GameShell eyebrow="V24 FIX" title="Pet Crash" subtitle="Cash out before the server-side crash point. A crashed round is now permanently settled, so the next round can start normally." icon="🚀" right={<div className={`v23-game-badge ${status==='crashed'?'danger':''}`}>{status==='playing'?'LIVE':status==='won'?'WON':status==='crashed'?'CRASHED':'READY'}</div>}><div className="crash-stage"><div className="crash-stars"/><div className="crash-rocket" style={{transform:`translateY(${Math.min(180,(mult-1)*55)}px) rotate(${Math.min(18,(mult-1)*4)}deg)`}}>🚀</div><div className="crash-mult">{mult.toFixed(2)}×</div><div className="crash-status">{status==='playing'?'CASH OUT BEFORE THE CRASH':status==='won'?'CASHED OUT':status==='crashed'?'CRASHED':'READY'}</div></div><div className="v23-crash-controls"><DiamondStake value={bet} setValue={setBet} balance={balance}/>{status==='playing'?<button className="primary-btn crash-cash" disabled={busy} onClick={cash}>Cash Out · {mult.toFixed(2)}×</button>:<button className="primary-btn crash-start" disabled={busy} onClick={start}>{busy?'Launching…':'Launch Rocket'}</button>}</div></GameShell>;
}
function TimeRewardsPage({session,pets=[],balance,setAuthOpen,setToast}){
  const [rewards,setRewards]=useState([]);const [tickets,setTickets]=useState([]);const [busy,setBusy]=useState(null);const [tick,setTick]=useState(Date.now());const [opening,setOpening]=useState(null);const [openResult,setOpenResult]=useState(null);const [openingReel,setOpeningReel]=useState([]);
  const rewardCases=useMemo(()=>[...CASES].sort((a,b)=>a.price-b.price).slice(0,5),[]);const fallback=rewardCases.map((c,i)=>({stage:i+1,case_id:c.id,minutes:[30,60,120,240,480][i],claimed:false,available:i===0,unlock_at:i===0?new Date().toISOString():null}));
  async function load(){if(!session){setRewards(fallback);setTickets([]);return;}try{const r=await betaGetTimeRewards();setRewards(Array.isArray(r)&&r.length===5?r: fallback);const t=await betaGetTimeTickets();setTickets(Array.isArray(t)?t:[]);}catch(e){setRewards(fallback);setTickets([]);setToast(e.message||'Could not load Time Rewards.')}}
  useEffect(()=>{load();const t=setInterval(()=>setTick(Date.now()),1000);return()=>clearInterval(t)},[session?.user_id]);
  const ticketMap=useMemo(()=>Object.fromEntries(tickets.map(t=>[t.case_id,Number(t.quantity||0)])),[tickets,tick]);
  async function unlockAndOpen(caseId,stage){if(!session){setAuthOpen(true);return;}setOpening(caseId);setOpenResult(null);try{await betaGetTimeRewards();const t=await betaGetTimeTickets();const qty=Number((t||[]).find(x=>x.case_id===caseId)?.quantity||0);if(qty<1){await load();setToast('The timer has not finished yet.');return;}const c=rewardCases.find(x=>x.id===caseId);const pool=caseDisplayRewards(pets,c)||[];const base=pool.map(p=>({name:p.name,value:petValue(p),pet:p}));const fillers=base.length?Array.from({length:41},(_,i)=>base[(i*7)%base.length]):[];setOpeningReel(fillers);setOpening({caseId,caseName:c?.name||'Case'});playCaseOpenSound();playMatchSound("open");const d=await betaOpenCaseTicket(caseId);window.dispatchEvent(new Event('petflip:refresh-private'));await new Promise(r=>setTimeout(r,4600));setOpening(null);setOpenResult(d);playWinSound();await load();}catch(e){setOpening(null);setOpeningReel([]);setToast(e.message||'Could not open the free case.')}finally{setOpening(null)}}
  return <section className="time-rewards-page"><div className="page-header"><div><span>LOYALTY REWARDS</span><h1>Time Rewards</h1><small>Unlock one free case at a time. When the timer ends, the ticket is granted automatically.</small></div><div className="case-balance">💎 {formatCompact(balance)}</div></div><div className="time-rewards-hero"><div><span className="eyebrow">5 CASES · PROGRESSIVE UNLOCKS</span><h2>Stay active. Unlock better cases.</h2><p>Each timer unlocks the next case ticket automatically. Open the ticket when it becomes ready.</p></div><div className="time-reward-chain">{rewardCases.map((c,i)=>{const r=rewards[i]||fallback[i];return <div className={`time-chain-dot ${r?.claimed?'claimed':''} ${r?.available?'ready':''}`} key={c.id}><img src={caseImage(c)} alt={c.name}/><span>{i+1}</span></div>})}</div></div><div className="time-reward-grid">{rewardCases.map((c,i)=>{const r=rewards[i]||fallback[i];const remaining=r.unlock_at?Math.max(0,Math.ceil((new Date(r.unlock_at).getTime()-tick)/1000)):0;const mins=Math.floor(remaining/60),secs=remaining%60;const isReady=!r.claimed&&(r.available||!!r.unlock_at&&remaining<=0);const ticket=Number(ticketMap[c.id]||0);return <div className={`time-reward-card ${r.claimed?'claimed':''} ${isReady?'ready':''}`} key={c.id}><div className="time-reward-art"><img src={caseImage(c)} alt={c.name}/><div className="time-stage-badge">STAGE {i+1}</div>{r.claimed&&<span className="time-claimed-badge">CLAIMED</span>}{isReady&&<span className="time-ready-badge">READY</span>}</div><div className="time-reward-copy"><div className="time-reward-step"><span>{i===0?'START':'NEXT UNLOCK'}</span><b>{c.name}</b></div><p>{formatCompact(c.price)} case · free ticket · {r.minutes} min timer</p>{r.claimed&&ticket<=0?<div className="time-status claimed">✓ Case opened</div>:isReady&&ticket<=0?<button className="primary-btn wide" disabled={opening===c.id} onClick={()=>unlockAndOpen(c.id,i+1)}>{opening===c.id?'Unlocking…':'UNLOCK & OPEN'}</button>:r.unlock_at?<div className="time-status">🔒 Unlocks in <b>{mins}m {String(secs).padStart(2,'0')}s</b></div>:<div className="time-status">🔒 Claim Stage {i} first</div>}{ticket>0&&<button className="ghost-btn wide time-open-btn" disabled={opening===c.id} onClick={()=>unlockAndOpen(c.id,i+1)}>{opening===c.id?'Opening…':`OPEN TICKET · ${c.name}`}</button>}</div></div>})}</div>{opening&&<Modal className="time-case-opening-shell" onClose={()=>{}}><div className="time-case-opening"><div className="time-case-opening-head"><div><span className="eyebrow">TIME REWARD · OPENING</span><h2>{opening.caseName}</h2></div><span className="time-case-spinner">OPENING</span></div><div className="time-case-art-wrap"><img src={caseImage(rewardCases.find(c=>c.id===opening.caseId)||rewardCases[0])} alt=""/></div><div className="case-opening-reel-shell time-mini-reel"><div className="case-opening-marker">▼</div><div className="case-opening-reel"><div className="case-opening-track time-opening-track">{openingReel.map((r,i)=><div className="opening-tile" key={i}><PetIcon pet={r.pet} size="medium"/><b>{r.name}</b><small>💎 {formatCompact(r.value)}</small></div>)}</div></div></div><div className="time-opening-progress"><i/></div><small>Rolling your free case…</small></div></Modal>}{!session&&<div className="time-reward-login"><Gift size={25}/><div><b>Sign in to start the reward chain.</b><span>Stage 1 is ready immediately.</span></div><button className="primary-btn" onClick={()=>setAuthOpen(true)}>Sign in</button></div>}{openResult&&<Modal className="case-result-modal-shell" onClose={()=>{setOpenResult(null);setOpeningReel([])}}><div className="case-win-popup"><div className="case-win-burst">✦</div><span className="eyebrow">FREE CASE OPENED</span><h2>You won</h2><div className="case-result-card large"><PetIcon pet={{id:openResult.reward_pet_id,name:openResult.reward_pet_name,thumbnailUrl:openResult.reward_pet_thumbnail_url}} size="large"/><b>{openResult.reward_pet_name}</b><small>PS99 RAP · 💎 {formatCompact(openResult.reward_pet_value||0)}</small></div><button className="primary-btn wide" onClick={()=>{setOpenResult(null);setOpeningReel([])}}>Continue</button></div></Modal>}</section>
}
function ProfilePage({session,stats,history,rank,onSignIn,onClaim,onSignOut,onCustomAvatar}){
  const [avatarBusy,setAvatarBusy]=useState(false);
  const [avatarUrl,setAvatarUrl]=useState("");
  const pnl=Number(stats?.profit_loss||0);
  const chart=[-1,-.7,-.8,-.55,-.65,-.45,-.5,-.2,-.32,-.05,0].map((x,i)=>`${i*8},${120-x*45}`).join(" ");
  return <section className="profile-page"><div className="profile-hero"><div className="profile-avatar-wrap">{(stats?.custom_avatar_url||stats?.avatar_url)?<img src={stats.custom_avatar_url||stats.avatar_url} alt=""/>:<CircleUserRound size={54}/>}<span className="rank-dot"/></div><div className="profile-main"><span>SPINNYPET PLAYER</span><h1>@{stats?.username||session?.username||"Guest"}</h1><p>Customize your profile picture with an upload or image URL.</p><div className="profile-actions">{session?<><div className="avatar-upload-box"><label className="upload-picture-btn"><Upload size={15}/> {avatarBusy?"Uploading…":"Choose picture"}<input type="file" accept="image/png,image/jpeg,image/webp,image/gif" disabled={avatarBusy} onChange={async e=>{const file=e.target.files?.[0];e.target.value="";if(!file)return;if(file.size>8*1024*1024){alert("Please choose an image under 8MB.");return;}setAvatarBusy(true);try{const data=await compressAvatarFile(file);await onCustomAvatar(data);}finally{setAvatarBusy(false);}}}/></label><input value={avatarUrl} disabled={avatarBusy} onChange={e=>setAvatarUrl(e.target.value)} placeholder="Paste image URL"/><button className="ghost-btn" disabled={avatarBusy||!avatarUrl.trim()} onClick={async()=>{setAvatarBusy(true);try{await onCustomAvatar(avatarUrl.trim());}finally{setAvatarBusy(false);}}}>Use URL</button></div><button className="ghost-btn" onClick={onClaim}>Claim 50B + Titanic</button><button className="ghost-btn" onClick={onSignOut}>Sign out</button></>:<button className="primary-btn" onClick={onSignIn}>Create beta account</button>}</div></div><div className="rank-card"><span>RANK</span><strong>{rank.name}</strong><small>{stats?.wagered?formatCompact(stats.wagered):"0"} wagered</small></div></div><div className="profile-stats"><Stat icon={<WalletCards size={17}/>} value={formatCompact(stats?.wagered||0)} label="TOTAL WAGERED"/><Stat icon={<TrendingUp size={17}/>} value={formatCompact(Math.max(0,pnl))} label="TOTAL PROFIT"/><Stat icon={<TrendingDown size={17}/>} value={formatCompact(Math.max(0,-pnl))} label="TOTAL LOSS"/><Stat icon={<Trophy size={17}/>} value={`${stats?.games_won||0} / ${stats?.games_played||0}`} label="WINS / PLAYS"/></div><div className="profile-grid"><div className="history-card"><div className="panel-title"><div><span>PERFORMANCE</span><h2>Profit & loss</h2></div><b className={pnl>=0?"positive":"negative"}>{pnl>=0?"+":""}{formatCompact(pnl)}</b></div><svg className="profit-chart" viewBox="0 0 80 140" preserveAspectRatio="none"><polyline points={chart} fill="none" stroke="currentColor" strokeWidth="2"/></svg><div className="chart-labels"><span>START</span><span>RECENT</span></div></div><div className="history-card"><div className="panel-title"><div><span>ACCOUNT</span><h2>Rank progress</h2></div><Crown size={19}/></div><div className="rank-progress"><strong>{rank.name}</strong><span>Next milestone {rank.next?formatCompact(rank.next):"MAX"}</span><div><i style={{width:`${rank.next?Math.min(100,(Number(stats?.wagered||0)/rank.next)*100):100}%`}}/></div></div><p className="muted">Ranks are based on virtual value wagered.</p></div></div><div className="history-card full"><div className="panel-title"><div><span>ACTIVITY</span><h2>Site history</h2></div><History size={19}/></div><div className="history-list">{history.length?history.map(h=><div className="history-row" key={h.id}><div className="history-icon"><Sparkles size={16}/></div><div><b>{h.description}</b><small>{new Date(h.created_at).toLocaleString()}</small></div><strong className={h.profit_loss>0?"positive":h.profit_loss<0?"negative":""}>{h.profit_loss?`${h.profit_loss>0?"+":""}${formatCompact(h.profit_loss)}`:h.amount?`💎 ${formatCompact(h.amount)}`:"—"}</strong></div>):<div className="empty-state"><History size={30}/><b>No activity yet</b><span>Your games, upgrades and rewards will appear here.</span></div>}</div></div></section>}

function GiveawaysPage({session,giveaways,joinedGiveawayIds=[],setJoinedGiveawayIds,reload,setToast}){
  const [open,setOpen]=useState(false),[title,setTitle]=useState(""),[type,setType]=useState("diamonds"),[reward,setReward]=useState("1b"),[petId,setPetId]=useState(""),[petVariant,setPetVariant]=useState("normal"),[entries,setEntries]=useState(100),[minutes,setMinutes]=useState(60);
  const owned=(window.__SPINNYPET_INVENTORY__||[]).filter(p=>isHighTierName(p.name));
  const selectedPet=owned.find(p=>p.pet_id===petId&&p.variant===petVariant)||owned.find(p=>p.pet_id===petId);
  async function create(){try{
    if(!title.trim())throw new Error("Enter a giveaway title.");
    if(type==="diamonds"&&(!parseCompactAmount(reward)||parseCompactAmount(reward)<=0))throw new Error("Enter a valid diamond reward.");
    if(type==="pet"&&!selectedPet)throw new Error("Choose a pet from your inventory.");
    await betaCreateGiveaway(title,type,type==="diamonds"?parseCompactAmount(reward):0,type==="pet"?petId:null,type==="pet"?petVariant:"normal",entries,minutes);
    setOpen(false);setPetId("");await reload();setToast("Giveaway created. The reward is reserved.");
  }catch(e){setToast(e.message||"Could not create giveaway.");}}
  function canJoin(g){return normalizeUsername(g.host_username)!==normalizeUsername(session?.username)}
  return <section><div className="page-header"><div><span>COMMUNITY</span><h1>Giveaways</h1><small>Diamonds or a real owned Huge · Titanic · Gargantuan pet. Winners are selected automatically when the timer ends.</small></div><button className="primary-btn" onClick={()=>session?setOpen(true):setToast("Sign in to create a giveaway.")}><Plus size={16}/> Create giveaway</button></div>
    <div className="giveaway-grid">{giveaways.length?giveaways.map(g=><div className="giveaway-card" key={g.id}><div className="giveaway-head"><span><Gift size={16}/> GIVEAWAY</span><small><Clock3 size={13}/> {new Date(g.ends_at).toLocaleString()}</small></div><h2>{g.title}</h2><div className="giveaway-reward">{g.reward_type==="pet"?<><PetIcon pet={{name:g.reward_pet_name,id:g.reward_pet_id,thumbnailUrl:g.reward_pet_thumbnail_url,goldenThumbnailUrl:g.reward_pet_golden_thumbnail_url}} size="medium" variant={g.reward_pet_variant||"normal"}/><div><b>{g.reward_pet_name}</b><small>{g.reward_pet_variant||'normal'} · PS99 RAP</small></div></>:<div><span className="giveaway-diamond">💎</span><b>{formatCompact(g.reward_amount)}</b><small>Diamonds</small></div>}</div><p>Hosted by <b>@{g.host_username}</b> · {g.entries_count}/{g.max_entries} entries</p><div className="giveaway-actions">{g.status==="drawn"?<><div className="giveaway-winner">🏆 Winner: <b>@{g.winner_username||"Unknown"}</b></div><span className="giveaway-auto">RESULT SHOWN 10S</span></>:session&&joinedGiveawayIds.includes(g.id)?<button className="primary-btn joined-giveaway-btn" disabled>✓ JOINED</button>:session&&canJoin(g)?<button className="primary-btn" onClick={async()=>{try{await betaEnterGiveaway(g.id);const key=`spinnypet:joined-giveaways:${session?.user_id}`;setJoinedGiveawayIds?.(v=>{const next=[...new Set([...(v||[]),g.id])];try{localStorage.setItem(key,JSON.stringify(next))}catch{}return next});await reload();setToast("Entered giveaway — ✓ JOINED")}catch(e){setToast(e.message||"Could not enter.")}}}>JOIN GIVEAWAY</button>:<button className="ghost-btn" disabled>{session?"YOUR GIVEAWAY":"SIGN IN TO ENTER"}</button>}<span className="giveaway-auto">{g.status==="drawn"?"WINNER SELECTED":"AUTO DRAW AT END"}</span></div></div>):<div className="empty-state wide"><Gift size={34}/><b>No live giveaways</b><span>Create the first beta giveaway.</span></div>}</div>
    {open&&<Modal onClose={()=>setOpen(false)}><button className="modal-close" onClick={()=>setOpen(false)}><X size={18}/></button><div className="auth-icon"><Gift size={23}/></div><h2>Create giveaway</h2><p>Choose diamonds or one of your owned high-tier pets.</p><div className="auth-form"><input value={title} onChange={e=>setTitle(e.target.value)} placeholder="Giveaway title"/><div className="reward-toggle"><button className={type==="diamonds"?"active":""} onClick={()=>setType("diamonds")}>💎 Diamonds</button><button className={type==="pet"?"active":""} onClick={()=>setType("pet")}>🐾 Pet</button></div>{type==="diamonds"?<input value={reward} onChange={e=>setReward(e.target.value)} placeholder="Reward e.g. 1b / 5b"/>:<><div className="giveaway-pet-picker">{owned.length?owned.map(p=><button type="button" key={`${p.pet_id}:${p.variant}`} className={petId===p.pet_id&&petVariant===p.variant?"selected":""} onClick={()=>{setPetId(p.pet_id);setPetVariant(p.variant)}}><PetIcon pet={inventoryPetShape(p)} size="medium" variant={p.variant}/><span>{p.name}</span><small>{p.variant} · 💎 {formatPetValue(p)}</small></button>):<div className="empty-state"><Package size={26}/><span>No high-tier pets in inventory.</span></div>}</div></>}<input type="number" min="2" max="5000" value={entries} onChange={e=>setEntries(e.target.value)} placeholder="Max entries"/><input type="number" min="1" max="10080" value={minutes} onChange={e=>setMinutes(e.target.value)} placeholder="Duration in minutes"/><button className="primary-btn wide" onClick={create}>Create giveaway</button></div></Modal>}
  </section>
}
function EventPage({session,event,reload,setToast}){
  const [busy,setBusy]=useState(false),[team,setTeam]=useState(event?.team||""),[activity,setActivity]=useState([]),[phase,setPhase]=useState("ready"),[focus,setFocus]=useState("pressure"),[charge,setCharge]=useState(52),[charging,setCharging]=useState(false),[lockedCharge,setLockedCharge]=useState(null);
  useEffect(()=>setTeam(event?.team||""),[event?.team]);
  useEffect(()=>{
    if(!charging)return;
    let dir=1;
    const id=setInterval(()=>{
      setCharge(v=>{
        let next=v+(dir*3);
        if(next>=97){next=97;dir=-1}
        if(next<=8){next=8;dir=1}
        return next;
      });
    },55);
    return ()=>clearInterval(id);
  },[charging]);
  const red=Number(event?.red_score||0),blue=Number(event?.blue_score||0),total=Math.max(1,red+blue),redPct=red/total*100,bluePct=blue/total*100;
  async function choose(next){if(!session){setToast("Sign in first.");return;}try{const e=await betaJoinEvent(next);setTeam(next);setLockedCharge(null);setPhase("ready");setActivity(a=>[{id:Date.now(),text:`You joined ${next.toUpperCase()}.`,team:next},...a].slice(0,6));setToast(`Joined ${next.toUpperCase()}.`);await reload();}catch(e){setToast(e.message||"Could not join team.")}}
  function beginCharge(){
    if(!team){setToast("Choose Red or Blue first.");return;}
    if(busy)return;
    setLockedCharge(null);setPhase("rolling");setCharging(true);
  }
  async function lockAndPlay(){
    if(!session){setToast("Sign in first.");return;}
    if(!team){setToast("Choose Red or Blue first.");return;}
    if(busy)return;
    setCharging(false);setLockedCharge(charge);setPhase("hit");setBusy(true);
    try{
      await new Promise(r=>setTimeout(r,650));
      const d=await betaPlayEvent();
      const timing=charge>=42&&charge<=72?"CENTER HIT":"EDGE HIT";
      setActivity(a=>[{id:Date.now(),text:`${timing} · +${formatCompact(d.points)} event points`,team},...a].slice(0,6));
      setToast(`Round resolved · +${formatCompact(d.points)} event points`);
      await reload();
      setTimeout(()=>{setPhase("ready");setLockedCharge(null)},700);
    }catch(e){setPhase("ready");setLockedCharge(null);setToast(e.message||"Could not play this round.")}
    finally{setBusy(false)}
  }
  return <section className="event-page"><div className={`event-hero event-hero-${team||'none'}`}><div><span className="eyebrow">LIVE BETA EVENT · INTERACTIVE ROUND</span><h1>RED <span>VS</span> BLUE</h1><p>Choose a side, pick the battle focus, charge the meter and lock your timing before the virtual round resolves.</p><div className="event-quick-stats"><span>100B BANK</span><span>{formatCompact(red+blue)} SCORED</span><span>{event?.team?`YOU: ${event.team.toUpperCase()}`:"NO TEAM"}</span></div></div><div className="event-bank"><span>💎</span>{formatCompact(event?.bank_value||100000000000)}<small>VIRTUAL EVENT BANK</small></div></div>
    <div className="event-choice-grid"><button className={`team-choice red ${team==='red'?'selected':''}`} onClick={()=>choose('red')}><span>RED</span><strong>{formatCompact(red)}</strong><small>{redPct.toFixed(1)}% of current score</small><div className="event-mini-bar"><i style={{width:`${redPct}%`}}/></div><b>{team==='red'?'✓ SELECTED':'CHOOSE RED'}</b></button><div className="event-center"><div className={`event-orb ${phase}`}>{phase==='rolling'?'✦':phase==='hit'?'✓':'VS'}</div><span>{phase==='rolling'?'LOCK YOUR TIMING':phase==='hit'?'ROUND RESOLVED':'CHOOSE A TEAM'}</span></div><button className={`team-choice blue ${team==='blue'?'selected':''}`} onClick={()=>choose('blue')}><span>BLUE</span><strong>{formatCompact(blue)}</strong><small>{bluePct.toFixed(1)}% of current score</small><div className="event-mini-bar"><i style={{width:`${bluePct}%`}}/></div><b>{team==='blue'?'✓ SELECTED':'CHOOSE BLUE'}</b></button></div>
    <div className="event-control-card"><div className="event-control-copy"><span className="eyebrow">ROUND CONSOLE</span><h2>{team?`Ready for ${team.toUpperCase()}`:'Choose your side'}</h2><p>Focus is selected before the charge. Timing is visual beta feedback; the event server still controls the round reward.</p><div className="event-focus-row"><span>BATTLE FOCUS</span>{[["pressure","PRESSURE"],["comeback","COMEBACK"],["jackpot","JACKPOT"]].map(([v,l])=><button key={v} className={focus===v?"active-focus":""} onClick={()=>setFocus(v)}>{l}</button>)}</div><div className={`event-charge-box ${charging?'charging':''}`}><div className="event-charge-head"><span>ROUND TIMING</span><b>{lockedCharge!==null?`${lockedCharge}% LOCKED`:charging?`${charge}%`:"READY"}</b></div><div className="event-charge-track"><i style={{width:`${charge}%`}}/><b style={{left:`${charge}%`}}/></div><div className="event-charge-zones"><span>EDGE</span><strong>CENTER HIT</strong><span>EDGE</span></div><small>Start the meter, then lock it where you want your timing marker to land.</small></div></div><div className="event-round-cta"><div><span>ROUND REWARD</span><strong>+1B</strong><small>{focus.toUpperCase()} · virtual event points</small></div>{!charging&&lockedCharge===null?<button className="primary-btn" disabled={busy||!team} onClick={beginCharge}>CHARGE ROUND</button>:<button className="primary-btn" disabled={busy||!team||!charging} onClick={lockAndPlay}>{busy?'Resolving…':`LOCK ${charge}% · +1B`}</button>}</div></div>
    <div className="event-liveboard"><div className="event-liveboard-main"><div className="panel-title"><div><span>LIVE BOARD</span><h2>Team momentum</h2></div><Sparkles size={19}/></div><div className="event-double-bar"><i style={{width:`${redPct}%`}}/><b style={{left:`${redPct}%`}}/></div><div className="event-double-labels"><span>RED {formatCompact(red)}</span><span>BLUE {formatCompact(blue)}</span></div></div><div className="event-activity"><b>RECENT ACTIONS</b>{activity.length?activity.map(x=><div key={x.id}><span className={`activity-dot ${x.team||''}`}/>{x.text}</div>):<span className="muted">Choose a team and play a round to build the feed.</span>}</div></div></section>
}

function ClanAdminControls({role,setToast}){
  const [clans,setClans]=useState([]),[busy,setBusy]=useState(false);
  async function load(){try{setClans(await betaGetTopClans(50))}catch{setClans([])}}
  useEffect(()=>{load()},[]);
  async function removeClan(c){if(!confirm(`Delete clan "${c.name}"? This removes its members, invites and treasury.

This cannot be undone.`))return;setBusy(true);try{await betaAdminDeleteClan(c.id);setToast(`Clan ${c.name} deleted.`);await load();}catch(e){setToast(e.message||"Could not delete clan.")}finally{setBusy(false)}}
  return <div className="history-card"><h2>Clan management</h2><p className="muted">Owner and Manager can delete any clan. Deleting a clan removes its members and clan data.</p><div className="admin-clan-list">{clans.length?clans.map(c=><div className="admin-clan-row" key={c.id}><div><b>{c.name}</b><small>LV. {c.level} · {Number(c.points||0).toLocaleString()} pts · 💎 {formatCompact(c.treasury_diamonds||0)}</small></div><button className="ghost-btn danger" disabled={busy} onClick={()=>removeClan(c)}>Delete Clan</button></div>):<div className="empty-state">No clans found.</div>}</div></div>;
}

function AdminPage({session,role,setToast}){
  const [users,setUsers]=useState([]),[giveAllReport,setGiveAllReport]=useState(null),[target,setTarget]=useState(""),[targetInventory,setTargetInventory]=useState([]),[balance,setBalance]=useState("100b"),[minutes,setMinutes]=useState("60"),[reason,setReason]=useState(""),[newRole,setNewRole]=useState("moderator"),[eventLive,setEventLive]=useState(false),[working,setWorking]=useState(false),[adminError,setAdminError]=useState(""),[chaosEffect,setChaosEffect]=useState("jackpot"),[chaosPage,setChaosPage]=useState("all"),[chaosReward,setChaosReward]=useState("0"),[chaosMessage,setChaosMessage]=useState("");
  const canEvent=["owner","co_owner","manager","admin"].includes(role);
  const canAdmin=["owner","co_owner","manager","admin","moderator"].includes(role);
  async function reload(){try{setAdminError("");setUsers(await betaAdminGetUsers());const ev=await betaGetActiveEvent();setEventLive(Boolean(ev?.status==="live"));}catch(e){setAdminError(e.message||"Staff access required");setToast(e.message||"Staff access required")}}
  async function loadTargetInventory(name=target){if(!name)return;try{setTargetInventory(await betaAdminGetInventory(name));}catch(e){setTargetInventory([]);setToast(e.message||"Could not load inventory.")}}
  useEffect(()=>{reload()},[]);
  async function action(fn,msg){try{setWorking(true);await fn();await reload();await loadTargetInventory();setToast(msg)}catch(e){setToast(e.message||"Admin action failed")}finally{setWorking(false)}}
  if(!canAdmin) return <section className="admin-page"><div className="page-header"><div><span>STAFF CONTROL</span><h1>Admin Panel</h1><small>Your current role is {role.toUpperCase()}.</small></div><ShieldCheck size={28}/></div><div className="admin-access-card"><ShieldCheck size={42}/><h2>Staff access required</h2><p>This page exists and loaded correctly, but your account does not have a staff role.</p>{adminError&&<small>{adminError}</small>}</div></section>;
  return <section className="admin-page"><div className="page-header"><div><span>STAFF CONTROL</span><h1>Admin Panel</h1><small>Role: {role.toUpperCase()} · players, inventory, moderation, roles and events</small></div><ShieldCheck size={28}/></div>
    {adminError&&<div className="error-box admin-error-box">{adminError}<button className="ghost-btn" onClick={reload}>Retry</button></div>}<div className="admin-grid">
      <div className="history-card admin-control-card"><h2>Player controls</h2><div className="auth-form"><div className="admin-target-row"><input value={target} onChange={e=>setTarget(e.target.value)} onBlur={()=>loadTargetInventory(e.target.value)} placeholder="Username"/><button className="ghost-btn" type="button" disabled={!target||working} onClick={()=>loadTargetInventory(target)}>Load Player</button></div><input value={balance} onChange={e=>setBalance(e.target.value)} placeholder="Balance e.g. 100b"/><input value={minutes} onChange={e=>setMinutes(e.target.value)} placeholder="Minutes (0 = permanent)"/><input value={reason} onChange={e=>setReason(e.target.value)} placeholder="Reason"/><select value={newRole} onChange={e=>setNewRole(e.target.value)}><option value="user">Member</option><option value="helper">Helper</option><option value="moderator">Moderator</option><option value="admin">Admin</option><option value="manager">Manager</option><option value="co_owner">Co Owner</option><option value="owner">Owner</option></select><div className="admin-actions"><button className="primary-btn" disabled={working} onClick={()=>action(()=>betaAdminSetBalance(target,parseCompactAmount(balance)),"Balance updated")}>Set Balance</button><button className="ghost-btn danger" disabled={working} onClick={async()=>{if(!confirm('ADMIN ABUSE → GIVEALL\n\nGive every registered player the full high-tier catalog?'))return;try{const d=await betaAdminGiveAll('');setGiveAllReport(d);setToast('GIVEALL completed.');}catch(e){setToast(e.message||'Give All failed.')}}}>Give All Players</button><button className="ghost-btn" disabled={working} onClick={()=>action(()=>betaAdminModerate(target,"mute",minutes,reason),"Player muted")}>Mute</button><button className="ghost-btn" disabled={working} onClick={()=>action(()=>betaAdminModerate(target,"ban",minutes,reason),"Player banned")}>Ban</button><button className="ghost-btn" disabled={working} onClick={()=>action(()=>betaAdminModerate(target,"unmute",0,""),"Player unmuted")}>Unmute</button><button className="ghost-btn" disabled={working} onClick={()=>action(()=>betaAdminModerate(target,"unban",0,""),"Player unbanned")}>Unban</button><button className="primary-btn" disabled={working||!canEvent} onClick={()=>action(()=>betaAdminSetRole(target,newRole),`Role set to ${newRole}`)}>Set Role</button></div></div></div>
      <div className="history-card"><div className="panel-title"><div><span>INVENTORY TOOL</span><h2>@{target||'select a player'}</h2></div><Package size={20}/></div><div className="admin-inventory-tools"><button className="ghost-btn" disabled={!target||working} onClick={()=>action(()=>betaAdminClearInventory(target),"Inventory cleared")}>Clear All Inventory</button><button className="ghost-btn" disabled={!target||working} onClick={()=>loadTargetInventory()}>Refresh</button></div><div className="admin-inventory-list">{targetInventory.length?targetInventory.map(i=><div className="admin-inventory-row" key={i.id}><PetIcon pet={inventoryPetShape(i)} size="small" variant={i.variant}/><div><b>{i.name}</b><span>{i.variant} · {i.quantity}×</span></div><button className="ghost-btn" disabled={working} onClick={()=>action(()=>betaAdminRemovePet(target,i.pet_id,i.variant,1),"1 pet removed")}>Remove 1</button><button className="ghost-btn danger" disabled={working} onClick={()=>action(()=>betaAdminRemovePet(target,i.pet_id,i.variant,i.quantity),"Pet stack removed")}>Remove All</button></div>):<div className="empty-state"><Package size={28}/><b>No inventory loaded</b><span>Select a username above and refresh.</span></div>}</div></div>
      <div className="history-card admin-chaos-card"><div className="panel-title"><div><span className="admin-chaos-live">LIVE SERVER FX</span><h2>Admin Abuse</h2></div><Zap size={20}/></div><p className="admin-help">Send a live server-wide spectacle to players currently on the selected page. The animation is delivered through Supabase Realtime; the diamond reward is handled server-side.</p><div className="admin-chaos-form"><label><span>1 · EFFECT</span><select value={chaosEffect} onChange={e=>setChaosEffect(e.target.value)}><option value="jackpot">💎 Jackpot Rain</option><option value="coinstorm">🪙 Coin Storm</option><option value="dicefall">🎲 Dicefall</option><option value="petstorm">🐾 Pet Swarm</option><option value="caseburst">📦 Case Burst</option><option value="glitch">⚡ Reality Glitch</option><option value="rainbow">🌈 Rainbow Override</option></select></label><label><span>2 · WHERE</span><select value={chaosPage} onChange={e=>setChaosPage(e.target.value)}>{[["all","🌐 Everyone / All pages"],["home","🏠 Home"],["coinflip","🪙 Coinflip"],["dice","🎲 Color Dice"],["inventory","🐾 Inventory"],["profile","👤 Profile"],["time-rewards","🎁 Time Rewards"],["cases","📦 Cases"],["case-battle","⚔️ Case Battle"],["leaderboard","🏆 Leaderboard"],["clans","🛡️ Clans"],["giveaways","🎉 Giveaways"],["promo","🏷️ Promo"],["admin","⚡ Admin"]].map(([v,l])=><option key={v} value={v}>{l}</option>)}</select></label><label><span>3 · REWARD (OPTIONAL)</span><input value={chaosReward} onChange={e=>setChaosReward(e.target.value)} placeholder="Example: 1b diamonds"/></label><label><span>4 · MESSAGE (OPTIONAL)</span><input value={chaosMessage} onChange={e=>setChaosMessage(e.target.value)} placeholder="Example: JACKPOT DROP!"/></label></div><div className="admin-chaos-actions"><button className="primary-btn" disabled={working} onClick={()=>action(()=>betaAdminTriggerChaos(chaosEffect,chaosPage,Math.max(0,Number(parseCompactAmount(chaosReward))||0),chaosMessage),`Admin Abuse launched on ${chaosPage}`)}>⚡ Launch Admin Abuse</button><button className="ghost-btn" disabled={working} onClick={()=>action(()=>betaAdminTriggerChaos(chaosEffect,chaosPage,0,chaosMessage),`Visual FX launched on ${chaosPage}`)}>✨ Visual Only</button></div><div className="admin-chaos-warning"><b>How it works:</b> choose the page first. Players must currently be on that page to see the effect. Set reward to <b>0</b> for animation only.</div></div>
      {(role==="owner"||role==="manager")&&<div className="history-card"><h2>Clan Battle timer</h2><p className="muted">Reset the Clan Battle to a fresh 48-hour period when the current period has ended.</p><button className="primary-btn" disabled={working} onClick={()=>action(()=>betaAdminResetClanBattleTimer(),"Clan Battle timer reset to 48 hours.")}>Reset 48H Timer</button></div>}
      <div className="history-card"><h2>Event control</h2><p className="muted">Only Owner, Co Owner, Manager and Admin can activate or stop Red vs Blue. Moderator and Helper cannot toggle it.</p><button className={`event-toggle ${eventLive?"live":""}`} disabled={!canEvent||working} onClick={()=>action(()=>betaAdminSetEvent(!eventLive),eventLive?"Red vs Blue disabled":"Red vs Blue enabled for everyone")}>{eventLive?"● EVENT LIVE · Disable":"○ EVENT OFF · Enable"}</button></div>
      <div className="history-card promo-admin-card"><h2>Promo codes</h2><p className="muted">Owner, Co Owner, Manager and Admin can create codes.</p><PromoCodeAdmin role={role} setToast={setToast}/></div>
      {(role==="owner"||role==="manager")&&<ClanAdminControls role={role} setToast={setToast}/>}
      <div className="history-card"><h2>Staff roster / players</h2><div className="admin-users">{users.map(u=><button key={u.id} onClick={()=>{setTarget(u.username);setNewRole(u.role);loadTargetInventory(u.username)}}><b>@{u.username}</b><span>{u.role==='user'?'MEMBER':u.role}</span><small>💎 {formatCompact(u.balance)}</small></button>)}</div></div>
    </div>{giveAllReport&&<Modal onClose={()=>setGiveAllReport(null)}><button className="modal-close" onClick={()=>setGiveAllReport(null)}><X size={18}/></button><div className="giveall-abuse-modal"><div className="giveall-abuse-label">ADMIN ABUSE</div><h2>GIVEALL</h2><p>The full high-tier catalog was granted to every registered account.</p><div className="giveall-report-grid"><div><b>{Number(giveAllReport.players||0).toLocaleString()}</b><span>PLAYERS</span></div><div><b>{Number(giveAllReport.count||0).toLocaleString()}</b><span>PETS EACH</span></div></div><button className="primary-btn wide" onClick={()=>setGiveAllReport(null)}>Close</button></div></Modal>}</section>
}
function Chat({messages,text,setText,onSend,username,giveaways=[],joinedGiveawayIds=[],onEnterGiveaway}){
  const roleLabel={owner:"OWNER",co_owner:"CO OWNER",manager:"MANAGER",admin:"ADMIN",moderator:"MOD",helper:"HELPER",user:"MEMBER"};
  const [selectedGiveawayId,setSelectedGiveawayId]=useState(null);
  const carousel=useMemo(()=>giveaways.filter(g=>g.status==="open"||(g.status==="drawn"&&g.updated_at&&Date.now()-new Date(g.updated_at).getTime()<=10000)),[giveaways]);
  useEffect(()=>{setSelectedGiveawayId(id=>carousel.some(g=>g.id===id)?id:(carousel[0]?.id||null))},[carousel.map(g=>g.id).join('|')]);
  const giveaway=carousel.find(g=>g.id===selectedGiveawayId)||carousel[0];
  const giveawayIndex=Math.max(0,carousel.findIndex(g=>g.id===giveaway?.id));
  function move(delta){if(!carousel.length)return;const next=(giveawayIndex+delta+carousel.length)%carousel.length;setSelectedGiveawayId(carousel[next]?.id||null)}
  const joined=!!giveaway&&joinedGiveawayIds.includes(giveaway.id);
  return <aside className="chat"><div className="chat-head"><div><span className="online-dot"/><b>SPINNYPET CHAT</b><small> · live beta</small></div><Users size={16}/></div>{giveaway&&<div className={`chat-giveaway ${giveaway.status==="drawn"?"winner-state":""} ${joined?"is-joined":""}`}><div className="chat-giveaway-nav"><button onClick={()=>move(-1)} disabled={carousel.length<2}>‹</button><span>{giveawayIndex+1} / {carousel.length}</span><button onClick={()=>move(1)} disabled={carousel.length<2}>›</button></div><div className="chat-giveaway-reward"><span className="chat-giveaway-live">{giveaway.status==="drawn"?"🏆 WINNER SELECTED":"🎁 GIVEAWAY LIVE"}</span>{giveaway.reward_type==="pet"?<div className="chat-giveaway-object"><img className="chat-giveaway-pet-art" src={giveaway.reward_pet_thumbnail_url||"/assets/pet-gargantuan.png"} alt=""/><div><b>{giveaway.reward_pet_name}</b><small>{giveaway.reward_pet_variant||"normal"}</small></div></div>:<div className="chat-giveaway-object"><span className="chat-giveaway-diamond">💎</span><div><b>{formatCompact(giveaway.reward_amount)}</b><small>Diamonds</small></div></div>}{giveaway.status==="drawn"?<><small>Winner: <b>{giveaway.winner_username||"Unknown"}</b></small><small>Result remains for 10 seconds.</small></>:<small>Ends {new Date(giveaway.ends_at).toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"})}</small>}</div>{giveaway.status==="open"&&<button className={joined?"joined-giveaway-btn":""} onClick={()=>onEnterGiveaway(giveaway)} disabled={normalizeUsername(giveaway.host_username)===normalizeUsername(username)||joined}>{normalizeUsername(giveaway.host_username)===normalizeUsername(username)?"HOST":joined?"✓ JOINED":"JOIN"}</button>}</div>}<div className="chat-messages">{messages.length?messages.map((m,i)=><div className="chat-item" key={m.id||i}><div className="chat-avatar">{m.custom_avatar_url?<img src={m.custom_avatar_url} alt=""/>:String(m.username||"?")[0].toUpperCase()}</div><div><div className="chat-meta"><b>{m.username}</b><span className={`chat-badge badge-${m.role||"user"}`}>{roleLabel[m.role]||"MEMBER"}</span><span className="chat-rank">{m.rank_name||"ROOKIE"}</span><small>{new Date(m.created_at||Date.now()).toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"})}</small></div><p>{m.message}</p></div></div>):<div className="chat-empty">No messages yet.<br/>Be the first to say hi.</div>}</div><div className="chat-input"><input value={text} onChange={e=>setText(e.target.value)} onKeyDown={e=>e.key==="Enter"&&onSend()} placeholder={username?`Message as ${username}`:"Sign in to chat..."}/><button onClick={onSend}><Send size={15}/></button></div></aside>
}

function Loader(){return <div className="loader"><RefreshCw className="spin" size={24}/><span>Loading the PS99 high-tier catalog…</span></div>}

function AuthModal({mode,setMode,onClose,onSuccess}){const [username,setUsername]=useState("");const [password,setPassword]=useState("");const [roblox,setRoblox]=useState("");const [busy,setBusy]=useState(false);const [error,setError]=useState("");async function submit(e){e.preventDefault();if(!supabaseConfigured){setError("Supabase is not configured. Check your .env file.");return;}setBusy(true);setError("");try{const d=mode==="login"?await betaSignIn(username,password):await betaSignUp(username,password);if(mode==="signup"&&roblox.trim()) { const r=await resolveRobloxAvatar(roblox.trim()); if(r?.user) await betaUpdateRobloxProfile(r.user.id,r.user.name,r.url||""); else throw new Error("Roblox username / ID not found."); } onSuccess(d);}catch(e){setError(e.message||"Could not authenticate.");}finally{setBusy(false);}}return <Modal onClose={onClose}><button className="modal-close" onClick={onClose}><X size={18}/></button><div className="auth-icon"><ShieldCheck size={25}/></div><h2>{mode==="login"?"Welcome back":"Create your beta account"}</h2><p>Username + password only. You can optionally connect a Roblox username or numeric User ID.</p><form className="auth-form" onSubmit={submit}><input required minLength={3} maxLength={20} value={username} onChange={e=>setUsername(e.target.value)} placeholder="SpinnyPet username" autoComplete="username"/>{mode==="signup"&&<input value={roblox} onChange={e=>setRoblox(e.target.value)} placeholder="Roblox username or User ID (optional)"/>}<input required minLength={6} maxLength={72} type="password" value={password} onChange={e=>setPassword(e.target.value)} placeholder="Password" autoComplete={mode==="login"?"current-password":"new-password"}/>{error&&<div className="auth-error">{error}</div>}<button className="primary-btn wide" disabled={busy}>{busy?"Working…":mode==="login"?"Sign in":"Create account"}</button></form><button className="switch-auth" onClick={()=>{setMode(mode==="login"?"signup":"login");setError("")}}>{mode==="login"?"Need a beta account? Create one":"Already have an account? Sign in"}</button></Modal>}
