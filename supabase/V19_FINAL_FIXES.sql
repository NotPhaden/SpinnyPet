-- SpinnyPet V19 FINAL GAME + UI FIXES
-- Run after the working V18 patch.
-- This patch is intentionally incremental and does not require reinstalling the full schema.

-- ============================================================
-- 1) CASE BATTLE: join uses the EXACT cases chosen by the host.
--    The joiner never selects a second bundle. They pay the same
--    diamond wager and both sides open the host's case bundle.
-- ============================================================
create or replace function public.beta_join_case_battle(
  p_token text,
  p_battle_id uuid,
  p_case_ids jsonb default '[]'::jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; b beta_case_battles%rowtype;
  cid text; total bigint:=0; reward jsonb; rewards jsonb:='[]'::jsonb;
  cs bigint:=0; js bigint:=0; winner uuid; wname text; r jsonb;
  join_cases jsonb;
begin
  select user_id into uid
  from beta_sessions
  where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;

  select * into b
  from beta_case_battles
  where id=p_battle_id and status='open' and creator_id<>uid
  for update;
  if b.id is null then raise exception 'Case Battle is no longer available'; end if;

  select username into uname from beta_accounts where id=uid;
  join_cases:=coalesce(b.creator_cases,'[]'::jsonb);

  if jsonb_typeof(join_cases)<>'array'
     or jsonb_array_length(join_cases)<1
     or jsonb_array_length(join_cases)>5 then
    raise exception 'The host case bundle is invalid';
  end if;

  select coalesce(sum(c.price),0)
    into total
  from beta_cases c
  where c.id in(select value from jsonb_array_elements_text(join_cases))
    and c.active=true;

  if total<>b.creator_total then
    raise exception 'Case Battle wager is no longer valid';
  end if;
  if total>(select balance from beta_accounts where id=uid) then
    raise exception 'Not enough gems';
  end if;

  update beta_accounts
    set balance=balance-total,updated_at=now()
    where id=uid;

  -- Open the exact same case sequence for both players.
  for cid in select value from jsonb_array_elements_text(b.creator_cases) loop
    reward:=beta_case_battle_pick_reward(cid);
    cs:=cs+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(
      jsonb_build_object('owner','creator','case_id',cid)||reward
    );
  end loop;

  for cid in select value from jsonb_array_elements_text(join_cases) loop
    reward:=beta_case_battle_pick_reward(cid);
    js:=js+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(
      jsonb_build_object('owner','joiner','case_id',cid)||reward
    );
  end loop;

  if cs>js then
    winner:=b.creator_id; wname:=b.creator_username;
  elsif js>cs then
    winner:=uid; wname:=uname;
  else
    winner:=null; wname:=null;
  end if;

  if winner is null then
    update beta_accounts set balance=balance+b.creator_total,updated_at=now() where id=b.creator_id;
    update beta_accounts set balance=balance+total,updated_at=now() where id=uid;
  else
    for r in select value from jsonb_array_elements(rewards) loop
      perform beta_inventory_add_safe(winner,r->>'pet_id','normal',1);
    end loop;
  end if;

  update beta_case_battles
  set joiner_id=uid,
      joiner_username=uname,
      joiner_cases=join_cases,
      joiner_total=total,
      creator_score=cs,
      joiner_score=js,
      winner_id=winner,
      winner_username=wname,
      status='finished',
      finished_at=now()
  where id=b.id;

  insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description)
  values(
    case when winner is null then uid else winner end,
    case when winner is null then uname else wname end,
    'game_result','case_battle',cs+js,
    case when winner is null then 0 else (cs+js)-b.creator_total end,
    case when winner is null then 'Case Battle draw' else 'Won Case Battle' end
  );

  return jsonb_build_object(
    'ok',true,'status','finished','id',b.id,
    'creator_username',b.creator_username,'joiner_username',uname,
    'creator_cases',b.creator_cases,'joiner_cases',join_cases,
    'creator_score',cs,'joiner_score',js,
    'winner_id',winner,'winner_username',wname,
    'rewards',rewards,'draw',winner is null
  );
