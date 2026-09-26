-- SpinnyPet V18 GAME + UI FIXES
-- Run after V16/V17. Uses CREATE OR REPLACE and IF NOT EXISTS only.

-- ============================================================
-- 1) Fix inventory check constraint on exact-stack consumption.
--    Never update quantity to 0 because beta_inventory.quantity > 0.
-- ============================================================

-- Rebuild the V17 upgrader with safe delete/update semantics.
create or replace function public.beta_run_upgrade_v3(
  p_token text,p_input_pet_items jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb,p_risk_angle numeric default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;uname text;diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0));input_value bigint:=0;target_value bigint:=0;chance numeric;won boolean;result_id text;result_name text;a beta_accounts%rowtype;item jsonb;pid text;v text;qty integer;chosen_value bigint;risk_angle numeric:=mod(coalesce(p_risk_angle,0)+360,360);win_angle numeric;roll_angle numeric;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid for update;
  if jsonb_typeof(coalesce(p_input_pet_items,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection'; end if;
  if jsonb_array_length(coalesce(p_input_pet_items,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems'; end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target'; end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id');
    v:=coalesce(item->>'variant','normal');
    qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid selected pet'; end if;
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'One selected pet variant is no longer in your inventory'; end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;
    if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
    input_value:=input_value+chosen_value*qty;
  end loop;

  input_value:=input_value+diamond_amount;
  select coalesce(sum(coalesce(rap,0)),0) into target_value
  from pets_cache where id in(select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0;
  if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.'; end if;

  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));
  win_angle:=chance*3.6;
  roll_angle:=random()*360;
  won:=case
    when risk_angle+win_angle<=360 then roll_angle between risk_angle and risk_angle+win_angle
    else roll_angle>=risk_angle or roll_angle<=risk_angle+win_angle-360
  end;

  -- SAFE CONSUMPTION: delete exact stacks, update larger stacks.
  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id');
    v:=coalesce(item->>'variant','normal');
    qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if (select quantity from beta_inventory where user_id=uid and pet_id=pid and variant=v) = qty then
      delete from beta_inventory where user_id=uid and pet_id=pid and variant=v;
    else
      update beta_inventory set quantity=quantity-qty,updated_at=now()
      where user_id=uid and pet_id=pid and variant=v;
    end if;
  end loop;

  if diamond_amount>0 then
    update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid;
  end if;

  if won then
    select id,name into result_id,result_name
    from pets_cache
    where id in(select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0
    order by random() limit 1;
    if result_id is null then raise exception 'No valid target reward was found'; end if;
    perform beta_inventory_add_safe(uid,result_id,'normal',1);
  end if;

  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'upgrade_result',input_value,
    case when won then greatest(0,target_value-input_value) else -input_value end,
    case when won then 'Won an upgrade: '||result_name else 'Lost an upgrade' end);

  select * into a from beta_accounts where id=uid;
  return jsonb_build_object(
    'won',won,'chance',chance,'input_value',input_value,'target_value',target_value,
    'result_id',result_id,'result_name',result_name,'balance',a.balance,
    'risk_angle',risk_angle,'roll_angle',roll_angle,'inventory_consumed',true,'inventory_awarded',won
  );
end; $$;
grant execute on function public.beta_run_upgrade_v3(text,jsonb,bigint,jsonb,numeric) to anon,authenticated;

-- ============================================================
-- 2) Rebuild lobby join with the same safe inventory consumption.
-- ============================================================
create or replace function public.beta_join_lobby_v2(
  p_token text,p_lobby_id uuid,p_pet_items jsonb default '[]'::jsonb,p_choice text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; lid uuid; host_id uuid; host_name text; gtype text; st text; amt bigint;
  host_choice text; host_items jsonb; host_avatar text; join_choice text:=trim(coalesce(p_choice,''));
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
    join_has:=roll_color=any(string_to_array(join_choice,','));
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
    update beta_game_lobbies set status='finished',join_pet_items=coalesce(p_pet_items,'[]'::jsonb),join_choice=join_choice,result_side=roll_color,winner_id=null,winner_username=null,payout=0 where id=lid;
    return jsonb_build_object('ok',true,'status','finished','lobby_id',lid,'choice',host_choice,'join_choice',join_choice,'result_side',roll_color,'winner_id',null,'winner_username',null,'payout',0,'draw',true);
  end if;

  if st='diamonds' then
    update beta_accounts set balance=balance+payout_value,updated_at=now() where id=winner returning balance into bal;
  else
    for item in select value from jsonb_array_elements(coalesce(host_items,'[]'::jsonb)) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(winner,pid,v,qty);end loop;
    for item in select value from jsonb_array_elements(coalesce(p_pet_items,'[]'::jsonb)) loop pid:=item->>'pet_id';v:=coalesce(item->>'variant','normal');qty:=greatest(1,coalesce((item->>'quantity')::integer,1));perform beta_inventory_add_safe(winner,pid,v,qty);end loop;
  end if;
  update beta_game_lobbies set status='finished',join_pet_items=coalesce(p_pet_items,'[]'::jsonb),join_choice=join_choice,result_side=roll_color,winner_id=winner,winner_username=wname,payout=payout_value where id=lid;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description)
  values(winner,wname,'game_result','dice',payout_value,payout_value-amt,'Won Color Dice on '||roll_color);
  return jsonb_build_object('ok',true,'status','finished','lobby_id',lid,'choice',host_choice,'join_choice',join_choice,'result_side',roll_color,'winner_id',winner,'winner_username',wname,'payout',payout_value);
end; $$;
grant execute on function public.beta_join_lobby_v2(text,uuid,jsonb,text) to anon,authenticated;

-- ============================================================
-- 3) Admin: load selected player's inventory.
-- ============================================================
create or replace function public.beta_admin_get_inventory(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; target_name text:=trim(coalesce(p_target_username,''));
begin
  adminid:=beta_admin_assert(p_token);
  if target_name='' then
    select username into target_name from beta_accounts where id=adminid;
  end if;
  select id into tid from beta_accounts where lower(username)=lower(target_name);
  if tid is null then raise exception 'User not found'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id',i.id,'pet_id',i.pet_id,'name',p.name,'variant',i.variant,'quantity',i.quantity,
      'rap',p.rap,'category',p.category,'thumbnail_asset',p.thumbnail_asset,
      'thumbnail_url',p.thumbnail_url,'golden_thumbnail_asset',p.golden_thumbnail_asset,
      'golden_thumbnail_url',p.golden_thumbnail_url
    ) order by p.name)
    from beta_inventory i join pets_cache p on p.id=i.pet_id where i.user_id=tid
  ),'[]'::jsonb);
