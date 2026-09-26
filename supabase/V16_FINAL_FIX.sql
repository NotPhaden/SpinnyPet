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
