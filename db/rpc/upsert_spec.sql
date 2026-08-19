-- Upserts one spec metadata row from the SQLite primary into the mirror,
-- keyed by (project slug, local_id) — same idempotent-upsert shape as
-- upsert_feature/upsert_session. Feature is resolved by name (not
-- nullable here — a specs row never exists without a feature). Content
-- (requirements.md/design.md/tasks.md) is never part of this payload; only
-- lifecycle metadata is mirrored. Exposed via POST /rest/v1/rpc/upsert_spec.
create or replace function upsert_spec(
  p_project_slug text,
  p_local_id bigint,
  p_feature_name text,
  p_path text,
  p_status spec_status default 'drafting',
  p_requirements_count integer default null,
  p_tasks_count integer default null,
  p_drafted_by text default null,
  p_ready_at timestamptz default null,
  p_approved_at timestamptz default null,
  p_approved_by text default null,
  p_deleted_at timestamptz default null
) returns specs
language plpgsql as $$
declare
  v_project_id uuid;
  v_feature_id bigint;
  result specs;
begin
  select id into v_project_id from projects where slug = p_project_slug and deleted_at is null;
  if v_project_id is null then
    raise exception 'unknown or deleted project slug: %', p_project_slug;
  end if;

  select id into v_feature_id from features
    where project_id = v_project_id and name = p_feature_name and deleted_at is null;
  if v_feature_id is null then
    raise exception 'feature % not yet synced for project %', p_feature_name, p_project_slug;
  end if;

  insert into specs (project_id, local_id, feature_id, path, status, requirements_count, tasks_count,
                      drafted_by, ready_at, approved_at, approved_by, deleted_at)
    values (v_project_id, p_local_id, v_feature_id, p_path, p_status, p_requirements_count, p_tasks_count,
            p_drafted_by, p_ready_at, p_approved_at, p_approved_by, p_deleted_at)
  on conflict (project_id, local_id)
    do update set
      feature_id = excluded.feature_id,
      path = excluded.path,
      status = excluded.status,
      requirements_count = excluded.requirements_count,
      tasks_count = excluded.tasks_count,
      drafted_by = excluded.drafted_by,
      ready_at = excluded.ready_at,
      approved_at = excluded.approved_at,
      approved_by = excluded.approved_by,
      deleted_at = excluded.deleted_at,
      updated_at = now()
  returning * into result;
  return result;
end;
$$;
