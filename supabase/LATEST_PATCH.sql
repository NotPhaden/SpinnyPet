-- SpinnyPet latest database patch: variant-safe matches, PS99 RAP-only economy, giveaway ownership, admin inventory tools, cases, claims and upgrader fixes.
-- ==================== SPINNYPET V9 ====================
-- Source of pet price data: BIG Games PS99 RAP only. Cosmic Values are ignored.

alter table public.beta_game_lobbies add column if not exists pet_variant text not null default 'normal';

create or replace function public.beta_create_lobby(
  p_token text,p_game_type text,p_stake_type text,p_stake_amount bigint,p_pet_id text,p_pet_name text,p_pet_variant text,p_choice text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; lid uuid; v text:=coalesce(nullif(trim(p_pet_variant),''),'normal');
begin
  select s.user_id,a.username into uid,uname from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  if p_game_type not in ('coinflip','dice','jackpot','blackjack') then raise exception 'Invalid game'; end if;
  if p_stake_type not in ('diamonds','pet') then raise exception 'Invalid stake type'; end if;
  if v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet variant'; end if;
  if p_stake_type='diamonds' then
    if p_stake_amount<=0 or p_stake_amount>(select balance from beta_accounts where id=uid) then raise exception 'Invalid diamond stake'; end if;
    update beta_accounts set balance=balance-p_stake_amount,updated_at=now() where id=uid;
  else
    if p_pet_id is null then raise exception 'Select a pet'; end if;
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=p_pet_id and variant=v and quantity>0) then raise exception 'You do not own that pet variant'; end if;
    delete from beta_inventory where user_id=uid and pet_id=p_pet_id and variant=v and quantity=1;
    update beta_inventory set quantity=quantity-1,updated_at=now() where user_id=uid and pet_id=p_pet_id and variant=v and quantity>1;
  end if;
  insert into beta_game_lobbies(game_type,creator_id,creator_username,stake_type,stake_amount,pet_id,pet_name,pet_variant,choice)
  values(p_game_type,uid,uname,p_stake_type,coalesce(p_stake_amount,0),p_pet_id,p_pet_name,v,p_choice) returning id into lid;
  return jsonb_build_object('ok',true,'id',lid,'status','open');
end; $$;
grant execute on function public.beta_create_lobby(text,text,text,bigint,text,text,text,text) to anon,authenticated;

create or replace function public.beta_join_lobby(p_token text,p_lobby_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; lid uuid; gtype text; st text; amt bigint; pid text; pvar text;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select id,game_type,stake_type,stake_amount,pet_id,coalesce(pet_variant,'normal') into lid,gtype,st,amt,pid,pvar from beta_game_lobbies where id=p_lobby_id and status='open' and creator_id<>uid for update;
  if lid is null then raise exception 'Match is no longer available'; end if;
  select username into uname from beta_accounts where id=uid;
  if st='diamonds' then
    if amt<=0 or amt>(select balance from beta_accounts where id=uid) then raise exception 'You do not have enough gems to join'; end if;
    update beta_accounts set balance=balance-amt,updated_at=now() where id=uid;
  else
    if pid is null or not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=pvar and quantity>0) then raise exception 'You do not own the required pet variant'; end if;
    delete from beta_inventory where user_id=uid and pet_id=pid and variant=pvar and quantity=1;
    update beta_inventory set quantity=quantity-1,updated_at=now() where user_id=uid and pet_id=pid and variant=pvar and quantity>1;
  end if;
  update beta_game_lobbies set status='joined' where id=lid;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,description) values(uid,uname,'game_joined',gtype,amt,'Joined a '||gtype||' match');
  return jsonb_build_object('ok',true,'lobby_id',lid,'status','joined');
end; $$;
grant execute on function public.beta_join_lobby(text,uuid) to anon,authenticated;

create or replace function public.beta_cancel_lobby(p_token text,p_lobby_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; lid uuid; st text; amt bigint; pid text; pvar text;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select id,stake_type,stake_amount,pet_id,coalesce(pet_variant,'normal') into lid,st,amt,pid,pvar from beta_game_lobbies where id=p_lobby_id and creator_id=uid and status='open' for update;
  if lid is null then raise exception 'Lobby is not open or not yours'; end if;
  if st='diamonds' then update beta_accounts set balance=balance+amt,updated_at=now() where id=uid;
  else insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,pid,pvar,1) on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now(); end if;
  update beta_game_lobbies set status='cancelled' where id=lid;
  return jsonb_build_object('ok',true,'balance',(select balance from beta_accounts where id=uid));
end; $$;
grant execute on function public.beta_cancel_lobby(text,uuid) to anon,authenticated;

-- Upgrade uses official PS99 RAP only. Zero-RAP pets stay selectable in the UI, but cannot make a positive-value chance.
create or replace function public.beta_run_upgrade(p_token text,p_input_pet_ids jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0)); input_value bigint:=0; target_value bigint:=0; chance numeric; won boolean; result_id text; result_name text; a beta_accounts%rowtype; pid text; chosen_value bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_input_pet_ids,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection'; end if;
  if jsonb_array_length(coalesce(p_input_pet_ids,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems'; end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target'; end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
  for pid in select value from jsonb_array_elements_text(coalesce(p_input_pet_ids,'[]'::jsonb)) loop
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant='normal' and quantity>0) then raise exception 'One selected pet is no longer in your inventory'; end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;
    if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
    input_value:=input_value+chosen_value;
    update beta_inventory set quantity=quantity-1,updated_at=now() where user_id=uid and pet_id=pid and variant='normal';
    delete from beta_inventory where user_id=uid and pet_id=pid and variant='normal' and quantity<=0;
  end loop;
  input_value:=input_value+diamond_amount;
  if diamond_amount>0 then update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid; end if;
  select coalesce(sum(coalesce(rap,0)),0) into target_value from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids));
  if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.'; end if;
  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));
  won:=random()<=chance/100;
  if won then
    select id,name into result_id,result_name from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0 order by random() limit 1;
    insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,result_id,'normal',1) on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  end if;
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description) values(uid,uname,'upgrade_result',input_value,case when won then greatest(0,target_value-input_value) else -input_value end,case when won then 'Won an upgrade: '||coalesce(result_name,'target') else 'Lost an upgrade' end);
  select * into a from beta_accounts where id=uid;
  return jsonb_build_object('won',won,'chance',chance,'input_value',input_value,'target_value',target_value,'result_id',result_id,'result_name',result_name,'balance',a.balance);
end; $$;
grant execute on function public.beta_run_upgrade(text,jsonb,bigint,jsonb) to anon,authenticated;

-- Cases: single-open function now uses RAP; multi-open endpoint is atomic.
create or replace function public.beta_open_case(p_token text,p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; bal bigint; c beta_cases%rowtype;
  pid text; pname text; pvalue bigint; pthumb text; pcat text;
  reward bigint:=0; reward_value bigint:=0; rtype text:='pet';
  tier text; slot integer; pool_size integer;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username,balance into uname,bal from beta_accounts where id=uid for update;
  select * into c from beta_cases where id=p_case_id and active=true;
  if c.id is null then raise exception 'Case not found'; end if;
  if bal<c.price then raise exception 'Not enough gems for this case'; end if;

  update beta_accounts set balance=balance-c.price,updated_at=now() where id=uid returning balance into bal;

  -- Every case has a fixed visible reward pool. The same pool is used by the
  -- real opening, so the opening cannot award a tier that is not shown on the case page.
  if c.id='basic' then
    pool_size:=5; slot:=floor(random()*pool_size)::integer+1;
    tier:=case when slot=1 then 'titanic' else 'huge' end;
  elsif c.id='lucky' then
    pool_size:=5; slot:=floor(random()*pool_size)::integer+1;
    tier:=case when slot<=2 then 'titanic' else 'huge' end;
  elsif c.id='titan' then
    pool_size:=5; tier:='titanic';
  elsif c.id='cosmic' then
    pool_size:=6; slot:=floor(random()*pool_size)::integer+1;
    tier:=case when slot<=3 then 'titanic' when slot=4 then 'gargantuan' else 'huge' end;
  elsif c.id='omega' then
    pool_size:=9; slot:=floor(random()*pool_size)::integer+1;
    tier:=case when slot<=3 then 'titanic' when slot<=5 then 'gargantuan' else 'huge' end;
  else
    raise exception 'Unsupported case';
  end if;

  select p.id,p.name,p.cosmic_value,p.thumbnail_url,p.category
    into pid,pname,pvalue,pthumb,pcat
  from pets_cache p
  where p.cosmic_value>0
    and (lower(p.category)=tier or lower(p.name) like tier||' %')
  order by p.cosmic_value desc, p.id
  offset floor(random()*greatest(1,(select count(*) from pets_cache q where q.cosmic_value>0 and (lower(q.category)=tier or lower(q.name) like tier||' %'))))::integer
  limit 1;

  if pid is null then
    update beta_accounts set balance=balance+c.price,updated_at=now() where id=uid;
    raise exception 'No % rewards are available for this case yet', tier;
  end if;

  reward_value:=coalesce(pvalue,0);
  insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,pid,'normal',1)
  on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();

  insert into beta_case_openings(user_id,username,case_id,case_price,reward_type,reward_amount,reward_pet_id,reward_pet_name,reward_pet_value)
  values(uid,uname,c.id,c.price,rtype,0,pid,pname,reward_value);
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'case_opened',c.price,reward_value-c.price,'Opened '||c.name||': '||coalesce(pname,'pet'));

  return jsonb_build_object('ok',true,'case_id',c.id,'case_name',c.name,'price',c.price,'reward_type',rtype,'reward_amount',0,'reward_pet_id',pid,'reward_pet_name',pname,'reward_pet_value',reward_value,'reward_pet_thumbnail_url',pthumb,'reward_pet_category',pcat,'balance',bal);