end; $$;
grant execute on function public.beta_join_case_battle(text,uuid,jsonb) to anon,authenticated;

-- ============================================================
-- 2) CASE TICKETS / TIME REWARDS
--    1 free case per stage. Stage 2 unlocks only after stage 1
--    has been claimed, etc.
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
create policy beta_case_tickets_read_own on public.beta_case_tickets
  for select to anon,authenticated using(true);
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
create policy beta_time_reward_claims_read_own on public.beta_time_reward_claims
  for select to anon,authenticated using(true);
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
declare
  uid uuid; last_claim timestamptz; stage integer; row jsonb; out jsonb:='[]'::jsonb;
  claim_time timestamptz; unlock_at timestamptz; claimed boolean; available boolean;
  minutes integer; case_id text;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;

  for row in select value from jsonb_array_elements(beta_time_reward_config()) loop
    stage:=(row->>'stage')::integer;
    case_id:=row->>'case_id';
    minutes:=(row->>'minutes')::integer;
    select tr.claimed_at into claim_time from beta_time_reward_claims tr where tr.user_id=uid and tr.stage=stage;
    claimed:=claim_time is not null;

    if stage=1 then
      unlock_at:=now();
    else
      select tr.claimed_at into last_claim from beta_time_reward_claims tr where tr.user_id=uid and tr.stage=stage-1;
      if last_claim is null then unlock_at:=null; else unlock_at:=last_claim+(minutes * interval '1 minute'); end if;
    end if;

    available:=not claimed and unlock_at is not null and now()>=unlock_at;
    out:=out||jsonb_build_array(jsonb_build_object(
      'stage',stage,'case_id',case_id,'minutes',minutes,
      'claimed',claimed,'claimed_at',claim_time,
      'unlock_at',unlock_at,'available',available,
      'remaining_seconds',case when available or unlock_at is null then 0 else greatest(0,ceil(extract(epoch from (unlock_at-now())))::integer) end
    ));
  end loop;
  return out;
end; $$;
grant execute on function public.beta_get_time_rewards(text) to anon,authenticated;

create or replace function public.beta_get_time_tickets(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('case_id',case_id,'quantity',quantity) order by case_id) from beta_case_tickets where user_id=uid and quantity>0),'[]'::jsonb);
end; $$;
grant execute on function public.beta_get_time_tickets(text) to anon,authenticated;

