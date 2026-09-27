import { supabase } from "./supabase";

const TOKEN_KEY = "petflip_beta_session";
const PROFILE_KEY = "petflip_beta_profile";

export function getBetaToken() { return localStorage.getItem(TOKEN_KEY) || ""; }
function saveSession(data) {
  if (!data?.token) return;
  localStorage.setItem(TOKEN_KEY, data.token);
  localStorage.setItem(PROFILE_KEY, JSON.stringify({ user_id: data.user_id, username: data.username, balance: Number(data.balance || 0) }));
}
function clearSession() { localStorage.removeItem(TOKEN_KEY); localStorage.removeItem(PROFILE_KEY); }
export function cachedBetaSession() { try { return JSON.parse(localStorage.getItem(PROFILE_KEY) || "null"); } catch { return null; } }

async function rpc(name, args) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data;
}

export async function betaSignUp(username, password) { const data = await rpc("beta_create_account", { p_username: username.trim(), p_password: password }); saveSession(data); return data; }
export async function betaSignIn(username, password) { const data = await rpc("beta_login", { p_username: username.trim(), p_password: password }); saveSession(data); return data; }

export async function betaSession() {
  const token = getBetaToken();
  if (!token || !supabase) return cachedBetaSession();
  try {
    const data = await rpc("beta_get_session", { p_token: token });
    if (!data?.user_id) { clearSession(); return null; }
    saveSession({ token, ...data });
    return data;
  } catch {
    // Keep the local session during transient Supabase/API errors. This prevents
    // a refresh from logging the tester out when the network blips.
    return cachedBetaSession();
  }
}

export async function betaSignOut() {
  const token = getBetaToken();
  clearSession();
  if (token && supabase) await supabase.rpc("beta_logout", { p_token: token }).catch(() => {});
  return true;
}

export async function betaClaimBonus() { const d=await rpc("beta_claim_bonus", { p_token: getBetaToken() }); saveSession({token:getBetaToken(),...d}); return d; }
export async function betaSendChat(message) { return rpc("beta_send_chat", { p_token: getBetaToken(), p_message: message.trim() }); }
export async function betaAddInventoryPet(petId, variant = "normal", quantity = 1) { return rpc("beta_add_pet", { p_token: getBetaToken(), p_pet_id: petId, p_variant: variant, p_quantity: quantity }); }
export async function betaGetInventory() { const data = await rpc("beta_get_inventory", { p_token: getBetaToken() }); return Array.isArray(data) ? data : []; }
export async function betaClaimDailyCase() { const d=await rpc("beta_claim_daily_case", { p_token: getBetaToken() }); saveSession({token:getBetaToken(),...d}); return d; }
export async function betaOpenCase(caseId) { return rpc("beta_open_case", { p_token: getBetaToken(), p_case_id: caseId }); }
export async function betaCreateDiceLobby(stake) {
  const pets = (stake.type==="pet" ? (stake.pets||[stake.pet]).filter(Boolean) : []).map(p=>({pet_id:p.pet_id||p.id, pet_name:p.name||null, variant:p.variant||"normal", quantity:1}));
  const args={ p_token:getBetaToken(), p_stake_type:stake.type, p_stake_amount:Number(stake.amount||0), p_pet_items:pets, p_choice:stake.choice||null };
  try { return await rpc("beta_create_dice_lobby", args); }
  catch(e) { if(/function .*beta_create_dice_lobby.*does not exist|could not find the function/i.test(String(e?.message||e))) return rpc("beta_create_lobby_v2", {p_token:getBetaToken(),p_game_type:"dice",...args}); throw e; }
}
export async function betaJoinDiceLobby(id, stake=null, choice=null) {
  const pets=(stake?.type==="pet"?(stake.pets||[]).map(p=>({pet_id:p.pet_id||p.id,variant:p.variant||"normal",quantity:1})):[]);
  const args={p_token:getBetaToken(),p_lobby_id:id,p_pet_items:pets,p_choice:choice||null};
  try { return await rpc("beta_join_dice_lobby", args); }
  catch(e) { if(/function .*beta_join_dice_lobby.*does not exist|could not find the function/i.test(String(e?.message||e))) return rpc("beta_join_lobby_v2", args); throw e; }
}