end; $$;
grant execute on function public.beta_open_case(text,text) to anon,authenticated;

-- Give All no longer depends on any third-party value source.
create or replace function public.beta_admin_give_all(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; n integer;
begin
  adminid:=beta_admin_assert(p_token);
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  insert into beta_inventory(user_id,pet_id,variant,quantity)
  select tid,p.id,'normal',1 from pets_cache p where lower(p.category) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %'
  on conflict(user_id,pet_id,variant) do update set quantity=greatest(beta_inventory.quantity,1),updated_at=now();
  select count(*) into n from pets_cache p where lower(p.category) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %';
  return jsonb_build_object('ok',true,'count',n);
end; $$;
grant execute on function public.beta_admin_give_all(text,text) to anon,authenticated;

create or replace function public.beta_admin_get_inventory(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid;
begin
  adminid:=beta_admin_assert(p_token);
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'pet_id',i.pet_id,'name',p.name,'variant',i.variant,'quantity',i.quantity,'rap',p.rap,'thumbnail_asset',p.thumbnail_asset,'thumbnail_url',p.thumbnail_url,'golden_thumbnail_asset',p.golden_thumbnail_asset,'golden_thumbnail_url',p.golden_thumbnail_url) order by p.name) from beta_inventory i join pets_cache p on p.id=i.pet_id where i.user_id=tid),'[]'::jsonb);
end; $$;
grant execute on function public.beta_admin_get_inventory(text,text) to anon,authenticated;

create or replace function public.beta_admin_clear_inventory(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; n integer;
begin
  adminid:=beta_admin_assert(p_token); select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  select count(*) into n from beta_inventory where user_id=tid; delete from beta_inventory where user_id=tid; return jsonb_build_object('ok',true,'removed_rows',n);
end; $$;
grant execute on function public.beta_admin_clear_inventory(text,text) to anon,authenticated;

create or replace function public.beta_admin_remove_pet(p_token text,p_target_username text,p_pet_id text,p_variant text,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; q integer; take integer:=greatest(1,coalesce(p_quantity,1));
begin
  adminid:=beta_admin_assert(p_token); select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  select quantity into q from beta_inventory where user_id=tid and pet_id=p_pet_id and variant=coalesce(p_variant,'normal'); if q is null then raise exception 'Pet is not in inventory'; end if;
  if q<=take then delete from beta_inventory where user_id=tid and pet_id=p_pet_id and variant=coalesce(p_variant,'normal'); else update beta_inventory set quantity=quantity-take,updated_at=now() where user_id=tid and pet_id=p_pet_id and variant=coalesce(p_variant,'normal'); end if;
  return jsonb_build_object('ok',true);
end; $$;
grant execute on function public.beta_admin_remove_pet(text,text,text,text,integer) to anon,authenticated;

create or replace function public.beta_admin_add_pet(p_token text,p_target_username text,p_pet_id text,p_variant text,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; take integer:=greatest(1,coalesce(p_quantity,1));
begin
  adminid:=beta_admin_assert(p_token); select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  if p_variant not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet variant'; end if;
  if not exists(select 1 from pets_cache where id=p_pet_id and (lower(category) in ('huge','titanic','gargantuan') or lower(name) like 'huge %' or lower(name) like 'titanic %' or lower(name) like 'gargantuan %')) then raise exception 'Pet is not in high-tier catalog'; end if;
  insert into beta_inventory(user_id,pet_id,variant,quantity) values(tid,p_pet_id,p_variant,take) on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+take,updated_at=now();
  return jsonb_build_object('ok',true,'quantity',take);
end; $$;
grant execute on function public.beta_admin_add_pet(text,text,text,text,integer) to anon,authenticated;

-- Giveaway host may never enter their own giveaway.
create or replace function public.beta_enter_giveaway(p_token text,p_giveaway_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; cnt integer; host uuid;
begin
  select s.user_id,a.username into uid,uname from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select host_id into host from beta_giveaways where id=p_giveaway_id and status='open' and ends_at>now(); if host is null then raise exception 'Giveaway is closed'; end if;
  if host=uid then raise exception 'You cannot join your own giveaway'; end if;
  select entries_count into cnt from beta_giveaways where id=p_giveaway_id; if cnt >= (select max_entries from beta_giveaways where id=p_giveaway_id) then raise exception 'Giveaway is full'; end if;
  insert into beta_giveaway_entries(giveaway_id,user_id,username) values(p_giveaway_id,uid,uname) on conflict do nothing;
  update beta_giveaways set entries_count=(select count(*) from beta_giveaway_entries where giveaway_id=p_giveaway_id) where id=p_giveaway_id;
  return jsonb_build_object('ok',true,'entered',true);
end; $$;
grant execute on function public.beta_enter_giveaway(text,uuid) to anon,authenticated;

-- Inventory/game APIs should expose the stored variant.
drop function if exists public.beta_get_inventory(text);
create or replace function public.beta_get_inventory(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'pet_id',i.pet_id,'name',p.name,'variant',i.variant,'quantity',i.quantity,'rap',p.rap,'cosmic_value',0,'thumbnail_asset',p.thumbnail_asset,'thumbnail_url',p.thumbnail_url,'golden_thumbnail_asset',p.golden_thumbnail_asset,'golden_thumbnail_url',p.golden_thumbnail_url) order by p.name) from beta_inventory i join pets_cache p on p.id=i.pet_id where i.user_id=uid and i.quantity>0),'[]'::jsonb);
end; $$;
grant execute on function public.beta_get_inventory(text) to anon,authenticated;

-- ==================== SPINNYPET V10 ====================
-- Remove all runtime dependence on third-party Cosmic Values. The app uses official PS99 RAP.

create or replace function public.beta_claim_bonus(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; a beta_accounts%rowtype; tid text; tname text; tvalue bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select * into a from beta_accounts where id=uid for update;
  if a.bonus_claimed then
    return jsonb_build_object('user_id',a.id,'username',a.username,'balance',a.balance,'claimed',true);
  end if;
  select id,name,coalesce(rap,0) into tid,tname,tvalue
  from pets_cache
  where lower(category)='titanic' or lower(name) like 'titanic %'
  order by random() limit 1;
  if tid is null then raise exception 'High-tier catalog is empty. Open the site once or run npm run sync:ps99.'; end if;
  update beta_accounts set balance=balance+50000000000,bonus_claimed=true,updated_at=now() where id=uid returning * into a;
  insert into beta_inventory(user_id,pet_id,variant,quantity)
  values(uid,tid,'normal',1)
  on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  insert into beta_activity(user_id,username,activity_type,amount,description)
  values(uid,a.username,'bonus_claimed',50000000000,'Claimed 50B + random Titanic: '||tname);
  return jsonb_build_object('user_id',a.id,'username',a.username,'balance',a.balance,'claimed',true,'pet_id',tid,'pet_name',tname,'pet_value',coalesce(tvalue,0));
end; $$;
grant execute on function public.beta_claim_bonus(text) to anon,authenticated;

create or replace function public.beta_claim_daily_case(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; today date:=current_date; reward bigint; tid text; tname text; tvalue bigint; bal bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if exists(select 1 from beta_daily_claims where user_id=uid and claim_date=today) then raise exception 'Daily case already claimed today'; end if;
  select id,name,coalesce(rap,0) into tid,tname,tvalue
  from pets_cache
  where lower(category)='titanic' or lower(name) like 'titanic %'
  order by random() limit 1;
  if tid is null then raise exception 'High-tier catalog is empty. Open the site once or run npm run sync:ps99.'; end if;
  reward:=500000000+floor(random()*29500000001)::bigint;
  update beta_accounts set balance=balance+reward,updated_at=now() where id=uid returning balance into bal;
  insert into beta_daily_claims(user_id,claim_date,reward) values(uid,today,reward);
  insert into beta_inventory(user_id,pet_id,variant,quantity)
  values(uid,tid,'normal',1)
  on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  insert into beta_activity(user_id,username,activity_type,amount,description)
  values(uid,uname,'daily_case',reward,'Daily Case: '||tname);
  return jsonb_build_object('balance',bal,'reward',reward,'pet_id',tid,'pet_name',tname,'pet_value',coalesce(tvalue,0));
end; $$;
grant execute on function public.beta_claim_daily_case(text) to anon,authenticated;

create or replace function public.beta_get_stats(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; a beta_accounts%rowtype; wagered bigint; pnl bigint; games bigint; wins bigint; losses bigint; pet_total bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select * into a from beta_accounts where id=uid;
  select coalesce(sum(amount),0),coalesce(sum(profit_loss),0),
         count(*) filter(where activity_type in ('game_created','game_joined','game_result')),
         count(*) filter(where profit_loss>0),count(*) filter(where profit_loss<0)
    into wagered,pnl,games,wins,losses
  from beta_activity where user_id=uid;
  select coalesce(sum(i.quantity*greatest(coalesce(p.rap,0),0)),0)
    into pet_total
  from beta_inventory i join pets_cache p on p.id=i.pet_id where i.user_id=uid;
  return jsonb_build_object(
    'balance',a.balance,
    'pet_value',pet_total,
    'total_value',a.balance+pet_total,
    'wagered',wagered,
    'profit_loss',pnl,
    'games_played',games,
    'games_won',wins,
    'games_lost',losses,
    'username',a.username,
    'roblox_user_id',a.roblox_user_id,
    'roblox_username',a.roblox_username,
    'avatar_url',a.avatar_url,
    'custom_avatar_url',a.custom_avatar_url
  );
end; $$;
grant execute on function public.beta_get_stats(text) to anon,authenticated;

-- Give All grants exactly one of every high-tier catalog pet; repeating the action is idempotent.
create or replace function public.beta_admin_give_all(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; n integer;
begin
  adminid:=beta_admin_assert(p_token);
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username));
  if tid is null then raise exception 'User not found'; end if;
  select count(*) into n from pets_cache p
  where lower(p.category) in ('huge','titanic','gargantuan')
     or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %';
  if n=0 then raise exception 'High-tier catalog is empty. Run npm run sync:ps99 first.'; end if;
  insert into beta_inventory(user_id,pet_id,variant,quantity)
  select tid,p.id,'normal',1
  from pets_cache p
  where lower(p.category) in ('huge','titanic','gargantuan')
     or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %'
  on conflict(user_id,pet_id,variant) do update set quantity=greatest(beta_inventory.quantity,1),updated_at=now();
  return jsonb_build_object('ok',true,'count',n);
end; $$;
grant execute on function public.beta_admin_give_all(text,text) to anon,authenticated;

-- ==================== SPINNYPET V11 ====================
-- Upgrader consumes exact inventory variants. Backward compatible with old string-only payloads.
create or replace function public.beta_run_upgrade(p_token text,p_input_pet_ids jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0)); input_value bigint:=0; target_value bigint:=0; chance numeric; won boolean; result_id text; result_name text; a beta_accounts%rowtype; item jsonb; pid text; pvar text; chosen_value bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_input_pet_ids,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection'; end if;
  if jsonb_array_length(coalesce(p_input_pet_ids,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems'; end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target'; end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;

  for item in select value from jsonb_array_elements(coalesce(p_input_pet_ids,'[]'::jsonb)) loop
    if jsonb_typeof(item)='object' then
      pid:=nullif(trim(item->>'id'),''); pvar:=coalesce(nullif(trim(item->>'variant'),''),'normal');
    else
      pid:=nullif(trim(item #>> '{}'),''); pvar:='normal';
    end if;
    if pid is null then raise exception 'Invalid selected pet'; end if;
    if pvar not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet variant'; end if;
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=pvar and quantity>0) then raise exception 'One selected pet is no longer in your inventory'; end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;
    if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
    input_value:=input_value+chosen_value;
    update beta_inventory set quantity=quantity-1,updated_at=now() where user_id=uid and pet_id=pid and variant=pvar;
    delete from beta_inventory where user_id=uid and pet_id=pid and variant=pvar and quantity<=0;
  end loop;

  input_value:=input_value+diamond_amount;
  if diamond_amount>0 then update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid; end if;
  select coalesce(sum(coalesce(rap,0)),0) into target_value from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids));
  if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.'; end if;
  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));
  won:=random()<=chance/100;
  if won then
    select id,name into result_id,result_name from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0 order by random() limit 1;
    insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,result_id,'normal',1) on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  end if;
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description) values(uid,uname,'upgrade_result',input_value,case when won then greatest(0,target_value-input_value) else -input_value end,case when won then 'Won an upgrade: '||coalesce(result_name,'target') else 'Lost an upgrade' end);
  select * into a from beta_accounts where id=uid;
  return jsonb_build_object('won',won,'chance',chance,'input_value',input_value,'target_value',target_value,'result_id',result_id,'result_name',result_name,'balance',a.balance);
