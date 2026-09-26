-- SpinnyPet V21.2 FINAL FIXES
-- Run after V21_FINAL_FIXES.sql.
-- Fixes: official UUID cases, ambiguous clan upgrade alias, automatic 24h clan reward, no manual claim.

alter table public.beta_clans add column if not exists treasury_diamonds bigint not null default 0;

-- ============================================================
-- OFFICIAL CASE CATALOG: always restore the 9 supplied cases.
-- ============================================================
insert into public.beta_cases(id,name,tag,description,price,pet_chance,min_pet_value,max_pet_value,diamond_min,diamond_max,image_path,active) values
('1c32cfeb-9f26-427b-8b0d-4d244b5ddcf8','The Pixelverse','PIXELVERSE','A neon case built around the rarest pixel pets.',200000000,1,10000000,5000000000,0,0,'/pixelverse.png',true),
('5b7d4d72-338a-4afd-8884-bd931a866514','Draconic','DRACONIC','Dragon-themed high tier rewards.',75000000,1,5000000,2500000000,0,0,'/draconic1.png',true),
('b2fdbb43-eaf0-4a3d-add3-d4bd84459c8e','Frozen Fury','FROZEN','Cold-blooded rewards with a high-value ceiling.',40000000,1,3000000,1500000000,0,0,'/subzero.png',true),
('6eb40aaf-7b82-425a-a8a0-ef2eb8ee0f9c','Thunder Skies','THUNDER','Lightning-fast rewards from the sky.',25000000,1,2000000,1000000000,0,0,'/zeuscase.png',true),
('85d616cb-83f9-431f-b9e6-8568739819a8','Midnight Howl','MIDNIGHT','A dark premium case with a deep reward pool.',300000000,1,15000000,8000000000,0,0,'/ghostlycase.png',true),
('25803f6f-0558-4c99-b5be-459c5bb52baa','A Starry Night','STARRY','Rare night-sky rewards.',50000000,1,3000000,2000000000,0,0,'/starrycase.png',true),
('cd5cfaaf-bb96-46d1-af2e-9d0f19db731c','Shadow Case','SHADOW','A compact case with a surprisingly deep reward pool.',10000000,1,2000000,200000000,0,0,'/galaxycase.png',true),
('6bbbd6ee-b389-48af-9a90-7eb23540a66e','Scorching Summer','SUMMER','Blaze your way toward a huge reward.',100000000,1,5000000,4000000000,0,0,'/scorchingcase.png',true),
('309d4425-d5e5-43ff-a083-477590662dd5','Gargantuan Vault','GARGANTUAN','The ultimate high-stakes vault.',500000000,1,50000000,20000000000,0,0,'/gargcase.png',true)
on conflict(id) do update set name=excluded.name,tag=excluded.tag,description=excluded.description,price=excluded.price,pet_chance=excluded.pet_chance,min_pet_value=excluded.min_pet_value,max_pet_value=excluded.max_pet_value,diamond_min=excluded.diamond_min,diamond_max=excluded.diamond_max,image_path=excluded.image_path,active=true;

-- ============================================================
-- CASE OPENING: UUID-safe and self-healing if the catalog was missing.
-- ============================================================
create or replace function public.beta_open_case(p_token text,p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; bal bigint; c beta_cases%rowtype; pid text; pname text; pvalue bigint; pthumb text; pcat text;
  low bigint; high bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username,balance into uname,bal from beta_accounts where id=uid for update;
  select bc.* into c from beta_cases bc where bc.id=p_case_id and bc.active=true;
  if c.id is null then raise exception 'Case not found'; end if;
  if bal<c.price then raise exception 'Not enough gems'; end if;
  update beta_accounts set balance=balance-c.price,updated_at=now() where id=uid returning balance into bal;
  low:=greatest(1,c.min_pet_value); high:=greatest(low,c.max_pet_value);
  select p.id,p.name,p.rap,p.thumbnail_url,p.category into pid,pname,pvalue,pthumb,pcat
  from pets_cache p where coalesce(p.rap,0)>0 and p.rap between low and high order by random() limit 1;
  if pid is null then
    select p.id,p.name,p.rap,p.thumbnail_url,p.category into pid,pname,pvalue,pthumb,pcat
    from pets_cache p where coalesce(p.rap,0)>0 order by abs(p.rap-c.price) asc,random() limit 1;
  end if;
  if pid is null then
    update beta_accounts set balance=balance+c.price,updated_at=now() where id=uid;
    raise exception 'No rewards are available for this case yet';
  end if;
  perform beta_inventory_add_safe(uid,pid,'normal',1);
  insert into beta_case_openings(user_id,username,case_id,case_price,reward_type,reward_amount,reward_pet_id,reward_pet_name,reward_pet_value)
  values(uid,uname,c.id,c.price,'pet',0,pid,pname,coalesce(pvalue,0));
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'case_opened',c.price,coalesce(pvalue,0)-c.price,'Opened '||c.name||': '||pname);
  return jsonb_build_object('ok',true,'case_id',c.id,'case_name',c.name,'price',c.price,'reward_type','pet','reward_amount',0,'reward_pet_id',pid,'reward_pet_name',pname,'reward_pet_value',coalesce(pvalue,0),'reward_pet_thumbnail_url',pthumb,'reward_pet_category',pcat,'balance',bal);
