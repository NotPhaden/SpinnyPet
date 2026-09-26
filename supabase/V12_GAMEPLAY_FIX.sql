-- SpinnyPet final gameplay patch: multi-pet matches, own-bundle joining,
-- safe inventory quantities, and variant-aware upgrades.
alter table public.beta_game_lobbies add column if not exists pet_count integer not null default 0;
alter table public.beta_game_lobbies add column if not exists stake_pet_items jsonb not null default '[]'::jsonb;
create index if not exists beta_game_lobbies_status_idx on public.beta_game_lobbies(status, created_at desc);

create or replace function public.beta_create_lobby_v2(
  p_token text,p_game_type text,p_stake_type text,p_stake_amount bigint,
  p_pet_items jsonb,p_choice text
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; lid uuid; item jsonb; pid text; v text; qty integer;
  total bigint:=0; count_items integer:=0; first_id text; first_name text; first_variant text;
  pv bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if p_stake_type not in ('diamonds','pet') then raise exception 'Invalid stake type'; end if;
  if p_stake_type='diamonds' then
    if coalesce(p_stake_amount,0)<=0 or p_stake_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;
    update beta_accounts set balance=balance-p_stake_amount,updated_at=now() where id=uid;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,stake_type,stake_amount,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,'diamonds',p_stake_amount,0,'[]'::jsonb,p_choice) returning id into lid;
  else
    if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select at least one pet'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
      if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
      select coalesce(rap,0),name into pv,first_name from pets_cache where id=pid;
      if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
      total:=total+pv*qty; count_items:=count_items+qty;
      if first_id is null then first_id:=pid; first_variant:=v; end if;
    end loop;
    if total<=0 then raise exception 'Pet bundle has no PS99 RAP'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
    end loop;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,choice)
    values(p_game_type,uid,uname,'pet',total,first_id,first_name,first_variant,count_items,p_pet_items,p_choice) returning id into lid;
  end if;
  return jsonb_build_object('ok',true,'id',lid,'status','open','stake_amount',case when p_stake_type='pet' then total else p_stake_amount end,'pet_count',count_items);
end; $$;
grant execute on function public.beta_create_lobby_v2(text,text,text,bigint,jsonb,text) to anon,authenticated;

create or replace function public.beta_join_lobby_v2(
  p_token text,p_lobby_id uuid,p_pet_items jsonb default '[]'::jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; lid uuid; st text; amt bigint; item jsonb; pid text; v text; qty integer;
  total bigint:=0; pv bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select id,stake_type,stake_amount into lid,st,amt from beta_game_lobbies where id=p_lobby_id and status='open' and creator_id<>uid for update;
  if lid is null then raise exception 'Match is no longer available'; end if;
  select username into uname from beta_accounts where id=uid;
  if st='diamonds' then
    if amt<=0 or amt>(select balance from beta_accounts where id=uid) then raise exception 'You do not have enough gems to join'; end if;
    update beta_accounts set balance=balance-amt,updated_at=now() where id=uid;
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
    if total < amt then raise exception using message = 'Your pet bundle must be worth at least ' || amt || ' gems'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
    end loop;
  end if;
  update beta_game_lobbies set status='joined' where id=lid;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,description)
  values(uid,uname,'game_joined',(select game_type from beta_game_lobbies where id=lid),case when st='pet' then total else amt end,'Joined a match with a custom stake bundle');
  return jsonb_build_object('ok',true,'lobby_id',lid,'status','joined','stake_value',case when st='pet' then total else amt end);
end; $$;
grant execute on function public.beta_join_lobby_v2(text,uuid,jsonb) to anon,authenticated;

create or replace function public.beta_cancel_lobby_v2(p_token text,p_lobby_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; lid uuid; st text; amt bigint; item jsonb; pid text; v text; qty integer; bal bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select id,stake_type,stake_amount,stake_pet_items into lid,st,amt,item from beta_game_lobbies where id=p_lobby_id and creator_id=uid and status='open' for update;
  if lid is null then raise exception 'Lobby is not open or not yours'; end if;
  if st='diamonds' then
    update beta_accounts set balance=balance+amt,updated_at=now() where id=uid returning balance into bal;
  else
    for item in select value from jsonb_array_elements(coalesce(item,'[]'::jsonb)) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,pid,v,qty)
      on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+excluded.quantity,updated_at=now();
    end loop;
    select balance into bal from beta_accounts where id=uid;
  end if;
  update beta_game_lobbies set status='cancelled' where id=lid;
  return jsonb_build_object('ok',true,'balance',bal);