end; $$;
grant execute on function public.beta_run_upgrade(text,jsonb,bigint,jsonb) to anon,authenticated;


-- SpinnyPet final gameplay patch: multi-pet matches, own-bundle joining,
-- safe inventory quantities, and variant-aware upgrades.
alter table public.beta_game_lobbies add column if not exists pet_count integer not null default 0;
alter table public.beta_game_lobbies add column if not exists stake_pet_items jsonb not null default '[]'::jsonb;
create index if not exists beta_game_lobbies_status_idx on public.beta_game_lobbies(status, created_at desc);

create or replace function public.beta_create_lobby_v2(
  p_token text,p_game_type text,p_stake_type text,p_stake_amount bigint,
  p_pet_items jsonb,p_choice text
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; lid uuid; item jsonb; pid text; v text; qty integer;
  total bigint:=0; count_items integer:=0; first_id text; first_name text; first_variant text;
  pv bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if p_stake_type not in ('diamonds','pet') then raise exception 'Invalid stake type'; end if;
  if p_stake_type='diamonds' then
    if coalesce(p_stake_amount,0)<=0 or p_stake_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
    update beta_accounts set balance=balance-p_stake_amount,updated_at=now() where id=uid;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,stake_type,stake_amount,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,'diamonds',p_stake_amount,0,'[]'::jsonb,p_choice) returning id into lid;
  else
    if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select at least one pet'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
      if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
      select coalesce(rap,0),name into pv,first_name from pets_cache where id=pid;
      if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
      total:=total+pv*qty; count_items:=count_items+qty;
      if first_id is null then first_id:=pid; first_variant:=v; end if;
    end loop;
    if total<=0 then raise exception 'Pet bundle has no PS99 RAP'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
    end loop;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,'pet',total,first_id,first_name,first_variant,count_items,p_pet_items,p_choice) returning id into lid;
  end if;
  return jsonb_build_object('ok',true,'id',lid,'status','open','stake_amount',case when p_stake_type='pet' then total else p_stake_amount end,'pet_count',count_items);
end; $$;
grant execute on function public.beta_create_lobby_v2(text,text,text,bigint,jsonb,text) to anon,authenticated;

create or replace function public.beta_join_lobby_v2(
  p_token text,p_lobby_id uuid,p_pet_items jsonb default '[]'::jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; lid uuid; st text; amt bigint; item jsonb; pid text; v text; qty integer;
  total bigint:=0; pv bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select id,stake_type,stake_amount into lid,st,amt from beta_game_lobbies where id=p_lobby_id and status='open' and creator_id<>uid for update;
  if lid is null then raise exception 'Match is no longer available'; end if;
  select username into uname from beta_accounts where id=uid;
  if st='diamonds' then
    if amt<=0 or amt>(select balance from beta_accounts where id=uid) then raise exception 'You do not have enough gems to join'; end if;
    update beta_accounts set balance=balance-amt,updated_at=now() where id=uid;
  else
    if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select one or more pets to join'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
      if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
      select coalesce(rap,0) into pv from pets_cache where id=pid;
      if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
      total:=total+pv*qty;
    end loop;
    if total < amt then raise exception using message = 'Your pet bundle must be worth at least ' || amt || ' gems'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
    end loop;
  end if;
  update beta_game_lobbies set status='joined' where id=lid;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,description)
  values(uid,uname,'game_joined',(select game_type from beta_game_lobbies where id=lid),case when st='pet' then total else amt end,'Joined a match with a custom stake bundle');
  return jsonb_build_object('ok',true,'lobby_id',lid,'status','joined','stake_value',case when st='pet' then total else amt end);
end; $$;
grant execute on function public.beta_join_lobby_v2(text,uuid,jsonb) to anon,authenticated;

create or replace function public.beta_cancel_lobby_v2(p_token text,p_lobby_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; lid uuid; st text; amt bigint; item jsonb; pid text; v text; qty integer; bal bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select id,stake_type,stake_amount,stake_pet_items into lid,st,amt,item from beta_game_lobbies where id=p_lobby_id and creator_id=uid and status='open' for update;
  if lid is null then raise exception 'Lobby is not open or not yours'; end if;
  if st='diamonds' then
    update beta_accounts set balance=balance+amt,updated_at=now() where id=uid returning balance into bal;
  else
    for item in select value from jsonb_array_elements(coalesce(item,'[]'::jsonb)) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,pid,v,qty)
      on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+excluded.quantity,updated_at=now();
    end loop;
    select balance into bal from beta_accounts where id=uid;
  end if;
  update beta_game_lobbies set status='cancelled' where id=lid;
  return jsonb_build_object('ok',true,'balance',bal);
end; $$;
grant execute on function public.beta_cancel_lobby_v2(text,uuid) to anon,authenticated;