end; $$;
grant execute on function public.beta_open_case(text,text) to anon,authenticated;

-- New clans start their automatic 24h reward cycle at creation time.
create or replace function public.beta_create_clan(p_token text,p_name text,p_description text default '',p_image_url text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; clean text:=trim(p_name); cid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  if exists(select 1 from beta_clan_members where user_id=uid) then raise exception 'You are already in a clan'; end if;
  if clean !~ '^[A-Za-z0-9 _-]{3,24}$' then raise exception 'Clan name must be 3-24 characters'; end if;
  if (select balance from beta_accounts where id=uid)<5000000000 then raise exception 'Creating a clan costs 5B diamonds'; end if;
  update beta_accounts set balance=balance-5000000000,updated_at=now() where id=uid;
  insert into beta_clans(name,owner_id,description,image_url,last_top_reward_at) values(clean,uid,trim(coalesce(p_description,'')),nullif(trim(coalesce(p_image_url,'')),''),now()) returning id into cid;
  insert into beta_clan_members(clan_id,user_id,role) values(cid,uid,'leader');
  return public.beta_get_clan(p_token);
exception when unique_violation then raise exception 'That clan name is already taken';
end; $$;
grant execute on function public.beta_create_clan(text,text,text,text) to anon,authenticated;

-- ============================================================
-- CLAN UPGRADE: fix ambiguous c.id reference.
-- ============================================================
create or replace function public.beta_upgrade_clan(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; clan_row beta_clans%rowtype; cost bigint; reward bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select bc.* into clan_row
  from beta_clans bc
  join beta_clan_members bm on bm.clan_id=bc.id
  where bm.user_id=uid and bm.role='leader'
  for update;
  if clan_row.id is null then raise exception 'Leader access required'; end if;
  if clan_row.level>=10 then raise exception 'Clan is already max level'; end if;
  cost:=1000000000*clan_row.level*clan_row.level;
  reward:=1000000000*(clan_row.level+1);
  if (select balance from beta_accounts where id=uid)<cost then raise exception 'You need % diamonds for this upgrade',cost; end if;
  update beta_accounts set balance=balance-cost+reward,updated_at=now() where id=uid;
  update beta_clans bc set level=clan_row.level+1,slots=least(12,clan_row.slots+1) where bc.id=clan_row.id;
  return jsonb_build_object('ok',true,'cost',cost,'reward',reward,'level',clan_row.level+1,'slots',least(12,clan_row.slots+1),'clan_id',clan_row.id);
end; $$;
grant execute on function public.beta_upgrade_clan(text) to anon,authenticated;

-- ============================================================
-- AUTOMATIC TOP-CLAN REWARD: 5B every 24h, paid to the leader.
-- The payout is triggered safely on clan reads / site activity; there is no claim action.
-- ============================================================
create or replace function public.beta_auto_award_clan_top_reward()
returns jsonb language plpgsql security definer set search_path=public as $$
declare top_clan beta_clans%rowtype; reward bigint:=5000000000; ready boolean:=false;
begin
  select bc.* into top_clan
  from beta_clans bc
  order by bc.points desc,bc.created_at asc
  limit 1
  for update;
  if top_clan.id is null then return jsonb_build_object('awarded',false,'reason','no_clans'); end if;
  if top_clan.last_top_reward_at is null then
    update beta_clans set last_top_reward_at=now() where id=top_clan.id;
    return jsonb_build_object('awarded',false,'next_at',now()+interval '24 hours','clan_id',top_clan.id,'initialized',true);
  end if;
  ready:=top_clan.last_top_reward_at<=now()-interval '24 hours';
  if not ready then return jsonb_build_object('awarded',false,'next_at',top_clan.last_top_reward_at+interval '24 hours','clan_id',top_clan.id); end if;
  update beta_accounts set balance=balance+reward,updated_at=now() where id=top_clan.owner_id;
  if not found then return jsonb_build_object('awarded',false,'reason','leader_missing','clan_id',top_clan.id); end if;
  update beta_clans set last_top_reward_at=now() where id=top_clan.id;
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  select a.id,a.username,'clan_top_reward',reward,reward,'Automatic #1 Clan reward (24h)'
  from beta_accounts a where a.id=top_clan.owner_id;
  return jsonb_build_object('awarded',true,'reward',reward,'clan_id',top_clan.id,'owner_id',top_clan.owner_id,'awarded_at',now());
end; $$;
grant execute on function public.beta_auto_award_clan_top_reward() to anon,authenticated;

create or replace function public.beta_get_clan(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; cid uuid; out jsonb; reward_info jsonb; reward_next timestamptz;
begin
  reward_info:=public.beta_auto_award_clan_top_reward();
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then return jsonb_build_object('clan',null,'members','[]'::jsonb,'invites','[]'::jsonb,'reward_info',reward_info); end if;
  select clan_id into cid from beta_clan_members where user_id=uid;
  if cid is null then
    return jsonb_build_object('clan',null,'members','[]'::jsonb,'invites',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'clan_id',i.clan_id,'clan_name',(select c2.name from beta_clans c2 where c2.id=i.clan_id),'created_at',i.created_at) order by i.created_at desc) from beta_clan_invites i where i.invited_user_id=uid and i.status='pending'),'[]'::jsonb),'reward_info',reward_info);
  end if;
  select c.last_top_reward_at+interval '24 hours' into reward_next from beta_clans c where c.id=cid;
  select jsonb_build_object('id',c.id,'name',c.name,'description',c.description,'image_url',c.image_url,'level',c.level,'slots',c.slots,'points',c.points,'owner_id',c.owner_id,'is_leader',c.owner_id=uid,
    'reward_ready',false,'last_top_reward_at',c.last_top_reward_at,'reward_next_at',case when c.last_top_reward_at is null then now() else c.last_top_reward_at+interval '24 hours' end) into out from beta_clans c where c.id=cid;
  return jsonb_build_object('clan',out,
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'username',a.username,'avatar',coalesce(a.custom_avatar_url,a.avatar_url),'role',m.role,'points',m.points) order by m.role desc,m.points desc,a.username) from beta_clan_members m join beta_accounts a on a.id=m.user_id where m.clan_id=cid),'[]'::jsonb),
    'invites',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'clan_id',i.clan_id,'clan_name',(select c2.name from beta_clans c2 where c2.id=i.clan_id),'created_at',i.created_at) order by i.created_at desc) from beta_clan_invites i where i.invited_user_id=uid and i.status='pending'),'[]'::jsonb),'reward_info',reward_info);