end; $$;
grant execute on function public.beta_cancel_lobby_v2(text,uuid) to anon,authenticated;

-- Variant-aware, transaction-safe upgrader. Inventory rows are deleted at zero,
-- and a winning reward always inserts quantity=1 or increments an existing row.
create or replace function public.beta_run_upgrade_v2(
  p_token text,p_input_pet_items jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0));
  input_value bigint:=0; target_value bigint:=0; chance numeric; won boolean;
  result_id text; result_name text; a beta_accounts%rowtype; item jsonb; pid text; v text; qty integer; chosen_value bigint;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_input_pet_items,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection'; end if;
  if jsonb_array_length(coalesce(p_input_pet_items,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems'; end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target'; end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=item->>'id'; if pid is null then pid:=item->>'pet_id'; end if;
    v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then
      raise exception 'One selected pet variant is no longer in your inventory';
    end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;
    if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
    input_value:=input_value+chosen_value*qty;
  end loop;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=item->>'id'; if pid is null then pid:=item->>'pet_id'; end if;
    v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
    delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
  end loop;

  input_value:=input_value+diamond_amount;
  if diamond_amount>0 then update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid; end if;
  select coalesce(sum(coalesce(rap,0)),0) into target_value from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0;
  if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.'; end if;
  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));
  won:=random()<=chance/100;
  if won then
    select id,name into result_id,result_name from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0 order by random() limit 1;
    if result_id is null then raise exception 'No valid target reward was found'; end if;
    insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,result_id,'normal',1)
    on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  end if;
  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'upgrade_result',input_value,case when won then greatest(0,target_value-input_value) else -input_value end,
    case when won then 'Won an upgrade: '||coalesce(result_name,'target') else 'Lost an upgrade' end);
  select * into a from beta_accounts where id=uid;
  return jsonb_build_object('won',won,'chance',chance,'input_value',input_value,'target_value',target_value,'result_id',result_id,'result_name',result_name,'balance',a.balance);
end; $$;
grant execute on function public.beta_run_upgrade_v2(text,jsonb,bigint,jsonb) to anon,authenticated;


