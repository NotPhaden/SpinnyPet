-- SpinnyPet V21.9 FINAL FIXES
-- Run this AFTER your existing SpinnyPet SQL patches.
-- This patch restores the Color Dice join RPC, removes the Time Rewards stage ambiguity,
-- and ensures the lobby columns used by the current frontend exist.

DO $$
BEGIN
  ALTER TABLE public.beta_game_lobbies ADD COLUMN IF NOT EXISTS choice text;
  ALTER TABLE public.beta_game_lobbies ADD COLUMN IF NOT EXISTS join_choice text;
  ALTER TABLE public.beta_game_lobbies ADD COLUMN IF NOT EXISTS result_side text;
  ALTER TABLE public.beta_game_lobbies ADD COLUMN IF NOT EXISTS stake_pet_items jsonb NOT NULL DEFAULT '[]'::jsonb;
  ALTER TABLE public.beta_game_lobbies ADD COLUMN IF NOT EXISTS join_pet_items jsonb NOT NULL DEFAULT '[]'::jsonb;
EXCEPTION WHEN undefined_table THEN
  RAISE EXCEPTION 'beta_game_lobbies table is missing. Run the base SpinnyPet schema/migrations first.';
END $$;

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


create or replace function public.beta_join_lobby_v2(
  p_token text,p_lobby_id uuid,p_pet_items jsonb default '[]'::jsonb,p_choice text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; lid uuid; host_id uuid; host_name text; gtype text; st text; amt bigint;
  host_choice text; host_items jsonb; host_avatar text; join_choice_value text:=trim(coalesce(p_choice,''));
  item jsonb; pid text; v text; qty integer; total bigint:=0; pv bigint; first_name text; pcat text;
  winner uuid; wname text; payout_value bigint:=0; roll_color text; host_has boolean; join_has boolean;
  i integer; bal bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select id,creator_id,creator_username,game_type,stake_type,stake_amount,choice,stake_pet_items,creator_avatar_url
    into lid,host_id,host_name,gtype,st,amt,host_choice,host_items,host_avatar
  from beta_game_lobbies where id=p_lobby_id and status='open' and creator_id<>uid for update;
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
        if (select quantity from beta_inventory where user_id=uid and pet_id=pid and variant=v)=qty then
          delete from beta_inventory where user_id=uid and pet_id=pid and variant=v;
        else
          update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
        end if;
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
    update beta_game_lobbies set status='finished',join_pet_items=coalesce(p_pet_items,'[]'::jsonb),join_choice=null,result_side=roll_color,winner_id=winner,winner_username=wname,payout=payout_value where id=lid;
    insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description) values(winner,wname,'game_result','coinflip',payout_value,payout_value-amt,'Won Coinflip: '||roll_color);
    return jsonb_build_object('ok',true,'status','finished','lobby_id',lid,'winner_id',winner,'winner_username',wname,'winner_side',roll_color,'result_side',roll_color,'payout',payout_value);
  end if;

  if gtype<>'dice' then raise exception 'Unsupported match game'; end if;
  if array_length(string_to_array(join_choice_value,','),1) <> 2 then raise exception 'Choose exactly 2 colors'; end if;
  if join_choice_value !~ '^(Red|Orange|Yellow|Green|Blue|Purple),(Red|Orange|Yellow|Green|Blue|Purple)$' then raise exception 'Invalid dice colors'; end if;
  if split_part(join_choice_value,',',1)=split_part(join_choice_value,',',2) then raise exception 'Choose two different colors'; end if;

  if st='diamonds' then
    if amt<5000000000 or amt>(select balance from beta_accounts where id=uid) then raise exception 'Color Dice requires exactly the host wager in gems'; end if;
    update beta_accounts set balance=balance-amt,updated_at=now() where id=uid;
    payout_value:=amt*2;
  else
    if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select one or more pets to join'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
      if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
      select coalesce(rap,0) into pv from pets_cache where id=pid;
      if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
      total:=total+pv*qty;
    end loop;
    if total<amt then raise exception using message='Your pet bundle must be worth at least '||amt||' gems'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if (select quantity from beta_inventory where user_id=uid and pet_id=pid and variant=v)=qty then
        delete from beta_inventory where user_id=uid and pet_id=pid and variant=v;
      else
        update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      end if;
    end loop;
    payout_value:=amt+total;
  end if;

  for i in 1..30 loop
    roll_color:=(array['Red','Orange','Yellow','Green','Blue','Purple'])[floor(random()*6)::integer+1];
    host_has:=roll_color=any(string_to_array(host_choice,','));
    join_has:=roll_color=any(string_to_array(join_choice_value,','));
    exit when host_has is distinct from join_has;
  end loop;

  if host_has and not join_has then winner:=host_id;wname:=host_name;
  elsif join_has and not host_has then winner:=uid;wname:=uname;
  else winner:=null;wname:=null;end if;

  if winner is null then
    if st='diamonds' then
      update beta_accounts set balance=balance+amt,updated_at=now() where id=host_id;
      update beta_accounts set balance=balance+amt,updated_at=now() where id=uid;
    else
      for item in select value from jsonb_array_elements(coalesce(host_items,'[]'::jsonb)) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(host_id,pid,v,qty);end loop;
      for item in select value from jsonb_array_elements(coalesce(p_pet_items,'[]'::jsonb)) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(uid,pid,v,qty);end loop;
    end if;
    update beta_game_lobbies set status='finished',join_pet_items=coalesce(p_pet_items,'[]'::jsonb),join_choice=join_choice_value,result_side=roll_color,winner_id=null,winner_username=null,payout=0 where id=lid;
    return jsonb_build_object('ok',true,'status','finished','lobby_id',lid,'choice',host_choice,'join_choice',join_choice_value,'result_side',roll_color,'winner_id',null,'winner_username',null,'payout',0,'draw',true);
  end if;

  if st='diamonds' then
    update beta_accounts set balance=balance+payout_value,updated_at=now() where id=winner returning balance into bal;
  else
    for item in select value from jsonb_array_elements(coalesce(host_items,'[]'::jsonb)) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(winner,pid,v,qty);end loop;
    for item in select value from jsonb_array_elements(coalesce(p_pet_items,'[]'::jsonb)) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(winner,pid,v,qty);end loop;
  end if;
  update beta_game_lobbies set status='finished',join_pet_items=coalesce(p_pet_items,'[]'::jsonb),join_choice=join_choice_value,result_side=roll_color,winner_id=winner,winner_username=wname,payout=payout_value where id=lid;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description)
  values(winner,wname,'game_result','dice',payout_value,payout_value-amt,'Won Color Dice on '||roll_color);
  return jsonb_build_object('ok',true,'status','finished','lobby_id',lid,'choice',host_choice,'join_choice',join_choice_value,'result_side',roll_color,'winner_id',winner,'winner_username',wname,'payout',payout_value);