end; $$;
grant execute on function public.beta_get_clan(text) to anon,authenticated;

-- Manual claim is intentionally disabled. The top reward is automatic.
create or replace function public.beta_claim_clan_top_reward(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  raise exception 'The Top 1 clan reward is automatic every 24 hours. There is no Claim button.';
end; $$;
grant execute on function public.beta_claim_clan_top_reward(text) to anon,authenticated;

-- Keep PostgREST schema cache current.


-- ============================================================
-- V21.3: automatic progressive Time Rewards (no manual Claim)
-- ============================================================
create or replace function public.beta_time_reward_config()
returns jsonb language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('stage',1,'case_id','cd5cfaaf-bb96-46d1-af2e-9d0f19db731c','minutes',30),
    jsonb_build_object('stage',2,'case_id','6eb40aaf-7b82-425a-a8a0-ef2eb8ee0f9c','minutes',60),
    jsonb_build_object('stage',3,'case_id','b2fdbb43-eaf0-4a3d-add3-d4bd84459c8e','minutes',120),
    jsonb_build_object('stage',4,'case_id','5b7d4d72-338a-4afd-8884-bd931a866514','minutes',240),
    jsonb_build_object('stage',5,'case_id','1c32cfeb-9f26-427b-8b0d-4d244b5ddcf8','minutes',480)
  );
$$;