-- Variant-aware, transaction-safe upgrader. Inventory rows are deleted at zero,
-- and a winning reward always inserts quantity=1 or increments an existing row.
create or replace function public.beta_run_upgrade_v2(
  p_token text,p_input_pet_items jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0));
  input_value bigint:=0; target_value bigint:=0; chance numeric; won boolean;
  result_id text; result_name text; a beta_accounts%rowtype; item jsonb; pid text; v text; qty integer; chosen_value bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_input_pet_items,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection'; end if;
  if jsonb_array_length(coalesce(p_input_pet_items,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems'; end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target'; end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=item->>'id'; if pid is null then pid:=item->>'pet_id'; end if;
    v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then
      raise exception 'One selected pet variant is no longer in your inventory';
    end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;
    if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
    input_value:=input_value+chosen_value*qty;
  end loop;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=item->>'id'; if pid is null then pid:=item->>'pet_id'; end if;
    v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
    delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
  end loop;

  input_value:=input_value+diamond_amount;
  if diamond_amount>0 then update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid; end if;
  select coalesce(sum(coalesce(rap,0)),0) into target_value from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0;
  if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.'; end if;
  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));
  won:=random()<=chance/100;
  if won then
    select id,name into result_id,result_name from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0 order by random() limit 1;
    if result_id is null then raise exception 'No valid target reward was found'; end if;
    insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,result_id,'normal',1)
    on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  end if;
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'upgrade_result',input_value,case when won then greatest(0,target_value-input_value) else -input_value end,
    case when won then 'Won an upgrade: '||coalesce(result_name,'target') else 'Lost an upgrade' end);
  select * into a from beta_accounts where id=uid;
  return jsonb_build_object('won',won,'chance',chance,'input_value',input_value,'target_value',target_value,'result_id',result_id,'result_name',result_name,'balance',a.balance);
end; $$;
grant execute on function public.beta_run_upgrade_v2(text,jsonb,bigint,jsonb) to anon,authenticated;


create or replace function public.beta_run_upgrade_v3(
  p_token text,p_input_pet_items jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb,p_risk_angle numeric default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0));
  input_value bigint:=0; target_value bigint:=0; chance numeric; won boolean;
  result_id text; result_name text; a beta_accounts%rowtype; item jsonb; pid text; v text; qty integer; chosen_value bigint;
  risk_angle numeric:=mod(coalesce(p_risk_angle,0)+360,360); win_angle numeric; roll_angle numeric; spin_angle numeric;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_input_pet_items,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection'; end if;
  if jsonb_array_length(coalesce(p_input_pet_items,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems'; end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target'; end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id'); v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'One selected pet variant is no longer in your inventory'; end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;
    if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
    input_value:=input_value+chosen_value*qty;
  end loop;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id'); v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
    delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
  end loop;

  input_value:=input_value+diamond_amount;
  if diamond_amount>0 then update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid; end if;
  select coalesce(sum(coalesce(rap,0)),0) into target_value from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0;
  if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.'; end if;

  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));
  win_angle:=chance*3.6;
  roll_angle:=random()*360;
  won:=(case when risk_angle+win_angle<=360
             then roll_angle between risk_angle and risk_angle+win_angle
             else roll_angle>=risk_angle or roll_angle<=risk_angle+win_angle-360 end);
  spin_angle:=1440 + mod(360-roll_angle,360);

  if won then
    select id,name into result_id,result_name from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0 order by random() limit 1;
    if result_id is null then raise exception 'No valid target reward was found'; end if;
    insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,result_id,'normal',1)
    on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  end if;

  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'upgrade_result',input_value,case when won then greatest(0,target_value-input_value) else -input_value end,
    case when won then 'Won an upgrade: '||coalesce(result_name,'target') else 'Lost an upgrade' end);
  select * into a from beta_accounts where id=uid;
  return jsonb_build_object('won',won,'chance',chance,'input_value',input_value,'target_value',target_value,
    'result_id',result_id,'result_name',result_name,'balance',a.balance,'risk_angle',risk_angle,
    'roll_angle',roll_angle,'spin_angle',spin_angle);
end; $$;
grant execute on function public.beta_run_upgrade_v3(text,jsonb,bigint,jsonb,numeric) to anon,authenticated;


-- V13 STAFF/ADMIN RPC FIX
create or replace function public.beta_admin_assert(p_token text)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid; r text;
begin
  select s.user_id,a.role into uid,r from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now();
  if uid is null or r not in ('owner','co_owner','manager','admin','moderator') then raise exception 'Staff access required'; end if;
  return uid;
end; $$;

create or replace function public.beta_admin_get_users(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform beta_admin_assert(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'username',username,'balance',balance,'role',role,'banned_until',banned_until,'muted_until',muted_until,'created_at',created_at) order by created_at desc) from beta_accounts),'[]'::jsonb);
end; $$;

grant execute on function public.beta_admin_get_users(text) to anon,authenticated;