create or replace function public.beta_run_upgrade_v3(
  p_token text,p_input_pet_items jsonb,p_diamond_amount bigint,p_target_pet_ids jsonb,p_risk_angle numeric default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; diamond_amount bigint:=greatest(0,coalesce(p_diamond_amount,0));
  input_value bigint:=0; target_value bigint:=0; chance numeric; won boolean;
  result_id text; result_name text; a beta_accounts%rowtype; item jsonb; pid text; v text; qty integer; chosen_value bigint;
  risk_angle numeric:=mod(coalesce(p_risk_angle,0)+360,360); win_angle numeric; roll_angle numeric; spin_angle numeric;
begin
  select user_id into uid from beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from beta_accounts where id=uid;
  if jsonb_typeof(coalesce(p_input_pet_items,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_target_pet_ids,'[]'::jsonb))<>'array' then raise exception 'Invalid upgrade selection'; end if;
  if jsonb_array_length(coalesce(p_input_pet_items,'[]'::jsonb))=0 and diamond_amount<=0 then raise exception 'Select items or gems'; end if;
  if jsonb_array_length(coalesce(p_target_pet_ids,'[]'::jsonb))=0 then raise exception 'Select at least one target'; end if;
  if diamond_amount>(select balance from beta_accounts where id=uid) then raise exception 'Not enough gems'; end if;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id'); v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'One selected pet variant is no longer in your inventory'; end if;
    select coalesce(rap,0) into chosen_value from pets_cache where id=pid;
    if coalesce(chosen_value,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
    input_value:=input_value+chosen_value*qty;
  end loop;

  for item in select value from jsonb_array_elements(p_input_pet_items) loop
    pid:=coalesce(item->>'id',item->>'pet_id'); v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
    update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
    delete from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity<=0;
  end loop;

  input_value:=input_value+diamond_amount;
  if diamond_amount>0 then update beta_accounts set balance=balance-diamond_amount,updated_at=now() where id=uid; end if;
  select coalesce(sum(coalesce(rap,0)),0) into target_value from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0;
  if target_value<=0 then raise exception 'Target selection has no PS99 RAP yet.'; end if;

  chance:=least(95,greatest(1,(input_value::numeric/target_value::numeric)*100));
  win_angle:=chance*3.6;
  roll_angle:=random()*360;
  won:=(case when risk_angle+win_angle<=360
             then roll_angle between risk_angle and risk_angle+win_angle
             else roll_angle>=risk_angle or roll_angle<=risk_angle+win_angle-360 end);
  spin_angle:=1440 + mod(360-roll_angle,360);

  if won then
    select id,name into result_id,result_name from pets_cache where id in (select value from jsonb_array_elements_text(p_target_pet_ids)) and coalesce(rap,0)>0 order by random() limit 1;
    if result_id is null then raise exception 'No valid target reward was found'; end if;
    insert into beta_inventory(user_id,pet_id,variant,quantity) values(uid,result_id,'normal',1)
    on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  end if;

  insert into beta_activity(user_id,username,activity_type,amount,profit_loss,description)
  values(uid,uname,'upgrade_result',input_value,case when won then greatest(0,target_value-input_value) else -input_value end,
    case when won then 'Won an upgrade: '||coalesce(result_name,'target') else 'Lost an upgrade' end);
  select * into a from beta_accounts where id=uid;
  return jsonb_build_object('won',won,'chance',chance,'input_value',input_value,'target_value',target_value,
    'result_id',result_id,'result_name',result_name,'balance',a.balance,'risk_angle',risk_angle,
    'roll_angle',roll_angle,'spin_angle',spin_angle);
end; $$;
grant execute on function public.beta_run_upgrade_v3(text,jsonb,bigint,jsonb,numeric) to anon,authenticated;


-- V13 STAFF/ADMIN RPC FIX
create or replace function public.beta_admin_assert(p_token text)
returns uuid language plpgsql security definer set search_path=public as $$
declare uid uuid; r text;
begin
  select s.user_id,a.role into uid,r from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now();
  if uid is null or r not in ('owner','co_owner','manager','admin','moderator') then raise exception 'Staff access required'; end if;
  return uid;
end; $$;

create or replace function public.beta_admin_get_users(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  perform beta_admin_assert(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object('id',id,'username',username,'balance',balance,'role',role,'banned_until',banned_until,'muted_until',muted_until,'created_at',created_at) order by created_at desc) from beta_accounts),'[]'::jsonb);
end; $$;

grant execute on function public.beta_admin_get_users(text) to anon,authenticated;

create or replace function public.beta_admin_set_balance(p_token text,p_target_username text,p_balance bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; b bigint;
begin
  adminid:=beta_admin_assert(p_token);
  if p_balance<0 then raise exception 'Balance cannot be negative'; end if;
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  update beta_accounts set balance=p_balance,updated_at=now() where id=tid returning balance into b;
  return jsonb_build_object('ok',true,'username',p_target_username,'balance',b);
end; $$;
grant execute on function public.beta_admin_set_balance(text,text,bigint) to anon,authenticated;

create or replace function public.beta_admin_give_all(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; n integer;
begin
  adminid:=beta_admin_assert(p_token);
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  insert into beta_inventory(user_id,pet_id,variant,quantity)
  select tid,p.id,'normal',1 from pets_cache p where p.cosmic_value>0 and (lower(p.category) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %')
  on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+1,updated_at=now();
  select count(*) into n from pets_cache p where p.cosmic_value>0 and (lower(p.category) in ('huge','titanic','gargantuan') or lower(p.name) like 'huge %' or lower(p.name) like 'titanic %' or lower(p.name) like 'gargantuan %');
  return jsonb_build_object('ok',true,'count',n);
end; $$;
grant execute on function public.beta_admin_give_all(text,text) to anon,authenticated;

create or replace function public.beta_admin_moderate(p_token text,p_target_username text,p_action text,p_minutes integer,p_reason text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; until_at timestamptz;
begin
  adminid:=beta_admin_assert(p_token);
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  until_at:=case when p_minutes<=0 then null else now()+make_interval(mins=>p_minutes) end;
  if p_action='ban' then update beta_accounts set banned_until=until_at,ban_reason=left(coalesce(p_reason,''),200),updated_at=now() where id=tid;
  elsif p_action='unban' then update beta_accounts set banned_until=null,ban_reason=null,updated_at=now() where id=tid;
  elsif p_action='mute' then update beta_accounts set muted_until=until_at,updated_at=now() where id=tid;
  elsif p_action='unmute' then update beta_accounts set muted_until=null,updated_at=now() where id=tid;
  else raise exception 'Unknown moderation action'; end if;
  return jsonb_build_object('ok',true);
end; $$;
grant execute on function public.beta_admin_moderate(text,text,text,integer,text) to anon,authenticated;

create or replace function public.beta_admin_set_role(p_token text,p_target_username text,p_role text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; adminrole text; tid uuid; newrole text:=lower(trim(p_role));
begin
  select s.user_id,a.role into adminid,adminrole from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now();
  if adminid is null then raise exception 'Staff access required'; end if;
  if adminrole not in ('owner','co_owner','manager','admin') then raise exception 'Only Owner, Co Owner, Manager or Admin can change roles'; end if;
  if newrole not in ('user','helper','moderator','admin','manager','co_owner','owner') then raise exception 'Invalid role'; end if;
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username));
  if tid is null then raise exception 'User not found'; end if;
  if tid=adminid and newrole<>'owner' and adminrole='owner' then null; end if;
  if adminrole='admin' and newrole in ('owner','co_owner','manager') then raise exception 'Admin cannot grant Owner, Co Owner or Manager'; end if;
  if adminrole='manager' and newrole in ('owner','co_owner') then raise exception 'Manager cannot grant Owner or Co Owner'; end if;
  if adminrole='co_owner' and newrole='owner' then raise exception 'Co Owner cannot grant Owner'; end if;
  update beta_accounts set role=newrole,updated_at=now() where id=tid;
  return jsonb_build_object('ok',true,'username',(select username from beta_accounts where id=tid),'role',newrole);
end; $$;
grant execute on function public.beta_admin_set_role(text,text,text) to anon,authenticated;

-- Event control. Only Owner / Co Owner / Manager / Admin can toggle it.
create or replace function public.beta_admin_set_event(p_token text,p_enabled boolean)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; r text; eid uuid;
begin
  select s.user_id,a.role into uid,r from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now();
  if uid is null or r not in ('owner','co_owner','manager','admin') then raise exception 'Only Owner, Co Owner, Manager or Admin can control the event'; end if;
  select id into eid from beta_events where slug='red-vs-blue' limit 1;
  if eid is null then
    insert into beta_events(slug,title,description,bank_value,status) values('red-vs-blue','RED vs BLUE · Virtual World','A 100B virtual event where the whole beta community pushes one of two teams.',100000000000,case when p_enabled then 'live' else 'ended' end) returning id into eid;
  else
    update beta_events set status=case when p_enabled then 'live' else 'ended' end,updated_at=now() where id=eid;
  end if;
  return beta_get_active_event(p_token);
end; $$;
grant execute on function public.beta_admin_set_event(text,boolean) to anon,authenticated;

create or replace function public.beta_admin_create_promo(p_token text,p_code text,p_reward_amount bigint,p_max_uses integer,p_duration_minutes integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; r text; pid bigint; clean text:=upper(regexp_replace(trim(coalesce(p_code,'')),'\s+','','g'));
begin
  select a.id,a.role into uid,r from beta_sessions s join beta_accounts a on a.id=s.user_id where s.token=p_token and s.expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  if r not in ('owner','co_owner','manager','admin') then raise exception 'Promo codes require Owner, Co Owner, Manager or Admin'; end if;
  if clean !~ '^[A-Z0-9_-]{3,32}$' then raise exception 'Code must be 3-32 letters, numbers, _ or -'; end if;
  if p_reward_amount<=0 then raise exception 'Reward must be greater than 0'; end if;
  if p_max_uses<1 or p_max_uses>100000 then raise exception 'Invalid max uses'; end if;
  if p_duration_minutes<1 or p_duration_minutes>43200 then raise exception 'Invalid duration'; end if;
  insert into beta_promo_codes(code,reward_amount,max_uses,created_by,expires_at) values(clean,p_reward_amount,p_max_uses,uid,now()+make_interval(mins=>p_duration_minutes)) returning id into pid;
  return jsonb_build_object('ok',true,'id',pid,'code',clean,'reward_amount',p_reward_amount);
end; $$;
grant execute on function public.beta_admin_create_promo(text,text,bigint,integer,integer) to anon,authenticated;

create or replace function public.beta_admin_get_inventory(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid;
begin
  adminid:=beta_admin_assert(p_token);
  select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'pet_id',i.pet_id,'name',p.name,'variant',i.variant,'quantity',i.quantity,'rap',p.rap,'thumbnail_asset',p.thumbnail_asset,'thumbnail_url',p.thumbnail_url,'golden_thumbnail_asset',p.golden_thumbnail_asset,'golden_thumbnail_url',p.golden_thumbnail_url) order by p.name) from beta_inventory i join pets_cache p on p.id=i.pet_id where i.user_id=tid),'[]'::jsonb);
end; $$;
grant execute on function public.beta_admin_get_inventory(text,text) to anon,authenticated;

create or replace function public.beta_admin_clear_inventory(p_token text,p_target_username text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; n integer;
begin
  adminid:=beta_admin_assert(p_token); select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  select count(*) into n from beta_inventory where user_id=tid; delete from beta_inventory where user_id=tid; return jsonb_build_object('ok',true,'removed_rows',n);
end; $$;
grant execute on function public.beta_admin_clear_inventory(text,text) to anon,authenticated;

create or replace function public.beta_admin_remove_pet(p_token text,p_target_username text,p_pet_id text,p_variant text,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; q integer; take integer:=greatest(1,coalesce(p_quantity,1));
begin
  adminid:=beta_admin_assert(p_token); select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  select quantity into q from beta_inventory where user_id=tid and pet_id=p_pet_id and variant=coalesce(p_variant,'normal'); if q is null then raise exception 'Pet is not in inventory'; end if;
  if q<=take then delete from beta_inventory where user_id=tid and pet_id=p_pet_id and variant=coalesce(p_variant,'normal'); else update beta_inventory set quantity=quantity-take,updated_at=now() where user_id=tid and pet_id=p_pet_id and variant=coalesce(p_variant,'normal'); end if;
  return jsonb_build_object('ok',true);
end; $$;
grant execute on function public.beta_admin_remove_pet(text,text,text,text,integer) to anon,authenticated;

create or replace function public.beta_admin_add_pet(p_token text,p_target_username text,p_pet_id text,p_variant text,p_quantity integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare adminid uuid; tid uuid; take integer:=greatest(1,coalesce(p_quantity,1));
begin
  adminid:=beta_admin_assert(p_token); select id into tid from beta_accounts where lower(username)=lower(trim(p_target_username)); if tid is null then raise exception 'User not found'; end if;
  if p_variant not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet variant'; end if;
  if not exists(select 1 from pets_cache where id=p_pet_id and (lower(category) in ('huge','titanic','gargantuan') or lower(name) like 'huge %' or lower(name) like 'titanic %' or lower(name) like 'gargantuan %')) then raise exception 'Pet is not in high-tier catalog'; end if;
  insert into beta_inventory(user_id,pet_id,variant,quantity) values(tid,p_pet_id,p_variant,take) on conflict(user_id,pet_id,variant) do update set quantity=beta_inventory.quantity+take,updated_at=now();
  return jsonb_build_object('ok',true,'quantity',take);
end; $$;
grant execute on function public.beta_admin_add_pet(text,text,text,text,integer) to anon,authenticated;
