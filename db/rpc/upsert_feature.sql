-- Upserts one feature row from the SQLite primary into the mirror, keyed by
-- (project slug, local_id) so re-syncing an already soft-deleted row updates
-- it in place instead of inserting a duplicate. Exposed via
-- POST /rest/v1/rpc/upsert_feature. Soft delete propagates by passing
-- p_deleted_at instead of a hard DELETE.
create or replace function upsert_feature(
  p_project_slug text,
  p_local_id bigint,
  p_feature_number integer,
  p_name text,
  p_title text,
  p_description text,
  p_acceptance text[],
  p_status feature_status,
  p_sdd boolean default false,
  p_deleted_at timestamptz default null
) returns features
language plpgsql as $$
declare
  v_project_id uuid;
  result features;
begin
  select id into v_project_id from projects where slug = p_project_slug and deleted_at is null;
  if v_project_id is null then
    raise exception 'unknown or deleted project slug: %', p_project_slug;
  end if;

  insert into features (project_id, local_id, feature_number, name, title, description, acceptance, sdd, status, deleted_at)
    values (v_project_id, p_local_id, p_feature_number, p_name, p_title, p_description, p_acceptance, p_sdd, p_status, p_deleted_at)
  on conflict (project_id, local_id)
    do update set
      feature_number = excluded.feature_number,
      name = excluded.name,
      title = excluded.title,
      description = excluded.description,
      acceptance = excluded.acceptance,
      sdd = excluded.sdd,
      status = excluded.status,
      deleted_at = excluded.deleted_at,
      updated_at = now()
  returning * into result;
  return result;
end;
$$;