create or replace function public.beta_admin_set_balance(p_token text,p_target_username text,p_balance bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; b bigint;
begin
  adminid:=beta_admin_assert(p_token);
  if p_balance<0 then raise exception 'Balance cannot be negative'; end if;
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  update beta_accounts set balance=p_balance,updated_at=now() where id=tid returning balance into b;
  return jsonb_build_object('ok',true,'username',p_target_username,'balance',b);
end; $$;
grant execute on function public.beta_admin_set_balance(text,text,bigint) to anon,authenticated;

create or replace function public.beta_admin_give_all(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; n integer;
begin
  adminid:=beta_admin_assert(p_token);
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  insert into beta_inventory(user_id,pet_id,variant,quantity)
  select tid,p.id,'normal',1 from pets_cache p where p.cosmic_value>0 and (lower(p.category) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %')
  on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  select count(*) into n from pets_cache p where p.cosmic_value>0 and (lower(p.category) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %');
  return jsonb_build_object('ok',true,'count',n);
end; $$;
grant execute on function public.beta_admin_give_all(text,text) to anon,authenticated;

create or replace function public.beta_admin_moderate(p_token text,p_target_username text,p_action text,p_minutes integer,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; until_at timestamptz;
begin
  adminid:=beta_admin_assert(p_token);
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  until_at:=case when p_minutes<=0 then null else now()+make_interval(mins=>p_minutes) end;
  if p_action='ban' then update beta_accounts set banned_until=until_at,ban_reason=left(coalesce(p_reason,''),200),updated_at=now() where id=tid;
  elsif p_action='unban' then update beta_accounts set banned_until=null,ban_reason=null,updated_at=now() where id=tid;
  elsif p_action='mute' then update beta_accounts set muted_until=until_at,updated_at=now() where id=tid;
  elsif p_action='unmute' then update beta_accounts set muted_until=null,updated_at=now() where id=tid;
  else raise exception 'Unknown moderation action'; end if;
  return jsonb_build_object('ok',true);
end; $$;
grant execute on function public.beta_admin_moderate(text,text,text,integer,text) to anon,authenticated;

create or replace function public.beta_admin_set_role(p_token text,p_target_username text,p_role text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; adminrole text; tid uuid; newrole text:=lower(trim(p_role));
begin
  select s.user_id,a.role into adminid,adminrole from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now();
  if adminid is null then raise exception 'Staff access required'; end if;
  if adminrole not in ('owner','co_owner','manager','admin') then raise exception 'Only Owner, Co Owner, Manager or Admin can change roles'; end if;
  if newrole not in ('user','helper','moderator','admin','manager','co_owner','owner') then raise exception 'Invalid role'; end if;
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username));
  if tid is null then raise exception 'User not found'; end if;
  if tid=adminid and newrole<>'owner' and adminrole='owner' then null; end if;
  if adminrole='admin' and newrole in ('owner','co_owner','manager') then raise exception 'Admin cannot grant Owner, Co Owner or Manager'; end if;
  if adminrole='manager' and newrole in ('owner','co_owner') then raise exception 'Manager cannot grant Owner or Co Owner'; end if;
  if adminrole='co_owner' and newrole='owner' then raise exception 'Co Owner cannot grant Owner'; end if;
  update beta_accounts set role=newrole,updated_at=now() where id=tid;
  return jsonb_build_object('ok',true,'username',(select username from beta_accounts where id=tid),'role',newrole);
end; $$;
grant execute on function public.beta_admin_set_role(text,text,text) to anon,authenticated;

-- Event control. Only Owner / Co Owner / Manager / Admin can toggle it.
create or replace function public.beta_admin_set_event(p_token text,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; r text; eid uuid;
begin
  select s.user_id,a.role into uid,r from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now();
  if uid is null or r not in ('owner','co_owner','manager','admin') then raise exception 'Only Owner, Co Owner, Manager or Admin can control the event'; end if;
  select id into eid from beta_events where slug='red-vs-blue' limit 1;
  if eid is null then
    insert into beta_events(slug,title,description,bank_value,status) values('red-vs-blue','RED vs BLUE · Virtual World','A 100B virtual event where the whole beta community pushes one of two teams.',100000000000,case when p_enabled then 'live' else 'ended' end) returning id into eid;
  else
    update beta_events set status=case when p_enabled then 'live' else 'ended' end,updated_at=now() where id=eid;
  end if;
  return beta_get_active_event(p_token);
end; $$;
grant execute on function public.beta_admin_set_event(text,boolean) to anon,authenticated;

create or replace function public.beta_admin_create_promo(p_token text,p_code text,p_reward_amount bigint,p_max_uses integer,p_duration_minutes integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; r text; pid bigint; clean text:=upper(regexp_replace(trim(coalesce(p_code,'')),'\s+','','g'));
begin
  select a.id,a.role into uid,r from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  if r not in ('owner','co_owner','manager','admin') then raise exception 'Promo codes require Owner, Co Owner, Manager or Admin'; end if;
  if clean !~ '^[A-Z0-9_-]{3,32}$' then raise exception 'Code must be 3-32 letters, numbers, _ or -'; end if;
  if p_reward_amount<=0 then raise exception 'Reward must be greater than 0'; end if;
  if p_max_uses<1 or p_max_uses>100000 then raise exception 'Invalid max uses'; end if;
  if p_duration_minutes<1 or p_duration_minutes>43200 then raise exception 'Invalid duration'; end if;
  insert into beta_promo_codes(code,reward_amount,max_uses,created_by,expires_at) values(clean,p_reward_amount,p_max_uses,uid,now()+make_interval(mins=>p_duration_minutes)) returning id into pid;
  return jsonb_build_object('ok',true,'id',pid,'code',clean,'reward_amount',p_reward_amount);
end; $$;
grant execute on function public.beta_admin_create_promo(text,text,bigint,integer,integer) to anon,authenticated;

create or replace function public.beta_admin_get_inventory(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid;
begin
  adminid:=beta_admin_assert(p_token);
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'pet_id',i.pet_id,'name',p.name,'variant',i.variant,'quantity',i.quantity,'rap',p.rap,'thumbnail_asset',p.thumbnail_asset,'thumbnail_url',p.thumbnail_url,'golden_thumbnail_asset',p.golden_thumbnail_asset,'golden_thumbnail_url',p.golden_thumbnail_url) order by p.name) from beta_inventory i join pets_cache p on p.id=i.pet_id where i.user_id=tid),'[]'::jsonb);
end; $$;
grant execute on function public.beta_admin_get_inventory(text,text) to anon,authenticated;

create or replace function public.beta_admin_clear_inventory(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; n integer;
begin
  adminid:=beta_admin_assert(p_token); select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  select count(*) into n from beta_inventory where user_id=tid; delete from beta_inventory where user_id=tid; return jsonb_build_object('ok',true,'removed_rows',n);
end; $$;
grant execute on function public.beta_admin_clear_inventory(text,text) to anon,authenticated;

create or replace function public.beta_admin_remove_pet(p_token text,p_target_username text,p_pet_id text,p_variant text,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; q integer; take integer:=greatest(1,coalesce(p_quantity,1));
begin
  adminid:=beta_admin_assert(p_token); select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  select quantity into q from beta_inventory where user_id=tid and pet_id=p_pet_id and variant=coalesce(p_variant,'normal'); if q is null then raise exception 'Pet is not in inventory'; end if;
  if q<=take then delete from beta_inventory where user_id=tid and pet_id=p_pet_id and variant=coalesce(p_variant,'normal'); else update beta_inventory set quantity=quantity-take,updated_at=now() where user_id=tid and pet_id=p_pet_id and variant=coalesce(p_variant,'normal'); end if;
  return jsonb_build_object('ok',true);
end; $$;
grant execute on function public.beta_admin_remove_pet(text,text,text,text,integer) to anon,authenticated;

create or replace function public.beta_admin_add_pet(p_token text,p_target_username text,p_pet_id text,p_variant text,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; take integer:=greatest(1,coalesce(p_quantity,1));
begin
  adminid:=beta_admin_assert(p_token); select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  if p_variant not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet variant'; end if;
  if not exists(select 1 from pets_cache where id=p_pet_id and (lower(category) in ('huge','titanic','gargantuan') or lower(name) like 'huge %' or lower(name) like 'titanic %' or lower(name) like 'gargantuan %')) then raise exception 'Pet is not in high-tier catalog'; end if;
  insert into beta_inventory(user_id,pet_id,variant,quantity) values(tid,p_pet_id,p_variant,take) on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+take,updated_at=now();
  return jsonb_build_object('ok',true,'quantity',take);
end; $$;
grant execute on function public.beta_admin_add_pet(text,text,text,text,integer) to anon,authenticated;

-- V15 ADMIN ROLE READ FIX: FINAL_FIX/LATEST_PATCH are valid standalone patches.
create or replace function public.beta_get_role(p_token text)
returns text language plpgsql security definer set search_path=public as $$
declare r text;
begin
  select a.role into r
  from beta_sessions s
  join beta_accounts a on a.id=s.user_id
  where s.token=p_token and s.expires_at>now();
  return coalesce(r,'user');
end; $$;
grant execute on function public.beta_get_role(text) to anon,authenticated;
-- SpinnyPet V16: coinflip settlement, safe inventory writes, 30-minute beta reward,
-- working promo page support, and RAP-based case opening.

-- Keep the inventory invariant explicit and repair any legacy zero/negative rows.
delete from public.beta_inventory where quantity <= 0;
alter table public.beta_inventory drop constraint if exists beta_inventory_quantity_check;
alter table public.beta_inventory add constraint beta_inventory_quantity_check check (quantity > 0);

create or replace function public.beta_inventory_add_safe(
  p_user_id uuid,p_pet_id text,p_variant text default 'normal',p_quantity integer default 1
)
returns integer language plpgsql security definer set search_path=public as $$
declare q integer:=greatest(1,coalesce(p_quantity,1)); v text:=coalesce(nullif(trim(p_variant),''),'normal'); new_q integer;
begin
  if p_user_id is null or p_pet_id is null then raise exception 'Invalid inventory write'; end if;
  if v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet variant'; end if;
  insert into public.beta_inventory(user_id,pet_id,variant,quantity)
  values(p_user_id,p_pet_id,v,q)
  on conflict(user_id,pet_id,variant)
  do update set quantity=greatest(1,public.beta_inventory.quantity+excluded.quantity),updated_at=now()
  returning quantity into new_q;
  return new_q;
end; $$;
grant execute on function public.beta_inventory_add_safe(uuid,text,text,integer) to anon,authenticated;

alter table public.beta_accounts add column if not exists bonus_claimed_at timestamptz;

-- The beta reward is repeatable once every 30 minutes.
create or replace function public.beta_claim_bonus(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; a beta_accounts%rowtype; tid text; tname text; tvalue bigint; next_at timestamptz; cooldown integer;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select * into a from beta_accounts where id=uid for update;
  if a.bonus_claimed_at is not null and a.bonus_claimed_at > now()-interval '30 minutes' then
    next_at:=a.bonus_claimed_at+interval '30 minutes';
    cooldown:=greatest(0,ceil(extract(epoch from (next_at-now())))::integer);
    return jsonb_build_object('user_id',a.id,'username',a.username,'balance',a.balance,'claimed',true,'cooldown_seconds',cooldown,'next_claim_at',next_at);
  end if;
  select id,name,coalesce(rap,0) into tid,tname,tvalue
  from pets_cache
  where lower(category)='titanic' or lower(name) like 'titanic %'
  order by random() limit 1;
  if tid is null then raise exception 'High-tier catalog is empty. Run npm run sync:ps99 first.'; end if;
  update beta_accounts set balance=balance+50000000000,bonus_claimed=true,bonus_claimed_at=now(),updated_at=now() where id=uid returning * into a;
  perform beta_inventory_add_safe(uid,tid,'normal',1);
  insert into beta_activity(user_id,username,activity_type,amount,description)
  values(uid,a.username,'bonus_claimed',50000000000,'Claimed 50B + random Titanic: '||tname);
  return jsonb_build_object('user_id',a.id,'username',a.username,'balance',a.balance,'claimed',true,'cooldown_seconds',1800,'pet_id',tid,'pet_name',tname,'pet_value',coalesce(tvalue,0));
end; $$;
grant execute on function public.beta_claim_bonus(text) to anon,authenticated;

alter table public.beta_game_lobbies add column if not exists join_pet_items jsonb not null default '[]'::jsonb;
alter table public.beta_game_lobbies add column if not exists result_side text;
alter table public.beta_game_lobbies add column if not exists winner_id uuid;
alter table public.beta_game_lobbies add column if not exists winner_username text;
alter table public.beta_game_lobbies add column if not exists payout bigint not null default 0;

create or replace function public.beta_create_lobby_v2(
  p_token text,p_game_type text,p_stake_type text,p_stake_amount bigint,
  p_pet_items jsonb,p_choice text
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; lid uuid; item jsonb; pid text; v text; qty integer;
  total bigint:=0; count_items integer:=0; first_id text; first_name text; first_variant text; pv bigint; pcat text; choice text:=initcap(lower(trim(coalesce(p_choice,''))));
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if p_game_type not in ('coinflip','dice') then raise exception 'Game is no longer available'; end if;
  if p_stake_type not in ('diamonds','pet') then raise exception 'Invalid stake type'; end if;
  if p_game_type='coinflip' and choice not in ('Heads','Tails') then raise exception 'Choose Heads or Tails'; end if;
  if p_stake_type='diamonds' then
    if coalesce(p_stake_amount,0)<10000000 or p_stake_amount>(select balance from beta_accounts where id=uid) then raise exception 'Coinflip requires at least 10M gems'; end if;
    update beta_accounts set balance=balance-p_stake_amount,updated_at=now() where id=uid;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,stake_type,stake_amount,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,'diamonds',p_stake_amount,0,'[]'::jsonb,case when p_game_type='coinflip' then choice else p_choice end) returning id into lid;
  else
    if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select at least one pet'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
      if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
      select coalesce(rap,0),name,category into pv,first_name,pcat from pets_cache where id=pid;
      if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
      if p_game_type='coinflip' and not (lower(coalesce(pcat,'')) in ('titanic','gargantuan') or lower(coalesce(first_name,'')) like 'titanic %' or lower(coalesce(first_name,'')) like 'gargantuan %') then raise exception 'Coinflip accepts only Titanic and Gargantuan pets'; end if;
      total:=total+pv*qty; count_items:=count_items+qty; if first_id is null then first_id:=pid; first_variant:=v; end if;
    end loop;
    if p_game_type='coinflip' and total<10000000 then raise exception 'Coinflip requires a wager of at least 10M gems'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
    end loop;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,'pet',total,first_id,first_name,first_variant,count_items,p_pet_items,case when p_game_type='coinflip' then choice else p_choice end) returning id into lid;
  end if;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,description) values(uid,uname,'game_created',p_game_type,case when p_stake_type='pet' then total else p_stake_amount end,'Created a '||p_game_type||' game');
  return jsonb_build_object('ok',true,'id',lid,'status','open','stake_amount',case when p_stake_type='pet' then total else p_stake_amount end,'pet_count',count_items);
end; $$;
grant execute on function public.beta_create_lobby_v2(text,text,text,bigint,jsonb,text) to anon,authenticated;

create or replace function public.beta_join_lobby_v2(
  p_token text,p_lobby_id uuid,p_pet_items jsonb default '[]'::jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; host_id uuid; host_name text; lid uuid; gtype text; st text; amt bigint; host_choice text; host_items jsonb; item jsonb; pid text; v text; qty integer; total bigint:=0; pv bigint; winner uuid; wname text; wside text; payout_value bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select id,creator_id,creator_username,game_type,stake_type,stake_amount,choice,stake_pet_items into lid,host_id,host_name,gtype,st,amt,host_choice,host_items from beta_game_lobbies where id=p_lobby_id and status='open' and creator_id<>uid for update;
  if lid is null then raise exception 'Game is no longer available'; end if;
  select username into uname from beta_accounts where id=uid;
  if gtype='coinflip' then
    if st='diamonds' then
      if amt<10000000 or amt>(select balance from beta_accounts where id=uid) then raise exception 'You do not have enough gems to join'; end if;
      update beta_accounts set balance=balance-amt,updated_at=now() where id=uid;
      payout_value:=amt*2;
    else
      if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select one or more pets to join'; end if;
      for item in select value from jsonb_array_elements(p_pet_items) loop
        pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
        if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
        if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
        select coalesce(rap,0) into pv from pets_cache where id=pid; if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
        if not exists(select 1 from pets_cache p where p.id=pid and (lower(coalesce(p.category,'')) in ('titanic','gargantuan') or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %')) then raise exception 'Coinflip accepts only Titanic and Gargantuan pets'; end if;
        total:=total+pv*qty;
      end loop;
      if total<amt then raise exception 'Your pet bundle must be worth at least '||amt||' gems'; end if;
      for item in select value from jsonb_array_elements(p_pet_items) loop
        pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
        update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v; delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
      end loop;
      payout_value:=amt+total;
    end if;
    if random()<0.5 then winner:=host_id; wname:=host_name; wside:=host_choice; else winner:=uid; wname:=uname; wside:=case when host_choice='Heads' then 'Tails' else 'Heads' end; end if;
    if st='diamonds' then
      update beta_accounts set balance=balance+payout_value,updated_at=now() where id=winner;
    else
      for item in select value from jsonb_array_elements(coalesce(host_items,'[]'::jsonb)) loop
        pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1)); perform beta_inventory_add_safe(winner,pid,v,qty);
      end loop;
      for item in select value from jsonb_array_elements(coalesce(p_pet_items,'[]'::jsonb)) loop
        pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1)); perform beta_inventory_add_safe(winner,pid,v,qty);
      end loop;
    end if;
    update beta_game_lobbies set status='finished',join_pet_items=coalesce(p_pet_items,'[]'::jsonb),result_side=wside,winner_id=winner,winner_username=wname,payout=payout_value where id=lid;
    insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description) values(winner,wname,'game_result','coinflip',payout_value,case when winner=host_id then payout_value-amt else payout_value-amt end,'Won Coinflip: '||wside);
    return jsonb_build_object('ok',true,'lobby_id',lid,'status','finished','winner_id',winner,'winner_username',wname,'winner_side',wside,'payout',payout_value,'stake_value',payout_value);
  end if;
  -- Color Dice keeps the existing lobby behaviour; coinflip is the only instant-settle game.
  if st='diamonds' then
    if amt<=0 or amt>(select balance from beta_accounts where id=uid) then raise exception 'You do not have enough gems to join'; end if;
    update beta_accounts set balance=balance-amt,updated_at=now() where id=uid;
  else
    if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select one or more pets to join'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
      select coalesce(rap,0) into pv from pets_cache where id=pid; if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if; total:=total+pv*qty;
    end loop;
    if total<amt then raise exception using message='Your pet bundle must be worth at least '||amt||' gems'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;end loop;
  end if;
  update beta_game_lobbies set status='joined',join_pet_items=coalesce(p_pet_items,'[]'::jsonb) where id=lid;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,description) values(uid,uname,'game_joined',gtype,case when st='pet' then total else amt end,'Joined a Color Dice game');
  return jsonb_build_object('ok',true,'lobby_id',lid,'status','joined','stake_value',case when st='pet' then total else amt end);
end; $$;
grant execute on function public.beta_join_lobby_v2(text,uuid,jsonb) to anon,authenticated;

create or replace function public.beta_cancel_lobby_v2(p_token text,p_lobby_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; lid uuid; st text; amt bigint; item jsonb; pid text; v text; qty integer; bal bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select id,stake_type,stake_amount,stake_pet_items into lid,st,amt,item from beta_game_lobbies where id=p_lobby_id and creator_id=uid and status='open' for update;
  if lid is null then raise exception 'Game is not open or not yours'; end if;
  if st='diamonds' then update beta_accounts set balance=balance+amt,updated_at=now() where id=uid returning balance into bal;
  else
    for item in select value from jsonb_array_elements(coalesce(item,'[]'::jsonb)) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(uid,pid,v,qty);end loop;
    select balance into bal from beta_accounts where id=uid;
  end if;
  update beta_game_lobbies set status='cancelled' where id=lid;
  return jsonb_build_object('ok',true,'balance',bal);
end; $$;
grant execute on function public.beta_cancel_lobby_v2(text,uuid) to anon,authenticated;

-- RAP-only case opening; no Cosmic Values or diamond fallback.
create or replace function public.beta_open_case(p_token text,p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; bal bigint; c beta_cases%rowtype; pid text; pname text; pvalue bigint; pthumb text; pcat text; tier text; slot integer; pool_size integer; reward_value bigint; titanic_slots integer:=0; huge_slots integer:=0; garg_slots integer:=0;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select username,balance into uname,bal from beta_accounts where id=uid for update;
  select * into c from beta_cases where id=p_case_id and active=true; if c.id is null then raise exception 'Case not found'; end if;
  if bal<c.price then raise exception 'Not enough gems'; end if;
  update beta_accounts set balance=balance-c.price,updated_at=now() where id=uid returning balance into bal;
  if c.id='basic' then pool_size:=5;titanic_slots:=1;huge_slots:=4;
  elsif c.id='lucky' then pool_size:=5;titanic_slots:=2;huge_slots:=3;
  elsif c.id='titan' then pool_size:=5;titanic_slots:=5;
  elsif c.id='cosmic' then pool_size:=6;titanic_slots:=3;garg_slots:=1;huge_slots:=2;
  elsif c.id='omega' then pool_size:=9;titanic_slots:=3;garg_slots:=2;huge_slots:=4;
  else raise exception 'Unsupported case'; end if;
  slot:=floor(random()*pool_size)::integer+1;
  tier:=case when slot<=titanic_slots then 'titanic' when slot<=titanic_slots+garg_slots then 'gargantuan' else 'huge' end;
  select z.id,z.name,z.rap,z.thumbnail_url,z.category into pid,pname,pvalue,pthumb,pcat
  from (
    select p.*,case when lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %' then 'titanic' when lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %' then 'gargantuan' when lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %' then 'huge' end as reward_tier,
      row_number() over(partition by case when lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %' then 'titanic' when lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %' then 'gargantuan' when lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %' then 'huge' end order by coalesce(p.rap,0) desc,p.id) as rn
    from pets_cache p where coalesce(p.rap,0)>0 and (lower(coalesce(p.category,'')) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %')
  ) z
  where z.reward_tier=tier and z.rn <= case when tier='titanic' then titanic_slots when tier='gargantuan' then garg_slots else huge_slots end
  order by random() limit 1;
  if pid is null then update beta_accounts set balance=balance+c.price,updated_at=now() where id=uid;raise exception 'No % rewards are available for this case yet',tier;end if;
  reward_value:=pvalue; perform beta_inventory_add_safe(uid,pid,'normal',1);
  insert into beta_case_openings(user_id,username,case_id,case_price,reward_type,reward_amount,reward_pet_id,reward_pet_name,reward_pet_value) values(uid,uname,c.id,c.price,'pet',0,pid,pname,reward_value);
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description) values(uid,uname,'case_opened',c.price,reward_value-c.price,'Opened '||c.name||': '||pname);
  return jsonb_build_object('ok',true,'case_id',c.id,'case_name',c.name,'price',c.price,'reward_type','pet','reward_amount',0,'reward_pet_id',pid,'reward_pet_name',pname,'reward_pet_value',reward_value,'reward_pet_thumbnail_url',pthumb,'reward_pet_category',pcat,'balance',bal);
end; $$;
grant execute on function public.beta_open_case(text,text) to anon,authenticated;

-- Make every current upgrade reward write use the safe inventory helper.
create or replace function public.beta_run_upgrade_v3(
  p_token text,p_input_pet_items jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb,p_risk_angle numeric default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0)); input_value bigint:=0; target_value bigint:=0; chance numeric; won boolean; result_id text; result_name text; a beta_accounts%rowtype; item jsonb; pid text; v text; qty integer; chosen_value bigint; risk_angle numeric:=mod(coalesce(p_risk_angle,0)+360,360); win_angle numeric; roll_angle numeric; spin_angle numeric;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if; select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_input_pet_items,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection'; end if;
  if jsonb_array_length(coalesce(p_input_pet_items,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems'; end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target'; end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id');v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid selected pet'; end if;
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'One selected pet variant is no longer in your inventory'; end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP';end if;input_value:=input_value+chosen_value*qty;
  end loop;
  for item in select value from jsonb_array_elements(p_input_pet_items) loop pid:=coalesce(item->>'id',item->>'pet_id');v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;end loop;
  input_value:=input_value+diamond_amount;if diamond_amount>0 then update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid;end if;
  select coalesce(sum(coalesce(rap,0)),0) into target_value from pets_cache where id in(select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0;if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.';end if;
  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));win_angle:=chance*3.6;roll_angle:=random()*360;
  won:=(case when risk_angle+win_angle<=360 then roll_angle between risk_angle and risk_angle+win_angle else roll_angle>=risk_angle or roll_angle<=risk_angle+win_angle-360 end);spin_angle:=1440+mod(360-roll_angle,360);
  if won then select id,name into result_id,result_name from pets_cache where id in(select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0 order by random() limit 1;if result_id is null then raise exception 'No valid target reward was found';end if;perform beta_inventory_add_safe(uid,result_id,'normal',1);end if;
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description) values(uid,uname,'upgrade_result',input_value,case when won then greatest(0,target_value-input_value) else -input_value end,case when won then 'Won an upgrade: '||coalesce(result_name,'target') else 'Lost an upgrade' end);
  select * into a from beta_accounts where id=uid;
  return jsonb_build_object('won',won,'chance',chance,'input_value',input_value,'target_value',target_value,'result_id',result_id,'result_name',result_name,'balance',a.balance,'risk_angle',risk_angle,'roll_angle',roll_angle,'spin_angle',spin_angle);
end; $$;
grant execute on function public.beta_run_upgrade_v3(text,jsonb,bigint,jsonb,numeric) to anon,authenticated;

-- Case/claim/admin/giveaway writes that can award pets use the same safe writer.
create or replace function public.beta_claim_daily_case(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; today date:=current_date; reward bigint; tid text; tname text; tvalue bigint; bal bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();if uid is null then raise exception 'Please sign in';end if;select username into uname from beta_accounts where id=uid;
  if exists(select 1 from beta_daily_claims where user_id=uid and claim_date=today) then raise exception 'Daily case already claimed today';end if;
  select id,name,coalesce(rap,0) into tid,tname,tvalue from pets_cache where lower(category)='titanic' or lower(name) like 'titanic %' order by random() limit 1;if tid is null then raise exception 'High-tier catalog is empty. Run npm run sync:ps99 first.';end if;
  reward:=500000000+floor(random()*29500000001)::bigint;update beta_accounts set balance=balance+reward,updated_at=now() where id=uid returning balance into bal;insert into beta_daily_claims(user_id,claim_date,reward) values(uid,today,reward);perform beta_inventory_add_safe(uid,tid,'normal',1);insert into beta_activity(user_id,username,activity_type,amount,description) values(uid,uname,'daily_case',reward,'Daily Case: '||tname);
  return jsonb_build_object('balance',bal,'reward',reward,'pet_id',tid,'pet_name',tname,'pet_value',coalesce(tvalue,0));
end; $$;
grant execute on function public.beta_claim_daily_case(text) to anon,authenticated;


create or replace function public.beta_draw_giveaway(p_token text,p_giveaway_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; gid uuid; winner uuid; wname text; reward bigint; rtype text; pid text; pvar text; pname text;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select id,reward_amount,reward_type,reward_pet_id,reward_pet_variant,reward_pet_name into gid,reward,rtype,pid,pvar,pname from beta_giveaways where id=p_giveaway_id and host_id=uid and status='open' and ends_at>now() for update;
  if gid is null then raise exception 'Giveaway not found, expired, or you are not the host'; end if;
  select e.user_id,e.username into winner,wname from beta_giveaway_entries e where e.giveaway_id=gid order by random() limit 1;
  if winner is null then raise exception 'No entries yet'; end if;
  if rtype='diamonds' then update beta_accounts set balance=balance+reward,updated_at=now() where id=winner;
  else perform beta_inventory_add_safe(winner,pid,coalesce(pvar,'normal'),1); end if;
  update beta_giveaways set status='drawn',winner_user_id=winner,winner_username=wname,updated_at=now() where id=gid;
  insert into beta_activity(user_id,username,activity_type,amount,description) values(winner,wname,'giveaway_won',case when rtype='diamonds' then reward else 0 end,'Won giveaway: '||coalesce((select title from beta_giveaways where id=gid),''));
  return jsonb_build_object('winner_username',wname,'reward_type',rtype,'reward_amount',reward,'reward_pet_name',pname,'status','drawn');
end; $$;
grant execute on function public.beta_draw_giveaway(text,uuid) to anon,authenticated;


-- ============================================================
-- V22.7 SUPER UPDATE
-- ============================================================
-- SpinnyPet V22.7 SUPER UPDATE
-- Apply AFTER V22.6_FINAL_FIXES.sql / V22.6.2_COLOR_DICE_FIX.sql.
-- Fixes:
--   1. Coinflip pet stakes never write quantity=0.
--   2. Case Battle supports the 1-50 round UI, including duplicate cases.
--   3. Players can sell one pet stack or their entire inventory for RAP value.
--   4. Adds realtime Admin Abuse / Global Drop effects with optional diamond rewards.
--   5. Keeps all inventory writes inside the quantity > 0 invariant.

begin;

-- ============================================================
-- 1) Inventory invariant helper
-- ============================================================
create or replace function public.beta_inventory_take_safe(
  p_user_id uuid,
  p_pet_id text,
  p_variant text default 'normal',
  p_quantity integer default 1
)
returns integer
language plpgsql security definer set search_path=public as $$
declare
  take integer:=greatest(1,coalesce(p_quantity,1));
  v text:=coalesce(nullif(trim(p_variant),''),'normal');
  q integer;
begin
  if p_user_id is null or p_pet_id is null then raise exception 'Invalid inventory item'; end if;
  if v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet variant'; end if;
  select quantity into q from public.beta_inventory
    where user_id=p_user_id and pet_id=p_pet_id and variant=v for update;
  if q is null or q<take then raise exception 'You do not own enough of this pet'; end if;
  if q=take then
    delete from public.beta_inventory where user_id=p_user_id and pet_id=p_pet_id and variant=v;
    return 0;
  end if;
  update public.beta_inventory set quantity=q-take,updated_at=now()
    where user_id=p_user_id and pet_id=p_pet_id and variant=v;
  return q-take;
end; $$;
grant execute on function public.beta_inventory_take_safe(uuid,text,text,integer) to anon,authenticated;

-- ============================================================
-- 2) Coinflip / generic lobby creation: safe pet consumption
-- ============================================================
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
      if first_id is null then first_id:=pid; first_variant:=v; end if;
    end loop;
    if total<min_stake then
      raise exception using message=case when p_game_type='coinflip' then 'Coinflip requires at least 10M value' else 'Color Dice pet wagers require at least 5B value' end;
    end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      perform public.beta_inventory_take_safe(uid,pid,v,qty);
    end loop;
    insert into public.beta_game_lobbies(game_type,creator_id,creator_username,creator_avatar_url,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,avatar,'pet',total,first_id,first_pet_name,first_variant,count_items,p_pet_items,choice) returning id into lid;
  end if;
  insert into public.beta_activity(user_id,username,activity_type,game_type,amount,description)
  values(uid,uname,'game_created',p_game_type,case when p_stake_type='pet' then total else p_stake_amount end,'Created a '||p_game_type||' game');
  return jsonb_build_object('ok',true,'id',lid,'status','open','stake_amount',case when p_stake_type='pet' then total else p_stake_amount end,'pet_count',count_items,'choice',choice);
end; $$;
grant execute on function public.beta_create_lobby_v2(text,text,text,bigint,jsonb,text) to anon,authenticated;

-- ============================================================
-- 3) Pet selling: exact stack or everything
-- ============================================================
create or replace function public.beta_sell_pet(
  p_token text,p_pet_id text,p_variant text default 'normal',p_quantity integer default 1
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; v text:=coalesce(nullif(trim(p_variant),''),'normal'); take integer:=greatest(1,coalesce(p_quantity,1));
  q integer; rap bigint; value bigint; bal bigint;
begin
  select user_id into uid from public.beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from public.beta_accounts where id=uid;
  if p_pet_id is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet'; end if;
  select i.quantity,coalesce(p.rap,0) into q,rap
    from public.beta_inventory i join public.pets_cache p on p.id=i.pet_id
    where i.user_id=uid and i.pet_id=p_pet_id and i.variant=v for update;
  if q is null then raise exception 'Pet is no longer in your inventory'; end if;
  if q<take then raise exception 'You only own % of this pet',q; end if;
  if rap<=0 then raise exception 'This pet has no PS99 RAP value yet'; end if;
  value:=rap*take;
  perform public.beta_inventory_take_safe(uid,p_pet_id,v,take);
  update public.beta_accounts set balance=balance+value,updated_at=now() where id=uid returning balance into bal;
  insert into public.beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'pet_sold',value,value,'Sold '||take||' × '||p_pet_id||' ('||v||')');
  return jsonb_build_object('ok',true,'pet_id',p_pet_id,'variant',v,'quantity',take,'value',value,'balance',bal);
end; $$;
grant execute on function public.beta_sell_pet(text,text,text,integer) to anon,authenticated;

create or replace function public.beta_sell_all_pets(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; total bigint:=0; stacks integer:=0; sold integer:=0; bal bigint;
  r record;
begin
  select user_id into uid from public.beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from public.beta_accounts where id=uid;
  for r in
    select i.pet_id,i.variant,i.quantity,coalesce(p.rap,0) rap
    from public.beta_inventory i join public.pets_cache p on p.id=i.pet_id
    where i.user_id=uid and i.quantity>0
    order by i.id
    for update
  loop
    if r.rap>0 then
      total:=total+(r.rap*r.quantity); stacks:=stacks+1; sold:=sold+r.quantity;
      delete from public.beta_inventory where user_id=uid and pet_id=r.pet_id and variant=r.variant;
    end if;
  end loop;
  if total<=0 then raise exception 'No pets with a valid RAP value are available to sell'; end if;
  update public.beta_accounts set balance=balance+total,updated_at=now() where id=uid returning balance into bal;
  insert into public.beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'pet_sold_all',total,total,'Sold all valued pets');
  return jsonb_build_object('ok',true,'value',total,'stacks',stacks,'quantity',sold,'balance',bal);
end; $$;
grant execute on function public.beta_sell_all_pets(text) to anon,authenticated;

-- ============================================================
-- 4) Case Battle: 1-50 rounds + duplicate case support
-- ============================================================
create or replace function public.beta_create_case_battle(p_token text,p_case_ids jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; cid text; total bigint:=0; bid uuid; price bigint;
begin
  select user_id into uid from public.beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from public.beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_case_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid case selection'; end if;
  if jsonb_array_length(p_case_ids)<1 or jsonb_array_length(p_case_ids)>50 then raise exception 'Choose 1 to 50 cases'; end if;
  for cid in select value from jsonb_array_elements_text(p_case_ids) loop
    select c.price into price from public.beta_cases c where c.id=cid and c.active=true;
    if price is null then raise exception 'Case % is unavailable',cid; end if;
    total:=total+price;
  end loop;
  if total<=0 or total>(select balance from public.beta_accounts where id=uid) then raise exception 'Not enough gems for this Case Battle'; end if;
  update public.beta_accounts set balance=balance-total,updated_at=now() where id=uid;
  insert into public.beta_case_battles(creator_id,creator_username,creator_cases,creator_total)
  values(uid,uname,p_case_ids,total) returning id into bid;
  insert into public.beta_activity(user_id,username,activity_type,game_type,amount,description)
  values(uid,uname,'game_created','case_battle',total,'Created a Case Battle with '||jsonb_array_length(p_case_ids)||' rounds');
  return jsonb_build_object('ok',true,'id',bid,'status','open','creator_total',total,'creator_cases',p_case_ids);
end; $$;
grant execute on function public.beta_create_case_battle(text,jsonb) to anon,authenticated;

create or replace function public.beta_join_case_battle(p_token text,p_battle_id uuid,p_case_ids jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; b public.beta_case_battles%rowtype; cid text; price bigint; total bigint:=0;
  reward jsonb; rewards jsonb:='[]'::jsonb; cs bigint:=0; js bigint:=0; winner uuid; wname text; r jsonb;
begin
  select user_id into uid from public.beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select * into b from public.beta_case_battles where id=p_battle_id and status='open' and creator_id<>uid for update;
  if b.id is null then raise exception 'Case Battle is no longer available'; end if;
  select username into uname from public.beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_case_ids,'[]'::jsonb))<>'array' or jsonb_array_length(p_case_ids)<1 or jsonb_array_length(p_case_ids)>50 then raise exception 'Choose 1 to 50 cases'; end if;
  if jsonb_array_length(p_case_ids)<>jsonb_array_length(b.creator_cases) then raise exception 'Use the same number of rounds as the host'; end if;
  for cid in select value from jsonb_array_elements_text(p_case_ids) loop
    select c.price into price from public.beta_cases c where c.id=cid and c.active=true;
    if price is null then raise exception 'Case % is unavailable',cid; end if;
    total:=total+price;
  end loop;
  if total<>b.creator_total then raise exception 'Your cases must total exactly % gems',b.creator_total; end if;
  if total>(select balance from public.beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
  update public.beta_accounts set balance=balance-total,updated_at=now() where id=uid;

  for cid in select value from jsonb_array_elements_text(b.creator_cases) loop
    reward:=public.beta_case_battle_pick_reward(cid); cs:=cs+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','creator','case_id',cid)||reward);
  end loop;
  for cid in select value from jsonb_array_elements_text(p_case_ids) loop
    reward:=public.beta_case_battle_pick_reward(cid); js:=js+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','joiner','case_id',cid)||reward);
  end loop;

  if cs>js then winner:=b.creator_id;wname:=b.creator_username;
  elsif js>cs then winner:=uid;wname:=uname;
  else winner:=null;wname:=null; end if;

  if winner is null then
    update public.beta_accounts set balance=balance+b.creator_total,updated_at=now() where id=b.creator_id;
    update public.beta_accounts set balance=balance+total,updated_at=now() where id=uid;
  else
    for r in select value from jsonb_array_elements(rewards) loop
      perform public.beta_inventory_add_safe(winner,r->>'pet_id','normal',1);
    end loop;
  end if;

  update public.beta_case_battles
  set joiner_id=uid,joiner_username=uname,joiner_cases=p_case_ids,joiner_total=total,
      creator_score=cs,joiner_score=js,winner_id=winner,winner_username=wname,status='finished',finished_at=now()
  where id=b.id;
  insert into public.beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description)
  values(coalesce(winner,uid),coalesce(wname,uname),'game_result','case_battle',cs+js,
    case when winner is null then 0 else cs+js-greatest(b.creator_total,total) end,
    case when winner is null then 'Case Battle draw' else 'Won Case Battle' end);
  return jsonb_build_object('ok',true,'status','finished','id',b.id,'creator_username',b.creator_username,'joiner_username',uname,'creator_score',cs,'joiner_score',js,'winner_id',winner,'winner_username',wname,'rewards',rewards,'draw',winner is null);
end; $$;
grant execute on function public.beta_join_case_battle(text,uuid,jsonb) to anon,authenticated;

-- ============================================================
-- 5) Admin Abuse / Global Drop realtime effects
-- ============================================================
create table if not exists public.beta_admin_effects (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references public.beta_accounts(id) on delete set null,
  actor_username text,
  effect_type text not null,
  target_page text not null default 'all',
  reward_amount bigint not null default 0,
  message text,
  created_at timestamptz not null default now()
);
create index if not exists beta_admin_effects_created_idx on public.beta_admin_effects(created_at desc);
alter table public.beta_admin_effects enable row level security;
drop policy if exists beta_admin_effects_read on public.beta_admin_effects;
create policy beta_admin_effects_read on public.beta_admin_effects for select to anon,authenticated using (true);
grant select on public.beta_admin_effects to anon,authenticated;

do $$
begin
  alter publication supabase_realtime add table public.beta_admin_effects;
exception when duplicate_object then null;
when undefined_object then null;
end $$;

create or replace function public.beta_admin_trigger_chaos(
  p_token text,p_effect_type text,p_target_page text default 'all',p_reward_amount bigint default 0,p_message text default ''
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; r text; aname text; reward bigint:=greatest(0,coalesce(p_reward_amount,0)); effect_id uuid;
  allowed_pages text[]:=array['all','home','coinflip','dice','inventory','profile','time-rewards','cases','case-battle','leaderboard','clans','giveaways','promo','admin'];
  allowed_effects text[]:=array['jackpot','coinstorm','dicefall','petstorm','caseburst','glitch','rainbow'];
begin
  select s.user_id,a.role,a.username into adminid,r,aname
  from public.beta_sessions s join public.beta_accounts a on a.id=s.user_id
  where s.token=p_token and s.expires_at>now();
  if adminid is null or r not in ('owner','co_owner','manager','admin','moderator') then raise exception 'Staff access required'; end if;
  if not (lower(coalesce(p_effect_type,'')) = any(allowed_effects)) then raise exception 'Invalid admin effect'; end if;
  if not (lower(coalesce(p_target_page,'')) = any(allowed_pages)) then raise exception 'Invalid target page'; end if;
  if reward>0 then
    update public.beta_accounts set balance=balance+reward,updated_at=now();
    insert into public.beta_activity(user_id,username,activity_type,amount,profit_loss,description)
    select id,username,'admin_drop',reward,reward,'Admin Abuse: '||coalesce(nullif(trim(p_message),''),p_effect_type)
    from public.beta_accounts;
  end if;
  insert into public.beta_admin_effects(actor_id,actor_username,effect_type,target_page,reward_amount,message)
  values(adminid,aname,lower(p_effect_type),lower(p_target_page),reward,nullif(trim(p_message),''))
  returning id into effect_id;
  return jsonb_build_object('ok',true,'id',effect_id,'effect_type',lower(p_effect_type),'target_page',lower(p_target_page),'reward_amount',reward,'message',coalesce(p_message,''));
end; $$;
grant execute on function public.beta_admin_trigger_chaos(text,text,text,bigint,text) to anon,authenticated;

notify pgrst,'reload schema';
commit;
