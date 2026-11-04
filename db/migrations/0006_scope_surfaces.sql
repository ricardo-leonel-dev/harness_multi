-- Migration 0006: mirror the scope fields (out-of-scope lines and checked edit
-- surfaces) to an already-deployed Postgres mirror. Fresh installs get them
-- from db/schema.postgres.sql.
--
--   features:    out_of_scope (JSON array of 0-5 lines: behaviour the change
--                must not add; '[]' = none, as in SQLite).
--   session_log: surfaces (JSON array of path globs the change may touch;
--                NULL = not declared yet, as in SQLite) and surfaces_required
--                (false = the session opened before surfaces existed, so
--                log-out only warns).
--
-- Safe to re-run. Apply db/rpc/upsert_feature.sql and db/rpc/upsert_session.sql
-- after this file (each drops its previous signature first). Until they are
-- applied, sync_postgres.sh retries each row without the new fields and
-- [WARN]s once, so nothing else stops syncing.

alter table features add column if not exists out_of_scope jsonb not null default '[]'::jsonb;

alter table session_log add column if not exists surfaces jsonb;
-- Rows that exist when the column is added predate surfaces: false. The
-- default then becomes true, matching SQLite (a new session must declare them).
-- The guard keeps a re-run from touching the default (already true) or rows.
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = current_schema() and table_name = 'session_log'
                   and column_name = 'surfaces_required') then
    alter table session_log add column surfaces_required boolean not null default false;
    alter table session_log alter column surfaces_required set default true;
  end if;
end;
$$;

-- `select *` views freeze their column list when created: re-create them so
-- the new columns show up (create or replace may only append columns, which
-- is all this does).
create or replace view active_features as select * from features where deleted_at is null;
create or replace view active_sessions as select * from session_log where deleted_at is null;

notify pgrst, 'reload schema';
