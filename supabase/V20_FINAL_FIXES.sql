-- SpinnyPet V20 FINAL FIXES
-- Run after V17/V18/V19. This patch is safe to re-run.

-- ============================================================
-- 1) CASE BATTLE: exact host bundle + server settlement
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
declare
  pool_size integer; t_slots integer:=0; g_slots integer:=0; h_slots integer:=0;
  slot integer; tier text; rid text; rname text; rvalue bigint; rthumb text; rcat text;
begin
  if p_case_id='basic' then pool_size:=5;t_slots:=1;h_slots:=4;
  elsif p_case_id='lucky' then pool_size:=5;t_slots:=2;h_slots:=3;
  elsif p_case_id='titan' then pool_size:=5;t_slots:=5;
  elsif p_case_id='cosmic' then pool_size:=6;t_slots:=3;g_slots:=1;h_slots:=2;
  elsif p_case_id='omega' then pool_size:=9;t_slots:=3;g_slots:=2;h_slots:=4;
  else raise exception 'Case not found'; end if;
  slot:=floor(random()*pool_size)::integer+1;
  tier:=case when slot<=t_slots then 'titanic' when slot<=t_slots+g_slots then 'gargantuan' else 'huge' end;
  select z.id,z.name,z.rap,z.thumbnail_url,z.category into rid,rname,rvalue,rthumb,rcat
  from (
    select p.*,
      case when lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %' then 'titanic'
           when lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %' then 'gargantuan'
           when lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %' then 'huge' end as reward_tier,
      row_number() over(partition by case when lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %' then 'titanic'
           when lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %' then 'gargantuan'
           when lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %' then 'huge' end order by coalesce(p.rap,0) desc,p.id) as rn
    from pets_cache p
    where coalesce(p.rap,0)>0
      and (lower(coalesce(p.category,'')) in ('huge','titanic','gargantuan')
           or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %')
  ) z
  where z.reward_tier=tier
    and z.rn<=case when tier='titanic' then t_slots when tier='gargantuan' then g_slots else h_slots end
  order by random() limit 1;
  if rid is null then raise exception 'No % rewards are available',tier; end if;
  return jsonb_build_object('pet_id',rid,'pet_name',rname,'pet_value',coalesce(rvalue,0),'pet_thumbnail_url',rthumb,'pet_category',rcat,'tier',tier);
end; $$;
revoke all on function public.beta_case_battle_pick_reward(text) from public;

drop function if exists public.beta_join_case_battle(text,uuid,jsonb);
create or replace function public.beta_join_case_battle(p_token text,p_battle_id uuid,p_case_ids jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; b beta_case_battles%rowtype; cid text; total bigint:=0;
  reward jsonb; rewards jsonb:='[]'::jsonb; cs bigint:=0; js bigint:=0;
  winner uuid; wname text; r jsonb; host_cases jsonb;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select * into b from beta_case_battles where id=p_battle_id and status='open' and creator_id<>uid for update;
  if b.id is null then raise exception 'Case Battle is no longer available'; end if;
  select username into uname from beta_accounts where id=uid;
  host_cases:=coalesce(b.creator_cases,'[]'::jsonb);
  if jsonb_typeof(host_cases)<>'array' or jsonb_array_length(host_cases)<1 or jsonb_array_length(host_cases)>5 then raise exception 'The host case bundle is invalid'; end if;
  select coalesce(sum(c.price),0) into total from beta_cases c where c.id in(select value from jsonb_array_elements_text(host_cases)) and c.active=true;
  if total<>b.creator_total then raise exception 'Case Battle wager is no longer valid'; end if;
  if total>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;

  update beta_accounts set balance=balance-total,updated_at=now() where id=uid;

  for cid in select value from jsonb_array_elements_text(host_cases) loop
    reward:=beta_case_battle_pick_reward(cid);
    cs:=cs+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','creator','case_id',cid)||reward);
  end loop;
  for cid in select value from jsonb_array_elements_text(host_cases) loop
    reward:=beta_case_battle_pick_reward(cid);
    js:=js+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','joiner','case_id',cid)||reward);
  end loop;

  if cs>js then winner:=b.creator_id;wname:=b.creator_username;
  elsif js>cs then winner:=uid;wname:=uname;
  else winner:=null;wname:=null; end if;

  if winner is null then
    update beta_accounts set balance=balance+b.creator_total,updated_at=now() where id=b.creator_id;
    update beta_accounts set balance=balance+total,updated_at=now() where id=uid;
  else
    for r in select value from jsonb_array_elements(rewards) loop
      perform beta_inventory_add_safe(winner,r->>'pet_id','normal',1);
    end loop;
  end if;

  update beta_case_battles set joiner_id=uid,joiner_username=uname,joiner_cases=host_cases,joiner_total=total,
    creator_score=cs,joiner_score=js,winner_id=winner,winner_username=wname,status='finished',finished_at=now()
  where id=b.id;

  if winner is not null then
    insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description)
    values(winner,wname,'game_result','case_battle',cs+js,(cs+js)-b.creator_total,'Won Case Battle');
  end if;

  return jsonb_build_object('ok',true,'status','finished','id',b.id,
    'creator_username',b.creator_username,'joiner_username',uname,
    'creator_cases',host_cases,'joiner_cases',host_cases,
    'creator_score',cs,'joiner_score',js,'winner_id',winner,'winner_username',wname,
    'rewards',rewards,'draw',winner is null);
end; $$;
grant execute on function public.beta_join_case_battle(text,uuid,jsonb) to anon,authenticated;

create or replace function public.beta_create_case_battle(p_token text,p_case_ids jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; cid text; total bigint:=0; bid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_case_ids,'[]'::jsonb))<>'array' or jsonb_array_length(p_case_ids)<1 or jsonb_array_length(p_case_ids)>5 then raise exception 'Choose 1 to 5 cases'; end if;
  for cid in select value from jsonb_array_elements_text(p_case_ids) loop
    if not exists(select 1 from beta_cases where id=cid and active=true) then raise exception 'Case % is unavailable',cid; end if;
  end loop;
  select coalesce(sum(c.price),0) into total from beta_cases c where c.id in(select value from jsonb_array_elements_text(p_case_ids)) and c.active=true;
  if total<=0 then raise exception 'Invalid Case Battle wager'; end if;
  if total>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems for this Case Battle'; end if;
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
declare uid uuid; out jsonb;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  select to_jsonb(b) into out from beta_case_battles b where b.id=p_battle_id;
  if out is null then raise exception 'Case Battle not found'; end if;
  return out;
end; $$;
grant execute on function public.beta_get_case_battle(text,uuid) to anon,authenticated;

-- ============================================================
-- 2) TIME REWARDS: always expose all five stages
-- ============================================================
create table if not exists public.beta_case_tickets (
  user_id uuid not null references public.beta_accounts(id) on delete cascade,
  case_id text not null references public.beta_cases(id) on delete cascade,
  quantity integer not null default 0 check(quantity>=0),
  updated_at timestamptz not null default now(),
  primary key(user_id,case_id)
);
alter table public.beta_case_tickets enable row level security;
drop policy if exists beta_case_tickets_read_own on public.beta_case_tickets;
create policy beta_case_tickets_read_own on public.beta_case_tickets for select to anon,authenticated using(true);
grant select on public.beta_case_tickets to anon,authenticated;

