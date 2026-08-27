-- Harness mirror store (Postgres, hosted on Supabase or a local/self-hosted
-- instance fronted by PostgREST). Optional and best-effort: nothing about the
-- harness's correctness depends on this schema being reachable. Table/column
-- names mirror db/schema.sqlite.sql (the actual local primary) so syncing is
-- a near-mechanical row copy.

create extension if not exists pgcrypto; -- for gen_random_uuid()

create table projects (
  id uuid primary key default gen_random_uuid(),
  slug text not null,
  description text,
  one_feature_at_a_time boolean not null default true,
  require_tests_to_close boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index projects_slug_active on projects (slug) where deleted_at is null;

create type feature_status as enum ('pending', 'spec_drafting', 'spec_ready', 'in_progress', 'done', 'blocked');

create table features (
  id bigserial primary key,
  project_id uuid not null references projects(id) on delete cascade,
  local_id bigint not null,   -- features.id from the SQLite primary; lets sync upsert idempotently regardless of delete state
  feature_number integer not null,
  name text not null,
  title text not null,
  description text,
  acceptance text[] not null default '{}',
  sdd boolean not null default false,   -- opt-in: does this feature require an approved spec first?
  status feature_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index features_local_id on features (project_id, local_id);
create unique index features_number_active on features (project_id, feature_number) where deleted_at is null;
create unique index features_name_active on features (project_id, name) where deleted_at is null;

-- Mirrors the SQLite primary's "at most one in_progress" guarantee.
create unique index one_in_progress_per_project on features (project_id)
  where status = 'in_progress' and deleted_at is null;

create table session_log (
  id bigserial primary key,
  project_id uuid not null references projects(id) on delete cascade,
  local_id bigint not null,   -- session_log.id from the SQLite primary; lets sync upsert idempotently
  feature_id bigint references features(id) on delete set null,
  agent text not null,
  plan text[] default '{}',
  next_step text[] default '{}',
  changes text[],
  verification text,
  closure text,
  started_at timestamptz not null default now(),
  closed_at timestamptz,
  deleted_at timestamptz
);

create unique index session_log_local_id on session_log (project_id, local_id);
create unique index one_open_session_per_project on session_log (project_id)
  where closed_at is null and deleted_at is null;

create table session_log_entries (
  id bigserial primary key,
  session_id bigint not null references session_log(id) on delete cascade,
  local_id bigint not null,   -- session_log_entries.id from the SQLite primary
  entry text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index session_log_entries_local_id on session_log_entries (session_id, local_id);

-- Metadata about a feature's spec-driven-development artifacts, mirroring
-- SQLite's specs table. Content (requirements.md/design.md/tasks.md) is
-- never mirrored here — only lifecycle metadata, same "files stay local"
-- boundary as everywhere else in this mirror (src/, tests/, specs/ are
-- never synced; only features/sessions/specs state is).
create type spec_status as enum ('drafting', 'ready', 'approved');

create table specs (
  id bigserial primary key,
  project_id uuid not null references projects(id) on delete cascade,
  local_id bigint not null,   -- specs.id from the SQLite primary
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

create unique index specs_local_id on specs (project_id, local_id);
create unique index specs_feature_active on specs (feature_id) where deleted_at is null;

create index idx_features_project_status on features (project_id, status);
create index idx_session_log_project_closed on session_log (project_id, closed_at);
create index idx_session_entries_session on session_log_entries (session_id, created_at);
create index idx_specs_feature on specs (feature_id);

-- Convenience views so the mirror's default read path ignores soft-deleted rows.
create view active_features as select * from features where deleted_at is null;
create view active_sessions as select * from session_log where deleted_at is null;
create view active_specs as select * from specs where deleted_at is null;
