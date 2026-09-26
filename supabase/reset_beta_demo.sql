-- Optional: reset ONLY the beta testing economy for a fresh demo.
-- Safe to run even if some optional beta tables have not been created yet.
do $$
declare
  t text;
  tables text[] := array[
    'beta_event_members',
    'beta_giveaway_entries',
    'beta_giveaways',
    'beta_activity',
    'beta_chat_messages',
    'beta_inventory',
    'beta_sessions',
    'beta_accounts'
  ];
begin
  foreach t in array tables loop
    if to_regclass('public.' || t) is not null then
      execute format('truncate table public.%I cascade', t);
    end if;
  end loop;

  if to_regclass('public.beta_events') is not null then
    update public.beta_events
    set red_score=0, blue_score=0, status='ended', updated_at=now();
  end if;
end $$;
