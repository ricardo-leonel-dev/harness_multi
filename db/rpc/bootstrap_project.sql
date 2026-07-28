-- Idempotent upsert of a project row, exposed via PostgREST at
-- POST /rest/v1/rpc/bootstrap_project. Called once by install.sh, and
-- safe to re-run (e.g. on harness_version bumps).
create or replace function bootstrap_project(
  p_slug text,
  p_description text default null,
  p_one_feature_at_a_time boolean default true,
  p_require_tests_to_close boolean default true
) returns projects
language plpgsql as $$
declare
  result projects;
begin
  insert into projects (slug, description, one_feature_at_a_time, require_tests_to_close)
    values (p_slug, p_description, p_one_feature_at_a_time, p_require_tests_to_close)
  on conflict (slug) where deleted_at is null
    do update set
      description = excluded.description,
      one_feature_at_a_time = excluded.one_feature_at_a_time,
      require_tests_to_close = excluded.require_tests_to_close,
      updated_at = now()
  returning * into result;
  return result;
end;
$$;
