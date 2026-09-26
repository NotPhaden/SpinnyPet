-- SpinnyPet V21 FINAL STABILITY + UI PATCH
-- Apply after V20. This patch only overrides existing RPCs and frontend support functions.

-- Color Dice: eliminate PL/pgSQL variable/column ambiguity around join_choice.
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

-- Upgrader: authoritative wheel result now includes the selected risk angle in the visual stop calculation.
create or replace function public.beta_run_upgrade_v3(
  p_token text,p_input_pet_items jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb,p_risk_angle numeric default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid;uname text;diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0));input_value bigint:=0;target_value bigint:=0;chance numeric;won boolean;result_id text;result_name text;a beta_accounts%rowtype;item jsonb;pid text;v text;qty integer;chosen_value bigint;risk_angle numeric:=mod(coalesce(p_risk_angle,0)+360,360);win_angle numeric;roll_angle numeric;spin_angle numeric;
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
  spin_angle:=1440+mod(risk_angle-roll_angle+360,360);
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
    'risk_angle',risk_angle,'roll_angle',roll_angle,'spin_angle',spin_angle,'inventory_consumed',true,'inventory_awarded',won
  );
end; $$;


grant execute on function public.beta_run_upgrade_v3(text,jsonb,bigint,jsonb,numeric) to anon,authenticated;

-- Admin Give All: blank target means every registered account.
create or replace function public.beta_admin_give_all(p_token text,p_target_username text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; n integer:=0; players integer:=0;
begin
  adminid:=beta_admin_assert(p_token);
  if nullif(trim(coalesce(p_target_username,'')),'') is null then
    select count(*) into players from beta_accounts;
    for tid in select id from beta_accounts loop
      insert into beta_inventory(user_id,pet_id,variant,quantity)
      select tid,p.id,'normal',1
      from pets_cache p
      where lower(p.category) in ('huge','titanic','gargantuan')
         or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %'
      on conflict(user_id,pet_id,variant) do update set quantity=greatest(beta_inventory.quantity,1),updated_at=now();
    end loop;
    select count(*) into n from pets_cache p
      where lower(p.category) in ('huge','titanic','gargantuan')
         or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %';
    return jsonb_build_object('ok',true,'count',n,'players',players,'scope','all');
  end if;
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username));
  if tid is null then raise exception 'User not found'; end if;
  select count(*) into n from pets_cache p
    where lower(p.category) in ('huge','titanic','gargantuan')
       or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %';
  insert into beta_inventory(user_id,pet_id,variant,quantity)
  select tid,p.id,'normal',1 from pets_cache p
  where lower(p.category) in ('huge','titanic','gargantuan')
     or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %'
  on conflict(user_id,pet_id,variant) do update set quantity=greatest(beta_inventory.quantity,1),updated_at=now();
  return jsonb_build_object('ok',true,'count',n,'players',1,'scope','user');
end; $$;
grant execute on function public.beta_admin_give_all(text,text) to anon,authenticated;


notify pgrst, 'reload schema';

-- ============================================================
-- V21.1 VISUAL CASES + LEADERBOARD + CLANS
-- ============================================================

-- Official case catalog supplied for the V21 UI. Re-runnable.
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

