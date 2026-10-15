-- Upserts one agent_runs row from the SQLite primary into the mirror, keyed
-- by (project slug, local_id) — idempotent regardless of deleted state.
-- Session and feature are resolved by their local ids (both nullable: a run
-- outside every harness session has neither). Requires session_log/features
-- rows to be synced first (sync_postgres.sh does sessions before agent runs).
-- Exposed via POST /rest/v1/rpc/upsert_agent_run.
create or replace function upsert_agent_run(
  p_project_slug text,
  p_local_id bigint,
  p_runtime text,
  p_external_id text,
  p_session_local_id bigint default null,
  p_feature_local_id bigint default null,
  p_agent_role text default null,
  p_label text default null,
  p_parent_external_id text default null,
  p_spawn_depth integer default null,
  p_model text default null,
  p_started_at timestamptz default null,
  p_finished_at timestamptz default null,
  p_duration_seconds double precision default null,
  p_input_tokens bigint default null,
  p_cache_read_tokens bigint default null,
  p_cache_write_tokens bigint default null,
  p_output_tokens bigint default null,
  p_reasoning_tokens bigint default null,
  p_total_tokens bigint default null,
  p_deleted_at timestamptz default null
) returns agent_runs
language plpgsql as $$
declare
  v_project_id uuid;
  v_session_id bigint;
  v_feature_id bigint;
  result agent_runs;
begin
  select id into v_project_id from projects where slug = p_project_slug and deleted_at is null;
  if v_project_id is null then
    raise exception 'unknown or deleted project slug: %', p_project_slug;
  end if;

  if p_session_local_id is not null then
    select id into v_session_id from session_log
      where project_id = v_project_id and local_id = p_session_local_id;
  end if;
  if p_feature_local_id is not null then
    select id into v_feature_id from features
      where project_id = v_project_id and local_id = p_feature_local_id;
  end if;

  insert into agent_runs (project_id, local_id, session_id, feature_id, runtime, agent_role, label,
                          external_id, parent_external_id, spawn_depth, model, started_at, finished_at,
                          duration_seconds, input_tokens, cache_read_tokens, cache_write_tokens,
                          output_tokens, reasoning_tokens, total_tokens, deleted_at)
    values (v_project_id, p_local_id, v_session_id, v_feature_id, p_runtime, p_agent_role, p_label,
            p_external_id, p_parent_external_id, p_spawn_depth, p_model, p_started_at, p_finished_at,
            p_duration_seconds, p_input_tokens, p_cache_read_tokens, p_cache_write_tokens,
            p_output_tokens, p_reasoning_tokens, p_total_tokens, p_deleted_at)
  on conflict (project_id, local_id)
    do update set
      session_id = excluded.session_id,
      feature_id = excluded.feature_id,
      runtime = excluded.runtime,
      agent_role = excluded.agent_role,
      label = excluded.label,
      external_id = excluded.external_id,
      parent_external_id = excluded.parent_external_id,
      spawn_depth = excluded.spawn_depth,
      model = excluded.model,
      started_at = excluded.started_at,
      finished_at = excluded.finished_at,
      duration_seconds = excluded.duration_seconds,
      input_tokens = excluded.input_tokens,
      cache_read_tokens = excluded.cache_read_tokens,
      cache_write_tokens = excluded.cache_write_tokens,
      output_tokens = excluded.output_tokens,
      reasoning_tokens = excluded.reasoning_tokens,
      total_tokens = excluded.total_tokens,
      updated_at = now(),
      deleted_at = excluded.deleted_at
  returning * into result;
  return result;
end;
$$;

notify pgrst, 'reload schema';
