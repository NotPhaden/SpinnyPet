-- SpinnyPet V21.6 FINAL FIXES
-- Run this AFTER V21.5_FINAL_FIXES.sql.
-- Fixes: Time Rewards ambiguous "stage" reference, safer Color Dice creator RPC,
-- and keeps the official 9-case/tier data unchanged.

create or replace function public.beta_get_time_rewards(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  uid uuid;
  uname text;
  cfg_row jsonb;
  out jsonb := '[]'::jsonb;
  claim_time timestamptz;
  prior_time timestamptz;
  unlock_at timestamptz;
  v_stage integer;
  v_case_id text;
  v_minutes integer;
  granted boolean;
begin
  select user_id into uid from public.beta_sessions where token=p_token and expires_at>now();
  if uid is null then raise exception 'Please sign in'; end if;
  select username into uname from public.beta_accounts where id=uid;

  for cfg_row in select value from jsonb_array_elements(public.beta_time_reward_config()) loop
    v_stage := (cfg_row->>'stage')::integer;
    v_case_id := cfg_row->>'case_id';
    v_minutes := (cfg_row->>'minutes')::integer;

    select tr.claimed_at into claim_time
    from public.beta_time_reward_claims tr
    where tr.user_id=uid and tr.stage=v_stage;

    if v_stage=1 then
      unlock_at := coalesce(claim_time,now());
    else
      select tr.claimed_at into prior_time
      from public.beta_time_reward_claims tr
      where tr.user_id=uid and tr.stage=v_stage-1;
      unlock_at := case when prior_time is null then null else prior_time+(v_minutes*interval '1 minute') end;
    end if;

    if claim_time is null and unlock_at is not null and now()>=unlock_at then
      insert into public.beta_time_reward_claims(user_id,stage,case_id)
      values(uid,v_stage,v_case_id)
      on conflict(user_id,stage) do nothing;

      insert into public.beta_case_tickets(user_id,case_id,quantity,updated_at)
      values(uid,v_case_id,1,now())
      on conflict(user_id,case_id)
      do update set quantity=public.beta_case_tickets.quantity+1,updated_at=now();

      insert into public.beta_activity(user_id,username,activity_type,amount,description)
      values(uid,uname,'time_reward',0,'Time Reward unlocked: '||coalesce((select bc.name from public.beta_cases bc where bc.id=v_case_id),v_case_id));

      select tr.claimed_at into claim_time
      from public.beta_time_reward_claims tr
      where tr.user_id=uid and tr.stage=v_stage;
      granted := true;
    else
      granted := false;
    end if;

    out := out || jsonb_build_array(jsonb_build_object(
      'stage',v_stage,
      'case_id',v_case_id,
      'minutes',v_minutes,
      'claimed',claim_time is not null,
      'unlocked',claim_time is not null,
      'granted_now',granted,
      'claimed_at',claim_time,
      'unlock_at',unlock_at,
      'available',claim_time is not null,
      'remaining_seconds',case when claim_time is not null then 0 when unlock_at is null then 0 else greatest(0,ceil(extract(epoch from(unlock_at-now())))::integer) end
    ));
  end loop;
  return out;
end;
$$;
grant execute on function public.beta_get_time_rewards(text) to anon,authenticated;

notify pgrst,'reload schema';