-- Case opening accepts the official UUID case catalog instead of the old demo IDs.
create or replace function public.beta_open_case(p_token text,p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; bal bigint; c beta_cases%rowtype; pid text; pname text; pvalue bigint; pthumb text; pcat text;
  low bigint; high bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username,balance into uname,bal from beta_accounts where id=uid for update;
  select * into c from beta_cases where id=p_case_id and active=true;
  if c.id is null then raise exception 'Case not found'; end if;
  if bal<c.price then raise exception 'Not enough gems'; end if;
  update beta_accounts set balance=balance-c.price,updated_at=now() where id=uid returning balance into bal;
  low:=greatest(1,c.min_pet_value); high:=greatest(low,c.max_pet_value);

  select p.id,p.name,p.rap,p.thumbnail_url,p.category into pid,pname,pvalue,pthumb,pcat
  from pets_cache p
  where coalesce(p.rap,0)>0 and p.rap between low and high
  order by random() limit 1;
  if pid is null then
    select p.id,p.name,p.rap,p.thumbnail_url,p.category into pid,pname,pvalue,pthumb,pcat
    from pets_cache p where coalesce(p.rap,0)>0 order by abs(p.rap-c.price) asc, random() limit 1;
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
  return jsonb_build_object('ok',true,'case_id',c.id,'case_name',c.name,'price',c.price,'reward_type','pet','reward_amount',0,
    'reward_pet_id',pid,'reward_pet_name',pname,'reward_pet_value',coalesce(pvalue,0),'reward_pet_thumbnail_url',pthumb,
    'reward_pet_category',pcat,'balance',bal);
end; $$;
grant execute on function public.beta_open_case(text,text) to anon,authenticated;

-- Case Battle reward picker accepts the official case IDs and uses their value bands.
create or replace function public.beta_case_battle_pick_reward(p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare rid text; rname text; rvalue bigint; rthumb text; rcat text; c beta_cases%rowtype;
begin
  select * into c from beta_cases where id=p_case_id and active=true;
  if c.id is null then raise exception 'Case not found'; end if;
  select p.id,p.name,p.rap,p.thumbnail_url,p.category into rid,rname,rvalue,rthumb,rcat
  from pets_cache p where coalesce(p.rap,0)>0 and p.rap between greatest(1,c.min_pet_value) and greatest(c.min_pet_value,c.max_pet_value)
  order by random() limit 1;
  if rid is null then
    select p.id,p.name,p.rap,p.thumbnail_url,p.category into rid,rname,rvalue,rthumb,rcat
    from pets_cache p where coalesce(p.rap,0)>0 order by abs(p.rap-c.price) asc,random() limit 1;
  end if;
  if rid is null then raise exception 'No rewards are available for this case yet'; end if;
  return jsonb_build_object('pet_id',rid,'pet_name',rname,'pet_value',coalesce(rvalue,0),'pet_thumbnail_url',rthumb,'pet_category',rcat);
end; $$;
grant execute on function public.beta_case_battle_pick_reward(text) to anon,authenticated;

-- ============================================================
-- LEADERBOARD
-- ============================================================
drop function if exists public.beta_get_leaderboard(text);
create or replace function public.beta_get_leaderboard(p_mode text default 'wagered')
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.metric desc,x.username), '[]'::jsonb)
  from (
    select a.roblox_user_id as "robloxId", a.username, coalesce(a.custom_avatar_url,a.avatar_url) as avatar,
      count(*) filter(where e.activity_type='game_result')::bigint as "gamesPlayed",
      count(*) filter(where e.activity_type='game_result' and e.profit_loss>0)::bigint as "gamesWon",
      coalesce(sum(case when e.activity_type='game_result' then e.profit_loss else 0 end),0)::bigint as "totalProfit",
      coalesce(sum(case when e.activity_type in ('game_created','game_joined') then e.amount else 0 end),0)::bigint as "totalWagered",
      case when lower(coalesce(p_mode,'wagered'))='profit' then coalesce(sum(case when e.activity_type='game_result' then e.profit_loss else 0 end),0) else coalesce(sum(case when e.activity_type in ('game_created','game_joined') then e.amount else 0 end),0) end as metric
    from beta_accounts a left join beta_activity e on e.user_id=a.id
    group by a.id,a.roblox_user_id,a.username,a.custom_avatar_url,a.avatar_url
    having count(e.id)>0
  ) x
  limit 100;
$$;
grant execute on function public.beta_get_leaderboard(text) to anon,authenticated;

