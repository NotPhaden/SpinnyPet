-- SpinnyPet V24 Stable Fix
-- Base: V23 original. This patch is intentionally additive/idempotent and repairs the V24 DB changes.
-- Run AFTER V22.7_SUPER_UPDATE.sql and V23_GAMES_UPDATE.sql.

begin;

-- ------------------------------------------------------------
-- Case Battle: synchronized round metadata + deterministic UI data
-- ------------------------------------------------------------
alter table public.beta_case_battles add column if not exists battle_started_at timestamptz;
create index if not exists beta_case_battles_status_idx on public.beta_case_battles(status,created_at desc);

create or replace function public.beta_join_case_battle(p_token text,p_battle_id uuid,p_case_ids jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; b public.beta_case_battles%rowtype; cid text; price bigint; total bigint:=0;
  join_cases jsonb; reward jsonb; rewards jsonb:='[]'::jsonb; cs bigint:=0; js bigint:=0;
  winner uuid; wname text; r jsonb; round_no integer:=0; started timestamptz:=now();
begin
  select user_id into uid from public.beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select * into b from public.beta_case_battles where id=p_battle_id and status='open' and creator_id<>uid for update;
  if b.id is null then raise exception 'Case Battle is no longer available'; end if;
  select username into uname from public.beta_accounts where id=uid;
  join_cases:=case when jsonb_typeof(coalesce(p_case_ids,'[]'::jsonb))='array' and jsonb_array_length(coalesce(p_case_ids,'[]'::jsonb))=0 then b.creator_cases else coalesce(p_case_ids,'[]'::jsonb) end;
  if jsonb_typeof(join_cases)<>'array' or jsonb_array_length(join_cases)<1 or jsonb_array_length(join_cases)>50 then raise exception 'Choose 1 to 50 cases'; end if;
  if jsonb_array_length(join_cases)<>jsonb_array_length(b.creator_cases) then raise exception 'Use the same number of rounds as the host'; end if;
  for cid in select value from jsonb_array_elements_text(join_cases) loop
    select c.price into price from public.beta_cases c where c.id=cid and c.active=true;
    if price is null then raise exception 'Case % is unavailable',cid; end if;
    total:=total+price;
  end loop;
  if total<>b.creator_total then raise exception 'Your cases must total exactly % gems',b.creator_total; end if;
  if total>(select balance from public.beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
  update public.beta_accounts set balance=balance-total,updated_at=now() where id=uid;

  round_no:=0;
  for cid in select value from jsonb_array_elements_text(b.creator_cases) loop
    round_no:=round_no+1; reward:=public.beta_case_battle_pick_reward(cid); cs:=cs+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','creator','round',round_no,'case_id',cid)||reward);
  end loop;
  round_no:=0;
  for cid in select value from jsonb_array_elements_text(join_cases) loop
    round_no:=round_no+1; reward:=public.beta_case_battle_pick_reward(cid); js:=js+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','joiner','round',round_no,'case_id',cid)||reward);
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
  set joiner_id=uid,joiner_username=uname,joiner_cases=join_cases,joiner_total=total,
      creator_score=cs,joiner_score=js,winner_id=winner,winner_username=wname,
      battle_started_at=started,status='finished',finished_at=now()
  where id=b.id;

  return jsonb_build_object('ok',true,'status','finished','id',b.id,'creator_username',b.creator_username,'joiner_username',uname,
    'creator_score',cs,'joiner_score',js,'winner_id',winner,'winner_username',wname,'rewards',rewards,'draw',winner is null,
    'battle_started_at',started);
end; $$;
grant execute on function public.beta_join_case_battle(text,uuid,jsonb) to anon,authenticated;

-- ------------------------------------------------------------
-- Admin Abuse: explicit row-by-row updates (no unsafe UPDATE without WHERE)
-- ------------------------------------------------------------
create or replace function public.beta_admin_trigger_chaos(
  p_token text,p_effect_type text,p_target_page text default 'all',p_reward_amount bigint default 0,p_message text default ''
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  adminid uuid; r text; aname text; reward bigint:=greatest(0,coalesce(p_reward_amount,0)); effect_id uuid;
  allowed_pages text[]:=array['all','home','coinflip','dice','inventory','profile','time-rewards','cases','case-battle','mines','plinko','crash','leaderboard','clans','giveaways','promo','admin'];
  allowed_effects text[]:=array['jackpot','coinstorm','dicefall','petstorm','caseburst','glitch','rainbow'];
  account_row record; note text;
begin
  select s.user_id,a.role,a.username into adminid,r,aname
  from public.beta_sessions s join public.beta_accounts a on a.id=s.user_id
  where s.token=p_token and s.expires_at>now();
  if adminid is null or r not in ('owner','co_owner','manager','admin','moderator') then raise exception 'Staff access required'; end if;
  if not (lower(coalesce(p_effect_type,'')) = any(allowed_effects)) then raise exception 'Invalid admin effect'; end if;
  if not (lower(coalesce(p_target_page,'')) = any(allowed_pages)) then raise exception 'Invalid target page'; end if;
  note:='Admin Abuse: '||coalesce(nullif(trim(p_message),''),p_effect_type);

  if reward>0 then
    for account_row in select id,username from public.beta_accounts loop
      update public.beta_accounts set balance=balance+reward,updated_at=now() where id=account_row.id;
      insert into public.beta_activity(user_id,username,activity_type,amount,profit_loss,description)
      values(account_row.id,account_row.username,'admin_drop',reward,reward,note);
    end loop;
  end if;

  insert into public.beta_admin_effects(actor_id,actor_username,effect_type,target_page,reward_amount,message)
  values(adminid,aname,lower(p_effect_type),lower(p_target_page),reward,nullif(trim(p_message),''))
  returning id into effect_id;
  return jsonb_build_object('ok',true,'id',effect_id,'effect_type',lower(p_effect_type),'target_page',lower(p_target_page),
    'reward_amount',reward,'message',coalesce(p_message,''));
end; $$;
grant execute on function public.beta_admin_trigger_chaos(text,text,text,bigint,text) to anon,authenticated;

-- ------------------------------------------------------------
-- Crash: recover/close stale rounds and never leave a crashed row as playing
-- ------------------------------------------------------------
create or replace function public.beta_crash_get_active(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; g public.beta_v23_games%rowtype; crash_seconds numeric;
begin
  uid:=public.beta_v23_uid(p_token);
  select * into g from public.beta_v23_games where user_id=uid and game_type='crash' and status='playing' order by started_at desc limit 1 for update;
  if g.id is null then return null; end if;
  crash_seconds:=greatest(0.05,ln(greatest(1.01,g.crash_point))*9.0);
  if extract(epoch from (now()-g.started_at))>=crash_seconds then
    update public.beta_v23_games set status='crashed',settled_at=now(),multiplier=g.crash_point,payout=0 where id=g.id;
    return null;
  end if;
  return jsonb_build_object('id',g.id,'status','playing','stake_amount',g.stake_amount,'started_at',g.started_at);
end; $$;
grant execute on function public.beta_crash_get_active(text) to anon,authenticated;

create or replace function public.beta_crash_start(p_token text,p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; gid uuid; bal bigint; cp numeric; old public.beta_v23_games%rowtype; crash_seconds numeric;
begin
  uid:=public.beta_v23_uid(p_token);
  if coalesce(p_amount,0)<1000000 then raise exception 'Crash requires at least 1M diamonds'; end if;

  select * into old from public.beta_v23_games where user_id=uid and game_type='crash' and status='playing' order by started_at desc limit 1 for update;
  if old.id is not null then
    crash_seconds:=greatest(0.05,ln(greatest(1.01,old.crash_point))*9.0);
    if extract(epoch from (now()-old.started_at))>=crash_seconds then
      update public.beta_v23_games set status='crashed',settled_at=now(),multiplier=old.crash_point,payout=0 where id=old.id;
    else
      raise exception 'You already have an active Crash round';
    end if;
  end if;

  select balance into bal from public.beta_accounts where id=uid for update;
  if bal<p_amount then raise exception 'Not enough diamonds'; end if;
  cp:=greatest(1.01,least(50,round((1.01/(1-random()))::numeric,4)));
  update public.beta_accounts set balance=balance-p_amount,updated_at=now() where id=uid;
  insert into public.beta_v23_games(user_id,game_type,stake_amount,status,crash_point) values(uid,'crash',p_amount,'playing',cp) returning id into gid;
  return jsonb_build_object('id',gid,'stake_amount',p_amount,'started_at',now(),'status','playing');
end; $$;
grant execute on function public.beta_crash_start(text,bigint) to anon,authenticated;

create or replace function public.beta_crash_cashout(p_token text,p_game_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; g public.beta_v23_games%rowtype; elapsed numeric; current_mult numeric; payout bigint; bal bigint; crash_seconds numeric;
begin
  uid:=public.beta_v23_uid(p_token);
  select * into g from public.beta_v23_games where id=p_game_id and user_id=uid for update;
  if g.id is null then raise exception 'Game not found'; end if;
  if g.status<>'playing' then raise exception 'This round is already settled'; end if;
  elapsed:=extract(epoch from (now()-g.started_at));
  current_mult:=greatest(1,exp(elapsed/9.0));
  crash_seconds:=greatest(0.05,ln(greatest(1.01,g.crash_point))*9.0);
  if elapsed>=crash_seconds or current_mult>=g.crash_point then
    update public.beta_v23_games set status='crashed',settled_at=now(),multiplier=g.crash_point,payout=0 where id=g.id;
    return jsonb_build_object('status','crashed','multiplier',g.crash_point,'payout',0,'balance',(select balance from public.beta_accounts where id=uid));
  end if;
  current_mult:=least(current_mult,g.crash_point-0.0001);
  payout:=greatest(0,floor(g.stake_amount*current_mult));
  update public.beta_accounts set balance=balance+payout,updated_at=now() where id=uid returning balance into bal;
  update public.beta_v23_games set status='won',settled_at=now(),multiplier=current_mult,payout=payout where id=g.id;
  return jsonb_build_object('status','won','multiplier',current_mult,'payout',payout,'balance',bal);
end; $$;
grant execute on function public.beta_crash_cashout(text,uuid) to anon,authenticated;

-- ------------------------------------------------------------
-- Plinko: path determines the exact bottom gate/multiplier
-- ------------------------------------------------------------
create or replace function public.beta_plinko_play(p_token text,p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; bal bigint; r numeric; m numeric; payout bigint; path text:=''; step integer; final_pos integer:=0; gate_index integer; gates numeric[]:=array[0.2,0.5,1.0,1.5,2.0,3.0,5.0,10.0,5.0,3.0,2.0,1.5,1.0,0.5,0.2];
begin
  uid:=public.beta_v23_uid(p_token);
  if coalesce(p_amount,0)<1000000 then raise exception 'Plinko requires at least 1M diamonds'; end if;
  select balance into bal from public.beta_accounts where id=uid for update;
  if bal<p_amount then raise exception 'Not enough diamonds'; end if;
  for step in 1..14 loop
    if random()<0.5 then path:=path||'L'; final_pos:=final_pos-1; else path:=path||'R'; final_pos:=final_pos+1; end if;
  end loop;
  gate_index:=greatest(1,least(15,final_pos+8));
  m:=gates[gate_index];
  payout:=floor(p_amount*m);
  update public.beta_accounts set balance=balance-p_amount+greatest(0,payout),updated_at=now() where id=uid returning balance into bal;
  insert into beta_v23_games(user_id,game_type,stake_amount,status,multiplier,payout,settled_at,metadata)
  values(uid,'plinko',p_amount,'won',m,payout,now(),jsonb_build_object('path',path,'multiplier',m,'gate_index',gate_index));
  return jsonb_build_object('multiplier',m,'payout',payout,'path',path,'gate_index',gate_index,'balance',bal);
end; $$;
grant execute on function public.beta_plinko_play(text,bigint) to anon,authenticated;

notify pgrst,'reload schema';
commit;