drop function if exists public.beta_get_time_rewards(text);
create or replace function public.beta_get_time_rewards(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; cfg_row jsonb; out jsonb:='[]'::jsonb; claim_time timestamptz; prior_time timestamptz; unlock_at timestamptz; v_stage integer; v_case_id text; v_minutes integer; granted boolean;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  for cfg_row in select value from jsonb_array_elements(public.beta_time_reward_config()) loop
    v_stage:=(cfg_row->>'stage')::integer; v_case_id:=cfg_row->>'case_id'; v_minutes:=(cfg_row->>'minutes')::integer;
    select tr.claimed_at into claim_time from beta_time_reward_claims tr where tr.user_id=uid and tr.stage=v_stage;
    if v_stage=1 then unlock_at=coalesce(claim_time,now()); else select tr.claimed_at into prior_time from beta_time_reward_claims tr where tr.user_id=uid and tr.stage=v_stage-1; unlock_at=case when prior_time is null then null else prior_time+(v_minutes*interval '1 minute') end; end if;
    if claim_time is null and unlock_at is not null and now()>=unlock_at then
      insert into beta_time_reward_claims(user_id,stage,case_id) values(uid,v_stage,v_case_id) on conflict(user_id,stage) do nothing;
      insert into beta_case_tickets(user_id,case_id,quantity,updated_at) values(uid,v_case_id,1,now()) on conflict(user_id,case_id) do update set quantity=beta_case_tickets.quantity+1,updated_at=now();
      insert into beta_activity(user_id,username,activity_type,amount,description) values(uid,uname,'time_reward',0,'Time Reward unlocked: '||coalesce((select bc.name from beta_cases bc where bc.id=v_case_id),v_case_id));
      select tr.claimed_at into claim_time from beta_time_reward_claims tr where tr.user_id=uid and tr.stage=v_stage;
      granted:=true;
    else granted:=false; end if;
    out:=out||jsonb_build_array(jsonb_build_object('stage',v_stage,'case_id',v_case_id,'minutes',v_minutes,'claimed',claim_time is not null,'unlocked',claim_time is not null,'granted_now',granted,'claimed_at',claim_time,'unlock_at',unlock_at,'available',claim_time is not null,'remaining_seconds',case when claim_time is not null then 0 when unlock_at is null then 0 else greatest(0,ceil(extract(epoch from(unlock_at-now())))::integer) end));
  end loop;
  return out;
end; $$;
grant execute on function public.beta_get_time_rewards(text) to anon,authenticated;

create or replace function public.beta_claim_time_reward(p_token text,p_stage integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; cfg jsonb; case_id text; claim_row beta_time_reward_claims%rowtype; ticket_qty integer;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  if p_stage<1 or p_stage>5 then raise exception 'Invalid Time Reward stage'; end if;
  -- Reading the ladder performs the automatic unlock when the timer has elapsed.
  perform public.beta_get_time_rewards(p_token);
  cfg:=public.beta_time_reward_config()->(p_stage-1);
  case_id:=cfg->>'case_id';
  select * into claim_row from beta_time_reward_claims where user_id=uid and stage=p_stage;
  if claim_row.user_id is null then raise exception 'This Time Reward is not ready yet'; end if;
  select t.quantity into ticket_qty from beta_case_tickets t where t.user_id=uid and t.case_id=case_id;
  if coalesce(ticket_qty,0)<=0 then
    insert into beta_case_tickets(user_id,case_id,quantity,updated_at) values(uid,case_id,1,now())
    on conflict(user_id,case_id) do update set quantity=beta_case_tickets.quantity+1,updated_at=now();
    ticket_qty:=1;
  end if;
  return jsonb_build_object('ok',true,'stage',p_stage,'case_id',case_id,'ticket_quantity',ticket_qty,'claimed_at',claim_row.claimed_at);
end; $$;
grant execute on function public.beta_claim_time_reward(text,integer) to anon,authenticated;

-- Joined giveaway state for the chat and giveaway cards.
drop function if exists public.beta_get_joined_giveaways(text);
create or replace function public.beta_get_joined_giveaways(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(e.giveaway_id) from beta_giveaway_entries e join beta_giveaways g on g.id=e.giveaway_id where e.user_id=uid and g.status='open'),'[]'::jsonb);
end; $$;
grant execute on function public.beta_get_joined_giveaways(text) to anon,authenticated;

-- Stronger case tier routing: every premium case has an explicit Huge/Titanic/Gargantuan pool.
create or replace function public.beta_case_tier_for_open(p_case_id text)
returns text language plpgsql volatile as $$
declare r numeric; has_t boolean; has_g boolean;
begin
  has_t:=p_case_id in ('6eb40aaf-7b82-425a-a8a0-ef2eb8ee0f9c','b2fdbb43-eaf0-4a3d-add3-d4bd84459c8e','25803f6f-0558-4c99-b5be-459c5bb52baa','5b7d4d72-338a-4afd-8884-bd931a866514','6bbbd6ee-b389-48af-9a90-7eb23540a66e','1c32cfeb-9f26-427b-8b0d-4d244b5ddcf8','85d616cb-83f9-431f-b9e6-8568739819a8','309d4425-d5e5-43ff-a083-477590662dd5');
  has_g:=p_case_id in ('6bbbd6ee-b389-48af-9a90-7eb23540a66e','1c32cfeb-9f26-427b-8b0d-4d244b5ddcf8','85d616cb-83f9-431f-b9e6-8568739819a8','309d4425-d5e5-43ff-a083-477590662dd5');
  r:=random();
  if has_g and r<0.02 then return 'gargantuan'; end if;
  if has_t and r<0.16 then return 'titanic'; end if;
  return 'huge';
end; $$;
grant execute on function public.beta_case_tier_for_open(text) to anon,authenticated;

-- Patch case opening to honor the tier route while retaining safe fallback.
drop function if exists public.beta_open_case(text,text);
create or replace function public.beta_open_case(p_token text,p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; bal bigint; c beta_cases%rowtype; pid text; pname text; pvalue bigint; pthumb text; pcat text; tier text;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select username,balance into uname,bal from beta_accounts where id=uid for update;
  select bc.* into c from beta_cases bc where bc.id=p_case_id and bc.active=true; if c.id is null then raise exception 'Case not found'; end if;
  if bal<c.price then raise exception 'Not enough gems'; end if;
  update beta_accounts set balance=balance-c.price,updated_at=now() where id=uid returning balance into bal;
  tier:=public.beta_case_tier_for_open(c.id);
  select p.id,p.name,p.rap,p.thumbnail_url,p.category into pid,pname,pvalue,pthumb,pcat
  from pets_cache p where coalesce(p.rap,0)>0 and ((tier='gargantuan' and (lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %')) or (tier='titanic' and (lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %')) or (tier='huge' and (lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %'))) order by random() limit 1;
  if pid is null then
    select p.id,p.name,p.rap,p.thumbnail_url,p.category into pid,pname,pvalue,pthumb,pcat from pets_cache p where coalesce(p.rap,0)>0 and p.rap between greatest(1,c.min_pet_value) and greatest(c.min_pet_value,c.max_pet_value) order by random() limit 1;
  end if;
  if pid is null then update beta_accounts set balance=balance+c.price,updated_at=now() where id=uid; raise exception 'No % rewards are available for this case yet',tier; end if;
  perform beta_inventory_add_safe(uid,pid,'normal',1);
  insert into beta_case_openings(user_id,username,case_id,case_price,reward_type,reward_amount,reward_pet_id,reward_pet_name,reward_pet_value) values(uid,uname,c.id,c.price,'pet',0,pid,pname,coalesce(pvalue,0));
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description) values(uid,uname,'case_opened',c.price,coalesce(pvalue,0)-c.price,'Opened '||c.name||': '||pname);
  return jsonb_build_object('ok',true,'case_id',c.id,'case_name',c.name,'price',c.price,'reward_type','pet','reward_amount',0,'reward_pet_id',pid,'reward_pet_name',pname,'reward_pet_value',coalesce(pvalue,0),'reward_pet_thumbnail_url',pthumb,'reward_pet_category',pcat,'reward_tier',tier,'balance',bal);
end; $$;
grant execute on function public.beta_open_case(text,text) to anon,authenticated;



-- V21.4.2: public Top Clans leaderboard + clickable public clan profiles.
drop function if exists public.beta_get_top_clans(integer);
create or replace function public.beta_get_top_clans(p_limit integer default 50)
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,'name',c.name,'image_url',c.image_url,'level',c.level,'slots',c.slots,
    'points',c.points,'treasury_diamonds',c.treasury_diamonds,'owner_id',c.owner_id,
    'member_count',(select count(*) from public.beta_clan_members m where m.clan_id=c.id)
    ) order by c.points desc, c.treasury_diamonds desc, c.name), '[]'::jsonb)
  from (select id,name,image_url,level,slots,points,treasury_diamonds,owner_id
        from public.beta_clans
        order by points desc, treasury_diamonds desc, name
        limit greatest(1,least(coalesce(p_limit,50),100))) c;
$$;
grant execute on function public.beta_get_top_clans(integer) to anon,authenticated;

drop function if exists public.beta_get_clan_public(uuid);
create or replace function public.beta_get_clan_public(p_clan_id uuid)
returns jsonb language sql security definer set search_path=public as $$
  select coalesce((
    select jsonb_build_object(
      'clan',jsonb_build_object(
        'id',c.id,'name',c.name,'description',c.description,'image_url',c.image_url,
        'level',c.level,'slots',c.slots,'points',c.points,'treasury_diamonds',c.treasury_diamonds,
        'owner_id',c.owner_id,'member_count',(select count(*) from public.beta_clan_members m where m.clan_id=c.id)
      ),
      'members',coalesce((select jsonb_agg(jsonb_build_object(
        'user_id',m.user_id,'username',a.username,'avatar',coalesce(a.custom_avatar_url,a.avatar_url),
        'role',m.role,'points',m.points
      ) order by m.role desc,m.points desc,a.username) from public.beta_clan_members m join public.beta_accounts a on a.id=m.user_id where m.clan_id=c.id),'[]'::jsonb)
    ) from public.beta_clans c where c.id=p_clan_id
  ),jsonb_build_object('clan',null,'members','[]'::jsonb));
$$;
grant execute on function public.beta_get_clan_public(uuid) to anon,authenticated;

notify pgrst,'reload schema';

-- If Supabase pg_cron is enabled, run the payout worker every 5 minutes so the
-- 24h Top-1 reward does not depend on a user visiting the Clans page.
do $$
begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    begin
      perform cron.unschedule(jobid) from cron.job where jobname='spinnypet-clan-top-reward';
    exception when others then null;
    end;
    perform cron.schedule('spinnypet-clan-top-reward','*/5 * * * *', 'select public.beta_auto_award_clan_top_reward();');
  end if;
end $$;


-- Case Battle reward picker: use the official 9-case IDs instead of the old demo case IDs.
drop function if exists public.beta_case_battle_pick_reward(text);
create or replace function public.beta_case_battle_pick_reward(p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare tier text; rid text; rname text; rvalue bigint; rthumb text; rcat text;
begin
  if not exists(select 1 from beta_cases where id=p_case_id and active=true) then raise exception 'Case not found'; end if;
  tier:=public.beta_case_tier_for_open(p_case_id);
  select p.id,p.name,p.rap,p.thumbnail_url,p.category into rid,rname,rvalue,rthumb,rcat
  from pets_cache p
  where coalesce(p.rap,0)>0 and ((tier='gargantuan' and (lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %')) or (tier='titanic' and (lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %')) or (tier='huge' and (lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %')))
  order by random() limit 1;
  if rid is null then raise exception 'No % rewards are available',tier; end if;
  return jsonb_build_object('pet_id',rid,'pet_name',rname,'pet_value',coalesce(rvalue,0),'pet_thumbnail_url',rthumb,'pet_category',rcat,'tier',tier);
end; $$;
grant execute on function public.beta_case_battle_pick_reward(text) to anon,authenticated;


-- ============================================================
-- V21.4: Clan treasury + persistent giveaway JOINED state
-- ============================================================
-- Giveaway membership is durable while the entry exists; the frontend also caches it for UI continuity.
drop function if exists public.beta_get_joined_giveaways(text);
create or replace function public.beta_get_joined_giveaways(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(e.giveaway_id order by e.created_at desc)
    from beta_giveaway_entries e join beta_giveaways g on g.id=e.giveaway_id
    where e.user_id=uid and g.status in ('open','drawn')),'[]'::jsonb);
end; $$;
grant execute on function public.beta_get_joined_giveaways(text) to anon,authenticated;

-- Deposit is the only clan action that removes diamonds from the personal wallet.
create or replace function public.beta_deposit_clan(p_token text,p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; cid uuid; amount bigint:=greatest(0,coalesce(p_amount,0)); new_balance bigint; new_treasury bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  if amount<=0 then raise exception 'Enter a diamond amount to deposit'; end if;
  select clan_id into cid from beta_clan_members where user_id=uid;
  if cid is null then raise exception 'Join a clan first'; end if;
  if (select balance from beta_accounts where id=uid)<amount then raise exception 'Not enough diamonds'; end if;
  update beta_accounts set balance=balance-amount,updated_at=now() where id=uid returning balance into new_balance;
  update beta_clans set treasury_diamonds=treasury_diamonds+amount where id=cid returning treasury_diamonds into new_treasury;
  insert into beta_activity(user_id,username,activity_type,amount,description)
    select a.id,a.username,'clan_deposit',amount,'Deposited diamonds into clan treasury'
    from beta_accounts a where a.id=uid;
  return jsonb_build_object('ok',true,'amount',amount,'balance',new_balance,'treasury_diamonds',new_treasury,'clan_id',cid);
end; $$;
grant execute on function public.beta_deposit_clan(text,bigint) to anon,authenticated;

-- Upgrades spend only the clan treasury. Personal diamonds are untouched until the player deposits them.
create or replace function public.beta_upgrade_clan(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; clan_row beta_clans%rowtype; cost bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select bc.* into clan_row from beta_clans bc join beta_clan_members bm on bm.clan_id=bc.id
    where bm.user_id=uid and bm.role='leader' for update;
  if clan_row.id is null then raise exception 'Leader access required'; end if;
  if clan_row.level>=10 then raise exception 'Clan is already max level'; end if;
  cost:=1000000000*clan_row.level;
  if clan_row.treasury_diamonds<cost then raise exception 'Deposit % diamonds into the clan treasury first',cost; end if;
  update beta_clans set treasury_diamonds=treasury_diamonds-cost,level=level+1,slots=least(12,slots+1) where id=clan_row.id;
  return jsonb_build_object('ok',true,'cost',cost,'level',clan_row.level+1,'slots',least(12,clan_row.slots+1),'treasury_diamonds',clan_row.treasury_diamonds-cost,'clan_id',clan_row.id);
end; $$;
grant execute on function public.beta_upgrade_clan(text) to anon,authenticated;

-- Clan reads expose the treasury so My Clan and Top Clans can show deposited diamonds.
create or replace function public.beta_get_clan(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; cid uuid; out jsonb; reward_info jsonb;
begin
  reward_info:=public.beta_auto_award_clan_top_reward();
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then return jsonb_build_object('clan',null,'members','[]'::jsonb,'invites','[]'::jsonb,'reward_info',reward_info); end if;
  select clan_id into cid from beta_clan_members where user_id=uid;
  if cid is null then
    return jsonb_build_object('clan',null,'members','[]'::jsonb,
      'invites',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'clan_id',i.clan_id,'clan_name',(select c2.name from beta_clans c2 where c2.id=i.clan_id),'created_at',i.created_at) order by i.created_at desc) from beta_clan_invites i where i.invited_user_id=uid and i.status='pending'),'[]'::jsonb),
      'reward_info',reward_info);
  end if;
  select jsonb_build_object('id',c.id,'name',c.name,'description',c.description,'image_url',c.image_url,'level',c.level,'slots',c.slots,'points',c.points,'treasury_diamonds',c.treasury_diamonds,'owner_id',c.owner_id,'is_leader',c.owner_id=uid,
    'reward_ready',false,'last_top_reward_at',c.last_top_reward_at,'reward_next_at',case when c.last_top_reward_at is null then now() else c.last_top_reward_at+interval '24 hours' end) into out
    from beta_clans c where c.id=cid;
  return jsonb_build_object('clan',out,
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'username',a.username,'avatar',coalesce(a.custom_avatar_url,a.avatar_url),'role',m.role,'points',m.points) order by m.role desc,m.points desc,a.username) from beta_clan_members m join beta_accounts a on a.id=m.user_id where m.clan_id=cid),'[]'::jsonb),
    'invites',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'clan_id',i.clan_id,'clan_name',(select c2.name from beta_clans c2 where c2.id=i.clan_id),'created_at',i.created_at) order by i.created_at desc) from beta_clan_invites i where i.invited_user_id=uid and i.status='pending'),'[]'::jsonb),
    'reward_info',reward_info);