-- ============================================================
-- CLANS
-- ============================================================
create table if not exists public.beta_clans (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  owner_id uuid not null references public.beta_accounts(id) on delete cascade,
  description text not null default '',
  image_url text,
  level integer not null default 1 check(level between 1 and 10),
  slots integer not null default 3 check(slots between 3 and 12),
  points bigint not null default 0,
  last_top_reward_at timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists public.beta_clan_members (
  clan_id uuid not null references public.beta_clans(id) on delete cascade,
  user_id uuid not null references public.beta_accounts(id) on delete cascade,
  role text not null default 'member' check(role in ('leader','member')),
  points bigint not null default 0,
  joined_at timestamptz not null default now(),
  primary key(clan_id,user_id), unique(user_id)
);
create table if not exists public.beta_clan_invites (
  id uuid primary key default gen_random_uuid(),
  clan_id uuid not null references public.beta_clans(id) on delete cascade,
  invited_user_id uuid not null references public.beta_accounts(id) on delete cascade,
  invited_by uuid not null references public.beta_accounts(id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','accepted','declined','cancelled')),
  created_at timestamptz not null default now()
);
alter table public.beta_clans enable row level security;
alter table public.beta_clan_members enable row level security;
alter table public.beta_clan_invites enable row level security;
drop policy if exists beta_clans_read on public.beta_clans;
create policy beta_clans_read on public.beta_clans for select to anon,authenticated using(true);
drop policy if exists beta_clan_members_read on public.beta_clan_members;
create policy beta_clan_members_read on public.beta_clan_members for select to anon,authenticated using(true);
grant select on public.beta_clans,public.beta_clan_members,public.beta_clan_invites to anon,authenticated;

create or replace function public.beta_get_clan(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; cid uuid; out jsonb;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then return jsonb_build_object('clan',null,'members','[]'::jsonb,'invites','[]'::jsonb); end if;
  select clan_id into cid from beta_clan_members where user_id=uid;
  if cid is null then
    return jsonb_build_object('clan',null,'members','[]'::jsonb,'invites',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'clan_id',i.clan_id,'clan_name',(select c2.name from beta_clans c2 where c2.id=i.clan_id),'created_at',i.created_at) order by i.created_at desc) from beta_clan_invites i where i.invited_user_id=uid and i.status='pending'),'[]'::jsonb));
  end if;
  select jsonb_build_object('id',c.id,'name',c.name,'description',c.description,'image_url',c.image_url,'level',c.level,'slots',c.slots,'points',c.points,'owner_id',c.owner_id,'is_leader',c.owner_id=uid,
    'reward_ready',c.last_top_reward_at is null or c.last_top_reward_at<now()-interval '24 hours') into out from beta_clans c where c.id=cid;
  return jsonb_build_object('clan',out,
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'username',a.username,'avatar',coalesce(a.custom_avatar_url,a.avatar_url),'role',m.role,'points',m.points) order by m.role desc,m.points desc,a.username) from beta_clan_members m join beta_accounts a on a.id=m.user_id where m.clan_id=cid),'[]'::jsonb),
    'invites',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'clan_id',i.clan_id,'clan_name',(select c2.name from beta_clans c2 where c2.id=i.clan_id),'created_at',i.created_at) order by i.created_at desc) from beta_clan_invites i where i.invited_user_id=uid and i.status='pending'),'[]'::jsonb));
end; $$;
grant execute on function public.beta_get_clan(text) to anon,authenticated;