end; $$;


grant execute on function public.beta_join_lobby_v2(text,uuid,jsonb,text) to anon,authenticated;



create or replace function public.beta_get_time_rewards(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_uid uuid;
  v_uname text;
  v_cfg jsonb;
  v_out jsonb := '[]'::jsonb;
  v_claimed_at timestamptz;
  v_prior_claimed_at timestamptz;
  v_unlock_at timestamptz;
  v_stage integer;
  v_case_id text;
  v_minutes integer;
  v_granted boolean;
begin
  select s.user_id into v_uid
  from public.beta_sessions s
  where s.token=p_token and s.expires_at>now();
  if v_uid is null then raise exception 'Please sign in'; end if;

  select a.username into v_uname
  from public.beta_accounts a
  where a.id=v_uid;

  for v_cfg in select value from jsonb_array_elements(public.beta_time_reward_config()) loop
    v_stage := (v_cfg->>'stage')::integer;
    v_case_id := v_cfg->>'case_id';
    v_minutes := (v_cfg->>'minutes')::integer;

    select tr.claimed_at into v_claimed_at
    from public.beta_time_reward_claims tr
    where tr.user_id=v_uid and tr.stage=v_stage;

    if v_stage=1 then
      v_unlock_at := coalesce(v_claimed_at,now());
    else
      select prior_tr.claimed_at into v_prior_claimed_at
      from public.beta_time_reward_claims prior_tr
      where prior_tr.user_id=v_uid and prior_tr.stage=(v_stage-1);
      v_unlock_at := case
        when v_prior_claimed_at is null then null
        else v_prior_claimed_at + (v_minutes * interval '1 minute')
      end;
    end if;

    if v_claimed_at is null and v_unlock_at is not null and now()>=v_unlock_at then
      insert into public.beta_time_reward_claims(user_id,stage,case_id)
      values(v_uid,v_stage,v_case_id)
      on conflict(user_id,stage) do nothing;

      insert into public.beta_case_tickets(user_id,case_id,quantity,updated_at)
      values(v_uid,v_case_id,1,now())
      on conflict(user_id,case_id)
      do update set quantity=public.beta_case_tickets.quantity+1,updated_at=now();

      insert into public.beta_activity(user_id,username,activity_type,amount,description)
      values(v_uid,v_uname,'time_reward',0,
        'Time Reward unlocked: '||coalesce((select bc.name from public.beta_cases bc where bc.id=v_case_id),v_case_id));

      select tr2.claimed_at into v_claimed_at
      from public.beta_time_reward_claims tr2
      where tr2.user_id=v_uid and tr2.stage=v_stage;
      v_granted := true;
    else
      v_granted := false;
    end if;

    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'stage',v_stage,
      'case_id',v_case_id,
      'minutes',v_minutes,
      'claimed',v_claimed_at is not null,
      'unlocked',v_claimed_at is not null,
      'granted_now',v_granted,
      'claimed_at',v_claimed_at,
      'unlock_at',v_unlock_at,
      'available',v_claimed_at is not null,
      'remaining_seconds',case
        when v_claimed_at is not null then 0
        when v_unlock_at is null then 0
        else greatest(0,ceil(extract(epoch from(v_unlock_at-now())))::integer)
      end
    ));
  end loop;
  return v_out;
end;
$$;
grant execute on function public.beta_get_time_rewards(text) to anon,authenticated;


notify pgrst,'reload schema';

-- V22.1 compatibility wrapper: Coinflip still calls the legacy 3-argument RPC.
-- Color Dice uses the 4-argument version above so the joiner's two colors are preserved.
create or replace function public.beta_join_lobby_v2(
  p_token text,p_lobby_id uuid,p_pet_items jsonb default '[]'::jsonb
)
returns jsonb
language sql
security definer
set search_path=public
as $$
  select public.beta_join_lobby_v2(p_token,p_lobby_id,p_pet_items,null::text);
$$;
grant execute on function public.beta_join_lobby_v2(text,uuid,jsonb) to anon,authenticated;

notify pgrst,'reload schema';