export async function betaCreateLobby(gameType, stake) {
  const pets = (stake.type==="pet" ? (stake.pets||[stake.pet]).filter(Boolean) : []).map(p=>({
    pet_id:p.pet_id||p.id,
    pet_name:p.name||null,
    variant:p.variant||"normal",
    quantity:1
  }));
  return rpc("beta_create_lobby_v2", { p_token:getBetaToken(), p_game_type:gameType, p_stake_type:stake.type, p_stake_amount:Number(stake.amount||0), p_pet_items:pets, p_choice:stake.choice||null });
}
export async function betaListLobbies(gameType) { const { data, error } = await supabase.from("beta_game_lobbies").select("id,game_type,creator_id,creator_username,creator_avatar_url,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,join_pet_items,choice,join_choice,result_side,winner_id,winner_username,payout,status,created_at").eq("game_type", gameType).eq("status", "open").order("created_at", { ascending: false }).limit(30); if (error) throw error; return data || []; }
export async function betaGetCoinflipResult(id) { const { data, error } = await supabase.from("beta_game_lobbies").select("id,game_type,creator_id,creator_username,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,join_pet_items,choice,result_side,winner_id,winner_username,payout,status,created_at").eq("id",id).maybeSingle(); if(error) throw error; return data; }
export async function betaGetHistory() { return (await rpc("beta_get_history", { p_token: getBetaToken() })) || []; }
export async function betaGetLiveBets() { return (await rpc("beta_live_bets", {})) || []; }
export async function betaGetStats() { return (await rpc("beta_get_stats", { p_token: getBetaToken() })) || {}; }
export async function betaGetJoinedGiveaways() { return (await rpc("beta_get_joined_giveaways", { p_token:getBetaToken() })) || []; }
export async function betaGetGiveaways() { const { data, error } = await supabase.from("beta_giveaways").select("id,host_username,title,reward_amount,reward_type,reward_pet_id,reward_pet_name,reward_pet_variant,max_entries,entries_count,status,ends_at,created_at,updated_at,winner_username").in("status", ["open","drawn"]).order("created_at", { ascending: false }).limit(30); if (error) throw error; const now=Date.now(); return (data||[]).filter(g=>g.status==="open" || (g.status==="drawn" && g.updated_at && now-new Date(g.updated_at).getTime()<=10000)); }
export async function betaCreateGiveaway(title, rewardType, rewardAmount, rewardPetId, rewardPetVariant, maxEntries, durationMinutes) { return rpc("beta_create_giveaway", { p_token: getBetaToken(), p_title: title, p_reward_type: rewardType, p_reward_amount: Number(rewardAmount||0), p_reward_pet_id: rewardPetId || null, p_reward_pet_variant: rewardPetVariant || "normal", p_max_entries: Number(maxEntries), p_duration_minutes: Number(durationMinutes) }); }
export async function betaEnterGiveaway(id) { return rpc("beta_enter_giveaway", { p_token: getBetaToken(), p_giveaway_id: id }); }
export async function betaDrawGiveaway(id) { return rpc("beta_draw_giveaway", { p_token: getBetaToken(), p_giveaway_id: id }); }
export async function betaFinalizeGiveaways() { return rpc("beta_finalize_expired_giveaways", { p_token: getBetaToken() }); }
export async function betaRedeemPromo(code) { return rpc("beta_redeem_promo", { p_token: getBetaToken(), p_code: String(code||"").trim().toUpperCase() }); }
export async function betaAdminCreatePromo(code, amount, maxUses, durationMinutes) { return rpc("beta_admin_create_promo", { p_token: getBetaToken(), p_code: String(code||"").trim().toUpperCase(), p_reward_amount: Number(amount||0), p_max_uses: Number(maxUses||0), p_duration_minutes: Number(durationMinutes||0) }); }
export async function betaUpdateRobloxProfile(userId, username, avatarUrl) { return rpc("beta_update_roblox_profile", { p_token: getBetaToken(), p_roblox_user_id: Number(userId), p_roblox_username: username, p_avatar_url: avatarUrl || "" }); }
export async function betaUpdateCustomAvatar(url) { return rpc("beta_update_custom_avatar", { p_token: getBetaToken(), p_avatar_url: String(url||"").trim() }); }
export async function betaCancelLobby(id) { return rpc("beta_cancel_lobby_v2",{p_token:getBetaToken(),p_lobby_id:id}); }
export async function betaJoinLobby(id, stake=null, choice=null) {
  const pets=(stake?.type==="pet"?(stake.pets||[]).map(p=>({pet_id:p.pet_id||p.id,variant:p.variant||"normal",quantity:1})):[]);
  return rpc("beta_join_lobby_v2",{p_token:getBetaToken(),p_lobby_id:id,p_pet_items:pets,p_choice:choice||null});
}
export async function betaGetLobbyResult(id) { const { data, error } = await supabase.from("beta_game_lobbies").select("id,game_type,creator_id,creator_username,creator_avatar_url,joiner_id,joiner_username,joiner_avatar_url,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,join_pet_items,choice,join_choice,result_side,winner_id,winner_username,payout,status,created_at").eq("id",id).maybeSingle(); if(error) throw error; return data; }
export async function betaCreateCaseBattle(caseIds) { return rpc("beta_create_case_battle", { p_token:getBetaToken(), p_case_ids:caseIds }); }
export async function betaJoinCaseBattle(id, caseIds = []) { return rpc("beta_join_case_battle", { p_token:getBetaToken(), p_battle_id:id, p_case_ids:Array.isArray(caseIds)?caseIds:[] }); }
export async function betaGetCaseBattle(id) { return rpc("beta_get_case_battle", { p_token:getBetaToken(), p_battle_id:id }); }
export async function betaListCaseBattles() { return (await rpc("beta_list_case_battles", {})) || []; }
export async function betaGetTimeRewards() { return (await rpc("beta_get_time_rewards", { p_token:getBetaToken() })) || []; }
export async function betaClaimTimeReward(stage) { return rpc("beta_claim_time_reward", { p_token:getBetaToken(), p_stage:Number(stage) }); }
export async function betaOpenCaseTicket(caseId) { return rpc("beta_open_case_ticket", { p_token:getBetaToken(), p_case_id:String(caseId) }); }
export async function betaGetTimeTickets() { return (await rpc("beta_get_time_tickets", { p_token:getBetaToken() })) || []; }
export async function betaGetLeaderboard(mode="wagered") { return (await rpc("beta_get_leaderboard", { p_mode:String(mode||"wagered") })) || []; }
export async function betaGetClan() { return (await rpc("beta_get_clan", { p_token:getBetaToken() })) || {clan:null,members:[],invites:[]}; }
export async function betaGetTopClans(limit=50) { return (await rpc("beta_get_top_clans", { p_limit:limit })) || []; }
export async function betaGetPublicClan(clanId) { return (await rpc("beta_get_clan_public", { p_clan_id:String(clanId) })) || null; }
export async function betaCreateClan(name,description,imageUrl) { return rpc("beta_create_clan", { p_token:getBetaToken(), p_name:name, p_description:description||"", p_image_url:imageUrl||null }); }
export async function betaInviteToClan(username) { return rpc("beta_invite_to_clan", { p_token:getBetaToken(), p_username:username }); }
export async function betaRespondClanInvite(inviteId,accept) { return rpc("beta_respond_clan_invite", { p_token:getBetaToken(), p_invite_id:inviteId, p_accept:Boolean(accept) }); }
export async function betaKickClanMember(userId) { return rpc("beta_kick_clan_member", { p_token:getBetaToken(), p_user_id:userId }); }
export async function betaUpgradeClan() { return rpc("beta_upgrade_clan", { p_token:getBetaToken() }); }
export async function betaDepositClan(amount) { return rpc("beta_deposit_clan", { p_token:getBetaToken(), p_amount:Number(amount||0) }); }
export async function betaClaimClanTopReward() { return rpc("beta_claim_clan_top_reward", { p_token:getBetaToken() }); }
export async function betaAdminDeleteClan(clanId) { return rpc("beta_admin_delete_clan", { p_token:getBetaToken(), p_clan_id:String(clanId) }); }
export async function betaGetClanBattleTimer() { return (await rpc("beta_get_clan_battle_timer", {})) || null; }
export async function betaAdminResetClanBattleTimer() { return rpc("beta_admin_reset_clan_battle_timer", { p_token:getBetaToken() }); }
export async function betaAdminResetLeaderboard() { return rpc("beta_admin_reset_leaderboard", { p_token:getBetaToken() }); }
export async function betaSellPet(petId, variant = "normal", quantity = 1) { return rpc("beta_sell_pet", { p_token:getBetaToken(), p_pet_id:petId, p_variant:variant, p_quantity:Number(quantity||1) }); }
export async function betaSellAllPets() { return rpc("beta_sell_all_pets", { p_token:getBetaToken() }); }
export async function betaAdminTriggerChaos(effectType, targetPage="all", rewardAmount=0, message="") { return rpc("beta_admin_trigger_chaos", { p_token:getBetaToken(), p_effect_type:String(effectType), p_target_page:String(targetPage), p_reward_amount:Number(rewardAmount||0), p_message:String(message||"") }); }

