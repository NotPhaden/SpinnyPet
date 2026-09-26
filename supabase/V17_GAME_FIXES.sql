-- SpinnyPet V17 gameplay fixes
-- Run this AFTER SUPABASE_SPINNYPET_V16_COMPLETE_FIXED.sql

begin;

-- ============================================================
-- 1) Color Dice: independent colors + server-side settlement
-- ============================================================
alter table public.beta_game_lobbies add column if not exists join_choice text;
alter table public.beta_game_lobbies add column if not exists creator_avatar_url text;

-- The old schema allowed only the legacy game names. Replace only the game_type check.
do $$
declare r record;
begin
  for r in
    select c.conname
    from pg_constraint c
    where c.conrelid='public.beta_game_lobbies'::regclass
      and c.contype='c'
      and pg_get_constraintdef(c.oid) ilike '%game_type%'
  loop
    execute format('alter table public.beta_game_lobbies drop constraint if exists %I', r.conname);
  end loop;
end $$;

alter table public.beta_game_lobbies
  add constraint beta_game_lobbies_game_type_check
  check (game_type in ('coinflip','dice','jackpot','blackjack'));

create or replace function public.beta_create_lobby_v2(
  p_token text,p_game_type text,p_stake_type text,p_stake_amount bigint,
  p_pet_items jsonb,p_choice text
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; avatar text; lid uuid; item jsonb; pid text; v text; qty integer;
  total bigint:=0; count_items integer:=0; first_id text; first_name text; first_variant text;
  pv bigint; pcat text; choice text:=trim(coalesce(p_choice,''));
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username,coalesce(custom_avatar_url,avatar_url) into uname,avatar from beta_accounts where id=uid;
  if p_game_type not in ('coinflip','dice') then raise exception 'Unsupported match game'; end if;
  if p_stake_type not in ('diamonds','pet') then raise exception 'Invalid stake type'; end if;
  if p_game_type='coinflip' then
    if choice not in ('Heads','Tails') then raise exception 'Choose Heads or Tails'; end if;
  else
    if array_length(string_to_array(choice,','),1) <> 2 then raise exception 'Choose exactly 2 colors'; end if;
    if choice !~ '^(Red|Orange|Yellow|Green|Blue|Purple),(Red|Orange|Yellow|Green|Blue|Purple)$' then raise exception 'Invalid dice colors'; end if;
    if split_part(choice,',',1)=split_part(choice,',',2) then raise exception 'Choose two different colors'; end if;
  end if;

  if p_stake_type='diamonds' then
    if coalesce(p_stake_amount,0)<case when p_game_type='coinflip' then 10000000 else 5000000000 end then raise exception using message=(case when p_game_type='coinflip' then 'Coinflip requires at least 10M gems' else 'Color Dice requires at least 5B gems' end); end if;
    if p_stake_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
    update beta_accounts set balance=balance-p_stake_amount,updated_at=now() where id=uid;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,creator_avatar_url,stake_type,stake_amount,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,avatar,'diamonds',p_stake_amount,0,'[]'::jsonb,choice) returning id into lid;
  else
    if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select at least one pet'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
      if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
      select coalesce(rap,0),name,category into pv,first_name,pcat from pets_cache where id=pid;
      if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
      if p_game_type='coinflip' then
        if lower(coalesce(pcat,'')) not in ('titanic','gargantuan') and lower(coalesce(first_name,'')) !~ '^(titanic|gargantuan) ' then raise exception 'Coinflip accepts only Titanic and Gargantuan pets'; end if;
      else
        if lower(coalesce(pcat,'')) not in ('huge','titanic','gargantuan') and lower(coalesce(first_name,'')) !~ '^(huge|titanic|gargantuan) ' then raise exception 'Color Dice accepts Huge, Titanic or Gargantuan pets'; end if;
      end if;
      total:=total+pv*qty; count_items:=count_items+qty; if first_id is null then first_id:=pid; first_variant:=v; end if;
    end loop;
    if total<case when p_game_type='coinflip' then 10000000 else 5000000000 end then raise exception using message=(case when p_game_type='coinflip' then 'Coinflip requires at least 10M value' else 'Color Dice pet wagers require at least 5B value' end); end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
    end loop;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,creator_avatar_url,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,avatar,'pet',total,first_id,first_name,first_variant,count_items,p_pet_items,choice) returning id into lid;
  end if;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,description)
  values(uid,uname,'game_created',p_game_type,case when p_stake_type='pet' then total else p_stake_amount end,'Created a '||p_game_type||' game');
  return jsonb_build_object('ok',true,'id',lid,'status','open','stake_amount',case when p_stake_type='pet' then total else p_stake_amount end,'pet_count',count_items,'choice',choice);