create table if not exists public.beta_time_reward_claims (
  user_id uuid not null references public.beta_accounts(id) on delete cascade,
  stage integer not null check(stage between 1 and 5),
  case_id text not null references public.beta_cases(id),
  claimed_at timestamptz not null default now(),
  primary key(user_id,stage)
);
alter table public.beta_time_reward_claims enable row level security;
drop policy if exists beta_time_reward_claims_read_own on public.beta_time_reward_claims;
create policy beta_time_reward_claims_read_own on public.beta_time_reward_claims for select to anon,authenticated using(true);
grant select on public.beta_time_reward_claims to anon,authenticated;

create or replace function public.beta_time_reward_config()
returns jsonb language sql immutable as $$
  select '[
    {"stage":1,"case_id":"basic","minutes":30},
    {"stage":2,"case_id":"lucky","minutes":60},
    {"stage":3,"case_id":"titan","minutes":120},
    {"stage":4,"case_id":"cosmic","minutes":240},
    {"stage":5,"case_id":"omega","minutes":480}
  ]'::jsonb;
$$;
revoke all on function public.beta_time_reward_config() from public;

create or replace function public.beta_get_time_rewards(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; last_claim timestamptz; row jsonb; out jsonb:='[]'::jsonb; claim_time timestamptz; unlock_at timestamptz; claimed boolean; available boolean; stage integer; case_id text; minutes integer;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  for row in select value from jsonb_array_elements(beta_time_reward_config()) loop
    stage:=(row->>'stage')::integer; case_id:=row->>'case_id'; minutes:=(row->>'minutes')::integer;
    select tr.claimed_at into claim_time from beta_time_reward_claims tr where tr.user_id=uid and tr.stage=stage;
    claimed:=claim_time is not null;
    if stage=1 then unlock_at:=now();
    else select tr.claimed_at into last_claim from beta_time_reward_claims tr where tr.user_id=uid and tr.stage=stage-1;
      if last_claim is null then unlock_at:=null; else unlock_at:=last_claim+(minutes * interval '1 minute'); end if;
    end if;
    available:=not claimed and unlock_at is not null and now()>=unlock_at;
    out:=out||jsonb_build_array(jsonb_build_object('stage',stage,'case_id',case_id,'minutes',minutes,'claimed',claimed,'claimed_at',claim_time,'unlock_at',unlock_at,'available',available,'remaining_seconds',case when available or unlock_at is null then 0 else greatest(0,ceil(extract(epoch from (unlock_at-now())))::integer) end));
  end loop;
  return out;
end; $$;
grant execute on function public.beta_get_time_rewards(text) to anon,authenticated;

create or replace function public.beta_get_time_tickets(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('case_id',case_id,'quantity',quantity) order by case_id) from beta_case_tickets where user_id=uid and quantity>0),'[]'::jsonb);
end; $$;
grant execute on function public.beta_get_time_tickets(text) to anon,authenticated;