export async function betaRunUpgrade(inputPetItems, diamondAmount, targetPetIds, riskAngle=0) {
  return rpc("beta_run_upgrade_v3",{p_token:getBetaToken(),p_input_pet_items:inputPetItems,p_diamond_amount:Number(diamondAmount||0),p_target_pet_ids:targetPetIds,p_risk_angle:Number(riskAngle)||0});
}

export async function betaGetRole() { return (await rpc("beta_get_role", { p_token: getBetaToken() })) || "user"; }
export async function betaAdminGetUsers() { return (await rpc("beta_admin_get_users", { p_token: getBetaToken() })) || []; }
export async function betaAdminSetBalance(username, balance) { return rpc("beta_admin_set_balance", { p_token: getBetaToken(), p_target_username: username, p_balance: Number(balance) }); }
export async function betaAdminGiveAll(username) { return rpc("beta_admin_give_all", { p_token: getBetaToken(), p_target_username: String(username||"").trim() }); }
export async function betaAdminGetInventory(username) { return (await rpc("beta_admin_get_inventory", { p_token: getBetaToken(), p_target_username: String(username||"").trim() })) || []; }
export async function betaAdminClearInventory(username) { return rpc("beta_admin_clear_inventory", { p_token: getBetaToken(), p_target_username: username }); }
export async function betaAdminRemovePet(username, petId, variant="normal", quantity=1) { return rpc("beta_admin_remove_pet", { p_token: getBetaToken(), p_target_username: username, p_pet_id: petId, p_variant: variant, p_quantity: Number(quantity||1) }); }
export async function betaAdminAddPet(username, petId, variant="normal", quantity=1) { return rpc("beta_admin_add_pet", { p_token: getBetaToken(), p_target_username: username, p_pet_id: petId, p_variant: variant, p_quantity: Number(quantity||1) }); }

export async function betaAdminModerate(username, action, minutes, reason="") { return rpc("beta_admin_moderate", { p_token: getBetaToken(), p_target_username: username, p_action: action, p_minutes: Number(minutes||0), p_reason: reason }); }
export async function betaAdminSetRole(username, role) { return rpc("beta_admin_set_role", { p_token: getBetaToken(), p_target_username: username, p_role: role }); }
export async function betaAdminSetEvent(enabled) { return rpc("beta_admin_set_event", { p_token: getBetaToken(), p_enabled: Boolean(enabled) }); }
export async function betaGetActiveEvent() { return (await rpc("beta_get_active_event", { p_token: getBetaToken() })) || null; }
export async function betaJoinEvent(team) { return rpc("beta_join_event", { p_token: getBetaToken(), p_team: team }); }
export async function betaPlayEvent() { return rpc("beta_play_event", { p_token: getBetaToken() }); }
