-- MAYAMA V19: additional server-side score sanity checks.
-- Run this in Supabase SQL Editor after the existing V16 setup.
-- This replaces only submit_score; it does not alter the leaderboard functions or data.

create or replace function public.submit_score(
  p_nickname text,
  p_score integer,
  p_mayama_clears integer,
  p_max_chain integer,
  p_player_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_allowed uuid;
begin
  if p_player_id is null then
    raise exception 'Missing player ID';
  end if;

  if p_nickname is null or char_length(btrim(p_nickname)) < 1 or char_length(btrim(p_nickname)) > 16 then
    raise exception 'Nickname must be 1-16 characters';
  end if;

  if p_score is null or p_score < 0 or p_score > 1000000 then
    raise exception 'Score outside allowed range';
  end if;
  if p_mayama_clears is null or p_mayama_clears < 0 or p_mayama_clears > 10000 then
    raise exception 'Clear count outside allowed range';
  end if;
  if p_max_chain is null or p_max_chain < 0 or p_max_chain > 100 then
    raise exception 'Chain count outside allowed range';
  end if;

  -- Score increments are always multiples of 100 in the current game rules.
  if p_score % 100 <> 0 then
    raise exception 'Invalid score increment';
  end if;

  -- A positive score requires at least one MAYAMA path and a non-zero chain.
  if p_score = 0 and (p_mayama_clears <> 0 or p_max_chain <> 0) then
    raise exception 'Inconsistent zero-score result';
  end if;
  if p_score > 0 and (p_mayama_clears < 1 or p_max_chain < 1) then
    raise exception 'Inconsistent score and clear count';
  end if;
  if p_max_chain > p_mayama_clears then
    raise exception 'Chain count exceeds total clears';
  end if;

  -- Each MAYAMA path contains six cells. The union of cells cleared cannot
  -- exceed six times the number of paths; each cell is worth 100 points,
  -- multiplied by a chain multiplier no greater than the recorded max chain.
  if p_score > (600::bigint * p_mayama_clears * greatest(p_max_chain, 1)) then
    raise exception 'Score is inconsistent with clear and chain counts';
  end if;

  -- Keep the existing per-player cooldown.
  insert into public.score_submission_limits(player_id,last_submitted_at)
  values (p_player_id, now())
  on conflict (player_id) do update
    set last_submitted_at = now()
    where public.score_submission_limits.last_submitted_at < now() - interval '15 seconds'
  returning player_id into v_allowed;
  if v_allowed is null then
    raise exception 'Please wait 15 seconds before submitting again';
  end if;

  insert into public.scores(nickname,score,mayama_clears,max_chain,player_id)
  values (btrim(p_nickname),p_score,p_mayama_clears,p_max_chain,p_player_id);
  return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.submit_score(text,integer,integer,integer,uuid) from public;
grant execute on function public.submit_score(text,integer,integer,integer,uuid) to anon, authenticated;