end; $$;
grant execute on function public.beta_admin_get_inventory(text,text) to anon,authenticated;

-- ============================================================
-- 4) Admin Give All: no username required; grant high-tier catalog to every account.
-- ============================================================
create or replace function public.beta_admin_give_all(p_token text,p_target_username text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid;tid uuid;target_name text:=trim(coalesce(p_target_username,''));n integer:=0;users_updated integer:=0;
begin
  adminid:=beta_admin_assert(p_token);
  select count(*) into n from pets_cache p
  where lower(coalesce(p.category,'')) in ('huge','titanic','gargantuan')
     or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %';
  if n=0 then raise exception 'High-tier catalog is empty. Run the pet sync first.'; end if;

  if target_name='' then
    for tid in select id from beta_accounts loop
      insert into beta_inventory(user_id,pet_id,variant,quantity)
      select tid,p.id,'normal',1 from pets_cache p
      where lower(coalesce(p.category,'')) in ('huge','titanic','gargantuan')
         or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %'
      on conflict(user_id,pet_id,variant) do update set quantity=greatest(beta_inventory.quantity,1),updated_at=now();
      users_updated:=users_updated+1;
    end loop;
    return jsonb_build_object('ok',true,'mode','all','users_updated',users_updated,'pet_count',n);
  end if;

  select id into tid from beta_accounts where lower(username)=lower(target_name);
  if tid is null then raise exception 'User not found'; end if;
  insert into beta_inventory(user_id,pet_id,variant,quantity)
  select tid,p.id,'normal',1 from pets_cache p
  where lower(coalesce(p.category,'')) in ('huge','titanic','gargantuan')
     or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %'
  on conflict(user_id,pet_id,variant) do update set quantity=greatest(beta_inventory.quantity,1),updated_at=now();
  return jsonb_build_object('ok',true,'mode','single','username',target_name,'pet_count',n);
end; $$;
grant execute on function public.beta_admin_give_all(text,text) to anon,authenticated;

-- ============================================================
-- 5) Homepage Live Bets: Coinflip + Color Dice open rooms + recent Upgrader.
-- ============================================================
create or replace function public.beta_live_bets()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
  from (
    select l.id::text as id,
      l.game_type,
      case when l.game_type='coinflip' then 'Coinflip' else 'Color Dice' end as game_label,
      l.creator_username as username,
      l.choice,
      l.stake_amount as bet,
      2.0::numeric as multiplier,
      (l.stake_amount*2) as payout,
      'OPEN'::text as status_label,
      l.created_at
    from beta_game_lobbies l
    where l.status='open' and l.game_type in ('coinflip','dice')

    union all

    select a.id::text as id,
      'upgrader'::text as game_type,
      'Upgrader'::text as game_label,
      a.username,
      null::text as choice,
      a.amount as bet,
      case when a.amount>0 then greatest(0,a.amount+a.profit_loss)::numeric/a.amount else 0 end as multiplier,
      greatest(0,a.amount+a.profit_loss) as payout,
      case when a.profit_loss>=0 then 'WON' else 'LOST' end as status_label,
      a.created_at
    from beta_activity a
    where a.activity_type='upgrade_result' and a.created_at>now()-interval '30 minutes'
  ) x;
$$;
grant execute on function public.beta_live_bets() to anon,authenticated;

-- Refresh PostgREST's function cache.
notify pgrst,'reload schema';
