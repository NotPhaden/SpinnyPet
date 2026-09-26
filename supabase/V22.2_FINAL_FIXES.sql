-- SpinnyPet V22.2 FINAL FIXES
-- 1) Dedicated Color Dice RPCs to avoid overloaded lobby-RPC ambiguity.
-- 2) Case Battle supports repeated case IDs (+/- quantities), exact per-round pricing,
--    exact per-round rewards, and winner by total pet RAP.

create or replace function public.beta_create_dice_lobby(
  p_token text,
  p_stake_type text,
  p_stake_amount bigint,
  p_pet_items jsonb default '[]'::jsonb,
  p_choice text default null
)
returns jsonb
language plpgsql security definer set search_path=public as $$
declare out jsonb;
begin
  out:=public.beta_create_lobby_v2(p_token,'dice',p_stake_type,p_stake_amount,coalesce(p_pet_items,'[]'::jsonb),p_choice);
  return out;
end; $$;
grant execute on function public.beta_create_dice_lobby(text,text,bigint,jsonb,text) to anon,authenticated;

create or replace function public.beta_join_dice_lobby(
  p_token text,
  p_lobby_id uuid,
  p_pet_items jsonb default '[]'::jsonb,
  p_choice text default null
)
returns jsonb
language plpgsql security definer set search_path=public as $$
declare out jsonb;
begin
  out:=public.beta_join_lobby_v2(p_token,p_lobby_id,coalesce(p_pet_items,'[]'::jsonb),p_choice);
  return out;
end; $$;
grant execute on function public.beta_join_dice_lobby(text,uuid,jsonb,text) to anon,authenticated;

-- Rebuild Case Battle creation so duplicate IDs count as separate rounds and prices.
create or replace function public.beta_create_case_battle(p_token text,p_case_ids jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; cid text; total bigint:=0; bid uuid; round_count integer:=0;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_case_ids,'[]'::jsonb))<>'array' or jsonb_array_length(p_case_ids)<1 or jsonb_array_length(p_case_ids)>50 then
    raise exception 'Choose 1 to 50 rounds';
  end if;

  for cid in select value from jsonb_array_elements_text(p_case_ids) loop
    if not exists(select 1 from beta_cases where id=cid and active=true) then raise exception 'Case % is unavailable',cid; end if;
    round_count:=round_count+1;
  end loop;

  -- Recalculate exactly per occurrence (duplicates are intentional rounds).
  total:=0;
  for cid in select value from jsonb_array_elements_text(p_case_ids) loop
    total:=total+coalesce((select price from beta_cases where id=cid and active=true),0);
  end loop;
  if total<=0 then raise exception 'Invalid Case Battle wager'; end if;
  if total>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems for this Case Battle'; end if;

  update beta_accounts set balance=balance-total,updated_at=now() where id=uid;
  insert into beta_case_battles(creator_id,creator_username,creator_cases,creator_total)
  values(uid,uname,p_case_ids,total) returning id into bid;

  return jsonb_build_object('ok',true,'id',bid,'status','open','creator_total',total,'creator_cases',p_case_ids,'rounds',round_count);
end; $$;
grant execute on function public.beta_create_case_battle(text,jsonb) to anon,authenticated;

-- Rebuild settlement: every occurrence is one round; both players receive a reward
-- for every round, and the player with the larger sum of reward RAP wins.
create or replace function public.beta_join_case_battle(p_token text,p_battle_id uuid,p_case_ids jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; b beta_case_battles%rowtype; cid text; total bigint:=0;
  reward jsonb; rewards jsonb:='[]'::jsonb; cs bigint:=0; js bigint:=0;
  winner uuid; wname text; r jsonb; host_cases jsonb; round_no integer:=0;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select * into b from beta_case_battles where id=p_battle_id and status='open' and creator_id<>uid for update;
  if b.id is null then raise exception 'Case Battle is no longer available'; end if;
  select username into uname from beta_accounts where id=uid;

  host_cases:=coalesce(b.creator_cases,'[]'::jsonb);
  if jsonb_typeof(host_cases)<>'array' or jsonb_array_length(host_cases)<1 or jsonb_array_length(host_cases)>50 then raise exception 'The host case bundle is invalid'; end if;

  total:=0;
  for cid in select value from jsonb_array_elements_text(host_cases) loop
    total:=total+coalesce((select price from beta_cases where id=cid and active=true),0);
  end loop;
  if total<>b.creator_total then raise exception 'Case Battle wager is no longer valid'; end if;
  if total>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
  update beta_accounts set balance=balance-total,updated_at=now() where id=uid;

  for cid in select value from jsonb_array_elements_text(host_cases) loop
    round_no:=round_no+1;
    reward:=public.beta_case_battle_pick_reward(cid);
    cs:=cs+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','creator','round',round_no,'case_id',cid)||reward);
  end loop;
  round_no:=0;
  for cid in select value from jsonb_array_elements_text(host_cases) loop
    round_no:=round_no+1;
    reward:=public.beta_case_battle_pick_reward(cid);
    js:=js+coalesce((reward->>'pet_value')::bigint,0);
    rewards:=rewards||jsonb_build_array(jsonb_build_object('owner','joiner','round',round_no,'case_id',cid)||reward);
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

  update beta_case_battles set
    joiner_id=uid,joiner_username=uname,joiner_cases=host_cases,joiner_total=total,
    creator_score=cs,joiner_score=js,winner_id=winner,winner_username=wname,status='finished',finished_at=now()
  where id=b.id;

  if winner is not null then
    insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description)
    values(winner,wname,'game_result','case_battle',cs+js,(cs+js)-b.creator_total,'Won Case Battle');
  end if;

  return jsonb_build_object(
    'ok',true,'status','finished','id',b.id,
    'creator_username',b.creator_username,'joiner_username',uname,
    'creator_cases',host_cases,'joiner_cases',host_cases,
    'creator_total',b.creator_total,'joiner_total',total,
    'creator_score',cs,'joiner_score',js,'winner_id',winner,'winner_username',wname,
    'rewards',rewards,'rounds',jsonb_array_length(host_cases),'draw',winner is null
  );
end; $$;
grant execute on function public.beta_join_case_battle(text,uuid,jsonb) to anon,authenticated;

notify pgrst,'reload schema';
