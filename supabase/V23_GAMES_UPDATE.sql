-- SpinnyPet V23 · Original Games
-- Adds server-settled Pet Mines, Pet Plinko and Pet Crash.
-- Run AFTER V22.7_SUPER_UPDATE_FIXED.sql.
-- Virtual diamonds only in V23. Pet-stake mode can be added later without changing game state.

begin;

create table if not exists public.beta_v23_games (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.beta_accounts(id) on delete cascade,
  game_type text not null check(game_type in ('mines','plinko','crash')),
  stake_amount bigint not null check(stake_amount > 0),
  status text not null default 'playing' check(status in ('playing','won','lost','crashed')),
  mine_positions integer[],
  revealed_positions integer[] not null default '{}',
  multiplier numeric(12,4) not null default 1,
  crash_point numeric(12,4),
  started_at timestamptz not null default now(),
  settled_at timestamptz,
  payout bigint not null default 0 check(payout >= 0),
  metadata jsonb not null default '{}'::jsonb
);
create index if not exists beta_v23_games_user_idx on public.beta_v23_games(user_id,started_at desc);
create index if not exists beta_v23_games_open_idx on public.beta_v23_games(user_id,game_type,status);

alter table public.beta_v23_games enable row level security;
revoke all on public.beta_v23_games from anon, authenticated;

create or replace function public.beta_v23_uid(p_token text)
returns uuid
language plpgsql security definer set search_path=public as $$
declare uid uuid;
begin
  select user_id into uid from public.beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  return uid;
end; $$;
grant execute on function public.beta_v23_uid(text) to anon, authenticated;

