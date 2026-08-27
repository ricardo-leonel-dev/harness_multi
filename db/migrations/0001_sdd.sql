-- Migration 0001: add SDD (spec-driven development) support to an
-- already-deployed Postgres mirror (one that had db/schema.postgres.sql
-- applied before this change existed).
--
-- Safe to re-run: every statement is defensive against already-applied
-- state (IF NOT EXISTS / IF EXISTS guards throughout).
--
-- Also apply db/rpc/upsert_feature.sql (updated, adds p_sdd) and the new
-- db/rpc/upsert_spec.sql after this file — a schema-only migration isn't
-- enough on its own, the RPC functions need to match.
--
-- IMPORTANT: run this file's statements as top-level statements, not
-- batched inside an explicit BEGIN...COMMIT block. ALTER TYPE ... ADD VALUE
-- cannot run inside a transaction block on Postgres versions before 12, and
-- even on 12+, a value added in a transaction can't be used by a later
-- statement in that SAME transaction. Running via `psql -f` or the Supabase
-- SQL editor without wrapping in BEGIN/COMMIT already gives each statement
-- its own implicit transaction, which is exactly what's needed here.

alter table features add column if not exists sdd boolean not null default false;

alter type feature_status add value if not exists 'spec_drafting';
alter type feature_status add value if not exists 'spec_ready';

do $$ begin
  if not exists (select 1 from pg_type where typname = 'spec_status') then
    create type spec_status as enum ('drafting', 'ready', 'approved');
  end if;
end $$;

create table if not exists specs (
  id bigserial primary key,
  project_id uuid not null references projects(id) on delete cascade,
  local_id bigint not null,
  feature_id bigint not null references features(id) on delete cascade,
  path text not null,
  status spec_status not null default 'drafting',
  requirements_count integer,
  tasks_count integer,
  drafted_by text,
  ready_at timestamptz,
  approved_at timestamptz,
  approved_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index if not exists specs_local_id on specs (project_id, local_id);
create unique index if not exists specs_feature_active on specs (feature_id) where deleted_at is null;
create index if not exists idx_specs_feature on specs (feature_id);

create or replace view active_specs as select * from specs where deleted_at is null;

-- PostgREST caches the schema at startup and after each DDL-triggering
-- migration — without this, upsert_feature/upsert_spec 404 with "Could not
-- find the function in the schema cache" even though the SQL above
-- succeeded. Also re-apply db/rpc/upsert_feature.sql and db/rpc/upsert_spec.sql
-- (see header note) before or after this NOTIFY; either order works, but
-- reload again if you run this file before the RPC files.
NOTIFY pgrst, 'reload schema';