create or replace function public.beta_claim_time_reward(p_token text,p_stage integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; cfg jsonb; case_id text; minutes integer; prior_claim timestamptz; bal bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  if p_stage<1 or p_stage>5 then raise exception 'Invalid reward stage'; end if;
  select value into cfg from jsonb_array_elements(beta_time_reward_config()) where (value->>'stage')::integer=p_stage;
  case_id:=cfg->>'case_id'; minutes:=(cfg->>'minutes')::integer;
  if exists(select 1 from beta_time_reward_claims where user_id=uid and stage=p_stage) then raise exception 'This time reward has already been claimed'; end if;
  if p_stage>1 then
    select claimed_at into prior_claim from beta_time_reward_claims where user_id=uid and stage=p_stage-1;
    if prior_claim is null then raise exception 'Unlock the previous time reward first'; end if;
    if now()<prior_claim+(minutes * interval '1 minute') then raise exception 'This reward is not unlocked yet'; end if;
  end if;
  select username into uname from beta_accounts where id=uid;
  insert into beta_time_reward_claims(user_id,stage,case_id) values(uid,p_stage,case_id);
  insert into beta_case_tickets(user_id,case_id,quantity,updated_at) values(uid,case_id,1,now()) on conflict(user_id,case_id) do update set quantity=beta_case_tickets.quantity+1,updated_at=now();
  select balance into bal from beta_accounts where id=uid;
  insert into beta_activity(user_id,username,activity_type,amount,description) values(uid,uname,'time_reward',0,'Time Reward: '||initcap(case_id)||' Case');
  return jsonb_build_object('ok',true,'stage',p_stage,'case_id',case_id,'case_name',initcap(case_id)||' Case','balance',bal,'message','Time reward unlocked: '||initcap(case_id)||' Case');
end; $$;
grant execute on function public.beta_claim_time_reward(text,integer) to anon,authenticated;

-- ============================================================
-- 3) CASE OPENING: exact five-slot reward pools, safe inventory
-- ============================================================
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
  select z.id,z.name,z.rap,z.thumbnail_url,z.category into pid,pname,pvalue,pthumb,pcat from (
    select p.*,case when lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %' then 'titanic' when lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %' then 'gargantuan' when lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %' then 'huge' end as reward_tier,
      row_number() over(partition by case when lower(coalesce(p.category,''))='titanic' or lower(p.name) like 'titanic %' then 'titanic' when lower(coalesce(p.category,''))='gargantuan' or lower(p.name) like 'gargantuan %' then 'gargantuan' when lower(coalesce(p.category,''))='huge' or lower(p.name) like 'huge %' then 'huge' end order by coalesce(p.rap,0) desc,p.id) as rn
    from pets_cache p where coalesce(p.rap,0)>0 and (lower(coalesce(p.category,'')) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %')
  ) z where z.reward_tier=tier and z.rn<=case when tier='titanic' then titanic_slots when tier='gargantuan' then garg_slots else huge_slots end order by random() limit 1;
  if pid is null then update beta_accounts set balance=balance+c.price,updated_at=now() where id=uid; raise exception 'No % rewards are available for this case yet',tier; end if;
  reward_value:=pvalue; perform beta_inventory_add_safe(uid,pid,'normal',1);
  insert into beta_case_openings(user_id,username,case_id,case_price,reward_type,reward_amount,reward_pet_id,reward_pet_name,reward_pet_value) values(uid,uname,c.id,c.price,'pet',0,pid,pname,reward_value);
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description) values(uid,uname,'case_opened',c.price,reward_value-c.price,'Opened '||c.name||': '||pname);
  return jsonb_build_object('ok',true,'case_id',c.id,'case_name',c.name,'price',c.price,'reward_type','pet','reward_amount',0,'reward_pet_id',pid,'reward_pet_name',pname,'reward_pet_value',reward_value,'reward_pet_thumbnail_url',pthumb,'reward_pet_category',pcat,'balance',bal);