create or replace function public.beta_mines_start(p_token text,p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; gid uuid; mines integer[]; bal bigint; safe_count integer:=22;
begin
  uid:=public.beta_v23_uid(p_token);
  if coalesce(p_amount,0)<1000000 then raise exception 'Mines requires at least 1M diamonds'; end if;
  select balance into bal from beta_accounts where id=uid for update;
  if bal<p_amount then raise exception 'Not enough diamonds'; end if;
  if exists(select 1 from beta_v23_games where user_id=uid and game_type='mines' and status='playing') then raise exception 'You already have an active Mines round'; end if;
  select array_agg(x order by random()) into mines from generate_series(0,24) x;
  mines:=mines[1:3];
  update beta_accounts set balance=balance-p_amount,updated_at=now() where id=uid;
  insert into beta_v23_games(user_id,game_type,stake_amount,mine_positions) values(uid,'mines',p_amount,mines) returning id into gid;
  return jsonb_build_object('id',gid,'status','playing','stake_amount',p_amount,'mine_count',3,'safe_tiles',safe_count,'started_at',now());
end; $$;
grant execute on function public.beta_mines_start(text,bigint) to anon, authenticated;

create or replace function public.beta_mines_reveal(p_token text,p_game_id uuid,p_index integer)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; g beta_v23_games%rowtype; hit boolean; safe_count integer; mult numeric; payout bigint; rev integer[];
begin
  uid:=public.beta_v23_uid(p_token);
  if p_index<0 or p_index>24 then raise exception 'Invalid tile'; end if;
  select * into g from beta_v23_games where id=p_game_id and user_id=uid for update;
  if g.id is null then raise exception 'Game not found'; end if;
  if g.status<>'playing' then raise exception 'This round is already settled'; end if;
  if p_index=any(coalesce(g.revealed_positions,'{}')) then raise exception 'Tile already revealed'; end if;
  hit:=p_index=any(g.mine_positions);
  rev:=array_append(coalesce(g.revealed_positions,'{}'),p_index);
  if hit then
    update beta_v23_games set revealed_positions=rev,status='lost',settled_at=now(),multiplier=1,payout=0 where id=g.id;
    return jsonb_build_object('hit',true,'multiplier',1,'payout',0,'mines',g.mine_positions,'revealed',rev);
  end if;
  safe_count:=array_length(rev,1);
  mult:=round(power(1.16,safe_count)::numeric,4);
  payout:=floor(g.stake_amount*mult);
  update beta_v23_games set revealed_positions=rev,multiplier=mult where id=g.id;
  return jsonb_build_object('hit',false,'multiplier',mult,'payout',payout,'revealed',rev);
end; $$;
grant execute on function public.beta_mines_reveal(text,uuid,integer) to anon, authenticated;

create or replace function public.beta_mines_cashout(p_token text,p_game_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; g beta_v23_games%rowtype; payout bigint; safe_count integer; bal bigint;
begin
  uid:=public.beta_v23_uid(p_token);
  select * into g from beta_v23_games where id=p_game_id and user_id=uid for update;
  if g.id is null then raise exception 'Game not found'; end if;
  if g.status<>'playing' then raise exception 'This round is already settled'; end if;
  safe_count:=coalesce(array_length(g.revealed_positions,1),0);
  if safe_count<1 then raise exception 'Reveal at least one safe tile first'; end if;
  payout:=floor(g.stake_amount*g.multiplier);
  update beta_accounts set balance=balance+payout,updated_at=now() where id=uid returning balance into bal;
  update beta_v23_games set status='won',settled_at=now(),payout=payout where id=g.id;
  return jsonb_build_object('status','won','multiplier',g.multiplier,'payout',payout,'balance',bal);
end; $$;
grant execute on function public.beta_mines_cashout(text,uuid) to anon, authenticated;

create or replace function public.beta_plinko_play(p_token text,p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; bal bigint; r numeric; m numeric; payout bigint; path text; steps integer:=7;
begin
  uid:=public.beta_v23_uid(p_token);
  if coalesce(p_amount,0)<1000000 then raise exception 'Plinko requires at least 1M diamonds'; end if;
  select balance into bal from beta_accounts where id=uid for update;
  if bal<p_amount then raise exception 'Not enough diamonds'; end if;
  update beta_accounts set balance=balance-p_amount,updated_at=now() where id=uid;
  r:=random();
  m:=case
    when r<0.03 then 10.0
    when r<0.07 then 5.0
    when r<0.15 then 3.0
    when r<0.28 then 2.0
    when r<0.45 then 1.5
    when r<0.68 then 1.0
    when r<0.84 then 0.5
    else 0.2 end;
  payout:=floor(p_amount*m);
  if payout>0 then update beta_accounts set balance=balance+payout,updated_at=now() where id=uid returning balance into bal; end if;
  path:=case when random()<.5 then 'L' else 'R' end || case when random()<.5 then 'L' else 'R' end || case when random()<.5 then 'L' else 'R' end || case when random()<.5 then 'L' else 'R' end || case when random()<.5 then 'L' else 'R' end || case when random()<.5 then 'L' else 'R' end || case when random()<.5 then 'L' else 'R' end;
  insert into beta_v23_games(user_id,game_type,stake_amount,status,multiplier,payout,settled_at,metadata) values(uid,'plinko',p_amount,'won',m,payout,now(),jsonb_build_object('path',path,'multiplier',m));
  return jsonb_build_object('multiplier',m,'payout',payout,'path',path,'balance',bal);
end; $$;
grant execute on function public.beta_plinko_play(text,bigint) to anon, authenticated;

create or replace function public.beta_crash_start(p_token text,p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; gid uuid; bal bigint; cp numeric; uname text;
begin
  uid:=public.beta_v23_uid(p_token);
  if coalesce(p_amount,0)<1000000 then raise exception 'Crash requires at least 1M diamonds'; end if;
  select balance into bal from beta_accounts where id=uid for update;
  if bal<p_amount then raise exception 'Not enough diamonds'; end if;
  if exists(select 1 from beta_v23_games where user_id=uid and game_type='crash' and status='playing') then raise exception 'You already have an active Crash round'; end if;
  -- Heavy tail with a hard floor: most rounds are short, occasional rounds run high.
  cp:=greatest(1.01,least(50,round((1.01/(1-random()))::numeric,4)));
  update beta_accounts set balance=balance-p_amount,updated_at=now() where id=uid;
  insert into beta_v23_games(user_id,game_type,stake_amount,status,crash_point) values(uid,'crash',p_amount,'playing',cp) returning id into gid;
  return jsonb_build_object('id',gid,'stake_amount',p_amount,'started_at',now(),'status','playing');
end; $$;
grant execute on function public.beta_crash_start(text,bigint) to anon, authenticated;

create or replace function public.beta_crash_cashout(p_token text,p_game_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; g beta_v23_games%rowtype; elapsed numeric; current_mult numeric; payout bigint; bal bigint;
begin
  uid:=public.beta_v23_uid(p_token);
  select * into g from beta_v23_games where id=p_game_id and user_id=uid for update;
  if g.id is null then raise exception 'Game not found'; end if;
  if g.status<>'playing' then raise exception 'This round is already settled'; end if;
  elapsed:=extract(epoch from (now()-g.started_at));
  current_mult:=greatest(1,exp(elapsed/9.0));
  if current_mult>=g.crash_point then
    update beta_v23_games set status='crashed',settled_at=now(),multiplier=g.crash_point,payout=0 where id=g.id;
    raise exception 'CRASHED at %×',to_char(g.crash_point,'FM999990.00');
  end if;
  current_mult:=least(current_mult,g.crash_point-0.01);
  payout:=floor(g.stake_amount*current_mult);
  update beta_accounts set balance=balance+payout,updated_at=now() where id=uid returning balance into bal;
  update beta_v23_games set status='won',settled_at=now(),multiplier=current_mult,payout=payout where id=g.id;
  return jsonb_build_object('status','won','multiplier',current_mult,'payout',payout,'balance',bal);
end; $$;
grant execute on function public.beta_crash_cashout(text,uuid) to anon, authenticated;

commit;