end; $$;
grant execute on function public.beta_get_clan(text) to anon,authenticated;


-- ============================================================
-- V21.5 FINAL: Top Clans profile + reward cards + Time Ticket opening
-- ============================================================

-- Top Clans must expose member_count and never depend on client RLS.
drop function if exists public.beta_get_top_clans(integer);
create or replace function public.beta_get_top_clans(p_limit integer default 50)
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',c.id,
    'name',c.name,
    'image_url',c.image_url,
    'level',c.level,
    'slots',c.slots,
    'points',c.points,
    'treasury_diamonds',c.treasury_diamonds,
    'owner_id',c.owner_id,
    'member_count',coalesce((select count(*) from public.beta_clan_members m where m.clan_id=c.id),0)
  ) order by c.points desc,c.treasury_diamonds desc,c.name), '[]'::jsonb)
  from (
    select bc.id,bc.name,bc.image_url,bc.level,bc.slots,bc.points,bc.treasury_diamonds,bc.owner_id
    from public.beta_clans bc
    order by bc.points desc,bc.treasury_diamonds desc,bc.name
    limit greatest(1,least(coalesce(p_limit,50),100))
  ) c;
$$;
grant execute on function public.beta_get_top_clans(integer) to anon,authenticated;

-- Public clan profile: clicking any Top Clan always returns its members and stats.
drop function if exists public.beta_get_clan_public(uuid);
create or replace function public.beta_get_clan_public(p_clan_id uuid)
returns jsonb language sql security definer set search_path=public as $$
  select coalesce((
    select jsonb_build_object(
      'clan',jsonb_build_object(
        'id',c.id,
        'name',c.name,
        'description',coalesce(c.description,''),
        'image_url',c.image_url,
        'level',c.level,
        'slots',c.slots,
        'points',c.points,
        'treasury_diamonds',c.treasury_diamonds,
        'owner_id',c.owner_id,
        'member_count',coalesce((select count(*) from public.beta_clan_members m0 where m0.clan_id=c.id),0)
      ),
      'members',coalesce((
        select jsonb_agg(jsonb_build_object(
          'user_id',m.user_id,
          'username',a.username,
          'avatar',coalesce(a.custom_avatar_url,a.avatar_url),
          'role',m.role,
          'points',coalesce(m.points,0)
        ) order by case when m.role='leader' then 0 else 1 end,coalesce(m.points,0) desc,a.username)
        from public.beta_clan_members m
        join public.beta_accounts a on a.id=m.user_id
        where m.clan_id=c.id
      ),'[]'::jsonb)
    )
    from public.beta_clans c
    where c.id=p_clan_id
  ),jsonb_build_object('clan',null,'members','[]'::jsonb));
