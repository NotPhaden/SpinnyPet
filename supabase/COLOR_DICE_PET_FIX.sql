-- Color Dice pet-stake hotfix for existing SpinnyPet deployments.
-- Run this after the existing SQL stack. It removes the quantity=0 intermediate update.

create or replace function public.beta_create_dice_lobby(
  p_token text, p_stake_type text, p_stake_amount bigint,
  p_pet_items jsonb default '[]'::jsonb, p_choice text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; uname text; avatar text; lid uuid; item jsonb; pid text; v text; qty integer; total bigint:=0; count_items integer:=0; first_id text; first_name text; first_variant text; pv bigint; choice text:=trim(coalesce(p_choice,''));
begin
  select s.user_id into uid from beta_sessions s where s.token=p_token and s.expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username,coalesce(custom_avatar_url,avatar_url) into uname,avatar from beta_accounts where id=uid;
  if p_stake_type not in ('diamonds','pet') then raise exception 'Invalid stake type'; end if;
  if choice !~ '^(Red|Orange|Yellow|Green|Blue|Purple),(Red|Orange|Yellow|Green|Blue|Purple)$' then raise exception 'Choose exactly 2 valid colors'; end if;
  if split_part(choice,',',1)=split_part(choice,',',2) then raise exception 'Choose two different colors'; end if;
  if p_stake_type='diamonds' then
    if coalesce(p_stake_amount,0)<5000000000 then raise exception 'Color Dice minimum wager is 5B gems'; end if;
    if p_stake_amount>(select balance from beta_accounts where id=uid) then raise exception 'You do not have enough gems'; end if;
    update beta_accounts set balance=balance-p_stake_amount,updated_at=now() where id=uid;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,creator_avatar_url,stake_type,stake_amount,pet_count,stake_pet_items,choice) values('dice',uid,uname,avatar,'diamonds',p_stake_amount,0,'[]'::jsonb,choice) returning id into lid;
  else
    if jsonb_typeof(coalesce(p_pet_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_pet_items,'[]'::jsonb))=0 then raise exception 'Select at least one pet'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if pid is null or v not in ('normal','golden','rainbow','shiny') then raise exception 'Invalid pet selection'; end if;
      if not exists(select 1 from beta_inventory where user_id=uid and pet_id=pid and variant=v and quantity>=qty) then raise exception 'You do not own the selected pet variant'; end if;
      select coalesce(rap,0),name into pv,first_name from pets_cache where id=pid;
      if coalesce(pv,0)<=0 then raise exception 'Selected pet has no PS99 RAP'; end if;
      total:=total+pv*qty; count_items:=count_items+qty; if first_id is null then first_id:=pid; first_variant:=v; end if;
    end loop;
    if total<5000000000 then raise exception 'Color Dice pet wager must be worth at least 5B gems'; end if;
    for item in select value from jsonb_array_elements(p_pet_items) loop
      pid:=item->>'pet_id'; v:=coalesce(item->>'variant','normal'); qty:=greatest(1,coalesce((item->>'quantity')::integer,1));
      if (select quantity from beta_inventory where user_id=uid and pet_id=pid and variant=v)=qty then
        delete from beta_inventory where user_id=uid and pet_id=pid and variant=v;
      else
        update beta_inventory set quantity=quantity-qty,updated_at=now() where user_id=uid and pet_id=pid and variant=v;
      end if;
    end loop;
    insert into beta_game_lobbies(game_type,creator_id,creator_username,creator_avatar_url,stake_type,stake_amount,pet_id,pet_name,pet_variant,pet_count,stake_pet_items,choice) values('dice',uid,uname,avatar,'pet',total,first_id,first_name,first_variant,count_items,p_pet_items,choice) returning id into lid;
  end if;
  insert into beta_activity(user_id,username,activity_type,game_type,amount,description) values(uid,uname,'game_created','dice',case when p_stake_type='pet' then total else p_stake_amount end,'Created a Color Dice game');
  return jsonb_build_object('ok',true,'id',lid,'status','open','stake_amount',case when p_stake_type='pet' then total else p_stake_amount end,'pet_count',count_items);
end; $$;
grant execute on function public.beta_create_dice_lobby(text,text,bigint,jsonb,text) to anon,authenticated;

notify pgrst,'reload schema';