end; $$;
grant execute on function public.beta_create_lobby_v2(text,text,text,bigint,jsonb,text) to anon,authenticated;

create or replace function public.beta_join_lobby_v2(
  p_token text,p_lobby_id uuid,p_pet_items jsonb default '[]'::jsonb,p_choice text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; lid uuid; host_id uuid; host_name text; gtype text; st text; amt bigint;
  host_choice text; host_items jsonb; host_avatar text; join_choice text:=trim(coalesce(p_choice,''));
  item jsonb; pid text; v text; qty integer; total bigint:=0; pv bigint; first_name text; pcat text;
  winner uuid; wname text; payout_value bigint:=0; roll_color text; host_has boolean; join_has boolean;
  i integer; host_refund bigint; join_refund bigint; bal bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select id,creator_id,creator_username,game_type,stake_type,stake_amount,choice,stake_pet_items,creator_avatar_url
    into lid,host_id,host_name,gtype,st,amt,host_choice,host_items,host_avatar
  from beta_game_lobbies where id=p_lobby_id and status='open' and creator_id<>uid for update;
  if lid is null then raise exception 'Game is no longer available'; end if;
  select username into uname from beta_accounts where id=uid;
  if gtype='coinflip' then
    -- Keep the 4-argument RPC compatible with Coinflip as well as Color Dice.
    if st='diamonds' then
      if amt<10000000 or amt>(select balance from beta_accounts where id=uid) then raise exception 'You do not have enough gems to join'; end if;
      update beta_accounts set balance=balance-amt,updated_at=now() where id=uid;
      payout_value:=amt*2;
    else
      if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select one or more pets to join'; end if;
      for item in select value from jsonb_array_elements(p_pet_items) loop
        pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
        if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
        if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
        select coalesce(rap,0),category,name into pv,pcat,first_name from pets_cache where id=pid;
        if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
        if lower(coalesce(pcat,'')) not in ('titanic','gargantuan') and lower(coalesce(first_name,'')) !~ '^(titanic|gargantuan) ' then raise exception 'Coinflip accepts only Titanic and Gargantuan pets'; end if;
        total:=total+pv*qty;
      end loop;
      if total<amt then raise exception using message='Your pet bundle must be worth at least '||amt||' gems'; end if;
      for item in select value from jsonb_array_elements(p_pet_items) loop
        pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
        update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
        delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
      end loop;
      payout_value:=amt+total;
    end if;
    if random()<0.5 then winner:=host_id;wname:=host_name;roll_color:=host_choice;else winner:=uid;wname:=uname;roll_color:=case when host_choice='Heads' then 'Tails' else 'Heads' end;end if;
    if st='diamonds' then
      update beta_accounts set balance=balance+payout_value,updated_at=now() where id=winner;
    else
      for item in select value from jsonb_array_elements(coalesce(host_items,'[]'::jsonb)) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(winner,pid,v,qty);end loop;
      for item in select value from jsonb_array_elements(coalesce(p_pet_items,'[]'::jsonb)) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(winner,pid,v,qty);end loop;
    end if;
    update beta_game_lobbies set status='finished',join_pet_items=coalesce(p_pet_items,'[]'::jsonb),result_side=roll_color,winner_id=winner,winner_username=wname,payout=payout_value where id=lid;
    insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description) values(winner,wname,'game_result','coinflip',payout_value,payout_value-amt,'Won Coinflip: '||roll_color);
    return jsonb_build_object('ok',true,'status','finished','lobby_id',lid,'winner_id',winner,'winner_username',wname,'winner_side',roll_color,'result_side',roll_color,'payout',payout_value);
  end if;
  if gtype<>'dice' then raise exception 'Unsupported match game'; end if;
  if array_length(string_to_array(join_choice,','),1) <> 2 then raise exception 'Choose exactly 2 colors'; end if;
  if join_choice !~ '^(Red|Orange|Yellow|Green|Blue|Purple),(Red|Orange|Yellow|Green|Blue|Purple)$' then raise exception 'Invalid dice colors'; end if;
  if split_part(join_choice,',',1)=split_part(join_choice,',',2) then raise exception 'Choose two different colors'; end if;

  if st='diamonds' then
    if amt<5000000000 or amt>(select balance from beta_accounts where id=uid) then raise exception 'Color Dice requires exactly the host wager in gems'; end if;
    update beta_accounts set balance=balance-amt,updated_at=now() where id=uid;
    payout_value:=amt*2;
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
    if total<amt then raise exception using message='Your pet bundle must be worth at least '||amt||' gems'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
    end loop;
    payout_value:=amt+total;
  end if;

  -- Roll until exactly one side owns the rolled color. This avoids invisible "no winner" rolls.
  for i in 1..30 loop
    roll_color:=(array['Red','Orange','Yellow','Green','Blue','Purple'])[floor(random()*6)::integer+1];
    host_has:=roll_color=any(string_to_array(host_choice,','));
    join_has:=roll_color=any(string_to_array(join_choice,','));
    exit when host_has is distinct from join_has;
  end loop;

  if host_has and not join_has then
    winner:=host_id;wname:=host_name;
  elsif join_has and not host_has then
    winner:=uid;wname:=uname;
  else
    -- Extremely unlikely fallback: refund both stakes as a draw.
    winner:=null;wname:=null;
  end if;

  if winner is null then
    if st='diamonds' then
      update beta_accounts set balance=balance+amt,updated_at=now() where id=host_id;
      update beta_accounts set balance=balance+amt,updated_at=now() where id=uid;
    else
      for item in select value from jsonb_array_elements(coalesce(host_items,'[]'::jsonb)) loop
        pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(host_id,pid,v,qty);
      end loop;
      for item in select value from jsonb_array_elements(coalesce(p_pet_items,'[]'::jsonb)) loop
        pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(uid,pid,v,qty);
      end loop;
    end if;
    update beta_game_lobbies set status='finished',join_pet_items=coalesce(p_pet_items,'[]'::jsonb),join_choice=join_choice,result_side=roll_color,winner_id=null,winner_username=null,payout=0 where id=lid;
    return jsonb_build_object('ok',true,'status','finished','lobby_id',lid,'choice',host_choice,'join_choice',join_choice,'result_side',roll_color,'winner_id',null,'winner_username',null,'payout',0,'draw',true);
  end if;

  if st='diamonds' then
    update beta_accounts set balance=balance+payout_value,updated_at=now() where id=winner returning balance into bal;
  else
    for item in select value from jsonb_array_elements(coalesce(host_items,'[]'::jsonb)) loop
      pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(winner,pid,v,qty);
    end loop;
    for item in select value from jsonb_array_elements(coalesce(p_pet_items,'[]'::jsonb)) loop
      pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(winner,pid,v,qty);
    end loop;
  end if;
  update beta_game_lobbies set status='finished',join_pet_items=coalesce(p_pet_items,'[]'::jsonb),join_choice=join_choice,result_side=roll_color,winner_id=winner,winner_username=wname,payout=payout_value where id=lid;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description)
  values(winner,wname,'game_result','dice',payout_value,payout_value-amt,'Won Color Dice on '||roll_color);
  return jsonb_build_object('ok',true,'status','finished','lobby_id',lid,'choice',host_choice,'join_choice',join_choice,'result_side',roll_color,'winner_id',winner,'winner_username',wname,'payout',payout_value);