$$;
grant execute on function public.beta_get_clan_public(uuid) to anon,authenticated;

-- Official Time Reward ticket opener. It consumes one ticket and uses the same
-- official tier reward router as Case Battle / Cases.
drop function if exists public.beta_open_case_ticket(text,text);
create or replace function public.beta_open_case_ticket(p_token text,p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid;
  uname text;
  q integer;
  reward jsonb;
  bal bigint;
  cid text:=trim(coalesce(p_case_id,''));
  cname text;
begin
  select user_id into uid from public.beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  if not exists(select 1 from public.beta_cases c where c.id=cid and c.active=true) then raise exception 'Case not found'; end if;

  select quantity into q
  from public.beta_case_tickets
  where user_id=uid and case_id=cid
  for update;
  if coalesce(q,0)<1 then raise exception 'You do not own a free case ticket for this case'; end if;

  reward:=public.beta_case_battle_pick_reward(cid);
  select username into uname from public.beta_accounts where id=uid;
  select name into cname from public.beta_cases where id=cid;

  if q=1 then
    delete from public.beta_case_tickets where user_id=uid and case_id=cid;
  else
    update public.beta_case_tickets set quantity=q-1,updated_at=now() where user_id=uid and case_id=cid;
  end if;

  perform public.beta_inventory_add_safe(uid,reward->>'pet_id','normal',1);
  select balance into bal from public.beta_accounts where id=uid;

  insert into public.beta_case_openings(user_id,username,case_id,case_price,reward_type,reward_amount,reward_pet_id,reward_pet_name,reward_pet_value)
  values(uid,uname,cid,0,'pet',0,reward->>'pet_id',reward->>'pet_name',coalesce((reward->>'pet_value')::bigint,0));
  insert into public.beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'time_case_opened',0,coalesce((reward->>'pet_value')::bigint,0),'Opened free '||coalesce(cname,cid)||': '||(reward->>'pet_name'));

  return jsonb_build_object(
    'ok',true,
    'case_id',cid,
    'case_name',cname,
    'reward_type','pet',
    'reward_pet_id',reward->>'pet_id',
    'reward_pet_name',reward->>'pet_name',
    'reward_pet_value',coalesce((reward->>'pet_value')::bigint,0),
    'reward_pet_thumbnail_url',reward->>'pet_thumbnail_url',
    'reward_pet_category',reward->>'pet_category',
    'balance',bal,
    'ticket_remaining',case when q>1 then q-1 else 0 end
  );