create or replace function public.beta_claim_time_reward(p_token text,p_stage integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; cfg jsonb; case_id text; minutes integer;
  prior_claim timestamptz; bal bigint; ticket_qty integer;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  if p_stage<1 or p_stage>5 then raise exception 'Invalid reward stage'; end if;

  select value into cfg from jsonb_array_elements(beta_time_reward_config()) where (value->>'stage')::integer=p_stage;
  case_id:=cfg->>'case_id'; minutes:=(cfg->>'minutes')::integer;
  if case_id is null then raise exception 'Reward stage not found'; end if;
  if exists(select 1 from beta_time_reward_claims where user_id=uid and stage=p_stage) then
    raise exception 'This time reward has already been claimed';
  end if;

  if p_stage>1 then
    select claimed_at into prior_claim from beta_time_reward_claims where user_id=uid and stage=p_stage-1;
    if prior_claim is null then raise exception 'Unlock the previous time reward first'; end if;
    if now()<prior_claim+(minutes * interval '1 minute') then
      raise exception 'This reward is not unlocked yet';
    end if;
  end if;

  select username into uname from beta_accounts where id=uid;
  insert into beta_time_reward_claims(user_id,stage,case_id) values(uid,p_stage,case_id);
  insert into beta_case_tickets(user_id,case_id,quantity,updated_at)
  values(uid,case_id,1,now())
  on conflict(user_id,case_id) do update set quantity=beta_case_tickets.quantity+1,updated_at=now();
  select balance into bal from beta_accounts where id=uid;
  insert into beta_activity(user_id,username,activity_type,amount,description)
  values(uid,uname,'time_reward',0,'Time Reward: '||initcap(case_id)||' Case');

  return jsonb_build_object('ok',true,'stage',p_stage,'case_id',case_id,'case_name',initcap(case_id)||' Case','balance',bal,'message','Time reward unlocked: '||initcap(case_id)||' Case');
end; $$;
grant execute on function public.beta_claim_time_reward(text,integer) to anon,authenticated;

-- Helper used by free-ticket openings. Same exact 5-case reward composition.
create or replace function public.beta_pick_case_reward_v19(p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare pool_size integer; t integer:=0; g integer:=0; h integer:=0; slot integer; tier text;
  rid text; rname text; rvalue bigint; rthumb text; rcat text;
begin
  if p_case_id='basic' then pool_size:=5;t:=1;h:=4;
  elsif p_case_id='lucky' then pool_size:=5;t:=2;h:=3;
  elsif p_case_id='titan' then pool_size:=5;t:=5;
  elsif p_case_id='cosmic' then pool_size:=6;t:=3;g:=1;h:=2;
  elsif p_case_id='omega' then pool_size:=9;t:=3;g:=2;h:=4;
  else raise exception 'Case not found'; end if;

  slot:=floor(random()*pool_size)::integer+1;
  tier:=case when slot<=t then 'titanic' when slot<=t+g then 'gargantuan' else 'huge' end;
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
    and z.rn<=case when tier='titanic' then t when tier='gargantuan' then g else h end
  order by random() limit 1;
  if rid is null then raise exception 'No % rewards are available for this case yet',tier; end if;
  return jsonb_build_object('pet_id',rid,'pet_name',rname,'pet_value',coalesce(rvalue,0),'pet_thumbnail_url',rthumb,'pet_category',rcat,'tier',tier);
end; $$;
revoke all on function public.beta_pick_case_reward_v19(text) from public;

create or replace function public.beta_open_case_ticket(p_token text,p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; q integer; reward jsonb; bal bigint; cid text;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  cid:=trim(p_case_id);
  select quantity into q from beta_case_tickets where user_id=uid and case_id=cid for update;
  if coalesce(q,0)<1 then raise exception 'You do not own a free % case ticket',cid; end if;

  reward:=beta_pick_case_reward_v19(cid);
  delete from beta_case_tickets where user_id=uid and case_id=cid and quantity=1;
  if q>1 then
    update beta_case_tickets set quantity=q-1,updated_at=now() where user_id=uid and case_id=cid;
  end if;

  select username into uname from beta_accounts where id=uid;
  perform beta_inventory_add_safe(uid,reward->>'pet_id','normal',1);
  select balance into bal from beta_accounts where id=uid;
  insert into beta_case_openings(user_id,username,case_id,case_price,reward_type,reward_amount,reward_pet_id,reward_pet_name,reward_pet_value)
  values(uid,uname,cid,0,'pet',0,reward->>'pet_id',reward->>'pet_name',coalesce((reward->>'pet_value')::bigint,0));
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'time_case_opened',0,coalesce((reward->>'pet_value')::bigint,0),'Opened free '||initcap(cid)||' Case: '||(reward->>'pet_name'));
  return jsonb_build_object('ok',true,'case_id',cid,'case_name',initcap(cid)||' Case','reward_type','pet','reward_pet_id',reward->>'pet_id','reward_pet_name',reward->>'pet_name','reward_pet_value',coalesce((reward->>'pet_value')::bigint,0),'reward_pet_thumbnail_url',reward->>'pet_thumbnail_url','balance',bal,'ticket_remaining',case when q>1 then q-1 else 0 end);
end; $$;
grant execute on function public.beta_open_case_ticket(text,text) to anon,authenticated;

-- ============================================================
-- 3) Upgrader activity is explicit enough for the homepage to show
--    losses as negative amounts.
-- ============================================================
create or replace function public.beta_run_upgrade_v3(
  p_token text,p_input_pet_items jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb,p_risk_angle numeric default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0)); input_value bigint:=0; target_value bigint:=0; chance numeric; won boolean; result_id text; result_name text; a beta_accounts%rowtype; item jsonb; pid text; v text; qty integer; chosen_value bigint; risk_angle numeric:=mod(coalesce(p_risk_angle,0)+360,360); win_angle numeric; roll_angle numeric;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid for update;
  if jsonb_typeof(coalesce(p_input_pet_items,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection'; end if;
  if jsonb_array_length(coalesce(p_input_pet_items,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems'; end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target'; end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id'); v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid selected pet'; end if;
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'One selected pet variant is no longer in your inventory'; end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;
    if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
    input_value:=input_value+chosen_value*qty;
  end loop;
  input_value:=input_value+diamond_amount;
  select coalesce(sum(coalesce(rap,0)),0) into target_value from pets_cache where id in(select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0;
  if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.'; end if;
  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));
  win_angle:=chance*3.6; roll_angle:=random()*360;
  won:=case when risk_angle+win_angle<=360 then roll_angle between risk_angle and risk_angle+win_angle else roll_angle>=risk_angle or roll_angle<=risk_angle+win_angle-360 end;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id'); v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if (select quantity from beta_inventory where user_id=uid and pet_id=pid and variant=v)=qty then delete from beta_inventory where user_id=uid and pet_id=pid and variant=v;
    else update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v; end if;
  end loop;
  if diamond_amount>0 then update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid; end if;

  if won then
    select id,name into result_id,result_name from pets_cache where id in(select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0 order by random() limit 1;
    if result_id is null then raise exception 'No valid target reward was found'; end if;
    perform beta_inventory_add_safe(uid,result_id,'normal',1);
  end if;

  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'upgrade_result',input_value,case when won then greatest(0,target_value-input_value) else -input_value end,case when won then 'Won an upgrade: '||result_name else 'Lost an upgrade: -'||input_value::text end);
  select * into a from beta_accounts where id=uid;
  return jsonb_build_object('won',won,'chance',chance,'input_value',input_value,'target_value',target_value,'result_id',result_id,'result_name',result_name,'balance',a.balance,'risk_angle',risk_angle,'roll_angle',roll_angle,'inventory_consumed',true,'inventory_awarded',won);
end; $$;
grant execute on function public.beta_run_upgrade_v3(text,jsonb,bigint,jsonb,numeric) to anon,authenticated;

-- ============================================================
-- 4) Live Bets: include open + recently finished Coinflip/Color Dice
--    and Upgrader. Upgrader losses are negative.
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
      case when l.status='finished' then
        case when l.payout>0 then greatest(0,l.payout)::numeric/greatest(1,l.stake_amount)::numeric else 0 end
      else 2.0::numeric end as multiplier,
      case when l.status='finished' and l.payout>0 then l.payout else l.stake_amount*2 end as payout,
      case when l.status='finished' then 'FINISHED' else 'OPEN' end as status_label,
      l.created_at
    from beta_game_lobbies l
    where l.game_type in ('coinflip','dice')
      and (l.status='open' or l.created_at>now()-interval '30 minutes')

    union all

    select a.id::text,'upgrader','Upgrader',a.username,''::text,
      case when a.profit_loss<0 then 0::numeric when a.amount>0 then greatest(0,a.amount+a.profit_loss)::numeric/a.amount else 0 end,
      case when a.profit_loss<0 then -a.amount else greatest(0,a.amount+a.profit_loss) end,
      case when a.profit_loss>=0 then 'WON' else 'LOST' end,
      a.created_at
    from beta_activity a
    where a.activity_type='upgrade_result'
      and a.created_at>now()-interval '30 minutes'
  ) x;
$$;
grant execute on function public.beta_live_bets() to anon,authenticated;

notify pgrst,'reload schema';