end; $$;
grant execute on function public.beta_join_lobby_v2(text,uuid,jsonb,text) to anon,authenticated;

-- Keep profile pictures on already-created live matches in sync.
update public.beta_game_lobbies l set creator_avatar_url=coalesce(a.custom_avatar_url,a.avatar_url) from public.beta_accounts a where a.id=l.creator_id and l.status='open';

create or replace function public.beta_sync_lobby_avatar()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.custom_avatar_url is distinct from old.custom_avatar_url or new.avatar_url is distinct from old.avatar_url then
    update beta_game_lobbies
      set creator_avatar_url=coalesce(new.custom_avatar_url,new.avatar_url)
    where creator_id=new.id and status='open';
  end if;
  return new;
end; $$;
drop trigger if exists beta_sync_lobby_avatar_trigger on public.beta_accounts;
create trigger beta_sync_lobby_avatar_trigger
after update of custom_avatar_url,avatar_url on public.beta_accounts
for each row execute function public.beta_sync_lobby_avatar();

-- ============================================================
-- 2) Case Battle
-- ============================================================
create table if not exists public.beta_case_battles (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.beta_accounts(id) on delete cascade,
  creator_username text not null,
  creator_cases jsonb not null default '[]'::jsonb,
  creator_total bigint not null default 0,
  joiner_id uuid references public.beta_accounts(id) on delete set null,
  joiner_username text,
  joiner_cases jsonb not null default '[]'::jsonb,
  joiner_total bigint not null default 0,
  creator_score bigint not null default 0,
  joiner_score bigint not null default 0,
  winner_id uuid,
  winner_username text,
  status text not null default 'open' check(status in ('open','finished','cancelled')),
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
alter table public.beta_case_battles enable row level security;
drop policy if exists beta_case_battles_read on public.beta_case_battles;
create policy beta_case_battles_read on public.beta_case_battles for select to anon,authenticated using (true);
grant select on public.beta_case_battles to anon,authenticated;
create index if not exists beta_case_battles_open_idx on public.beta_case_battles(status,created_at desc);

create or replace function public.beta_case_battle_pick_reward(p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare pool_size integer; t_slots integer:=0;g_slots integer:=0;h_slots integer:=0;slot integer;tier text;rid text;rname text;rvalue bigint;rn integer;
begin
  if p_case_id='basic' then pool_size:=5;t_slots:=1;h_slots:=4;
  elsif p_case_id='lucky' then pool_size:=5;t_slots:=2;h_slots:=3;
  elsif p_case_id='titan' then pool_size:=5;t_slots:=5;
  elsif p_case_id='cosmic' then pool_size:=6;t_slots:=3;g_slots:=1;h_slots:=2;
  elsif p_case_id='omega' then pool_size:=9;t_slots:=3;g_slots:=2;h_slots:=4;
  else raise exception 'Case not found'; end if;
  slot:=floor(random()*pool_size)::integer+1;
  tier:=case when slot<=t_slots then 'titanic' when slot<=t_slots+g_slots then 'gargantuan' else 'huge' end;
  select z.id,z.name,z.rap,z.rn into rid,rname,rvalue,rn from (
    select p.id,p.name,coalesce(p.rap,0) rap,
      row_number() over(partition by case when lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %' then 'titanic' when lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %' then 'gargantuan' when lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %' then 'huge' end order by coalesce(p.rap,0) desc,p.id) rn,
      case when lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %' then 'titanic' when lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %' then 'gargantuan' when lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %' then 'huge' end reward_tier
    from pets_cache p
    where coalesce(p.rap,0)>0 and (lower(coalesce(p.category,'')) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %')
  ) z
  where z.reward_tier=tier and z.rn<=case when tier='titanic' then t_slots when tier='gargantuan' then g_slots else h_slots end
  order by random() limit 1;
  if rid is null then raise exception 'No % rewards are available',tier; end if;
  return jsonb_build_object('pet_id',rid,'pet_name',rname,'pet_value',rvalue,'tier',tier);
end; $$;
revoke all on function public.beta_case_battle_pick_reward(text) from public;

create or replace function public.beta_create_case_battle(p_token text,p_case_ids jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;uname text;ids text[];cid text;total bigint:=0;cnt integer:=0;bid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();if uid is null then raise exception 'Please sign in';end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_case_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid case selection';end if;
  if jsonb_array_length(p_case_ids)<1 or jsonb_array_length(p_case_ids)>5 then raise exception 'Choose 1 to 5 cases';end if;
  for cid in select value from jsonb_array_elements_text(p_case_ids) loop
    if not exists(select 1 from beta_cases where id=cid and active=true) then raise exception 'Case % is unavailable',cid;end if;
    select price into total from beta_cases where id=cid;
    cnt:=cnt+1;
  end loop;
  select coalesce(sum(c.price),0) into total from beta_cases c where c.id in(select value from jsonb_array_elements_text(p_case_ids));
  if total<=0 or total>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems for this Case Battle';end if;
  update beta_accounts set balance=balance-total,updated_at=now() where id=uid;
  insert into beta_case_battles(creator_id,creator_username,creator_cases,creator_total) values(uid,uname,p_case_ids,total) returning id into bid;
  return jsonb_build_object('ok',true,'id',bid,'status','open','creator_total',total,'creator_cases',p_case_ids);
end; $$;
grant execute on function public.beta_create_case_battle(text,jsonb) to anon,authenticated;

create or replace function public.beta_list_case_battles()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'creator_id',b.creator_id,'creator_username',b.creator_username,'creator_cases',b.creator_cases,'creator_total',b.creator_total,'status',b.status,'created_at',b.created_at) order by b.created_at desc),'[]'::jsonb)
  from beta_case_battles b where b.status='open';
$$;
grant execute on function public.beta_list_case_battles() to anon,authenticated;

create or replace function public.beta_get_case_battle(p_token text,p_battle_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;out jsonb;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  select to_jsonb(b) into out from beta_case_battles b where b.id=p_battle_id;
  if out is null then raise exception 'Case Battle not found';end if;
  return out;
end; $$;
grant execute on function public.beta_get_case_battle(text,uuid) to anon,authenticated;

create or replace function public.beta_join_case_battle(p_token text,p_battle_id uuid,p_case_ids jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;uname text; b beta_case_battles%rowtype; cid text;total bigint:=0; reward jsonb; rewards jsonb:='[]'::jsonb;creator_reward jsonb;join_reward jsonb;cs bigint:=0;js bigint:=0;winner uuid;wname text;r jsonb;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();if uid is null then raise exception 'Please sign in';end if;
  select * into b from beta_case_battles where id=p_battle_id and status='open' and creator_id<>uid for update;
  if b.id is null then raise exception 'Case Battle is no longer available';end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_case_ids,'[]'::jsonb))<>'array' or jsonb_array_length(p_case_ids)<1 or jsonb_array_length(p_case_ids)>5 then raise exception 'Choose 1 to 5 cases';end if;
  select coalesce(sum(c.price),0) into total from beta_cases c where c.id in(select value from jsonb_array_elements_text(p_case_ids)) and c.active=true;
  if total<>b.creator_total then raise exception 'Your cases must total exactly % gems',b.creator_total;end if;
  if total>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems';end if;
  update beta_accounts set balance=balance-total,updated_at=now() where id=uid;

  for cid in select value from jsonb_array_elements_text(b.creator_cases) loop
    reward:=beta_case_battle_pick_reward(cid);cs:=cs+coalesce((reward->>'pet_value')::bigint,0);rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','creator','case_id',cid)||reward);
  end loop;
  for cid in select value from jsonb_array_elements_text(p_case_ids) loop
    reward:=beta_case_battle_pick_reward(cid);js:=js+coalesce((reward->>'pet_value')::bigint,0);rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','joiner','case_id',cid)||reward);
  end loop;

  if cs>js then winner:=b.creator_id;wname:=b.creator_username;elsif js>cs then winner:=uid;wname:=uname;else winner:=null;wname:=null;end if;
  if winner is null then
    update beta_accounts set balance=balance+b.creator_total,updated_at=now() where id=b.creator_id;
    update beta_accounts set balance=balance+total,updated_at=now() where id=uid;
  else
    for r in select value from jsonb_array_elements(rewards) loop
      perform beta_inventory_add_safe(winner,r->>'pet_id','normal',1);
    end loop;
  end if;
  update beta_case_battles set joiner_id=uid,joiner_username=uname,joiner_cases=p_case_ids,joiner_total=total,creator_score=cs,joiner_score=js,winner_id=winner,winner_username=wname,status='finished',finished_at=now() where id=b.id;
  if winner is not null then
    insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description) values(winner,wname,'game_result','case_battle',cs+js,cs+js-greatest(b.creator_total,total),'Won Case Battle');
  end if;
  return jsonb_build_object('ok',true,'status','finished','id',b.id,'creator_username',b.creator_username,'joiner_username',uname,'creator_score',cs,'joiner_score',js,'winner_id',winner,'winner_username',wname,'rewards',rewards,'draw',winner is null);
end; $$;
grant execute on function public.beta_join_case_battle(text,uuid,jsonb) to anon,authenticated;

-- ============================================================
-- 3) Upgrader: explicit safe result + inventory behavior
-- ============================================================
create or replace function public.beta_run_upgrade_v3(
  p_token text,p_input_pet_items jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb,p_risk_angle numeric default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;uname text;diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0));input_value bigint:=0;target_value bigint:=0;chance numeric;won boolean;result_id text;result_name text;a beta_accounts%rowtype;item jsonb;pid text;v text;qty integer;chosen_value bigint;risk_angle numeric:=mod(coalesce(p_risk_angle,0)+360,360);win_angle numeric;roll_angle numeric;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();if uid is null then raise exception 'Please sign in';end if;select username into uname from beta_accounts where id=uid for update;
  if jsonb_typeof(coalesce(p_input_pet_items,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection';end if;
  if jsonb_array_length(coalesce(p_input_pet_items,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems';end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target';end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems';end if;
  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id');v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid selected pet';end if;
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'One selected pet variant is no longer in your inventory';end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP';end if;input_value:=input_value+chosen_value*qty;
  end loop;
  input_value:=input_value+diamond_amount;
  select coalesce(sum(coalesce(rap,0)),0) into target_value from pets_cache where id in(select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0;if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.';end if;
  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));win_angle:=chance*3.6;roll_angle:=random()*360;
  won:=case when risk_angle+win_angle<=360 then roll_angle between risk_angle and risk_angle+win_angle else roll_angle>=risk_angle or roll_angle<=risk_angle+win_angle-360 end;

  -- Consume the exact input only after all validation has passed.
  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id');v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
    delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
  end loop;
  if diamond_amount>0 then update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid;end if;

  if won then
    select id,name into result_id,result_name from pets_cache where id in(select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0 order by random() limit 1;
    if result_id is null then raise exception 'No valid target reward was found';end if;
    perform beta_inventory_add_safe(uid,result_id,'normal',1);
  end if;
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description) values(uid,uname,'upgrade_result',input_value,case when won then greatest(0,target_value-input_value) else -input_value end,case when won then 'Won an upgrade: '||result_name else 'Lost an upgrade' end);
  select * into a from beta_accounts where id=uid;
  return jsonb_build_object('won',won,'chance',chance,'input_value',input_value,'target_value',target_value,'result_id',result_id,'result_name',result_name,'balance',a.balance,'risk_angle',risk_angle,'roll_angle',roll_angle,'inventory_consumed',true,'inventory_awarded',won);
end; $$;
grant execute on function public.beta_run_upgrade_v3(text,jsonb,bigint,jsonb,numeric) to anon,authenticated;

-- ============================================================
-- 4) Admin Give All: empty target means the logged-in admin
-- ============================================================
create or replace function public.beta_admin_give_all(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid;tid uuid;n integer;target_name text:=trim(coalesce(p_target_username,''));
begin
  adminid:=beta_admin_assert(p_token);
  if target_name='' then select username into target_name from beta_accounts where id=adminid;end if;
  select id into tid from beta_accounts where lower(username)=lower(target_name);
  if tid is null then raise exception 'User not found';end if;
  select count(*) into n from pets_cache p where lower(coalesce(p.category,'')) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %';
  if n=0 then raise exception 'High-tier catalog is empty. Run the pet sync first.';end if;
  insert into beta_inventory(user_id,pet_id,variant,quantity)
  select tid,p.id,'normal',1 from pets_cache p where lower(coalesce(p.category,'')) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %'
  on conflict(user_id,pet_id,variant) do update set quantity=greatest(beta_inventory.quantity,1),updated_at=now();
  return jsonb_build_object('ok',true,'username',target_name,'count',n);
end; $$;
grant execute on function public.beta_admin_give_all(text,text) to anon,authenticated;

notify pgrst,'reload schema';
commit;
