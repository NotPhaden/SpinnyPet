-- SpinnyPet V22.5 FINAL FIXES
-- Color Dice countdown/menu + staff clan controls + leaderboard reset + Clan Battle timer.

-- ============================================================
-- LEADERBOARD RESET (OWNER ONLY)
-- Keeps all game/activity history intact. Only leaderboard totals
-- are calculated from activity after the latest reset timestamp.
-- ============================================================
create table if not exists public.beta_leaderboard_resets (
  id integer primary key check (id=1),
  reset_at timestamptz not null default now()
);
insert into public.beta_leaderboard_resets(id,reset_at)
values(1,now())
on conflict(id) do nothing;

create or replace function public.beta_admin_reset_leaderboard(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; r text; ts timestamptz:=now();
begin
  select s.user_id,a.role into uid,r
  from beta_sessions s join beta_accounts a on a.id=s.user_id
  where s.token=p_token and s.expires_at>now();
  if uid is null or r<>'owner' then
    raise exception 'Only Owner can reset the leaderboard';
  end if;
  insert into beta_leaderboard_resets(id,reset_at) values(1,ts)
  on conflict(id) do update set reset_at=excluded.reset_at;
  return jsonb_build_object('ok',true,'reset_at',ts);
end; $$;
grant execute on function public.beta_admin_reset_leaderboard(text) to anon,authenticated;

drop function if exists public.beta_get_leaderboard(text);
create or replace function public.beta_get_leaderboard(p_mode text default 'wagered')
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.metric desc,x.username), '[]'::jsonb)
  from (
    select a.roblox_user_id as "robloxId", a.username,
      coalesce(a.custom_avatar_url,a.avatar_url) as avatar,
      count(e.id) filter(where e.activity_type='game_result')::bigint as "gamesPlayed",
      count(e.id) filter(where e.activity_type='game_result' and e.profit_loss>0)::bigint as "gamesWon",
      coalesce(sum(case when e.activity_type='game_result' then e.profit_loss else 0 end),0)::bigint as "totalProfit",
      coalesce(sum(case when e.activity_type in ('game_created','game_joined') then e.amount else 0 end),0)::bigint as "totalWagered",
      case when lower(coalesce(p_mode,'wagered'))='profit'
        then coalesce(sum(case when e.activity_type='game_result' then e.profit_loss else 0 end),0)
        else coalesce(sum(case when e.activity_type in ('game_created','game_joined') then e.amount else 0 end),0)
      end as metric
    from beta_accounts a
    cross join beta_leaderboard_resets lr
    left join beta_activity e on e.user_id=a.id and e.created_at>lr.reset_at
    group by a.id,a.roblox_user_id,a.username,a.custom_avatar_url,a.avatar_url
  ) x
  limit 100;
$$;
grant execute on function public.beta_get_leaderboard(text) to anon,authenticated;

-- ============================================================
-- STAFF CLAN DELETE: Owner + Manager can delete ANY clan.
-- Cascades members/invites through the existing FK definitions.
-- ============================================================
create or replace function public.beta_admin_delete_clan(p_token text,p_clan_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; r text; cname text;
begin
  select s.user_id,a.role into uid,r
  from beta_sessions s join beta_accounts a on a.id=s.user_id
  where s.token=p_token and s.expires_at>now();
  if uid is null or r not in ('owner','manager') then
    raise exception 'Only Owner or Manager can delete clans';
  end if;
  select name into cname from beta_clans where id=p_clan_id;
  if cname is null then raise exception 'Clan not found'; end if;
  delete from beta_clans where id=p_clan_id;
  return jsonb_build_object('ok',true,'clan_id',p_clan_id,'clan_name',cname);
end; $$;
grant execute on function public.beta_admin_delete_clan(text,uuid) to anon,authenticated;

-- ============================================================
-- CLAN BATTLE GLOBAL 48H TIMER
-- Owner + Manager may restart it after the 48h period ends.
-- ============================================================
create table if not exists public.beta_clan_battle_settings (
  id integer primary key check(id=1),
  end_at timestamptz not null,
  updated_at timestamptz not null default now()
);
insert into public.beta_clan_battle_settings(id,end_at)
values(1,now()+interval '48 hours')
on conflict(id) do nothing;

create or replace function public.beta_get_clan_battle_timer()
returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object('end_at',end_at,'updated_at',updated_at,'active',end_at>now())
  from beta_clan_battle_settings where id=1;
$$;
grant execute on function public.beta_get_clan_battle_timer() to anon,authenticated;

create or replace function public.beta_admin_reset_clan_battle_timer(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid; r text; next_end timestamptz:=now()+interval '48 hours'; current_end timestamptz;
begin
  select s.user_id,a.role into uid,r
  from beta_sessions s join beta_accounts a on a.id=s.user_id
  where s.token=p_token and s.expires_at>now();
  if uid is null or r not in ('owner','manager') then
    raise exception 'Only Owner or Manager can reset the Clan Battle timer';
  end if;
  select end_at into current_end from beta_clan_battle_settings where id=1;
  if current_end is not null and current_end>now() then
    raise exception 'Clan Battle is still active for %', to_char(current_end-now(),'HH24:MI:SS');
  end if;
  insert into beta_clan_battle_settings(id,end_at,updated_at)
  values(1,next_end,now())
  on conflict(id) do update set end_at=excluded.end_at,updated_at=excluded.updated_at;
  return jsonb_build_object('ok',true,'end_at',next_end);
end; $$;
grant execute on function public.beta_admin_reset_clan_battle_timer(text) to anon,authenticated;

notify pgrst,'reload schema';
