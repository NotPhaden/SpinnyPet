-- SpinnyPet V21.7 FINAL FIXES
-- Run AFTER V21.6_FINAL_FIXES.sql / V21.5_FINAL_FIXES.sql.
-- Fixes Time Rewards stage ambiguity at the database level and keeps Color Dice/Case Battle compatible.

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

-- Manual claim is intentionally disabled: tickets are granted automatically by beta_get_time_rewards.
drop function if exists public.beta_claim_time_reward(text,integer);
create or replace function public.beta_claim_time_reward(p_token text,p_stage integer)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  raise exception 'Time Rewards unlock automatically when the timer ends. Open the unlocked ticket instead.';
end;
$$;
grant execute on function public.beta_claim_time_reward(text,integer) to anon,authenticated;

notify pgrst,'reload schema';