end; $$;
grant execute on function public.beta_open_case(text,text) to anon,authenticated;

-- ============================================================
-- 4) LIVE BETS: corrected UNION column count + negative losses
-- ============================================================
create or replace function public.beta_live_bets()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
  from (
    select l.id::text as id,l.game_type,
      case when l.game_type='coinflip' then 'Coinflip' else 'Color Dice' end as game_label,
      l.creator_username as username,
      coalesce(l.choice,'') as choice,
      l.stake_amount as bet,
      case when l.status='finished' then case when l.payout>0 then greatest(0,l.payout)::numeric/greatest(1,l.stake_amount)::numeric else 0 end else 2.0::numeric end as multiplier,
      case when l.status='finished' and l.payout>0 then l.payout else l.stake_amount*2 end as payout,
      case when l.status='finished' then 'FINISHED' else 'OPEN' end as status_label,
      l.created_at
    from beta_game_lobbies l
    where l.game_type in ('coinflip','dice') and (l.status='open' or l.created_at>now()-interval '30 minutes')
    union all
    select a.id::text,'upgrader','Upgrader',a.username,''::text,
      a.amount as bet,
      case when a.profit_loss<0 then 0::numeric when a.amount>0 then greatest(0,a.amount+a.profit_loss)::numeric/a.amount else 0 end as multiplier,
      case when a.profit_loss<0 then -a.amount else greatest(0,a.amount+a.profit_loss) end as payout,
      case when a.profit_loss>=0 then 'WON' else 'LOST' end as status_label,
      a.created_at
    from beta_activity a
    where a.activity_type='upgrade_result' and a.created_at>now()-interval '30 minutes'
  ) x;
$$;
grant execute on function public.beta_live_bets() to anon,authenticated;

notify pgrst,'reload schema';
