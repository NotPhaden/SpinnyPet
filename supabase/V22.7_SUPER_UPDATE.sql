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
