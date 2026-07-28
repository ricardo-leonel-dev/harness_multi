-- Upserts one session_log row from the SQLite primary into the mirror,
-- keyed by (project slug, local_id) — idempotent regardless of open/closed
-- or deleted state. Feature is resolved by name (nullable, for bootstrap
-- entries with no associated feature). Exposed via
-- POST /rest/v1/rpc/upsert_session.
create or replace function upsert_session(
  p_project_slug text,
  p_local_id bigint,
  p_feature_name text default null,
  p_agent text default 'unknown',
  p_plan text[] default '{}',
  p_next_step text[] default '{}',
  p_changes text[] default null,
  p_verification text default null,
  p_closure text default null,
  p_started_at timestamptz default now(),
  p_closed_at timestamptz default null,
  p_deleted_at timestamptz default null
) returns session_log
language plpgsql as $$
declare
  v_project_id uuid;
  v_feature_id bigint;
  result session_log;
begin
  select id into v_project_id from projects where slug = p_project_slug and deleted_at is null;
  if v_project_id is null then
    raise exception 'unknown or deleted project slug: %', p_project_slug;
  end if;

  if p_feature_name is not null then
    select id into v_feature_id from features
      where project_id = v_project_id and name = p_feature_name and deleted_at is null;
  end if;

  insert into session_log (project_id, local_id, feature_id, agent, plan, next_step,
                            changes, verification, closure, started_at, closed_at, deleted_at)
    values (v_project_id, p_local_id, v_feature_id, p_agent, p_plan, p_next_step,
            p_changes, p_verification, p_closure, p_started_at, p_closed_at, p_deleted_at)
  on conflict (project_id, local_id)
    do update set
      feature_id = excluded.feature_id,
      agent = excluded.agent,
      plan = excluded.plan,
      next_step = excluded.next_step,
      changes = excluded.changes,
      verification = excluded.verification,
      closure = excluded.closure,
      closed_at = excluded.closed_at,
      deleted_at = excluded.deleted_at
  returning * into result;
  return result;
end;
$$;

-- Companion RPC for the append-only "## Log" entries of an open session.
-- Exposed via POST /rest/v1/rpc/upsert_session_entry.
create or replace function upsert_session_entry(
  p_project_slug text,
  p_session_local_id bigint,
  p_local_id bigint,
  p_entry text,
  p_created_at timestamptz default now(),
  p_deleted_at timestamptz default null
) returns session_log_entries
language plpgsql as $$
declare
  v_project_id uuid;
  v_session_id bigint;
  result session_log_entries;
begin
  select id into v_project_id from projects where slug = p_project_slug and deleted_at is null;
  if v_project_id is null then
    raise exception 'unknown or deleted project slug: %', p_project_slug;
  end if;

  select id into v_session_id from session_log
    where project_id = v_project_id and local_id = p_session_local_id;
  if v_session_id is null then
    raise exception 'session with local_id % not yet synced for project %', p_session_local_id, p_project_slug;
  end if;

  insert into session_log_entries (session_id, local_id, entry, created_at, deleted_at)
    values (v_session_id, p_local_id, p_entry, p_created_at, p_deleted_at)
  on conflict (session_id, local_id)
    do update set entry = excluded.entry, deleted_at = excluded.deleted_at
  returning * into result;
  return result;
end;
$$;
