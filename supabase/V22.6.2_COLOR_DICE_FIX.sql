-- SpinnyPet V22.6.2 - Color Dice live-match + color-lock database patch
-- Apply AFTER V22.6_FINAL_FIXES.sql.
-- Prevents a joiner from selecting either color already reserved by the host.

-- Dedicated join path. Same positive-quantity invariant and records joiner identity.
create or replace function public.beta_join_dice_lobby(
  p_token text,
  p_lobby_id uuid,
  p_pet_items jsonb default '[]'::jsonb,
  p_choice text default null
)
returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  uid uuid; uname text; avatar text; lid uuid; host_id uuid; host_name text; host_avatar text;
  st text; amt bigint; host_choice text; host_items jsonb; item jsonb;
  pid text; v text; qty integer; total bigint:=0; pv bigint; winner uuid; wname text;
  roll_color text; host_has boolean; join_has boolean; payout_value bigint:=0; i integer; bal bigint;
  join_choice_value text:=trim(coalesce(p_choice,''));
begin
  select s.user_id into uid from beta_sessions s where s.token=p_token and s.expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select id,creator_id,creator_username,creator_avatar_url,stake_type,stake_amount,choice,stake_pet_items
    into lid,host_id,host_name,host_avatar,st,amt,host_choice,host_items
  from beta_game_lobbies where id=p_lobby_id and game_type='dice' and status='open' and creator_id<>uid for update;
  if lid is null then raise exception 'Color Dice match is no longer available'; end if;
  if join_choice_value !~ '^(Red|Orange|Yellow|Green|Blue|Purple),(Red|Orange|Yellow|Green|Blue|Purple)$' then raise exception 'Choose exactly 2 valid colors'; end if;
  if split_part(join_choice_value,',',1)=split_part(join_choice_value,',',2) then raise exception 'Choose two different colors'; end if;
  if split_part(join_choice_value,',',1)=any(string_to_array(host_choice,','))
     or split_part(join_choice_value,',',2)=any(string_to_array(host_choice,',')) then
    raise exception 'Those colors are already taken by the host';
  end if;
  select username,coalesce(custom_avatar_url,avatar_url) into uname,avatar from beta_accounts where id=uid;

  if st='diamonds' then
    if amt<5000000000 or amt>(select balance from beta_accounts where id=uid) then raise exception 'You do not have enough gems to join'; end if;
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
      for item in select value from jsonb_array_elements(coalesce(host_items,'[]'::jsonb)) loop perform beta_inventory_add_safe(host_id,item->>'pet_id',coalesce(item->>'variant','normal'),greatest(1,coalesce((item->>'quantity')::integer,1))); end loop;
      for item in select value from jsonb_array_elements(coalesce(p_pet_items,'[]'::jsonb)) loop perform beta_inventory_add_safe(uid,item->>'pet_id',coalesce(item->>'variant','normal'),greatest(1,coalesce((item->>'quantity')::integer,1))); end loop;
    end if;
  elsif st='diamonds' then
    update beta_accounts set balance=balance+payout_value,updated_at=now() where id=winner returning balance into bal;
  else
    for item in select value from jsonb_array_elements(coalesce(host_items,'[]'::jsonb)) loop perform beta_inventory_add_safe(winner,item->>'pet_id',coalesce(item->>'variant','normal'),greatest(1,coalesce((item->>'quantity')::integer,1))); end loop;
    for item in select value from jsonb_array_elements(coalesce(p_pet_items,'[]'::jsonb)) loop perform beta_inventory_add_safe(winner,item->>'pet_id',coalesce(item->>'variant','normal'),greatest(1,coalesce((item->>'quantity')::integer,1))); end loop;
  end if;

  update beta_game_lobbies set status='finished',joiner_id=uid,joiner_username=uname,joiner_avatar_url=avatar,join_pet_items=coalesce(p_pet_items,'[]'::jsonb),join_choice=join_choice_value,result_side=roll_color,winner_id=winner,winner_username=wname,payout=payout_value where id=lid;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,profit_loss,description)
  values(coalesce(winner,uid),coalesce(wname,uname),'game_result','dice',payout_value,case when winner is null then 0 else payout_value-amt end,'Color Dice roll: '||roll_color);
  return jsonb_build_object('ok',true,'status','finished','lobby_id',lid,'creator_id',host_id,'creator_username',host_name,'creator_avatar_url',host_avatar,'joiner_id',uid,'joiner_username',uname,'joiner_avatar_url',avatar,'choice',host_choice,'join_choice',join_choice_value,'result_side',roll_color,'winner_id',winner,'winner_username',wname,'payout',payout_value,'draw',winner is null);
end; $$;
grant execute on function public.beta_join_dice_lobby(text,uuid,jsonb,text) to anon,authenticated;

notify pgrst,'reload schema';
