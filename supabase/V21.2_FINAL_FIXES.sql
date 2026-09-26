-- SpinnyPet V21.2 FINAL FIXES
-- Run after V21_FINAL_FIXES.sql.
-- Fixes: official UUID cases, ambiguous clan upgrade alias, automatic 24h clan reward, no manual claim.

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
notify pgrst,'reload schema';