end; $$;
grant execute on function public.beta_open_case_ticket(text,text) to anon,authenticated;

-- Finished lobby rows are never returned as open matches. The UI also clears
-- the creator's local live card after settlement.
drop function if exists public.beta_cleanup_finished_matches();
create or replace function public.beta_cleanup_finished_matches()
returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object(
    'finished_lobbies',coalesce((select count(*) from public.beta_game_lobbies where status='finished' and created_at<now()-interval '10 minutes'),0),
    'finished_case_battles',coalesce((select count(*) from public.beta_case_battles where status='finished' and finished_at<now()-interval '10 minutes'),0)
  );
$$;
grant execute on function public.beta_cleanup_finished_matches() to anon,authenticated;

notify pgrst,'reload schema';

-- Color Dice / Coinflip create RPC: keep the current frontend signature stable
-- and validate/charge the creator exactly once.
create or replace function public.beta_create_lobby_v2(
  p_token text,p_game_type text,p_stake_type text,p_stake_amount bigint,
  p_pet_items jsonb default '[]'::jsonb,p_choice text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; avatar text; lid uuid; item jsonb;
  pid text; v text; qty integer; total bigint:=0; count_items integer:=0;
  first_id text; first_pet_name text; first_variant text; pv bigint; pcat text;
  choice text:=trim(coalesce(p_choice,'')); min_stake bigint;
begin
  select user_id into uid from public.beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username,coalesce(custom_avatar_url,avatar_url) into uname,avatar from public.beta_accounts where id=uid;
  if p_game_type not in ('coinflip','dice') then raise exception 'Unsupported match game'; end if;
  if p_stake_type not in ('diamonds','pet') then raise exception 'Invalid stake type'; end if;

  if p_game_type='coinflip' then
    if choice not in ('Heads','Tails') then raise exception 'Choose Heads or Tails'; end if;
  else
    if array_length(string_to_array(choice,','),1)<>2 then raise exception 'Choose exactly 2 colors'; end if;
    if choice !~ '^(Red|Orange|Yellow|Green|Blue|Purple),(Red|Orange|Yellow|Green|Blue|Purple)$' then raise exception 'Invalid dice colors'; end if;
    if split_part(choice,',',1)=split_part(choice,',',2) then raise exception 'Choose two different colors'; end if;
  end if;

  min_stake:=case when p_game_type='coinflip' then 10000000 else 5000000000 end;

  if p_stake_type='diamonds' then
    if coalesce(p_stake_amount,0)<min_stake then
      raise exception using message=case when p_game_type='coinflip' then 'Coinflip requires at least 10M gems' else 'Color Dice requires at least 5B gems' end;
    end if;
    if p_stake_amount>(select balance from public.beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
    update public.beta_accounts set balance=balance-p_stake_amount,updated_at=now() where id=uid;
    insert into public.beta_game_lobbies(game_type,creator_id,creator_username,creator_avatar_url,stake_type,stake_amount,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,avatar,'diamonds',p_stake_amount,0,'[]'::jsonb,choice) returning id into lid;
  else
    if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select at least one pet'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
      if not exists(select 1 from public.beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
      select coalesce(rap,0),name,category into pv,first_pet_name,pcat from public.pets_cache where id=pid;
      if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
      if p_game_type='coinflip' then
        if lower(coalesce(pcat,'')) not in ('titanic','gargantuan') and lower(coalesce(first_pet_name,'')) !~ '^(titanic|gargantuan) ' then raise exception 'Coinflip accepts only Titanic and Gargantuan pets'; end if;
      else
        if lower(coalesce(pcat,'')) not in ('huge','titanic','gargantuan') and lower(coalesce(first_pet_name,'')) !~ '^(huge|titanic|gargantuan) ' then raise exception 'Color Dice accepts Huge, Titanic or Gargantuan pets'; end if;
      end if;
      total:=total+pv*qty; count_items:=count_items+qty;
      if first_id is null then first_id:=pid; first_pet_name:=coalesce(first_pet_name,'Pet'); first_variant:=v; end if;
    end loop;
    if total<min_stake then raise exception using message=case when p_game_type='coinflip' then 'Coinflip requires at least 10M value' else 'Color Dice pet wagers require at least 5B value' end; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      update public.beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      delete from public.beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
    end loop;
    insert into public.beta_game_lobbies(game_type,creator_id,creator_username,creator_avatar_url,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,avatar,'pet',total,first_id,first_pet_name,first_variant,count_items,p_pet_items,choice) returning id into lid;
  end if;

  insert into public.beta_activity(user_id,username,activity_type,game_type,amount,description)
  values(uid,uname,'game_created',p_game_type,case when p_stake_type='pet' then total else p_stake_amount end,'Created a '||p_game_type||' game');
  return jsonb_build_object('ok',true,'id',lid,'status','open','stake_amount',case when p_stake_type='pet' then total else p_stake_amount end,'pet_count',count_items,'choice',choice);
end; $$;
grant execute on function public.beta_create_lobby_v2(text,text,text,bigint,jsonb,text) to anon,authenticated;

notify pgrst,'reload schema';