create or replace function public.beta_create_clan(p_token text,p_name text,p_description text default '',p_image_url text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; clean text:=trim(p_name); cid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  if exists(select 1 from beta_clan_members where user_id=uid) then raise exception 'You are already in a clan'; end if;
  if clean !~ '^[A-Za-z0-9 _-]{3,24}$' then raise exception 'Clan name must be 3-24 characters'; end if;
  if (select balance from beta_accounts where id=uid)<5000000000 then raise exception 'Creating a clan costs 5B diamonds'; end if;
  update beta_accounts set balance=balance-5000000000,updated_at=now() where id=uid;
  insert into beta_clans(name,owner_id,description,image_url) values(clean,uid,trim(coalesce(p_description,'')),nullif(trim(coalesce(p_image_url,'')),'')) returning id into cid;
  insert into beta_clan_members(clan_id,user_id,role) values(cid,uid,'leader');
  return public.beta_get_clan(p_token);
exception when unique_violation then raise exception 'That clan name is already taken';
end; $$;
grant execute on function public.beta_create_clan(text,text,text,text) to anon,authenticated;

create or replace function public.beta_invite_to_clan(p_token text,p_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; cid uuid; target uuid; slots integer; members integer;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select clan_id into cid from beta_clan_members where user_id=uid and role='leader'; if cid is null then raise exception 'Leader access required'; end if;
  select id into target from beta_accounts where lower(username)=lower(trim(p_username)); if target is null then raise exception 'Player not found'; end if;
  if exists(select 1 from beta_clan_members where user_id=target) then raise exception 'That player is already in a clan'; end if;
  select slots into slots from beta_clans where id=cid; select count(*) into members from beta_clan_members where clan_id=cid;
  if members>=slots then raise exception 'Your clan is full'; end if;
  insert into beta_clan_invites(clan_id,invited_user_id,invited_by) values(cid,target,uid);
  return jsonb_build_object('ok',true,'message','Invite sent');
end; $$;
grant execute on function public.beta_invite_to_clan(text,text) to anon,authenticated;

create or replace function public.beta_respond_clan_invite(p_token text,p_invite_id uuid,p_accept boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; i beta_clan_invites%rowtype; slots integer; members integer;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select * into i from beta_clan_invites where id=p_invite_id and invited_user_id=uid and status='pending' for update; if i.id is null then raise exception 'Invite not found'; end if;
  if not p_accept then update beta_clan_invites set status='declined' where id=i.id; return public.beta_get_clan(p_token); end if;
  if exists(select 1 from beta_clan_members where user_id=uid) then raise exception 'You are already in a clan'; end if;
  select slots into slots from beta_clans where id=i.clan_id; select count(*) into members from beta_clan_members where clan_id=i.clan_id;
  if members>=slots then raise exception 'Clan is full'; end if;
  insert into beta_clan_members(clan_id,user_id,role) values(i.clan_id,uid,'member'); update beta_clan_invites set status='accepted' where id=i.id;
  return public.beta_get_clan(p_token);
end; $$;
grant execute on function public.beta_respond_clan_invite(text,uuid,boolean) to anon,authenticated;

create or replace function public.beta_kick_clan_member(p_token text,p_user_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; cid uuid;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select clan_id into cid from beta_clan_members where user_id=uid and role='leader'; if cid is null then raise exception 'Leader access required'; end if;
  delete from beta_clan_members where clan_id=cid and user_id=p_user_id and role='member';
  return public.beta_get_clan(p_token);
end; $$;
grant execute on function public.beta_kick_clan_member(text,uuid) to anon,authenticated;

create or replace function public.beta_upgrade_clan(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; c beta_clans%rowtype; cost bigint; reward bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select c.* into c from beta_clans c join beta_clan_members m on m.clan_id=c.id where m.user_id=uid and m.role='leader' for update;
  if c.id is null then raise exception 'Leader access required'; end if;
  if c.level>=10 then raise exception 'Clan is already max level'; end if;
  cost:=1000000000*c.level*c.level;
  reward:=1000000000*(c.level+1);
  if (select balance from beta_accounts where id=uid)<cost then raise exception 'You need % diamonds for this upgrade',cost; end if;
  update beta_accounts set balance=balance-cost+reward,updated_at=now() where id=uid;
  update beta_clans set level=level+1,slots=least(12,slots+1) where id=c.id;
  return jsonb_build_object('ok',true,'cost',cost,'reward',reward,'level',c.level+1,'slots',least(12,c.slots+1),'clan_id',c.id);
end; $$;
grant execute on function public.beta_upgrade_clan(text) to anon,authenticated;

create or replace function public.beta_claim_clan_top_reward(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; cid uuid; topid uuid; reward bigint:=5000000000;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now(); if uid is null then raise exception 'Please sign in'; end if;
  select clan_id into cid from beta_clan_members where user_id=uid; if cid is null then raise exception 'Join a clan first'; end if;
  select id into topid from beta_clans order by points desc,created_at asc limit 1;
  if topid<>cid then raise exception 'Your clan is not currently #1'; end if;
  if exists(select 1 from beta_clans where id=cid and last_top_reward_at>=now()-interval '24 hours') then raise exception 'Daily clan reward is on cooldown'; end if;
  update beta_accounts set balance=balance+reward,updated_at=now() where id=uid;
  update beta_clans set last_top_reward_at=now() where id=cid;
  return jsonb_build_object('ok',true,'reward',reward);
end; $$;
grant execute on function public.beta_claim_clan_top_reward(text) to anon,authenticated;

-- Match participation points: loss = 5 or 10, win = 15 or 25. Awarded automatically from game_result activity.
create or replace function public.beta_award_clan_match_points()
returns trigger language plpgsql security definer set search_path=public as $$
declare cid uuid; pts bigint;
begin
  if new.activity_type<>'game_result' then return new; end if;
  select clan_id into cid from beta_clan_members where user_id=new.user_id;
  if cid is null then return new; end if;
  if new.profit_loss>0 then pts:=case when random()<0.5 then 15 else 25 end;
  else pts:=case when random()<0.5 then 5 else 10 end; end if;
  update beta_clan_members set points=points+pts where clan_id=cid and user_id=new.user_id;
  update beta_clans set points=points+pts where id=cid;
  return new;
end; $$;
drop trigger if exists beta_clan_match_points_trigger on public.beta_activity;
create trigger beta_clan_match_points_trigger after insert on public.beta_activity for each row execute function public.beta_award_clan_match_points();

notify pgrst,'reload schema';

create or replace function public.beta_time_reward_config()
returns jsonb language sql immutable as $$
  select '[
    {"stage":1,"case_id":"1c32cfeb-9f26-427b-8b0d-4d244b5ddcf8","minutes":30},
    {"stage":2,"case_id":"5b7d4d72-338a-4afd-8884-bd931a866514","minutes":60},
    {"stage":3,"case_id":"b2fdbb43-eaf0-4a3d-add3-d4bd84459c8e","minutes":120},
    {"stage":4,"case_id":"6eb40aaf-7b82-425a-a8a0-ef2eb8ee0f9c","minutes":240},
    {"stage":5,"case_id":"85d616cb-83f9-431f-b9e6-8568739819a8","minutes":480}
  ]'::jsonb;
$$;

create or replace function public.beta_pick_case_reward_v19(p_case_id text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare rid text; rname text; rvalue bigint; rthumb text; rcat text; c beta_cases%rowtype;
begin
  select * into c from beta_cases where id=p_case_id and active=true;
  if c.id is null then raise exception 'Case not found'; end if;
  select p.id,p.name,p.rap,p.thumbnail_url,p.category into rid,rname,rvalue,rthumb,rcat
  from pets_cache p where coalesce(p.rap,0)>0 and p.rap between greatest(1,c.min_pet_value) and greatest(c.min_pet_value,c.max_pet_value)
  order by random() limit 1;
  if rid is null then select p.id,p.name,p.rap,p.thumbnail_url,p.category into rid,rname,rvalue,rthumb,rcat from pets_cache p where coalesce(p.rap,0)>0 order by abs(p.rap-c.price) asc,random() limit 1; end if;
  if rid is null then raise exception 'No rewards are available for this case yet'; end if;
  return jsonb_build_object('pet_id',rid,'pet_name',rname,'pet_value',coalesce(rvalue,0),'pet_thumbnail_url',rthumb,'pet_category',rcat);
end; $$;

notify pgrst,'reload schema';
